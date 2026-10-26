#!/usr/bin/env bash
# Jaeger pass check: the pod is ready on its Badger volume, the Services expose OTLP and the query port, a span
# pushed over OTLP/HTTP is found again through the query API, the NetworkPolicy keeps a pod outside the allowed
# namespaces away, and Prometheus and Grafana can see it.
#
#   ./tests/jaeger.sh
#   NS=jaeger SVC=jaeger ./tests/jaeger.sh
#
# Pushes one span for the service `jaeger-test` (it ages out with the 3 day retention). Uses a port-forward
# (local port 16687) and two short-lived curl pods. The Grafana admin password is read at run time, never printed.
set -uo pipefail
NS="${NS:-jaeger}"
SVC="${SVC:-jaeger}"
PORT="${PORT:-16687}"
IMG="${IMG:-curlimages/curl:8.10.1}"
PASS=0; FAIL=0
ok()   { printf '  PASS  %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n' "$*"; FAIL=$((FAIL+1)); }
note() { printf '  NOTE  %s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
PF=""
trap '[ -n "$PF" ] && kill "$PF" >/dev/null 2>&1; kubectl -n "$NS" delete pod -l jaeger-test=run --ignore-not-found --wait=false >/dev/null 2>&1; kubectl -n default delete pod -l jaeger-test=run --ignore-not-found --wait=false >/dev/null 2>&1' EXIT
curlpod() { # curlpod <namespace> <name> <curl args...>   (restricted pod; waits for it to finish, prints curl output)
  local n="$1" name="$2"; shift 2
  local args; args=$(python3 -I -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "$@")
  kubectl -n "$n" delete pod "$name" --ignore-not-found --wait=true >/dev/null 2>&1
  kubectl -n "$n" apply -f - >/dev/null 2>&1 <<YAML
apiVersion: v1
kind: Pod
metadata: {name: $name, labels: {jaeger-test: run}}
spec:
  restartPolicy: Never
  securityContext: {runAsNonRoot: true, runAsUser: 100, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: c
      image: $IMG
      args: $args
      resources: {requests: {cpu: 10m, memory: 16Mi}, limits: {memory: 64Mi}}
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
YAML
  local i ph
  for i in $(seq 1 30); do
    ph=$(kubectl -n "$n" get pod "$name" -o jsonpath='{.status.phase}' 2>/dev/null)
    case "$ph" in Succeeded|Failed) break;; esac; sleep 2
  done
  kubectl -n "$n" logs "$name" 2>/dev/null
  kubectl -n "$n" delete pod "$name" --ignore-not-found --wait=false >/dev/null 2>&1
}

step "1. workload and volume"
R=$(kubectl -n "$NS" get deploy "$SVC" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[ "${R:-0}" -ge 1 ] && ok "deployment $SVC ready" || bad "deployment $SVC not ready"
PH=$(kubectl -n "$NS" get pvc jaeger-badger -o jsonpath='{.status.phase}' 2>/dev/null)
SC=$(kubectl -n "$NS" get pvc jaeger-badger -o jsonpath='{.spec.storageClassName}' 2>/dev/null)
[ "$PH" = "Bound" ] && [ "$SC" = "longhorn" ] && ok "Badger volume is Bound on class longhorn" || bad "Badger volume is '$PH' on '$SC'"
RT=$(kubectl -n "$NS" get pods -o json | python3 -I -c 'import json,sys; print(sum(c["restartCount"] for p in json.load(sys.stdin)["items"] for c in p["status"].get("containerStatuses",[])))')
[ "${RT:-1}" -eq 0 ] && ok "no container restarts" || bad "containers restarted $RT times (OOMKilled? Badger lock?)"
for p in 4317 4318 16686; do
  kubectl -n "$NS" get svc "$SVC" -o jsonpath='{.spec.ports[*].port}' | tr ' ' '\n' | grep -qx "$p" && ok "Service exposes port $p" || bad "Service does not expose port $p"
done

step "2. push a span over OTLP/HTTP from inside the namespace, read it back"
TID=$(openssl rand -hex 16); SID=$(openssl rand -hex 8); NOW=$(date +%s)
BODY="{\"resourceSpans\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"jaeger-test\"}}]},\"scopeSpans\":[{\"spans\":[{\"traceId\":\"$TID\",\"spanId\":\"$SID\",\"name\":\"tests-jaeger\",\"kind\":1,\"startTimeUnixNano\":\"${NOW}000000000\",\"endTimeUnixNano\":\"$((NOW+1))000000000\"}]}]}]}"
OUT=$(curlpod "$NS" jaeger-test-push -s -m 15 -o /dev/null -w 'HTTP %{http_code}' -H 'Content-Type: application/json' -d "$BODY" "http://$SVC.$NS.svc.cluster.local:4318/v1/traces")
echo "$OUT" | grep -q 'HTTP 200' && ok "span accepted by the OTLP receiver (HTTP 200)" || bad "push failed: $(echo "$OUT" | tail -1)"
kubectl -n "$NS" port-forward "svc/$SVC" "$PORT:16686" >/dev/null 2>&1 & PF=$!
sleep 4
FOUND=""
for i in $(seq 1 10); do
  curl -s -m 10 "http://127.0.0.1:$PORT/api/traces/$TID" | grep -q '"operationName":"tests-jaeger"' && { FOUND=1; break; }
  sleep 3
done
[ -n "$FOUND" ] && ok "trace $TID found through the query API" || bad "trace not found through the query API (Badger path? permissions?)"
# legacy endpoint: this is the one Grafana's Jaeger data source uses (Jaeger 2.21 removed it, see appsets/jaeger.yaml)
curl -s -m 10 "http://127.0.0.1:$PORT/api/services" | grep -q 'jaeger-test' && ok "service jaeger-test is listed (/api/services, used by Grafana)" || bad "service jaeger-test not listed on /api/services"
curl -s -m 10 "http://127.0.0.1:$PORT/api/v3/services" | grep -q 'jaeger-test' && ok "service jaeger-test is listed (/api/v3/services)" || bad "service jaeger-test not listed on /api/v3/services"

TR=$(curl -s -m 10 "http://127.0.0.1:$PORT/api/services" | grep -c '"traefik"')
[ "${TR:-0}" -ge 1 ] && ok "service traefik is sending traces" || note "no traces from Traefik yet (layer 0 tracing not applied: docs/jaeger.md)"

step "3. policy: a pod outside jaeger and monitoring must not reach OTLP"
OUT=$(curlpod default jaeger-test-deny -s -m 8 -o /dev/null -w 'HTTP %{http_code}' "http://$SVC.$NS.svc.cluster.local:4318/")
case "$OUT" in *"HTTP 000"*|"") ok "pod in namespace default is refused";; *"HTTP 2"*|*"HTTP 4"*) bad "pod in namespace default reached Jaeger: $OUT";; *) note "unclear answer from the deny test: $(echo "$OUT" | tail -1)";; esac

