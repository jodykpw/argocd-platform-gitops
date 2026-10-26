#!/usr/bin/env bash
# Fluent Bit pass check: one pod per node (control planes included), no restarts, no errors towards Loki, and
# an end-to-end tenant check: a marker line written by a pod in a tenant namespace shows up in that tenant's
# Loki tenant only, and a marker from a platform namespace shows up in `platform` only.
#
#   ./tests/fluent-bit.sh
#   TENANT_NS=zeedlogic-dev TENANT=zeedlogic OTHER=jodywan ./tests/fluent-bit.sh
#
# Creates two short-lived pods (one in TENANT_NS, one in PLATFORM_NS, unique names, label fb-test=run) and
# deletes them at the end.
# Needs Loki (tests/loki.sh passes). Uses a port-forward to svc/loki (local port 13101).
set -uo pipefail
NS="${NS:-fluent-bit}"
LOKI_NS="${LOKI_NS:-loki}"
TENANT_NS="${TENANT_NS:-zeedlogic-dev}"
TENANT="${TENANT:-zeedlogic}"
OTHER="${OTHER:-jodywan}"
PLATFORM_NS="${PLATFORM_NS:-default}"
IMG="${IMG:-busybox:1.36}"
PORT="${PORT:-13101}"
PASS=0; FAIL=0
ok()   { printf '  PASS  %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n' "$*"; FAIL=$((FAIL+1)); }
step() { printf '\n== %s\n' "$*"; }

# A fresh pod name every run: Fluent Bit's kubernetes filter caches pod metadata by name, so a reused name can
# arrive without namespace/pod/container labels (seen).
RUN="$(date +%s)-$RANDOM"
M_T="fb-tenant-$RUN"
M_P="fb-platform-$(date +%s)-$RANDOM"
cleanup() {
  kubectl -n "$TENANT_NS" delete pod -l fb-test=run --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl -n "$PLATFORM_NS" delete pod -l fb-test=run --ignore-not-found --wait=false >/dev/null 2>&1
  [ -n "${PF:-}" ] && kill "$PF" >/dev/null 2>&1
  rm -f "${PF_LOG:-}"
}
trap cleanup EXIT

step "1. DaemonSet"
DES=$(kubectl -n "$NS" get ds fluent-bit -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null)
RDY=$(kubectl -n "$NS" get ds fluent-bit -o jsonpath='{.status.numberReady}' 2>/dev/null)
NODES=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
[ "${RDY:-0}" -ge 1 ] && [ "$RDY" = "$DES" ] && ok "DaemonSet ready on $RDY of $DES nodes" || bad "DaemonSet ready $RDY of $DES"
[ "$DES" = "$NODES" ] && ok "one pod per node ($NODES nodes, control planes included)" || bad "desired $DES pods but $NODES nodes (tolerations?)"
RT=$(kubectl -n "$NS" get pods -o json | python3 -I -c 'import json,sys; print(sum(c["restartCount"] for p in json.load(sys.stdin)["items"] for c in p["status"].get("containerStatuses",[])))')
[ "${RT:-1}" -eq 0 ] && ok "no container restarts" || bad "containers restarted $RT times (OOMKilled? check the limit)"
ERR=$(kubectl -n "$NS" logs ds/fluent-bit --tail=200 2>/dev/null | grep -c -i -E '\[error\]|\[ warn\].*(loki|http_do)')
[ "${ERR:-0}" -eq 0 ] && ok "no output errors in the log" || { bad "$ERR error/warn lines in the log (last 3 below)"; kubectl -n "$NS" logs ds/fluent-bit --tail=200 | grep -i -E '\[error\]|\[ warn\]' | tail -3 | sed 's/^/    /'; }

step "2. write marker lines"
for pair in "$TENANT_NS:$M_T" "$PLATFORM_NS:$M_P"; do
  n=${pair%%:*}; m=${pair#*:}
  PN="fb-test-$RUN-${n%%-*}"
  kubectl -n "$n" apply -f - >/dev/null 2>&1 <<YAML
apiVersion: v1
kind: Pod
metadata: {name: $PN, labels: {fb-test: run}}
spec:
  restartPolicy: Never
  securityContext: {runAsNonRoot: true, runAsUser: 1000, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: m
      image: $IMG
      command: ["sh","-c","for i in 1 2 3; do echo $m; sleep 1; done; sleep 20"]
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
      resources: {requests: {cpu: 10m, memory: 16Mi}, limits: {cpu: 50m, memory: 32Mi}}
YAML
  [ $? -eq 0 ] && ok "pod $PN created in $n" || bad "could not create pod in $n"
done
# Poll instead of a fixed sleep: the tail input finds new log files every Refresh_Interval (5 s in the values,
# 60 s by default) and the pods stay (Completed) until the end of this script.
echo "  waiting for the lines to travel (read, filter, push), up to 90 s"

step "3. tenant routing in Loki"
PF_LOG=$(mktemp)
kubectl -n "$LOKI_NS" port-forward svc/loki "$PORT:3100" >"$PF_LOG" 2>&1 &
PF=$!
sleep 3
Q() { curl -s -m 15 -G -H "X-Scope-OrgID: $1" "http://127.0.0.1:$PORT/loki/api/v1/query_range" \
        --data-urlencode "query={namespace=\"$2\"} |= \"$3\"" --data-urlencode "since=10m"; }
for i in $(seq 1 18); do
  Q "$TENANT" "$TENANT_NS" "$M_T" | grep -q "$M_T" && Q platform "$PLATFORM_NS" "$M_P" | grep -q "$M_P" && break
  sleep 5
done
echo "  lines seen after about $((i*5)) s"
Q "$TENANT" "$TENANT_NS" "$M_T" | grep -q "$M_T" && ok "tenant line is in Loki tenant '$TENANT'" || bad "tenant line missing in '$TENANT' (labels? lua filter? see docs/fluent-bit.md)"
Q "$OTHER" "$TENANT_NS" "$M_T" | grep -q "$M_T" && bad "tenant line also visible to '$OTHER'" || ok "tenant line not visible to '$OTHER'"
Q platform "$TENANT_NS" "$M_T" | grep -q "$M_T" && bad "tenant line landed in 'platform'" || ok "tenant line not in 'platform'"
Q platform "$PLATFORM_NS" "$M_P" | grep -q "$M_P" && ok "platform line is in Loki tenant 'platform'" || bad "platform line missing in 'platform'"
Q "$TENANT" "$PLATFORM_NS" "$M_P" | grep -q "$M_P" && bad "platform line visible to '$TENANT'" || ok "platform line not visible to '$TENANT'"
L=$(curl -s -m 15 -G -H "X-Scope-OrgID: $TENANT" "http://127.0.0.1:$PORT/loki/api/v1/labels" --data-urlencode "since=10m")
echo "  labels for '$TENANT': $(echo "$L" | tr -d '\n' | head -c 200)"

step "result"
echo "  passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] && echo "  FLUENT BIT BASIC CHECK: OK" || echo "  FLUENT BIT BASIC CHECK: FAILED"
[ "$FAIL" -eq 0 ]
