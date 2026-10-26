#!/usr/bin/env bash
# Thanos pass check: Querier, Store Gateway and Compactor are ready with Bound volumes, the sidecar runs in the
# Prometheus pod, the Querier sees the sidecar and the Store Gateway and returns data with the `cluster` label,
# the Compactor is not halted, and the Garage bucket `thanos` exists with its quota (and holds blocks once the
# first 2 h block was uploaded).
#
#   ./tests/thanos.sh
#   NS=monitoring BUCKET=thanos ./tests/thanos.sh
#
# Read-only. Uses a port-forward to the Querier (local port 19191) and `kubectl exec` into garage-0.
set -uo pipefail
NS="${NS:-monitoring}"
REL="${REL:-thanos}"
BUCKET="${BUCKET:-thanos}"
PORT="${PORT:-19191}"
PASS=0; FAIL=0
ok()   { printf '  PASS  %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n' "$*"; FAIL=$((FAIL+1)); }
note() { printf '  NOTE  %s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
PF=""
trap '[ -n "$PF" ] && kill "$PF" >/dev/null 2>&1' EXIT

step "1. workloads and volumes"
R=$(kubectl -n "$NS" get deploy "$REL-query" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[ "${R:-0}" -ge 1 ] && ok "Querier ready" || bad "Querier not ready"
for s in "$REL-store-gateway" "$REL-compact"; do
  R=$(kubectl -n "$NS" get sts "$s" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  [ "${R:-0}" -ge 1 ] && ok "statefulset $s ready" || bad "statefulset $s not ready"
done
BADP=$(kubectl -n "$NS" get pvc --no-headers 2>/dev/null | grep -E "$REL" | awk '$2!="Bound"{print $1}' | tr '\n' ' ')
NP=$(kubectl -n "$NS" get pvc --no-headers 2>/dev/null | grep -c "$REL")
[ "$NP" -ge 2 ] && [ -z "$BADP" ] && ok "$NP Thanos volumes Bound" || bad "Thanos volumes: $NP, not Bound: $BADP"
kubectl -n "$NS" get secret thanos-objstore >/dev/null 2>&1 && ok "Secret thanos-objstore exists" || bad "Secret thanos-objstore missing"
RT=$(kubectl -n "$NS" get pods -o json | python3 -I -c 'import json,sys; print(sum(c["restartCount"] for p in json.load(sys.stdin)["items"] if "thanos" in p["metadata"]["name"] for c in p["status"].get("containerStatuses",[])))')
[ "${RT:-1}" -eq 0 ] && ok "no Thanos container restarts" || bad "Thanos containers restarted $RT times (OOMKilled?)"

step "2. sidecar in the Prometheus pod"
SC=$(kubectl -n "$NS" get pod prometheus-kube-prometheus-stack-prometheus-0 -o jsonpath='{.status.containerStatuses[?(@.name=="thanos-sidecar")].ready}' 2>/dev/null)
[ "$SC" = "true" ] && ok "thanos-sidecar container ready" || bad "thanos-sidecar not ready (Secret missing? stack not synced?)"
RET=$(kubectl -n "$NS" get prometheus kube-prometheus-stack-prometheus -o jsonpath='{.spec.retention}' 2>/dev/null)
[ "$RET" = "12h" ] && ok "Prometheus local retention is 12h" || bad "Prometheus retention is '$RET' (expected 12h)"

step "3. Querier"
kubectl -n "$NS" port-forward "svc/$REL-query" "$PORT:10902" >/dev/null 2>&1 & PF=$!
sleep 3
ST=$(curl -s -m 15 "http://127.0.0.1:$PORT/api/v1/stores" | python3 -I -c '
import json,sys
try: d=json.load(sys.stdin)["data"]
except Exception: print("ERR"); sys.exit()
print(" ".join("%s=%d"%(k,len(v)) for k,v in sorted(d.items())))' 2>/dev/null)
echo "  stores: ${ST:-none}"
case "$ST" in *sidecar=[1-9]*) ok "Querier sees the sidecar";; *) bad "Querier does not see the sidecar";; esac
case "$ST" in *store=[1-9]*) ok "Querier sees the Store Gateway";; *) bad "Querier does not see the Store Gateway";; esac
Q=$(curl -s -m 20 -G "http://127.0.0.1:$PORT/api/v1/query" --data-urlencode 'query=count(up) by (cluster)')
echo "$Q" | grep -q '"cluster":"k8s-1"' && ok "query returns data with label cluster=k8s-1" || bad "no data with cluster=k8s-1 (externalLabels? sidecar?)"
H=$(curl -s -m 10 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/-/ready")
[ "$H" = "200" ] && ok "Querier /-/ready 200" || bad "Querier /-/ready returned $H"

step "4. Compactor"
HALT=$(kubectl get --raw "/api/v1/namespaces/$NS/pods/$REL-compact-0:10902/proxy/metrics" 2>/dev/null | awk '/^thanos_compact_halted /{print $2}')
[ "${HALT:-x}" = "0" ] && ok "compactor not halted (thanos_compact_halted 0)" || bad "compactor halted or metric missing (thanos_compact_halted='${HALT:-none}')"
ERR=$(kubectl -n "$NS" logs "sts/$REL-compact" --tail=100 2>/dev/null | grep -c -i -E 'level=error|halt|error:|unknown (long )?flag')
[ "${ERR:-0}" -eq 0 ] && ok "no errors in the compactor log" || bad "$ERR error lines in the compactor log"

step "5. Garage bucket"
INFO=$(kubectl -n garage exec garage-0 -c garage -- /garage bucket info "$BUCKET" 2>/dev/null)
echo "$INFO" | grep -q 'maximum size' && ok "bucket $BUCKET exists with a size quota" || bad "bucket $BUCKET missing or without quota"
OBJ=$(echo "$INFO" | awk '/^Objects:/{print $2}')
SIZE=$(echo "$INFO" | awk '/^Size:/{print $2,$3}')
echo "  bucket: $OBJ objects, $SIZE"
UP=$(kubectl -n "$NS" get pod prometheus-kube-prometheus-stack-prometheus-0 -o jsonpath='{.status.startTime}' 2>/dev/null)
AGE=$(( $(date +%s) - $(date -d "${UP:-now}" +%s) ))
if [ "${OBJ:-0}" -gt 0 ]; then ok "blocks have been uploaded ($OBJ objects)"
elif [ "$AGE" -lt 10800 ]; then note "no blocks yet: the first block is uploaded about 2 h after Prometheus started (it started $((AGE/60)) min ago)"
else bad "no objects in $BUCKET although Prometheus started $((AGE/60)) min ago (check the sidecar log and the Secret)"; fi

step "6. LAN access for the central Grafana (docker-2)"
LANIP=$(kubectl -n "$NS" get svc thanos-query-lan -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
if [ -z "$LANIP" ]; then note "Service thanos-query-lan has no address yet (not deployed?)"; else
  [ "$LANIP" = "10.1.5.172" ] && ok "thanos-query-lan has address $LANIP" || bad "thanos-query-lan has address $LANIP (expected 10.1.5.172)"
  EP=$(kubectl -n "$NS" get svc thanos-query-lan -o jsonpath='{.spec.externalTrafficPolicy}')
  [ "$EP" = "Local" ] && ok "externalTrafficPolicy is Local (source IP kept)" || bad "externalTrafficPolicy is '$EP'"
  kubectl -n "$NS" get networkpolicy thanos-query-ingress >/dev/null 2>&1 && ok "NetworkPolicy thanos-query-ingress exists" || bad "NetworkPolicy thanos-query-ingress missing"
  C=$(curl -s -m 8 -o /dev/null -w '%{http_code}' "http://$LANIP/-/ready" 2>/dev/null)
  case "$C" in 000|"") ok "this host is refused (not docker-2): no answer";; 200) bad "this host can reach the Querier on $LANIP (policy not applied?)";; *) note "this host got HTTP $C from $LANIP";; esac
fi

step "result"
echo "  passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] && echo "  THANOS BASIC CHECK: OK" || echo "  THANOS BASIC CHECK: FAILED"
[ "$FAIL" -eq 0 ]
