#!/usr/bin/env bash
# Trivy Operator pass check: operator and Trivy server run, the infrastructure scanner is off (baseline namespace),
# the operator cannot read Secrets cluster-wide, a throwaway Deployment with an old image gets a VulnerabilityReport
# with findings and a ConfigAuditReport, tenant users can read reports in their own namespace and not in the other
# tenant's, and Prometheus holds Trivy's metrics.
#
#   ./tests/trivy-operator.sh
#   NS=trivy-system ./tests/trivy-operator.sh
#
# Creates and removes the namespace `trivy-test`. Takes about 3 to 8 minutes on a settled install. Right after the
# first sync the operator is still working through every workload in the cluster, so the new Deployment can wait
# up to 20 minutes for its turn: run the test once `kubectl get vulnerabilityreports -A` stops growing.
set -uo pipefail
NS="${NS:-trivy-system}"
T=trivy-test
IMG="${IMG:-alpine:3.12.0}"      # old on purpose: it has known vulnerabilities
PASS=0; FAIL=0
ok()   { printf '  PASS  %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n' "$*"; FAIL=$((FAIL+1)); }
step() { printf '\n== %s\n' "$*"; }
PF=""
cleanup() { [ -n "$PF" ] && kill "$PF" 2>/dev/null; kubectl delete ns "$T" --ignore-not-found --wait=false >/dev/null 2>&1; }
trap cleanup EXIT