step "4. Prometheus and Grafana"
M=$(kubectl get --raw '/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/query?query=up%7Bjob%3D%22jaeger%22%7D' 2>/dev/null | python3 -I -c '
import json,sys
try: r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else "none")
except Exception: print("err")')
case "$M" in 1) ok "Prometheus scrapes Jaeger (up=1)";; none) note "no Jaeger target in Prometheus yet (ServiceMonitor just created? wait a minute)";; *) bad "Jaeger target is not up ($M)";; esac
AU=$(kubectl -n grafana get secret grafana-admin -o jsonpath='{.data.admin-user}' 2>/dev/null | base64 -d)
AP=$(kubectl -n grafana get secret grafana-admin -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d)
if [ -n "$AU" ] && [ -n "$AP" ]; then
  kubectl -n grafana port-forward svc/grafana 13005:80 >/dev/null 2>&1 & P2=$!
  sleep 3
  H=$(curl -s -m 20 -u "$AU:$AP" http://127.0.0.1:13005/api/datasources/uid/jaeger/health)
  echo "$H" | grep -q '"status":"OK"' && ok "Grafana data source 'jaeger' is healthy" || bad "Grafana data source 'jaeger': $(echo "$H" | head -c 160)"
  kill "$P2" >/dev/null 2>&1
else note "Grafana admin Secret not readable: data source not checked"; fi
unset AU AP

step "result"
echo "  passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] && echo "  JAEGER BASIC CHECK: OK" || echo "  JAEGER BASIC CHECK: FAILED"
[ "$FAIL" -eq 0 ]
