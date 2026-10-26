#!/usr/bin/env bash
# KEDA pass check: operator, metrics API server and webhooks run, the external metrics API is registered next to
# metrics-server (no clash), tenants have no KEDA rights, a cron ScaledObject scales a Deployment up, another scales
# one to zero, the HPA that KEDA creates is removed with its ScaledObject, and Prometheus holds KEDA's metrics.
#
#   ./tests/keda.sh
#   NS=keda ./tests/keda.sh
#
# Creates and removes the namespace `keda-test`. Takes about 2 to 3 minutes. Cron trigger windows are computed in UTC
# from now: a run within a minute of midnight UTC may need to be repeated.
set -uo pipefail
NS="${NS:-keda}"
T=keda-test
PASS=0; FAIL=0
ok()   { printf '  PASS  %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n' "$*"; FAIL=$((FAIL+1)); }
step() { printf '\n== %s\n' "$*"; }
PF=""
cleanup() { [ -n "$PF" ] && kill "$PF" 2>/dev/null; kubectl delete ns "$T" --ignore-not-found --wait=false >/dev/null 2>&1; }
trap cleanup EXIT

step "1. components and APIs"
for d in keda-operator keda-operator-metrics-apiserver keda-admission-webhooks; do
  R=$(kubectl -n "$NS" get deploy "$d" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  [ "${R:-0}" -ge 1 ] && ok "deployment $d ready" || bad "deployment $d not ready"
done
# The operator exits once on a fresh install after it has written its certificates (reason Completed, exit 0).
# Only failure-type restarts (OOMKilled, Error) count.
RT=$(kubectl -n "$NS" get pods -o json | python3 -I -c 'import json,sys
n=0
for p in json.load(sys.stdin)["items"]:
    for c in p["status"].get("containerStatuses",[]):
        t=(c.get("lastState") or {}).get("terminated")
        if c["restartCount"] and t and t.get("reason")!="Completed": n+=c["restartCount"]
print(n)')
[ "${RT:-1}" -eq 0 ] && ok "no failed container restarts (the one-time certificate restart of a fresh install is expected)" || bad "containers failed and restarted $RT times"
A=$(kubectl get apiservice v1beta1.external.metrics.k8s.io -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)
[ "$A" = True ] && ok "external.metrics.k8s.io is registered and Available" || bad "external metrics APIService is '$A'"
M=$(kubectl get apiservice v1beta1.metrics.k8s.io -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)
[ "$M" = True ] && kubectl top nodes >/dev/null 2>&1 && ok "metrics-server (metrics.k8s.io) still works next to it" || bad "metrics.k8s.io is not healthy"
FP=$(kubectl get validatingwebhookconfiguration keda-admission -o jsonpath='{.webhooks[0].failurePolicy}' 2>/dev/null)
[ "$FP" = Ignore ] && ok "admission webhook failurePolicy is Ignore (an outage cannot block ScaledObjects)" || bad "webhook failurePolicy is '$FP'"
[ "$(kubectl get crd | grep -c keda.sh)" -ge 5 ] && ok "KEDA CRDs installed" || bad "KEDA CRDs missing"
[ "$(kubectl -n "$NS" get podmonitor -o name | wc -l)" -ge 2 ] && ok "PodMonitors exist (operator, metrics server)" || bad "PodMonitors missing"

step "2. tenants have no KEDA rights (decision: aggregateToDefaultRoles false)"
for who in "dev@zeedlogic.com zeedlogic-developers zeedlogic-dev" "owner@jodywan.dev jodywan-owners jodywan-prod"; do
  set -- $who
  C=$(kubectl auth can-i create scaledobjects.keda.sh -n "$3" --as="$1" --as-group="oidc:$2" --as-group=system:authenticated 2>/dev/null)
  [ "$C" = no ] && ok "$1 cannot create ScaledObjects in $3" || bad "$1 can create ScaledObjects in $3"
done

step "3. a ScaledObject scales up, another scales to zero"
kubectl create ns "$T" >/dev/null 2>&1
mkdep() { # mkdep <name> <replicas>
  cat <<YAML | kubectl -n "$T" apply -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata: {name: $1}
spec:
  replicas: $2
  selector: {matchLabels: {app: $1}}
  template:
    metadata: {labels: {app: $1}}
    spec:
      terminationGracePeriodSeconds: 0
      securityContext: {runAsNonRoot: true, runAsUser: 1000, seccompProfile: {type: RuntimeDefault}}
      containers:
        - name: c
          image: busybox:1.36
          command: ["sleep","3600"]
          resources: {requests: {cpu: 5m, memory: 8Mi}, limits: {cpu: 50m, memory: 32Mi}}
          securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
YAML
}
cron_window() { # cron_window <minutes-before-start> <minutes-until-end> -> "S_MIN S_HOUR * * *|E_MIN E_HOUR * * *"
  printf '%s * * *|%s * * *' "$(date -u -d "$1 minutes" +'%-M %-H')" "$(date -u -d "$2 minutes" +'%-M %-H')"
}
mkso() { # mkso <name> <target> <min> <desired> <start|end window>
  local S="${5%%|*}" E="${5##*|}"
  cat <<YAML | kubectl -n "$T" apply -f - >/dev/null
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata: {name: $1}
spec:
  scaleTargetRef: {name: $2}
  minReplicaCount: $3
  maxReplicaCount: 3
  pollingInterval: 5
  cooldownPeriod: 10
  triggers:
    - type: cron
      metadata: {timezone: UTC, start: "$S", end: "$E", desiredReplicas: "$4"}
YAML
}
mkdep kt-up 1; mkdep kt-zero 1
kubectl -n "$T" rollout status deploy/kt-up --timeout=60s >/dev/null 2>&1
mkso kt-up-so kt-up 1 2 "$(cron_window -1 20)"          # window is open now: wants 2 replicas
mkso kt-zero-so kt-zero 0 1 "$(cron_window 30 50)"       # window opens in 30 minutes: idle, so scale to zero
for i in $(seq 1 40); do
  U=$(kubectl -n "$T" get deploy kt-up -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  Z=$(kubectl -n "$T" get deploy kt-zero -o jsonpath='{.spec.replicas}' 2>/dev/null)
  [ "${U:-0}" = 2 ] && [ "${Z:-1}" = 0 ] && break; sleep 5
done
[ "${U:-0}" = 2 ] && ok "kt-up scaled from 1 to 2 replicas while its cron window is open" || bad "kt-up has ${U:-0} ready replicas (wanted 2)"
[ "${Z:-1}" = 0 ] && ok "kt-zero scaled to zero while its window is closed" || bad "kt-zero has $Z replicas (wanted 0)"
kubectl -n "$T" get hpa keda-hpa-kt-up-so >/dev/null 2>&1 && ok "KEDA created the HPA keda-hpa-kt-up-so" || bad "HPA keda-hpa-kt-up-so missing"
RDY=$(kubectl -n "$T" get scaledobject kt-up-so -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}/{.status.conditions[?(@.type=="Active")].status}' 2>/dev/null)
[ "$RDY" = "True/True" ] && ok "ScaledObject kt-up-so is Ready and Active" || bad "ScaledObject conditions (Ready/Active): $RDY"
kubectl -n "$T" delete scaledobject kt-up-so >/dev/null 2>&1
for i in $(seq 1 20); do kubectl -n "$T" get hpa keda-hpa-kt-up-so >/dev/null 2>&1 || break; sleep 3; done
kubectl -n "$T" get hpa keda-hpa-kt-up-so >/dev/null 2>&1 && bad "HPA remained after its ScaledObject was deleted" || ok "the HPA is removed together with its ScaledObject"

step "4. metrics reach Prometheus"
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 19099:9090 >/dev/null 2>&1 & PF=$!
sleep 3
N=0
for i in $(seq 1 12); do
  N=$(curl -s -m 15 -G "http://127.0.0.1:19099/api/v1/query" --data-urlencode 'query=count({__name__=~"keda_.*"})' | python3 -I -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else 0)' 2>/dev/null)
  [ "${N:-0}" != 0 ] && break; sleep 10
done
[ "${N:-0}" != 0 ] && ok "Prometheus has KEDA metrics ($N series)" || bad "no keda_* series in Prometheus (PodMonitors, scrape interval)"

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] && echo "KEDA CHECK: OK"
exit "$FAIL"
