#!/usr/bin/env bash
# Reloader pass check: the controller runs, a workload annotated for it restarts when its ConfigMap or Secret
# changes, an unannotated workload does not, the same works in a tenant namespace, and a change in another
# namespace restarts nothing.
#
#   ./tests/reloader.sh
#   NS=reloader ./tests/reloader.sh
#
# Creates and removes the namespace `reloader-test` and, in zeedlogic-dev, one Deployment and one ConfigMap.
set -uo pipefail
NS="${NS:-reloader}"
T=reloader-test
TEN=zeedlogic-dev
PASS=0; FAIL=0
ok()   { printf '  PASS  %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n' "$*"; FAIL=$((FAIL+1)); }
step() { printf '\n== %s\n' "$*"; }
cleanup() {
  kubectl delete ns "$T" --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl -n "$TEN" delete deployment rl-tenant --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl -n "$TEN" delete configmap rl-tenant-cm --ignore-not-found >/dev/null 2>&1
}
trap cleanup EXIT

step "1. controller"
R=$(kubectl -n "$NS" get deploy reloader-reloader -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[ "${R:-0}" -ge 1 ] && ok "deployment reloader-reloader ready" || bad "deployment not ready"
RT=$(kubectl -n "$NS" get pods -o json | python3 -I -c 'import json,sys; print(sum(c["restartCount"] for p in json.load(sys.stdin)["items"] for c in p["status"].get("containerStatuses",[])))')
[ "${RT:-1}" -eq 0 ] && ok "no container restarts" || bad "containers restarted $RT times"
kubectl -n "$NS" get deploy reloader-reloader -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -q "reload-strategy=annotations" \
  && ok "strategy is annotations (no env var changes in workloads)" || bad "reload strategy is not annotations"
kubectl -n "$NS" get deploy reloader-reloader -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -q "auto-reload-all" \
  && bad "autoReloadAll is on: every workload would restart" || ok "opt-in only (autoReloadAll is off)"
kubectl -n "$NS" get podmonitor reloader-reloader >/dev/null 2>&1 && ok "PodMonitor exists" || bad "PodMonitor missing"

mkapp() { # mkapp <ns> <name> <annotation key> <annotation value> <configmap> [secret]
  local ns="$1" name="$2" akey="$3" aval="$4" cm="$5" sec="${6:-}"
  {
    printf 'apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: %s\n' "$name"
    [ -n "$akey" ] && printf '  annotations:\n    %s: "%s"\n' "$akey" "$aval"
    printf 'spec:\n  replicas: 1\n  selector: {matchLabels: {app: %s}}\n  template:\n    metadata: {labels: {app: %s}}\n    spec:\n' "$name" "$name"
    printf '      terminationGracePeriodSeconds: 0\n'
    printf '      securityContext: {runAsNonRoot: true, runAsUser: 1000, seccompProfile: {type: RuntimeDefault}}\n'
    printf '      containers:\n        - name: c\n          image: busybox:1.36\n          command: ["sleep","3600"]\n'
    printf '          resources: {requests: {cpu: 5m, memory: 8Mi}, limits: {cpu: 50m, memory: 32Mi}}\n'
    printf '          securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}\n'
    printf '          volumeMounts:\n            - {name: cfg, mountPath: /cfg}\n'
    [ -n "$sec" ] && printf '            - {name: sec, mountPath: /sec}\n'
    printf '      volumes:\n        - {name: cfg, configMap: {name: %s}}\n' "$cm"
    [ -n "$sec" ] && printf '        - {name: sec, secret: {secretName: %s}}\n' "$sec"
  } | kubectl -n "$ns" apply -f - >/dev/null
}
gen() { kubectl -n "$1" get deploy "$2" -o jsonpath='{.status.observedGeneration}/{.metadata.generation}/{.spec.template.metadata.annotations.reloader\.stakater\.com/last-reloaded-from}' 2>/dev/null; }
rs()  { kubectl -n "$1" get rs -l "app=$2" --no-headers 2>/dev/null | wc -l; }
wait_ready() { kubectl -n "$1" rollout status "deploy/$2" --timeout=90s >/dev/null 2>&1; }

step "2. platform-style namespace ($T)"
kubectl create ns "$T" >/dev/null 2>&1
kubectl -n "$T" create configmap rt-cm --from-literal=v=1 >/dev/null 2>&1
kubectl -n "$T" create secret generic rt-sec --from-literal=v=1 >/dev/null 2>&1
mkapp "$T" rt-auto reloader.stakater.com/auto true rt-cm
mkapp "$T" rt-plain "" "" rt-cm
mkapp "$T" rt-secret secret.reloader.stakater.com/reload rt-sec rt-cm rt-sec
for d in rt-auto rt-plain rt-secret; do wait_ready "$T" "$d" || bad "$d did not become ready"; done
B1=$(rs "$T" rt-auto); B2=$(rs "$T" rt-plain); B3=$(rs "$T" rt-secret)
kubectl -n "$T" patch configmap rt-cm --type merge -p '{"data":{"v":"2"}}' >/dev/null
kubectl -n "$T" patch secret rt-sec --type merge -p '{"stringData":{"v":"2"}}' >/dev/null
for i in $(seq 1 30); do [ "$(rs "$T" rt-auto)" -gt "$B1" ] && [ "$(rs "$T" rt-secret)" -gt "$B3" ] && break; sleep 3; done
[ "$(rs "$T" rt-auto)" -gt "$B1" ] && ok "annotated Deployment (auto) restarted after its ConfigMap changed" || bad "rt-auto did not restart"
kubectl -n "$T" get deploy rt-auto -o jsonpath='{.spec.template.metadata.annotations}' | grep -q "reloader.stakater.com/last-reloaded-from" \
  && ok "the change is recorded as a pod-template annotation" || bad "no last-reloaded-from annotation on rt-auto"
[ "$(rs "$T" rt-secret)" -gt "$B3" ] && ok "Deployment with secret.reloader annotation restarted after its Secret changed" || bad "rt-secret did not restart"
sleep 5
[ "$(rs "$T" rt-plain)" -eq "$B2" ] && ok "unannotated Deployment was NOT restarted although it uses the changed ConfigMap" || bad "rt-plain restarted without an annotation"

step "3. tenant namespace ($TEN)"
kubectl -n "$TEN" create configmap rl-tenant-cm --from-literal=v=1 >/dev/null 2>&1
mkapp "$TEN" rl-tenant reloader.stakater.com/auto true rl-tenant-cm
wait_ready "$TEN" rl-tenant && ok "tenant Deployment ready (Pod Security, quota and placement policy accept it)" || bad "tenant Deployment not ready"
BT=$(rs "$TEN" rl-tenant)
# a ConfigMap with the same name in ANOTHER namespace must not restart it
kubectl -n "$T" create configmap rl-tenant-cm --from-literal=v=9 >/dev/null 2>&1
kubectl -n "$T" patch configmap rl-tenant-cm --type merge -p '{"data":{"v":"10"}}' >/dev/null
sleep 12
[ "$(rs "$TEN" rl-tenant)" -eq "$BT" ] && ok "a same-named ConfigMap changing in another namespace restarts nothing" || bad "cross-namespace restart"
kubectl -n "$TEN" patch configmap rl-tenant-cm --type merge -p '{"data":{"v":"2"}}' >/dev/null
for i in $(seq 1 30); do [ "$(rs "$TEN" rl-tenant)" -gt "$BT" ] && break; sleep 3; done
[ "$(rs "$TEN" rl-tenant)" -gt "$BT" ] && ok "tenant Deployment restarted after its own ConfigMap changed" || bad "tenant Deployment did not restart"
wait_ready "$TEN" rl-tenant && ok "the restarted tenant Deployment is ready again" || bad "tenant Deployment not ready after restart"

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] && echo "RELOADER CHECK: OK"
exit "$FAIL"
