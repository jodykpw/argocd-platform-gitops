#!/usr/bin/env bash
# blackbox-exporter pass check: the exporter runs, a probe through it succeeds for a good target and fails for a
# closed port, Prometheus holds probe_success=1 for every configured target, the NetworkPolicy keeps a pod outside
# the monitoring namespace away, and the alert rules are loaded.
#
#   ./tests/blackbox-exporter.sh
#   NS=monitoring ./tests/blackbox-exporter.sh
#
# Uses two port-forwards (local ports 19115 and 19092) and one short-lived curl pod in `default` (removed again).
set -uo pipefail
NS="${NS:-monitoring}"
IMG="${IMG:-curlimages/curl:8.10.1}"
PASS=0; FAIL=0
ok()   { printf '  PASS  %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n' "$*"; FAIL=$((FAIL+1)); }
note() { printf '  NOTE  %s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
PIDS=()
trap 'for p in "${PIDS[@]}"; do kill "$p" >/dev/null 2>&1; done; kubectl -n default delete pod bb-test-np --ignore-not-found --wait=false >/dev/null 2>&1' EXIT

step "1. workload and objects"
R=$(kubectl -n "$NS" get deploy blackbox-exporter -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[ "${R:-0}" -ge 1 ] && ok "deployment blackbox-exporter ready" || bad "deployment blackbox-exporter not ready"
RT=$(kubectl -n "$NS" get pods -l app.kubernetes.io/name=prometheus-blackbox-exporter -o json | python3 -I -c 'import json,sys; print(sum(c["restartCount"] for p in json.load(sys.stdin)["items"] for c in p["status"].get("containerStatuses",[])))')
[ "${RT:-1}" -eq 0 ] && ok "no container restarts" || bad "containers restarted $RT times"
for pr in public-ui dependencies tcp-ports; do
  kubectl -n "$NS" get probes.monitoring.coreos.com "$pr" >/dev/null 2>&1 && ok "Probe $pr exists" || bad "Probe $pr missing"
done
kubectl -n "$NS" get networkpolicy blackbox-exporter >/dev/null 2>&1 && ok "NetworkPolicy blackbox-exporter exists" || bad "NetworkPolicy missing"

step "2. a probe through the exporter (port-forward)"
kubectl -n "$NS" port-forward svc/blackbox-exporter 19115:9115 >/dev/null 2>&1 & PIDS+=($!)
sleep 3
P() { curl -s -m 20 -G "http://127.0.0.1:19115/probe" --data-urlencode "target=$1" --data-urlencode "module=$2" | awk '/^probe_success /{print $2}'; }
[ "$(P https://grafana-k8s.jodywan.com/api/health http_2xx)" = "1" ] && ok "http_2xx to the Grafana health URL: probe_success 1" || bad "Grafana health probe did not succeed"
[ "$(P 10.1.5.123:3910 tcp_connect)" = "1" ] && ok "tcp_connect to the backup Garage 10.1.5.123:3910: probe_success 1" || bad "backup Garage port probe did not succeed"
[ "$(P 10.1.5.123:1 tcp_connect)" = "0" ] && ok "a closed port is reported as probe_success 0 (failures are detected)" || bad "closed port was not reported as failed"

step "3. Prometheus holds the results"
kubectl -n "$NS" port-forward svc/kube-prometheus-stack-prometheus 19092:9090 >/dev/null 2>&1 & PIDS+=($!)
sleep 3
Q() { curl -s -m 20 -G "http://127.0.0.1:19092/api/v1/query" --data-urlencode "query=$1" | python3 -I -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else "none")' 2>/dev/null; }
WANT=$(kubectl -n "$NS" get probes.monitoring.coreos.com -o json | python3 -I -c 'import json,sys; print(sum(len(p["spec"]["targets"]["staticConfig"]["static"]) for p in json.load(sys.stdin)["items"]))')
GOT=$(Q 'count(probe_success)')
[ "$GOT" = "$WANT" ] && ok "probe_success exists for all $WANT targets" || bad "probe_success series: $GOT, targets configured: $WANT (wait a minute after a sync)"
UP=$(Q 'count(probe_success == 1)')
[ "$UP" = "$WANT" ] && ok "all $WANT targets are up (probe_success 1)" || bad "$UP of $WANT targets up: ./tests/blackbox-exporter.sh output below"
if [ "$UP" != "$WANT" ]; then
  curl -s -m 20 -G "http://127.0.0.1:19092/api/v1/query" --data-urlencode 'query=probe_success == 0' | python3 -I -c 'import json,sys
for x in json.load(sys.stdin)["data"]["result"]: print("        DOWN:",x["metric"].get("instance"))'
fi
EX=$(Q 'min(probe_ssl_earliest_cert_expiry{probe_group="public-ui"}) - time()')
python3 -I -c "import sys; v=sys.argv[1]; sys.exit(0 if v!='none' and float(v)>14*86400 else 1)" "$EX" \
  && ok "public certificates are valid for more than 14 days (shortest: $(python3 -I -c "print(round(float('$EX')/86400))") days)" \
  || bad "a public certificate expires within 14 days or is not measured ($EX)"

step "4. NetworkPolicy"
kubectl -n default delete pod bb-test-np --ignore-not-found --wait=true >/dev/null 2>&1
kubectl -n default apply -f - >/dev/null 2>&1 <<YAML
apiVersion: v1
kind: Pod
metadata: {name: bb-test-np}
spec:
  restartPolicy: Never
  securityContext: {runAsNonRoot: true, runAsUser: 100, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: c
      image: $IMG
      args: ["-s", "-m", "6", "-o", "/dev/null", "-w", "HTTP %{http_code}", "http://blackbox-exporter.$NS.svc:9115/metrics"]
      resources: {requests: {cpu: 10m, memory: 16Mi}, limits: {memory: 64Mi}}
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
YAML
for i in $(seq 1 30); do ph=$(kubectl -n default get pod bb-test-np -o jsonpath='{.status.phase}' 2>/dev/null); case "$ph" in Succeeded|Failed) break;; esac; sleep 2; done
OUT=$(kubectl -n default logs bb-test-np 2>/dev/null | tail -1)
echo "$OUT" | grep -q "HTTP 200" && bad "a pod in default reached the exporter ($OUT)" || ok "a pod in default cannot use the exporter (${OUT:-no answer})"

step "5. alert rules"
for a in ProbeFailed ProbeCertificateExpiresSoon ProbeCertificateExpiresVerySoon; do
  kubectl -n "$NS" get prometheusrule platform-alerts -o json | grep -q "\"$a\"" && ok "alert $a is defined" || bad "alert $a missing in platform-alerts"
done

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] && echo "BLACKBOX-EXPORTER CHECK: OK"
exit "$FAIL"
