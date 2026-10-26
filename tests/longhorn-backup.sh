#!/usr/bin/env bash
# Longhorn backup pass check: the backup target is Available, the recurring job exists, the labelled volumes are
# selected, and a real backup of the smallest labelled volume restores into a scratch volume.
#
#   ./tests/longhorn-backup.sh
#   VOL=<longhorn volume name> ./tests/longhorn-backup.sh
#
# Creates and removes: one snapshot (kept as `removed` until the next recurring snapshot purges it, 170 MB for the
# Grafana volume), one backup (also removed from the NFS share), one scratch volume.
set -uo pipefail
NS=longhorn-system
PASS=0; FAIL=0
ok()   { printf '  PASS  %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n' "$*"; FAIL=$((FAIL+1)); }
step() { printf '\n== %s\n' "$*"; }
ID="bkptest-$(date +%s)"; R="restore-$ID"; V=""
cleanup() {
  kubectl -n $NS delete volumes.longhorn.io "$R" --ignore-not-found --wait=true --timeout=60s >/dev/null 2>&1
  kubectl -n $NS delete backups.longhorn.io "$ID" --ignore-not-found --wait=true --timeout=60s >/dev/null 2>&1
  # Longhorn keeps the newest snapshot of a volume (marked removed) until the next snapshot is taken: do not wait
  kubectl -n $NS delete snapshots.longhorn.io "$ID" --ignore-not-found --wait=false >/dev/null 2>&1
}
trap cleanup EXIT

step "1. target and job"
A=$(kubectl -n $NS get backuptargets.longhorn.io default -o jsonpath='{.status.available}')
U=$(kubectl -n $NS get backuptargets.longhorn.io default -o jsonpath='{.spec.backupTargetURL}')
[ "$A" = true ] && ok "backup target Available ($U)" || bad "backup target not available: $U"
J=$(kubectl -n $NS get recurringjobs.longhorn.io backup-daily -o jsonpath='{.spec.task}|{.spec.cron}|{.spec.retain}|{.spec.groups[0]}' 2>/dev/null)
[ "$J" = "backup|30 1 * * *|7|backup" ] && ok "recurring job backup-daily ($J)" || bad "recurring job: '$J'"
SEL=$(kubectl -n $NS get volumes.longhorn.io -l recurring-job-group.longhorn.io/backup=enabled -o name | wc -l)
[ "$SEL" -ge 1 ] && ok "$SEL volume(s) in group backup" || bad "no volume has the label recurring-job-group.longhorn.io/backup=enabled"

step "2. backup and restore of one volume"
if [ -z "${VOL:-}" ]; then
  VOL=$(kubectl -n $NS get volumes.longhorn.io -l recurring-job-group.longhorn.io/backup=enabled \
        -o jsonpath='{range .items[*]}{.spec.size}{" "}{.metadata.name}{"\n"}{end}' | sort -n | head -1 | cut -d' ' -f2)
fi
V="$VOL"; SZ=$(kubectl -n $NS get volumes.longhorn.io "$V" -o jsonpath='{.spec.size}')
echo "  volume $V ($SZ bytes)"
kubectl -n $NS apply -f - >/dev/null 2>&1 <<YAML
apiVersion: longhorn.io/v1beta2
kind: Snapshot
metadata: {name: $ID, namespace: $NS}
spec: {volume: $V, createSnapshot: true}
YAML
for i in $(seq 1 30); do [ "$(kubectl -n $NS get snapshots.longhorn.io $ID -o jsonpath='{.status.readyToUse}')" = true ] && break; sleep 2; done
kubectl -n $NS apply -f - >/dev/null 2>&1 <<YAML
apiVersion: longhorn.io/v1beta2
kind: Backup
metadata: {name: $ID, namespace: $NS, labels: {backup-volume: $V}}
spec: {snapshotName: $ID, labels: {test: tests-longhorn-backup}}
YAML
for i in $(seq 1 120); do S=$(kubectl -n $NS get backups.longhorn.io $ID -o jsonpath='{.status.state}'); case "$S" in Completed|Error) break;; esac; sleep 3; done
[ "$S" = Completed ] && ok "backup $ID Completed" || bad "backup state '$S'"
BURL=$(kubectl -n $NS get backups.longhorn.io $ID -o jsonpath='{.status.url}')
kubectl -n $NS apply -f - >/dev/null 2>&1 <<YAML
apiVersion: longhorn.io/v1beta2
kind: Volume
metadata: {name: $R, namespace: $NS}
spec: {size: "$SZ", numberOfReplicas: 2, frontend: blockdev, fromBackup: "$BURL", dataEngine: v1}
YAML
for i in $(seq 1 100); do
  ST=$(kubectl -n $NS get volumes.longhorn.io $R -o jsonpath='{.status.state}/{.status.restoreRequired}')
  [ "$ST" = "detached/false" ] && break; sleep 3
done
[ "$ST" = "detached/false" ] && ok "restored into scratch volume $R" || bad "restore state '$ST'"

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
