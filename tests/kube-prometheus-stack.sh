#!/usr/bin/env bash
# kube-prometheus-stack pass check: operator, Prometheus, Alertmanager, Grafana, node-exporter and
# kube-state-metrics are ready; the volumes are Bound on Longhorn; the scrape targets are up; Grafana's
# Prometheus and Loki data sources are healthy; the route is accepted and answers; tenants cannot create
# ServiceMonitors.
#
#   ./tests/kube-prometheus-stack.sh
#   NS=monitoring HOST=grafana-k8s.jodywan.com TRAEFIK=10.1.5.170 ./tests/kube-prometheus-stack.sh
#
# Read-only. Uses port-forwards (local ports 19090 and 13000). The Grafana admin password is read from the
# cluster at run time and is never printed. The browser login is a manual check (docs/kube-prometheus-stack.md).
set -uo pipefail
NS="${NS:-monitoring}"
REL="${REL:-kube-prometheus-stack}"
HOST="${HOST:-grafana-k8s.jodywan.com}"
TRAEFIK="${TRAEFIK:-10.1.5.170}"
PASS=0; FAIL=0
ok()   { printf '  PASS  %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n' "$*"; FAIL=$((FAIL+1)); }
step() { printf '\n== %s\n' "$*"; }
PIDS=()
cleanup() { for p in "${PIDS[@]:-}"; do [ -n "$p" ] && kill "$p" >/dev/null 2>&1; done; }
trap cleanup EXIT

