#!/usr/bin/env bash
# Garage (S3) pass check: the cluster layout is applied, a temporary bucket and key can be created,
# and a pod inside the cluster can PUT, GET and LIST an object through the S3 API
# (http://garage.garage.svc:3900). Then the bucket, the key and the pod are removed.
#
#   ./tests/storage-garage.sh                # run the check
#   KEEP=1 ./tests/storage-garage.sh         # do not clean up
#
# Needs: kubectl with cluster access, Garage installed, layout applied (docs/storage-garage.md).
# Uses the Garage CLI inside pod garage-0 (/garage), and a short-lived pod with the aws CLI image.
# NOTE: written from the Garage v2.4.1 quick start; if a CLI flag differs in your version the
# script prints the failing command, adjust it here.
set -uo pipefail

NS="${NS:-garage}"
POD="${POD:-garage-0}"
SVC="${SVC:-garage}"
IMG="${IMG:-amazon/aws-cli:2.17.0}"
REGION="${REGION:-garage}"
KEEP="${KEEP:-0}"
SUF=$(head -c4 /dev/urandom | od -An -tx1 | tr -d ' \n')
BUCKET="k8s-test-$SUF"
KEYNAME="k8s-test-key-$SUF"
CLIPOD="garage-s3-test-$SUF"
PASS=0; FAIL=0
ok()   { printf '  PASS  %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n' "$*"; FAIL=$((FAIL+1)); }
step() { printf '\n== %s\n' "$*"; }
g()    { kubectl -n "$NS" exec "$POD" -- /garage "$@"; }

cleanup() {
  [ "$KEEP" = 1 ] && { echo; echo "KEEP=1: left bucket $BUCKET, key $KEYNAME, pod $CLIPOD"; return; }
  step "cleanup"
  kubectl -n "$NS" delete pod "$CLIPOD" --wait=false >/dev/null 2>&1 && echo "  pod $CLIPOD deleted"
  g bucket delete --yes "$BUCKET" >/dev/null 2>&1 && echo "  bucket $BUCKET deleted" || echo "  bucket $BUCKET not deleted (check: garage bucket list)"
  g key delete --yes "$KEYNAME" >/dev/null 2>&1 && echo "  key $KEYNAME deleted" || echo "  key $KEYNAME not deleted (check: garage key list)"
}
trap cleanup EXIT

step "preflight"
READY=$(kubectl -n "$NS" get sts "$SVC" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[ "${READY:-0}" -ge 1 ] && ok "Garage StatefulSet ready (${READY} replica)" || { bad "Garage StatefulSet not ready in namespace $NS"; exit 1; }
STATUS=$(g status 2>&1)
echo "$STATUS" | sed 's/^/  /' | head -8
echo "$STATUS" | grep -q "NO ROLE ASSIGNED" && { bad "layout not applied: run 'garage layout assign' and 'garage layout apply' (docs/storage-garage.md)"; exit 1; }
echo "$STATUS" | grep -q -i "HEALTHY NODES" && ok "node has a role (layout applied)" || bad "could not read garage status"

step "1. bucket and key"
g bucket create "$BUCKET" >/dev/null 2>&1 && ok "bucket $BUCKET created" || bad "bucket create failed"
KOUT=$(g key create "$KEYNAME" 2>&1)
KID=$(echo "$KOUT" | awk -F': *' '/Key ID/{print $2}' | tr -d ' \r')
KSEC=$(echo "$KOUT" | awk -F': *' '/Secret key/{print $2}' | tr -d ' \r')
[ -n "$KID" ] && [ -n "$KSEC" ] && ok "key $KEYNAME created ($KID)" || { bad "key create failed: $KOUT"; exit 1; }
g bucket allow --read --write --owner "$BUCKET" --key "$KEYNAME" >/dev/null 2>&1 \
  && ok "key allowed on bucket" || bad "bucket allow failed"

step "2. S3 PUT / GET / LIST from a pod"
OUT=$(kubectl -n "$NS" run "$CLIPOD" --rm -i --restart=Never --image="$IMG" --quiet \
  --env="AWS_ACCESS_KEY_ID=$KID" --env="AWS_SECRET_ACCESS_KEY=$KSEC" --env="AWS_DEFAULT_REGION=$REGION" \
  --command -- sh -c "
    E=http://$SVC.$NS.svc.cluster.local:3900
    echo hello-from-s3-test > /tmp/hello.txt
    aws --endpoint-url \$E s3 cp /tmp/hello.txt s3://$BUCKET/hello.txt && echo PUT_OK
    aws --endpoint-url \$E s3 cp s3://$BUCKET/hello.txt - | sed 's/^/GOT:/'
    aws --endpoint-url \$E s3 ls s3://$BUCKET/ | sed 's/^/LS:/'
    aws --endpoint-url \$E s3 rm s3://$BUCKET/hello.txt && echo RM_OK
  " 2>&1)
echo "$OUT" | sed 's/^/  /' | head -12
echo "$OUT" | grep -q "PUT_OK" && ok "PUT object" || bad "PUT failed"
echo "$OUT" | grep -q "GOT:hello-from-s3-test" && ok "GET object returns the same content" || bad "GET failed or wrong content"
echo "$OUT" | grep -q "LS:.*hello.txt" && ok "LIST shows the object" || bad "LIST failed"
echo "$OUT" | grep -q "RM_OK" && ok "DELETE object" || bad "DELETE failed"

step "result"
echo "  passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] && echo "  GARAGE S3 BASIC CHECK: OK" || echo "  GARAGE S3 BASIC CHECK: FAILED"
[ "$FAIL" -eq 0 ]
