#!/usr/bin/env bash
# NFS pass check: a ReadWriteMany volume binds, TWO pods on DIFFERENT workers mount it at the same time,
# each writes a file and each reads the other's file. Then everything it created is removed.
#
#   ./tests/storage-nfs.sh                 # run the check (uses a temporary StorageClass)
#   KEEP=1 ./tests/storage-nfs.sh          # do not clean up
#
# The check uses its own temporary StorageClass `nfs-test` (same provisioner as `nfs`, reclaimPolicy Delete,
# archiveOnDelete false) so deleting the test PVC also removes its directory on the NFS server. The real
# `nfs` class (Retain) is not used, so no leftovers stay on TrueNAS.
#
# Needs: kubectl with cluster access, the nfs provisioner installed. Not watched by Argo CD.
set -uo pipefail

NS="${NS:-nfs-test}"
IMG="${IMG:-busybox:1.36}"
KEEP="${KEEP:-0}"
REAL_SC="${REAL_SC:-nfs}"
TEST_SC="nfs-test"
PASS=0; FAIL=0
ok()   { printf '  PASS  %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n' "$*"; FAIL=$((FAIL+1)); }
step() { printf '\n== %s\n' "$*"; }

PV=""
cleanup() {
  [ "$KEEP" = 1 ] && { echo; echo "KEEP=1: left namespace $NS, StorageClass $TEST_SC and PV $PV"; return; }
  step "cleanup"
  kubectl delete namespace "$NS" --wait=true --timeout=120s >/dev/null 2>&1 && echo "  namespace $NS deleted"
  if [ -n "$PV" ]; then
    for i in $(seq 1 30); do kubectl get pv "$PV" >/dev/null 2>&1 || break; sleep 2; done
    kubectl get pv "$PV" >/dev/null 2>&1 \
      && { kubectl delete pv "$PV" --wait=false >/dev/null 2>&1; echo "  PV $PV still present, deleted by hand (check the NFS directory)"; } \
      || echo "  PV $PV gone (provisioner removed the directory)"
  fi
  kubectl delete storageclass "$TEST_SC" >/dev/null 2>&1 && echo "  StorageClass $TEST_SC deleted"
}
trap cleanup EXIT

step "preflight"
kubectl get storageclass "$REAL_SC" >/dev/null 2>&1 && ok "StorageClass $REAL_SC exists" || { bad "StorageClass $REAL_SC missing"; exit 1; }
PROV=$(kubectl get storageclass "$REAL_SC" -o jsonpath='{.provisioner}')
MOPT=$(kubectl get storageclass "$REAL_SC" -o jsonpath='{.mountOptions[*]}')
echo "  provisioner: $PROV   mountOptions: $MOPT"
kubectl -n nfs-provisioner get deploy -o jsonpath='{range .items[*]}{.metadata.name}{" ready="}{.status.readyReplicas}{"\n"}{end}' 2>/dev/null | grep -q 'ready=1' \
  && ok "provisioner pod ready" || bad "provisioner not ready in namespace nfs-provisioner"
kubectl get ns "$NS" >/dev/null 2>&1 && { bad "namespace $NS already exists, remove it first"; KEEP=1; exit 1; }
NODES=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' --no-headers 2>/dev/null | awk '$2=="Ready"{print $1}')
[ "$(echo "$NODES" | grep -c .)" -ge 2 ] && ok "at least 2 Ready worker nodes" || { bad "need 2 Ready workers"; exit 1; }

step "1. temporary StorageClass, RWX volume, two pods on different nodes"
kubectl apply -f - <<EOF >/dev/null
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata: {name: $TEST_SC}
provisioner: $PROV
parameters: {archiveOnDelete: "false"}
reclaimPolicy: Delete
volumeBindingMode: Immediate
$( [ -n "$MOPT" ] && { echo "mountOptions:"; for o in $MOPT; do echo "  - $o"; done; } )
---
apiVersion: v1
kind: Namespace
metadata: {name: $NS}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: shared, namespace: $NS}
spec:
  accessModes: [ReadWriteMany]
  storageClassName: $TEST_SC
  resources: {requests: {storage: 1Gi}}
---
apiVersion: v1
kind: Pod
metadata: {name: pod-a, namespace: $NS, labels: {app: nfs-test}}
spec:
  affinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector: {matchLabels: {app: nfs-test}}
          topologyKey: kubernetes.io/hostname
  containers:
    - name: c
      image: $IMG
      command: ["sh","-c","echo from-pod-a > /data/a.txt; sync; sleep 3600"]
      volumeMounts: [{name: d, mountPath: /data}]
  volumes: [{name: d, persistentVolumeClaim: {claimName: shared}}]
---
apiVersion: v1
kind: Pod
metadata: {name: pod-b, namespace: $NS, labels: {app: nfs-test}}
spec:
  affinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector: {matchLabels: {app: nfs-test}}
          topologyKey: kubernetes.io/hostname
  containers:
    - name: c
      image: $IMG
      command: ["sh","-c","echo from-pod-b > /data/b.txt; sync; sleep 3600"]
      volumeMounts: [{name: d, mountPath: /data}]
  volumes: [{name: d, persistentVolumeClaim: {claimName: shared}}]
EOF
kubectl -n "$NS" wait --for=jsonpath='{.status.phase}'=Bound pvc/shared --timeout=90s >/dev/null 2>&1 \
  && ok "RWX PVC bound" || bad "PVC did not bind in 90s"
PV=$(kubectl -n "$NS" get pvc shared -o jsonpath='{.spec.volumeName}' 2>/dev/null)
kubectl -n "$NS" wait --for=condition=Ready pod/pod-a pod/pod-b --timeout=150s >/dev/null 2>&1 \
  && ok "both pods running" || bad "pods not Ready in 150s"
NA=$(kubectl -n "$NS" get pod pod-a -o jsonpath='{.spec.nodeName}' 2>/dev/null)
NB=$(kubectl -n "$NS" get pod pod-b -o jsonpath='{.spec.nodeName}' 2>/dev/null)
echo "  volume: ${PV:-none}   pod-a on: ${NA:-?}   pod-b on: ${NB:-?}"
[ -n "$NA" ] && [ -n "$NB" ] && [ "$NA" != "$NB" ] && ok "pods on different nodes" || bad "pods not on different nodes"

step "2. each pod reads the other's file"
sleep 3
RA=$(kubectl -n "$NS" exec pod-a -- cat /data/b.txt 2>/dev/null)
RB=$(kubectl -n "$NS" exec pod-b -- cat /data/a.txt 2>/dev/null)
echo "  pod-a reads b.txt: ${RA:-<missing>}"
echo "  pod-b reads a.txt: ${RB:-<missing>}"
[ "$RA" = "from-pod-b" ] && ok "pod-a sees pod-b's file" || bad "pod-a cannot see b.txt"
[ "$RB" = "from-pod-a" ] && ok "pod-b sees pod-a's file" || bad "pod-b cannot see a.txt"

step "3. mount details"
kubectl -n "$NS" exec pod-a -- sh -c 'grep " /data " /proc/mounts | cut -d" " -f1,3,4 | cut -c1-200' 2>/dev/null | sed 's/^/  /'

step "result"
echo "  passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] && echo "  NFS BASIC CHECK: OK" || echo "  NFS BASIC CHECK: FAILED"
[ "$FAIL" -eq 0 ]
