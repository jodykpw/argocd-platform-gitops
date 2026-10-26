#!/usr/bin/env bash
# Tenant observability check: each tenant's Grafana organization sees only its own metrics and logs.
#
#   ./tests/tenant-observability.sh                # after the data sources are provisioned (uids prometheus, loki)
#   TEMP=1 ./tests/tenant-observability.sh         # before the sync: creates temporary data sources (removed at the end)
#
# Everything goes through Grafana's own data source proxy as the admin account with the organization header, which is
# the same path a tenant user's browser takes. Creates two short-lived pods (zeedlogic-dev and jodywan-dev) that log a
# marker; removes them again.
set -uo pipefail
PASS=0; FAIL=0
ok()   { printf '  PASS  %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n' "$*"; FAIL=$((FAIL+1)); }
step() { printf '\n== %s\n' "$*"; }
PW=$(kubectl -n grafana get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d)
kubectl -n grafana port-forward svc/grafana 13998:80 >/dev/null 2>&1 & PF=$!
G=http://127.0.0.1:13998
PU=prometheus; LU=loki; [ -n "${TEMP:-}" ] && { PU=tt-prom; LU=tt-loki; }
declare -A ORG
cleanup() {
  if [ -n "${TEMP:-}" ]; then for t in zeedlogic jodywan; do
    for u in $PU $LU; do curl -s -u "admin:$PW" -H "X-Grafana-Org-Id: ${ORG[$t]:-0}" -X DELETE "$G/api/datasources/uid/$u" >/dev/null 2>&1; done; done; fi
  kubectl -n zeedlogic-dev delete pod tto-z --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl -n jodywan-dev delete pod tto-j --ignore-not-found --wait=false >/dev/null 2>&1
  kill $PF 2>/dev/null; unset PW
}
trap cleanup EXIT
until curl -s -m 2 $G/api/health >/dev/null; do sleep 1; done
A() { curl -s -m 30 -u "admin:$PW" "$@"; }

step "1. organizations"
for t in zeedlogic jodywan; do
  ORG[$t]=$(A "$G/api/orgs/name/$t" | python3 -I -c 'import json,sys;print(json.load(sys.stdin).get("id",""))')
  [ -n "${ORG[$t]}" ] && ok "organization $t exists (id ${ORG[$t]})" || bad "organization $t is missing (./tenant-observability/grafana-orgs.sh)"
done
[ "${ORG[zeedlogic]:-}" = 2 ] && [ "${ORG[jodywan]:-}" = 3 ] && ok "ids match the provisioned orgId values (2 and 3)" || bad "organization ids differ from 2 and 3: update orgId in the values"

if [ -n "${TEMP:-}" ]; then
  for t in zeedlogic jodywan; do
    A -X POST -H 'Content-Type: application/json' -H "X-Grafana-Org-Id: ${ORG[$t]}" "$G/api/datasources" -d "{\"name\":\"tt-prom\",\"uid\":\"$PU\",\"type\":\"prometheus\",\"access\":\"proxy\",\"url\":\"http://prom-label-proxy-$t.monitoring.svc.cluster.local:8080\"}" >/dev/null
    A -X POST -H 'Content-Type: application/json' -H "X-Grafana-Org-Id: ${ORG[$t]}" "$G/api/datasources" -d "{\"name\":\"tt-loki\",\"uid\":\"$LU\",\"type\":\"loki\",\"access\":\"proxy\",\"url\":\"http://loki.loki.svc.cluster.local:3100\",\"jsonData\":{\"httpHeaderName1\":\"X-Scope-OrgID\"},\"secureJsonData\":{\"httpHeaderValue1\":\"$t\"}}" >/dev/null
  done
fi