step "1. workloads and volumes"
GNS="${GNS:-grafana}"     # Grafana has its own namespace and its own app (docs/grafana.md)
R=$(kubectl -n "$GNS" get deploy grafana -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[ "${R:-0}" -ge 1 ] && ok "deployment grafana ready (namespace $GNS)" || bad "deployment grafana not ready (namespace $GNS)"
for d in "$REL-operator" "$REL-kube-state-metrics"; do
  R=$(kubectl -n "$NS" get deploy "$d" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  [ "${R:-0}" -ge 1 ] && ok "deployment $d ready" || bad "deployment $d not ready"
done
for s in "prometheus-$REL-prometheus" "alertmanager-$REL-alertmanager"; do
  R=$(kubectl -n "$NS" get sts "$s" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  [ "${R:-0}" -ge 1 ] && ok "statefulset $s ready" || bad "statefulset $s not ready"
done
DES=$(kubectl -n "$NS" get ds "$REL-prometheus-node-exporter" -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null)
RDY=$(kubectl -n "$NS" get ds "$REL-prometheus-node-exporter" -o jsonpath='{.status.numberReady}' 2>/dev/null)
NODES=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
[ "${RDY:-0}" = "$NODES" ] && [ "$DES" = "$NODES" ] && ok "node-exporter ready on all $NODES nodes" || bad "node-exporter ready $RDY of $DES (nodes: $NODES)"
BAD=$(kubectl -n "$NS" get pvc --no-headers 2>/dev/null | awk '$2!="Bound" || $6!="longhorn"{print $1}' | tr '\n' ' ')
N=$(kubectl -n "$NS" get pvc --no-headers 2>/dev/null | wc -l)
[ "$N" -ge 3 ] && [ -z "$BAD" ] && ok "$N volumes Bound on class longhorn" || bad "volumes: $N, not Bound or not longhorn: $BAD"
RT=$(kubectl -n "$NS" get pods -o json | python3 -I -c 'import json,sys; print(sum(c["restartCount"] for p in json.load(sys.stdin)["items"] for c in p["status"].get("containerStatuses",[])))')
[ "${RT:-1}" -eq 0 ] && ok "no container restarts" || bad "containers restarted $RT times (OOMKilled? check the limits)"

step "2. Prometheus targets"
kubectl -n "$NS" port-forward "svc/$REL-prometheus" 19090:9090 >/dev/null 2>&1 & PIDS+=($!)
sleep 3
T=$(curl -s -m 15 http://127.0.0.1:19090/api/v1/targets?state=active)
SUMMARY=$(echo "$T" | python3 -I -c '
import json,sys
try: d=json.load(sys.stdin)["data"]["activeTargets"]
except Exception: print("ERR"); sys.exit()
by={}
for t in d:
    j=t["labels"].get("job","?"); by.setdefault(j,[0,0]); by[j][0]+=1; by[j][1]+= t["health"]=="up"
for j,(n,u) in sorted(by.items()): print("%s %d %d"%(j,n,u))')
if [ "$SUMMARY" = "ERR" ] || [ -z "$SUMMARY" ]; then bad "could not read targets from Prometheus"; else
  echo "$SUMMARY" | while read -r j n u; do echo "    $j: $u of $n up"; done
  DOWN=$(echo "$SUMMARY" | awk '$2!=$3{print $1}' | tr '\n' ' ')
  [ -z "$DOWN" ] && ok "all scrape targets up" || bad "targets down in job(s): $DOWN"
  echo "$SUMMARY" | awk '$1=="node-exporter"{exit !($3>=6)}' && ok "node-exporter: one target per node" || bad "node-exporter targets fewer than 6"
fi
A=$(curl -s -m 15 http://127.0.0.1:19090/api/v1/alerts | python3 -I -c '
import json,sys
a=[x["labels"]["alertname"] for x in json.load(sys.stdin)["data"]["alerts"] if x["state"]=="firing"]
print(" ".join(sorted(set(a))))' 2>/dev/null)
echo "  firing alerts: ${A:-none}"
case " $A " in *" Watchdog "*) ok "Watchdog alert fires (the alerting pipeline is alive)";; *) bad "Watchdog is not firing";; esac

step "3. Grafana and its data sources"
kubectl -n "$GNS" port-forward svc/grafana 13000:80 >/dev/null 2>&1 & PIDS+=($!)
sleep 3
H=$(curl -s -m 10 -o /dev/null -w '%{http_code}' http://127.0.0.1:13000/api/health)
[ "$H" = "200" ] && ok "Grafana /api/health returns 200" || bad "Grafana /api/health returned $H"
GA=$(kubectl -n argocd get application grafana -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null)
[ "$GA" = "Synced/Healthy" ] && ok "Grafana is its own Argo CD app (grafana): $GA" || bad "Argo CD application grafana is '$GA' (docs/grafana.md)"
AU=$(kubectl -n "$GNS" get secret grafana-admin -o jsonpath='{.data.admin-user}' 2>/dev/null | base64 -d)
AP=$(kubectl -n "$GNS" get secret grafana-admin -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d)
if [ -z "$AU" ] || [ -z "$AP" ]; then bad "Secret grafana-admin missing or incomplete"; else
  for uid in prometheus loki; do
    C=$(curl -s -m 20 -o /dev/null -w '%{http_code}' -u "$AU:$AP" "http://127.0.0.1:13000/api/datasources/uid/$uid/health")
    [ "$C" = "200" ] && ok "data source '$uid' is healthy" || bad "data source '$uid' health returned $C"
  done
  DB=$(curl -s -m 20 -u "$AU:$AP" "http://127.0.0.1:13000/api/search?type=dash-db" | python3 -I -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null)
  [ "${DB:-0}" -ge 10 ] && ok "default dashboards loaded ($DB)" || bad "only ${DB:-0} dashboards loaded (sidecar?)"
  TD=$(curl -s -m 20 -u "$AU:$AP" "http://127.0.0.1:13000/api/search?query=Traefik" | python3 -I -c 'import json,sys; print(sum(1 for d in json.load(sys.stdin) if d["title"].startswith("Traefik")))' 2>/dev/null)
  [ "${TD:-0}" -ge 1 ] && ok "Traefik dashboard is provisioned (dashboards/platform)" || bad "Traefik dashboard missing (ConfigMap platform-dashboard-traefik, sidecar?)"
  JD=$(curl -s -m 20 -u "$AU:$AP" "http://127.0.0.1:13000/api/search?query=Jaeger" | python3 -I -c 'import json,sys; print(sum(1 for d in json.load(sys.stdin) if d["title"].startswith("Jaeger")))' 2>/dev/null)
  [ "${JD:-0}" -ge 1 ] && ok "Jaeger dashboard is provisioned (dashboards/platform)" || bad "Jaeger dashboard missing (ConfigMap platform-dashboard-jaeger, sidecar?)"
  TS=$(curl -s -m 20 -G -u "$AU:$AP" "http://127.0.0.1:13000/api/datasources/proxy/uid/prometheus/api/v1/query" --data-urlencode 'query=count({__name__=~"traefik_entrypoint_requests_total"})' | python3 -I -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else 0)' 2>/dev/null)
  [ "${TS:-0}" -ge 1 ] && ok "Traefik metrics are in Prometheus (PodMonitor traefik)" || bad "no traefik_entrypoint_requests_total series (PodMonitor? Traefik metrics port?)"
fi
unset AU AP

step "4. route"
[ "$(kubectl get ns "$GNS" -o jsonpath='{.metadata.labels.gateway-access}' 2>/dev/null)" = "platform" ] \
  && ok "namespace $GNS labelled gateway-access=platform" || bad "namespace $GNS not labelled gateway-access=platform"
ACC=$(kubectl -n "$GNS" get httproute grafana -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null)
[ "$ACC" = "True" ] && ok "HTTPRoute accepted by the Gateway" || bad "HTTPRoute not accepted (Accepted=$ACC)"
CODE=$(curl -s -o /dev/null -m 10 -w '%{http_code}' --resolve "$HOST:80:$TRAEFIK" "http://$HOST/login")
[ "$CODE" = "200" ] && ok "login page answers through Traefik (HTTP $CODE)" || bad "login page did not answer through Traefik (HTTP $CODE)"
PCODE=$(curl -s -o /dev/null -m 15 -w '%{http_code}' "https://$HOST/login")
[ "$PCODE" = "200" ] && ok "login page answers on the public HTTPS URL" || echo "  NOTE  public https://$HOST/login returned HTTP $PCODE (DNS and HAProxy not set up yet?)"

step "5. tenants and CRDs"
for t in "zeedlogic-dev dev@zeedlogic.com oidc:zeedlogic-developers" "jodywan-dev dev@jodywan.dev oidc:jodywan-developers"; do
  set -- $t
  for r in servicemonitors.monitoring.coreos.com prometheusrules.monitoring.coreos.com; do
    kubectl auth can-i create "$r" -n "$1" --as="$2" --as-group="$3" >/dev/null 2>&1 \
      && bad "$2 can create $r in $1" || ok "$2 cannot create $r in $1"
  done
done
echo "  NOTE  tenant network isolation and the per-tenant Grafana organizations are checked by tests/tenant-network.sh"
echo "        and tests/tenant-observability.sh (docs/tenant-network.md, docs/tenant-observability.md)."

step "result"
echo "  passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] && echo "  KUBE-PROMETHEUS-STACK BASIC CHECK: OK" || echo "  KUBE-PROMETHEUS-STACK BASIC CHECK: FAILED"
[ "$FAIL" -eq 0 ]
