#!/usr/bin/env bash
# ZeedLogic observability pass check for one environment namespace (default zeedlogic-dev): metrics, database metrics, logs, traces,
# dashboards, and the isolation of Jaeger.
#   1. Prometheus scrapes fastapi (job zeedlogic-fastapi) and Kong (job zeedlogic-kong) of the namespace, and the CNPG cluster
#   2. Loki holds recent lines of the namespace under the tenant's own X-Scope-OrgID
#   3. Jaeger knows a ZeedLogic service (traces arrive), read through the query API from the monitoring namespace
#   4. the ZeedLogic dashboards are provisioned: ConfigMaps exist and, if Grafana's admin password is in the pod, the platform
#      organization lists all five and the zeedlogic organization four
#   5. a pod in the namespace can SEND to Jaeger (4318) but cannot READ (16686); a pod in another tenant namespace cannot reach either
#
#   ./tests/zeedlogic-observability.sh
#   NS=zeedlogic-dev TENANT=zeedlogic OTHER=jodywan-stg ./tests/zeedlogic-observability.sh
#
# Creates and removes only short-lived curl pods (limits set: the tenant ResourceQuota requires them). Prints no secret.
set -uo pipefail
NS="${NS:-zeedlogic-dev}"
TENANT="${TENANT:-zeedlogic}"
OTHER="${OTHER:-jodywan-stg}"
CLUSTER_DB="${CLUSTER_DB:-$NS-pg}"
IMG="${IMG:-curlimages/curl:8.10.1}"
PASS=0; FAIL=0; OUT=""; PHASE=""
ok()   { printf '  PASS  %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n' "$*"; FAIL=$((FAIL+1)); }
step() { printf '\n== %s\n' "$*"; }
POD="zlobs-$$"
cleanup() { for n in monitoring "$NS" "$OTHER"; do kubectl -n "$n" delete pod "$POD" --ignore-not-found --wait=false >/dev/null 2>&1; done; }
trap cleanup EXIT

# prom <promql>: first value of an instant query through the API server's service proxy, or empty.
prom() {
  local q; q=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$1")
  kubectl get --raw "/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/query?query=$q" 2>/dev/null \
    | python3 -c 'import sys,json
try:
    r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else "")
except Exception: print("")'
}

# curlpod <namespace> <shell command>: run the command in a throwaway curl pod. Sets OUT (its output) and PHASE (the pod's end phase).
# Not run in a subshell, so both globals stay.
curlpod() {
  local n="$1" cmd="$2" ph=""
  OUT=""; PHASE=""
  kubectl -n "$n" delete pod "$POD" --ignore-not-found --wait=true >/dev/null 2>&1
  kubectl -n "$n" run "$POD" --restart=Never --image="$IMG" --overrides="$(python3 -c '
import json,sys
print(json.dumps({"spec":{"securityContext":{"runAsNonRoot":True,"runAsUser":100,"seccompProfile":{"type":"RuntimeDefault"}},
 "containers":[{"name":sys.argv[1],"image":sys.argv[2],"command":["sh","-c",sys.argv[3]],
 "resources":{"limits":{"cpu":"100m","memory":"64Mi"},"requests":{"cpu":"10m","memory":"16Mi"}},
 "securityContext":{"allowPrivilegeEscalation":False,"capabilities":{"drop":["ALL"]}}}]}}))' "$POD" "$IMG" "$cmd")" >/dev/null 2>&1
  for _ in $(seq 1 45); do
    ph=$(kubectl -n "$n" get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null)
    [ "$ph" = Succeeded ] || [ "$ph" = Failed ] && break
    sleep 2
  done
  PHASE="$ph"
  OUT=$(kubectl -n "$n" logs "$POD" 2>/dev/null | tr -d '\r')
  kubectl -n "$n" delete pod "$POD" --ignore-not-found --wait=false >/dev/null 2>&1
}

step "1. metrics (Prometheus)"
v=$(prom "up{job=\"zeedlogic-fastapi\",namespace=\"$NS\"}")
[ "$v" = 1 ] && ok "fastapi target is up (job zeedlogic-fastapi, namespace $NS)" || bad "fastapi target not up ('$v'): ServiceMonitor zeedlogic-fastapi in monitoring"
v=$(prom "sum(http_requests_total{job=\"zeedlogic-fastapi\",namespace=\"$NS\"})")
[ -n "$v" ] && ok "fastapi request counters present (http_requests_total = $v)" || bad "no http_requests_total for fastapi"
v=$(prom "up{job=\"zeedlogic-kong\",namespace=\"$NS\"}")
[ "$v" = 1 ] && ok "Kong target is up (job zeedlogic-kong)" || bad "Kong target not up ('$v'): PodMonitor zeedlogic-kong in monitoring"
v=$(prom "kong_datastore_reachable{namespace=\"$NS\"}")
[ -n "$v" ] && ok "Kong plugin metrics present (kong_datastore_reachable = $v)" || bad "no Kong metrics"
v=$(prom "cnpg_collector_up{cluster=\"$CLUSTER_DB\"}")
[ "$v" = 1 ] && ok "database cluster $CLUSTER_DB reports metrics (cnpg_collector_up)" || bad "no CNPG metrics for $CLUSTER_DB ('$v')"
v=$(prom "count(container_memory_working_set_bytes{namespace=\"$NS\",container!=\"\",container!=\"POD\"})")
[ -n "$v" ] && ok "container metrics for $NS ($v containers)" || bad "no container metrics for $NS"