step "2. metrics: each organization sees only its own namespaces"
PQ() { # PQ <org> <promql> -> sorted namespaces, or ERR
  A -G -H "X-Grafana-Org-Id: $1" "$G/api/datasources/proxy/uid/$PU/api/v1/query" --data-urlencode "query=$2" \
   | python3 -I -c 'import json,sys
try: j=json.load(sys.stdin); r=j["data"]["result"]
except Exception: print("ERR"); sys.exit()
print(" ".join(sorted({x["metric"].get("namespace","(none)") for x in r})) or "(empty)")'; }
for t in zeedlogic jodywan; do
  other=$([ $t = zeedlogic ] && echo jodywan || echo zeedlogic); o=${ORG[$t]}
  got=$(PQ $o 'kube_namespace_status_phase == 1'); want="$t-dev $t-prod $t-stg"
  [ "$got" = "$want" ] && ok "$t org: namespaces are exactly $want" || bad "$t org: namespaces [$got], wanted [$want]"
  [ "$(PQ $o "kube_namespace_status_phase{namespace=\"$other-dev\"} == 1")" = "(empty)" ] && ok "$t org: cannot ask for $other-dev" || bad "$t org: reached $other-dev"
  [ "$(PQ $o 'kube_pod_info{namespace="monitoring"}')" = "(empty)" ] && ok "$t org: platform namespace monitoring is invisible" || bad "$t org: sees monitoring"
  [ "$(PQ $o 'node_load1')" = "(empty)" ] && ok "$t org: node metrics (no namespace label) are invisible" || bad "$t org: sees node metrics"
done

step "3. logs: each organization sees only its own tenant (marker pods)"
MZ="tto-z-$(date +%s)"; MJ="tto-j-$(date +%s)"
mkpod() { kubectl -n "$1" apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata: {name: $2}
spec:
  terminationGracePeriodSeconds: 0
  securityContext: {runAsNonRoot: true, runAsUser: 1000, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: c
      image: busybox:1.36
      command: ["sh","-c","while true; do echo $3; sleep 2; done"]
      resources: {requests: {cpu: 5m, memory: 8Mi}, limits: {cpu: 50m, memory: 32Mi}}
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
YAML
}
kubectl -n zeedlogic-dev delete pod tto-z --ignore-not-found --wait=true >/dev/null 2>&1; kubectl -n jodywan-dev delete pod tto-j --ignore-not-found --wait=true >/dev/null 2>&1
mkpod zeedlogic-dev tto-z "$MZ"; mkpod jodywan-dev tto-j "$MJ"
LQ() { # LQ <org> <logql> -> number of lines
  now=$(date +%s); A -G -H "X-Grafana-Org-Id: $1" "$G/api/datasources/proxy/uid/$LU/loki/api/v1/query_range" \
    --data-urlencode "query=$2" --data-urlencode "start=$((now-300))000000000" --data-urlencode "end=${now}000000000" --data-urlencode "limit=200" \
   | python3 -I -c 'import json,sys
try: j=json.load(sys.stdin); print(sum(len(s["values"]) for s in j["data"]["result"]))
except Exception: print("ERR")'; }
for i in $(seq 1 30); do [ "$(LQ ${ORG[zeedlogic]} "{namespace=\"zeedlogic-dev\"} |= \"$MZ\"")" -gt 0 ] 2>/dev/null && [ "$(LQ ${ORG[jodywan]} "{namespace=\"jodywan-dev\"} |= \"$MJ\"")" -gt 0 ] 2>/dev/null && break; sleep 4; done
z=$(LQ ${ORG[zeedlogic]} "{namespace=~\".+\"} |= \"$MZ\""); [ "${z:-0}" -gt 0 ] 2>/dev/null && ok "zeedlogic org reads its own log line" || bad "zeedlogic org did not find its marker ($z)"
z2=$(LQ ${ORG[zeedlogic]} "{namespace=~\".+\"} |= \"$MJ\""); [ "$z2" = 0 ] && ok "zeedlogic org cannot read jodywan's log line" || bad "zeedlogic org sees jodywan logs ($z2)"
j=$(LQ ${ORG[jodywan]} "{namespace=~\".+\"} |= \"$MJ\""); [ "${j:-0}" -gt 0 ] 2>/dev/null && ok "jodywan org reads its own log line" || bad "jodywan org did not find its marker ($j)"
j2=$(LQ ${ORG[jodywan]} "{namespace=~\".+\"} |= \"$MZ\""); [ "$j2" = 0 ] && ok "jodywan org cannot read zeedlogic's log line" || bad "jodywan org sees zeedlogic logs ($j2)"
p=$(LQ ${ORG[zeedlogic]} '{namespace="monitoring"}'); [ "$p" = 0 ] && ok "zeedlogic org cannot read platform logs (namespace monitoring)" || bad "zeedlogic org reads platform logs ($p)"
p2=$(LQ ${ORG[zeedlogic]} '{namespace=~".+"} |~ "level="'); echo "  note  zeedlogic org sees $p2 lines matching a broad query (own tenant only)"
# a client cannot choose the Loki tenant: an X-Scope-OrgID header in the request must not be forwarded
now=$(date +%s)
h=$(A -G -H "X-Grafana-Org-Id: ${ORG[zeedlogic]}" -H "X-Scope-OrgID: jodywan" "$G/api/datasources/proxy/uid/$LU/loki/api/v1/query_range" --data-urlencode "query={namespace=~\".+\"} |= \"$MJ\"" --data-urlencode "start=$((now-300))000000000" --data-urlencode "end=${now}000000000" | python3 -I -c 'import json,sys
try: j=json.load(sys.stdin); print(sum(len(s["values"]) for s in j["data"]["result"]))
except Exception: print("ERR")')
[ "$h" = 0 ] && ok "a client-supplied X-Scope-OrgID header does not change the tenant" || bad "the header override worked ($h)"

echo; echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] && echo "TENANT OBSERVABILITY CHECK: OK"
exit "$FAIL"
