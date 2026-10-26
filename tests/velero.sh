#!/usr/bin/env bash
# Velero pass check: the server and S3 plugin run, the backup location is Available, the daily schedule exists, and
# a real backup and restore works end to end: a temporary namespace with a ConfigMap and a Secret is backed up,
# deleted, restored, and the data is compared. The test backup is removed from the bucket again.
#
#   ./tests/velero.sh
#   NS=velero ./tests/velero.sh
#
# Uses full resource names (backups.velero.io): plain `backup` is also a Longhorn resource.
# Creates and deletes the namespace `velero-restore-test`. Needs the app synced and the Secret `velero-s3`.
set -uo pipefail
NS="${NS:-velero}"
T="velero-restore-test"
ID="t$(date +%s)"
PASS=0; FAIL=0
ok()   { printf '  PASS  %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n' "$*"; FAIL=$((FAIL+1)); }
note() { printf '  NOTE  %s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
cleanup() {
  kubectl delete ns "$T" --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl -n "$NS" delete restores.velero.io "$ID" --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl -n "$NS" apply -f - >/dev/null 2>&1 <<YAML
apiVersion: velero.io/v1
kind: DeleteBackupRequest
metadata: {name: $ID-del, namespace: $NS}
spec: {backupName: $ID}
YAML
}
trap cleanup EXIT
waitphase() { # waitphase <kind> <name> <seconds> -> prints final phase
  local i ph
  for i in $(seq 1 "$3"); do
    ph=$(kubectl -n "$NS" get "$1" "$2" -o jsonpath='{.status.phase}' 2>/dev/null)
    case "$ph" in Completed|Failed|PartiallyFailed|FailedValidation) break;; esac; sleep 2
  done
  echo "$ph"
}

step "1. workload"
R=$(kubectl -n "$NS" get deploy velero -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[ "${R:-0}" -ge 1 ] && ok "deployment velero ready" || bad "deployment velero not ready"
RT=$(kubectl -n "$NS" get pods -o json | python3 -I -c 'import json,sys; print(sum(c["restartCount"] for p in json.load(sys.stdin)["items"] for c in p["status"].get("containerStatuses",[])))')
[ "${RT:-1}" -eq 0 ] && ok "no container restarts" || bad "containers restarted $RT times"
kubectl -n "$NS" get deploy velero -o jsonpath='{.spec.template.spec.initContainers[*].name}' | grep -q velero-plugin-for-aws && ok "S3 plugin present" || bad "S3 plugin missing"
[ -z "$(kubectl -n "$NS" get ds node-agent -o name 2>/dev/null)" ] && ok "no node agent (objects only, by design)" || note "node agent is deployed"
kubectl -n "$NS" get secret velero-s3 >/dev/null 2>&1 && ok "Secret velero-s3 exists" || bad "Secret velero-s3 missing"

step "2. backup location and schedule"
PH=$(kubectl -n "$NS" get backupstoragelocations.velero.io default -o jsonpath='{.status.phase}' 2>/dev/null)
[ "$PH" = "Available" ] && ok "backup location default is Available (bucket reachable, key accepted)" || bad "backup location is '$PH'"
URL=$(kubectl -n "$NS" get backupstoragelocations.velero.io default -o jsonpath='{.spec.config.s3Url}' 2>/dev/null)
[ "$URL" = "http://10.1.5.123:3910" ] && ok "points at the Garage on docker-2 ($URL)" || bad "s3Url is '$URL'"
SCH=$(kubectl -n "$NS" get schedules.velero.io velero-daily -o jsonpath='{.spec.schedule}|{.spec.paused}' 2>/dev/null)
[ "${SCH%%|*}" = "30 2 * * *" ] && [ "${SCH##*|}" != "true" ] && ok "schedule velero-daily exists, not paused ($SCH)" || bad "schedule velero-daily: '$SCH'"
kubectl -n "$NS" get servicemonitor velero >/dev/null 2>&1 && ok "ServiceMonitor exists" || bad "ServiceMonitor missing"

step "3. backup and restore of a temporary namespace"
kubectl create ns "$T" >/dev/null 2>&1
kubectl -n "$T" create configmap probe --from-literal=value="$ID" >/dev/null 2>&1
kubectl -n "$T" create secret generic probe --from-literal=value="$ID-secret" >/dev/null 2>&1
kubectl -n "$NS" apply -f - >/dev/null 2>&1 <<YAML
apiVersion: velero.io/v1
kind: Backup
metadata: {name: $ID, namespace: $NS}
spec: {includedNamespaces: [$T], storageLocation: default, ttl: 1h, snapshotVolumes: false}
YAML
BP=$(waitphase backups.velero.io "$ID" 60)
[ "$BP" = "Completed" ] && ok "backup $ID Completed" || bad "backup phase '$BP' (velero backup logs $ID)"
ERR=$(kubectl -n "$NS" get backups.velero.io "$ID" -o jsonpath='{.status.errors}' 2>/dev/null)
[ -z "$ERR" ] || [ "$ERR" = "0" ] && ok "backup has no errors" || bad "backup errors: $ERR"
kubectl delete ns "$T" --wait=true --timeout=60s >/dev/null 2>&1
kubectl get ns "$T" >/dev/null 2>&1 && bad "temporary namespace not deleted" || ok "temporary namespace deleted"
kubectl -n "$NS" apply -f - >/dev/null 2>&1 <<YAML
apiVersion: velero.io/v1
kind: Restore
metadata: {name: $ID, namespace: $NS}
spec: {backupName: $ID, includedNamespaces: [$T]}
YAML
RP=$(waitphase restores.velero.io "$ID" 60)
[ "$RP" = "Completed" ] && ok "restore $ID Completed" || bad "restore phase '$RP'"
V=$(kubectl -n "$T" get configmap probe -o jsonpath='{.data.value}' 2>/dev/null)
[ "$V" = "$ID" ] && ok "ConfigMap restored with its data" || bad "ConfigMap value '$V'"
S=$(kubectl -n "$T" get secret probe -o jsonpath='{.data.value}' 2>/dev/null | base64 -d)
[ "$S" = "$ID-secret" ] && ok "Secret restored with its data" || bad "Secret value mismatch"

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
