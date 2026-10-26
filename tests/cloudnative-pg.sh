#!/usr/bin/env bash
# CloudNativePG pass check: the operator runs with two replicas on different nodes, its CRDs, webhooks and PodMonitor
# exist, tenants have no CloudNativePG rights, and a real single-instance Cluster comes up, answers a query through its
# read-write Service with the generated password, and is removed again (including the retained PV and Longhorn volume).
#
#   ./tests/cloudnative-pg.sh
#   NS=cnpg-system SC=longhorn ./tests/cloudnative-pg.sh
#   KEEP=1 ./tests/cloudnative-pg.sh            # do not clean up (inspect, then clean by hand)
#
# Creates and removes the namespace `cnpg-test`, one 1Gi volume and the Cluster `probe`. Takes about 2 to 5 minutes
# (the PostgreSQL image is pulled on first use).
set -uo pipefail
NS="${NS:-cnpg-system}"
SC="${SC:-longhorn}"
KEEP="${KEEP:-0}"
T=cnpg-test
PASS=0; FAIL=0
ok()   { printf '  PASS  %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n' "$*"; FAIL=$((FAIL+1)); }
step() { printf '\n== %s\n' "$*"; }

PV=""
cleanup() {
  [ "$KEEP" = 1 ] && { echo; echo "KEEP=1: left namespace $T and volume ${PV:-none} in place"; return; }
  step "cleanup"
  kubectl delete namespace "$T" --ignore-not-found --wait=true --timeout=180s >/dev/null 2>&1 && echo "  namespace $T deleted"
  if [ -n "$PV" ]; then
    kubectl delete pv "$PV" --wait=true --timeout=60s >/dev/null 2>&1 && echo "  PV $PV deleted"
    kubectl -n longhorn-system delete volumes.longhorn.io "$PV" --wait=true --timeout=90s >/dev/null 2>&1 \
      && echo "  Longhorn volume $PV deleted"
  fi
}
trap cleanup EXIT

step "1. operator"
R=$(kubectl -n "$NS" get deploy cnpg-cloudnative-pg -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[ "${R:-0}" -ge 2 ] && ok "operator ready ($R replicas)" || bad "operator ready replicas: ${R:-0} (expected 2)"
NODES=$(kubectl -n "$NS" get pods -l app.kubernetes.io/name=cloudnative-pg -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' 2>/dev/null | sort -u | wc -l)
[ "$NODES" -ge 2 ] && ok "operator pods run on $NODES different nodes" || bad "operator pods are on $NODES node(s)"
RT=$(kubectl -n "$NS" get pods -o json | python3 -I -c 'import json,sys
n=0
for p in json.load(sys.stdin)["items"]:
    for c in p["status"].get("containerStatuses",[]):
        t=(c.get("lastState") or {}).get("terminated")
        if c["restartCount"] and t and t.get("reason")!="Completed": n+=c["restartCount"]
print(n)')
[ "${RT:-1}" -eq 0 ] && ok "no failed container restarts" || bad "containers failed and restarted $RT times"
[ "$(kubectl get crd -o name | grep -c 'cnpg.io')" -ge 8 ] && ok "CloudNativePG CRDs installed" || bad "CloudNativePG CRDs missing"
kubectl get mutatingwebhookconfiguration cnpg-mutating-webhook-configuration >/dev/null 2>&1 \
  && kubectl get validatingwebhookconfiguration cnpg-validating-webhook-configuration >/dev/null 2>&1 \
  && ok "both webhook configurations exist" || bad "webhook configuration missing"
[ "$(kubectl -n "$NS" get podmonitor -o name 2>/dev/null | wc -l)" -ge 1 ] && ok "PodMonitor exists" || bad "PodMonitor missing"

step "2. tenants have no CloudNativePG rights (decision: aggregateClusterRoles false)"
for who in "dev@zeedlogic.com zeedlogic-developers zeedlogic-dev" "owner@jodywan.dev jodywan-owners jodywan-prod"; do
  set -- $who
  C=$(kubectl auth can-i create clusters.postgresql.cnpg.io -n "$3" --as="$1" --as-group="oidc:$2" --as-group=system:authenticated 2>/dev/null)
  [ "$C" = no ] && ok "$1 cannot create Clusters in $3" || bad "$1 can create Clusters in $3"
done

step "3. a real database comes up and answers"
kubectl create ns "$T" >/dev/null 2>&1
cat <<YAML | kubectl -n "$T" apply -f - >/dev/null
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata: {name: probe}
spec:
  instances: 1
  storage: {size: 1Gi, storageClass: $SC}
  resources:
    requests: {cpu: 50m, memory: 128Mi}
    limits: {memory: 512Mi}
YAML
if kubectl -n "$T" wait --for=condition=Ready cluster/probe --timeout=420s >/dev/null 2>&1; then
  ok "Cluster probe is Ready"
else
  bad "Cluster probe not Ready in 420s: $(kubectl -n "$T" get cluster probe -o jsonpath='{.status.phase}' 2>/dev/null)"
fi
PV=$(kubectl -n "$T" get pvc -o jsonpath='{.items[0].spec.volumeName}' 2>/dev/null)
[ -n "$PV" ] && ok "volume bound ($PV) on StorageClass $SC" || bad "no volume bound"
SECRET=$(kubectl -n "$T" get secret probe-app -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)
[ -n "$SECRET" ] && ok "Secret probe-app holds a generated password" || bad "Secret probe-app missing"
# The -rw Service can lag the Cluster's Ready condition by a few seconds, so try for up to 45 s.
OUT=""; ERR=""
for _ in $(seq 1 15); do
  R=$(kubectl -n "$T" exec probe-1 -c postgres -- env PGPASSWORD="$SECRET" psql -h probe-rw -U app -d app -tAc 'select 1' 2>&1)
  OUT=$(printf '%s' "$R" | tr -d '[:space:]')
  [ "$OUT" = 1 ] && break
  ERR="$R"; sleep 3
done
[ "$OUT" = 1 ] && ok "query through Service probe-rw as user app returned 1" || bad "query through probe-rw failed: ${ERR:0:200}"

step "result"
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] && echo "CLOUDNATIVE-PG CHECK: OK"
exit "$FAIL"