step "1. components"
R=$(kubectl -n "$NS" get deploy trivy-operator -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[ "${R:-0}" -ge 1 ] && ok "deployment trivy-operator ready" || bad "deployment trivy-operator not ready"
R=$(kubectl -n "$NS" get sts trivy-server -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[ "${R:-0}" -ge 1 ] && ok "statefulset trivy-server ready" || bad "statefulset trivy-server not ready"
P=$(kubectl -n "$NS" get pvc -o jsonpath='{.items[*].status.phase}' 2>/dev/null)
[ -n "$P" ] && [[ "$P" != *Pending* ]] && ok "trivy-server volume is Bound" || bad "trivy-server volume phase: '$P'"
RT=$(kubectl -n "$NS" get pods -o json | python3 -I -c 'import json,sys
n=0
for p in json.load(sys.stdin)["items"]:
    for c in p["status"].get("containerStatuses",[]):
        if c["restartCount"]: n+=c["restartCount"]
print(n)')
[ "${RT:-1}" -eq 0 ] && ok "no container restarts" || bad "containers restarted $RT times"
[ "$(kubectl get crd | grep -c aquasecurity.github.io)" -ge 7 ] && ok "Trivy CRDs installed" || bad "Trivy CRDs missing"
L=$(kubectl get ns "$NS" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}')
[ "$L" = baseline ] && ok "namespace $NS enforces Pod Security baseline" || bad "namespace $NS Pod Security is '$L'"
I=$(kubectl -n "$NS" get cm trivy-operator-config -o jsonpath='{.data.OPERATOR_INFRA_ASSESSMENT_SCANNER_ENABLED}' 2>/dev/null)
[ "$I" = false ] && ok "infrastructure assessment is off (node-collector needs hostPath, not allowed in baseline)" || bad "infra assessment setting is '$I'"

step "2. least privilege"
SA="system:serviceaccount:$NS:trivy-operator"
[ "$(kubectl auth can-i get secrets -n kube-system --as="$SA")" = no ] && ok "operator cannot read Secrets in kube-system" || bad "operator can read Secrets in kube-system"
[ "$(kubectl auth can-i get secrets -n "$NS" --as="$SA")" = yes ] && ok "operator can read its own Secrets (scan Job credentials)" || bad "operator cannot read Secrets in $NS"

step "3. a scan produces reports"
kubectl create ns "$T" >/dev/null 2>&1
cat <<YAML | kubectl -n "$T" apply -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata: {name: old-image}
spec:
  replicas: 1
  selector: {matchLabels: {app: old-image}}
  template:
    metadata: {labels: {app: old-image}}
    spec:
      terminationGracePeriodSeconds: 0
      containers:
        - name: c
          image: $IMG
          command: ["sleep","3600"]
          resources: {requests: {cpu: 5m, memory: 8Mi}, limits: {cpu: 50m, memory: 32Mi}}
YAML
V=0; C=0
for i in $(seq 1 120); do
  V=$(kubectl -n "$T" get vulnerabilityreports -o name 2>/dev/null | wc -l)
  C=$(kubectl -n "$T" get configauditreports -o name 2>/dev/null | wc -l)
  [ "$V" -ge 1 ] && [ "$C" -ge 1 ] && break; sleep 10
done
[ "$V" -ge 1 ] && ok "VulnerabilityReport created for the Deployment" || bad "no VulnerabilityReport after 20 minutes"
[ "$C" -ge 1 ] && ok "ConfigAuditReport created" || bad "no ConfigAuditReport after 20 minutes"
TOT=$(kubectl -n "$T" get vulnerabilityreports -o json 2>/dev/null | python3 -I -c 'import json,sys
d=json.load(sys.stdin)["items"]
print(sum(sum(i["report"]["summary"].get(k,0) for k in ("criticalCount","highCount","mediumCount","lowCount")) for i in d))' 2>/dev/null)
[ "${TOT:-0}" -gt 0 ] && ok "the old image has findings ($TOT)" || bad "no findings for $IMG "
LEFT=$(kubectl -n "$NS" get pods --field-selector=status.phase=Failed -o name 2>/dev/null | wc -l)
[ "$LEFT" -eq 0 ] && ok "no failed scan pods in $NS" || bad "$LEFT failed scan pods in $NS"

step "4. tenants read their own reports only"
# The chart aggregates read access to the report kinds into view, edit and admin.
can() { kubectl auth can-i "$1" "$2" -n "$3" --as="$4" --as-group="oidc:$5" --as-group=system:authenticated 2>/dev/null; }
[ "$(can list vulnerabilityreports.aquasecurity.github.io zeedlogic-dev dev@zeedlogic.com zeedlogic-developers)" = yes ] && ok "dev@zeedlogic.com can list VulnerabilityReports in zeedlogic-dev" || bad "dev@zeedlogic.com cannot list reports in zeedlogic-dev"
[ "$(can list vulnerabilityreports.aquasecurity.github.io jodywan-dev dev@zeedlogic.com zeedlogic-developers)" = no ] && ok "dev@zeedlogic.com cannot list reports in jodywan-dev" || bad "dev@zeedlogic.com can list reports in jodywan-dev"
[ "$(can delete vulnerabilityreports.aquasecurity.github.io zeedlogic-dev dev@zeedlogic.com zeedlogic-developers)" = no ] && ok "developers cannot delete reports" || bad "developers can delete reports"
[ "$(can list clustercompliancereports.aquasecurity.github.io '' dev@zeedlogic.com zeedlogic-developers)" = no ] && ok "tenants cannot read cluster compliance reports" || bad "tenants can read cluster compliance reports"

step "5. cluster reports and metrics"
[ "$(kubectl get clustercompliancereports -o name 2>/dev/null | wc -l)" -ge 1 ] && ok "ClusterComplianceReport specs exist" || bad "no ClusterComplianceReport"
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 19098:9090 >/dev/null 2>&1 & PF=$!
sleep 3
M=0
for i in $(seq 1 18); do
  M=$(curl -s -m 15 -G "http://127.0.0.1:19098/api/v1/query" --data-urlencode 'query=count(trivy_image_vulnerabilities{namespace="'"$T"'"})' | python3 -I -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else 0)' 2>/dev/null)
  [ "${M:-0}" != 0 ] && break; sleep 10
done
[ "${M:-0}" != 0 ] && ok "Prometheus has trivy_image_vulnerabilities for the test workload" || bad "no trivy_image_vulnerabilities series (ServiceMonitor, scrape interval)"

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] && echo "TRIVY OPERATOR CHECK: OK"
exit "$FAIL"