step "2. logs (Loki, tenant $TENANT)"
curlpod monitoring "S=\$(( \$(date +%s) - 600 ))000000000; curl -s -m 20 -H 'X-Scope-OrgID: $TENANT' -G http://loki.loki.svc:3100/loki/api/v1/query_range --data-urlencode 'query=sum(count_over_time({namespace=\"$NS\"}[10m]))' --data-urlencode start=\$S --data-urlencode step=600"
n=$(printf '%s' "$OUT" | python3 -c 'import sys,json
try:
    r=json.load(sys.stdin)["data"]["result"]; print(int(float(r[0]["values"][-1][1])) if r else 0)
except Exception: print(-1)')
[ "$n" -gt 0 ] 2>/dev/null && ok "Loki returned $n lines for $NS in the last 10 minutes" || bad "no recent lines in Loki for $NS (got '$n')"

step "3. traces (Jaeger)"
curlpod monitoring "curl -s -m 20 http://jaeger.jaeger.svc:16686/api/services"
for svc in zeedlogic-fastapi zeedlogic-kong; do
  echo "$OUT" | grep -q "\"$svc\"" && ok "Jaeger lists the service $svc" || bad "service $svc not in Jaeger yet (fastapi: global.observability.otlpEndpoint; Kong: otlpHttpEndpoint plus kong.env.tracing_instrumentations: all; send some API traffic through Kong, e.g. /health): ${OUT:0:140}"
done

step "4. dashboards (Grafana)"
kubectl -n grafana get configmap zeedlogic-dashboards >/dev/null 2>&1 && ok "ConfigMap zeedlogic-dashboards (zeedlogic organization)" || bad "ConfigMap zeedlogic-dashboards missing"
lbl=$(kubectl -n grafana get configmap zeedlogic-dashboards-platform -o jsonpath='{.metadata.labels.grafana_dashboard}' 2>/dev/null)
[ "$lbl" = 1 ] && ok "ConfigMap zeedlogic-dashboards-platform carries the sidecar label" || bad "zeedlogic-dashboards-platform missing or unlabelled"
G=$(kubectl -n grafana get pod -l app.kubernetes.io/name=grafana -o name 2>/dev/null | head -1)
if [ -n "$G" ]; then
  # The dashboard sidecar has python and the admin credentials in its environment (REQ_USERNAME/REQ_PASSWORD); nothing is printed.
  for pair in "1:5" "2:4"; do
    org="${pair%%:*}"; want="${pair##*:}"
    got=$(kubectl -n grafana exec "$G" -c grafana-sc-dashboard -- python3 -c '
import os,sys,json,base64,urllib.request
org=sys.argv[1]
req=urllib.request.Request("http://localhost:3000/api/search?query=ZeedLogic",headers={"X-Grafana-Org-Id":org,
 "Authorization":"Basic "+base64.b64encode((os.environ["REQ_USERNAME"]+":"+os.environ["REQ_PASSWORD"]).encode()).decode()})
try:
    r=json.load(urllib.request.urlopen(req,timeout=15))
    print(len([d for d in r if d.get("type")=="dash-db" and "(Kubernetes)" in d.get("title","")]))
except Exception:
    print(-1)' "$org" 2>/dev/null)
    if [ "$got" = -1 ] || [ -z "$got" ]; then echo "  SKIP  organization $org: could not query Grafana"
    elif [ "$got" -ge "$want" ]; then ok "organization $org lists $got Kubernetes ZeedLogic dashboards (expected $want)"
    else bad "organization $org lists $got Kubernetes ZeedLogic dashboards, expected $want"; fi
  done
fi

step "5. Jaeger isolation"
curlpod "$NS" "curl -s -m 8 -o /dev/null -w 'send=%{http_code} ' -X POST -H 'Content-Type: application/json' -d '{}' http://jaeger.jaeger.svc:4318/v1/traces; curl -s -m 5 -o /dev/null -w 'read=%{http_code}' http://jaeger.jaeger.svc:16686/api/services"
case "$OUT" in *send=200*|*send=400*) ok "a pod in $NS can send to Jaeger (OTLP/HTTP answered: ${OUT%% read*})";; *) bad "a pod in $NS cannot send to Jaeger: '$OUT' (phase $PHASE)";; esac
case "$OUT" in *read=000*) ok "the same pod cannot read Jaeger's query API (16686)";; *) bad "a pod in $NS CAN reach Jaeger's query API: '$OUT'";; esac
curlpod "$OTHER" "curl -s -m 6 -o /dev/null -w 'send=%{http_code} ' -X POST -H 'Content-Type: application/json' -d '{}' http://jaeger.jaeger.svc:4318/v1/traces; curl -s -m 5 -o /dev/null -w 'read=%{http_code}' http://jaeger.jaeger.svc:16686/api/services"
case "$OUT" in *send=000*read=000*) ok "a pod in $OTHER (started, $PHASE) reaches neither port";; *) bad "a pod in $OTHER reached Jaeger or did not run: '$OUT' (phase $PHASE)";; esac

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] && echo "ZEEDLOGIC OBSERVABILITY CHECK: OK"
exit "$FAIL"
