#!/usr/bin/env bash
# Longhorn pass check: a volume binds, a pod writes a file, the pod is deleted, a NEW pod on a
# DIFFERENT worker reads the file back. Then everything it created is removed, including the
# retained PV and the Longhorn volume (the StorageClass uses reclaimPolicy: Retain).
#
#   ./tests/storage-longhorn.sh                  # run the check (StorageClass: longhorn)
#   SC=longhorn ./tests/storage-longhorn.sh
#   KEEP=1 ./tests/storage-longhorn.sh           # do not clean up (inspect, then clean by hand)
#
# Needs: kubectl with cluster access, Longhorn installed. Not watched by Argo CD.
# Creates only: namespace longhorn-test, one 1Gi PVC, two short-lived pods.
set -uo pipefail

SC="${SC:-longhorn}"
NS="${NS:-longhorn-test}"
IMG="${IMG:-busybox:1.36}"
KEEP="${KEEP:-0}"
PASS=0; FAIL=0
ok()   { printf '  PASS  %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n' "$*"; FAIL=$((FAIL+1)); }
step() { printf '\n== %s\n' "$*"; }

PV=""
cleanup() {
  [ "$KEEP" = 1 ] && { echo; echo "KEEP=1: left namespace $NS and volume $PV in place"; return; }
  step "cleanup"
  kubectl delete namespace "$NS" --wait=true --timeout=120s >/dev/null 2>&1 && echo "  namespace $NS deleted"
  if [ -n "$PV" ]; then
    kubectl delete pv "$PV" --wait=true --timeout=60s >/dev/null 2>&1 && echo "  PV $PV deleted"
    kubectl -n longhorn-system delete volumes.longhorn.io "$PV" --wait=true --timeout=90s >/dev/null 2>&1 \
      && echo "  Longhorn volume $PV deleted"
  fi
}
trap cleanup EXIT

step "preflight"
kubectl get storageclass "$SC" >/dev/null 2>&1 && ok "StorageClass $SC exists" || { bad "StorageClass $SC missing"; exit 1; }
kubectl get ns "$NS" >/dev/null 2>&1 && { bad "namespace $NS already exists, remove it first"; KEEP=1; exit 1; }
READY=$(kubectl -n longhorn-system get nodes.longhorn.io -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null | grep -c True)
[ "$READY" -ge 2 ] && ok "$READY Longhorn nodes Ready" || bad "fewer than 2 Longhorn nodes Ready ($READY)"

step "1. create volume and writer pod"
kubectl apply -f - <<EOF >/dev/null
apiVersion: v1
kind: Namespace
metadata: {name: $NS}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: test-rwo, namespace: $NS}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: $SC
  resources: {requests: {storage: 1Gi}}
---
apiVersion: v1
kind: Pod
metadata: {name: writer, namespace: $NS}
spec:
  containers:
    - name: w
      image: $IMG
      command: ["sh","-c","echo \"written by writer at \$(date -u +%FT%TZ)\" > /data/hello.txt; sync; sleep 3600"]
      volumeMounts: [{name: d, mountPath: /data}]
  volumes: [{name: d, persistentVolumeClaim: {claimName: test-rwo}}]
EOF
kubectl -n "$NS" wait --for=jsonpath='{.status.phase}'=Bound pvc/test-rwo --timeout=90s >/dev/null 2>&1 \
  && ok "PVC bound" || bad "PVC did not bind in 90s"
PV=$(kubectl -n "$NS" get pvc test-rwo -o jsonpath='{.spec.volumeName}' 2>/dev/null)
kubectl -n "$NS" wait --for=condition=Ready pod/writer --timeout=120s >/dev/null 2>&1 \
  && ok "writer pod running" || bad "writer pod not Ready in 120s"
WNODE=$(kubectl -n "$NS" get pod writer -o jsonpath='{.spec.nodeName}' 2>/dev/null)
echo "  volume: ${PV:-none}   writer on: ${WNODE:-?}"

step "2. replicas"
if [ -n "$PV" ]; then
  kubectl -n longhorn-system get volumes.longhorn.io "$PV" -o jsonpath='  state={.status.state} robustness={.status.robustness} replicas={.spec.numberOfReplicas}{"\n"}' 2>/dev/null
  RN=$(kubectl -n longhorn-system get replicas.longhorn.io -l longhornvolume="$PV" -o jsonpath='{range .items[*]}{.spec.nodeID}{" "}{.status.currentState}{"\n"}{end}' 2>/dev/null)
  echo "$RN" | sed 's/^/  replica on /'
  [ "$(echo "$RN" | grep -c running)" -ge 2 ] && ok "at least 2 replicas running" || bad "fewer than 2 running replicas"
  [ "$(echo "$RN" | awk '{print $1}' | sort -u | wc -l)" -ge 2 ] && ok "replicas on different nodes" || bad "replicas not spread across nodes"
fi

step "3. delete writer, read back from a new pod on another node"
kubectl -n "$NS" delete pod writer --wait=true >/dev/null 2>&1
kubectl apply -f - <<EOF >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: reader, namespace: $NS}
spec:
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - {key: kubernetes.io/hostname, operator: NotIn, values: ["${WNODE:-none}"]}
  containers:
    - name: r
      image: $IMG
      command: ["sh","-c","sleep 3600"]
      volumeMounts: [{name: d, mountPath: /data}]
  volumes: [{name: d, persistentVolumeClaim: {claimName: test-rwo}}]
EOF
kubectl -n "$NS" wait --for=condition=Ready pod/reader --timeout=150s >/dev/null 2>&1 \
  && ok "reader pod running" || bad "reader pod not Ready in 150s"
RNODE=$(kubectl -n "$NS" get pod reader -o jsonpath='{.spec.nodeName}' 2>/dev/null)
[ -n "$RNODE" ] && [ "$RNODE" != "$WNODE" ] && ok "reader on a different node ($RNODE)" || bad "reader not on a different node"
CONTENT=$(kubectl -n "$NS" exec reader -- cat /data/hello.txt 2>/dev/null)
echo "  file: $CONTENT"
echo "$CONTENT" | grep -q "written by writer" && ok "data survived pod deletion and node change" || bad "file missing or wrong"

step "result"
echo "  passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] && echo "  LONGHORN BASIC CHECK: OK" || echo "  LONGHORN BASIC CHECK: FAILED"
[ "$FAIL" -eq 0 ]
