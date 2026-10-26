#!/usr/bin/env bash
# Tenant storage pass check: jodywan-dev can use ITS buckets in the platform's Garage over the S3 port and nothing else, and no other
# tenant namespace can reach Garage at all.
#   1. the buckets exist with a size quota, and the key is granted on exactly those two (not on `thanos`)
#   2. a pod in jodywan-dev, with the key from its Secret, writes, reads and deletes an object; lists the audit bucket
#   3. the same key cannot read the platform's `thanos` bucket
#   4. the same pod cannot reach Garage's admin (3903) or cluster RPC (3901) ports
#   5. pods in another environment (jodywan-stg) and the other tenant (zeedlogic-dev) cannot connect to 3900
#
#   ./tests/tenant-storage.sh
#   TENANT_NS=jodywan-dev FILES=jodywan-dev-zeedlogic-files AUDIT=jodywan-dev-zeedlogic-audit KEY=jodywan-dev-zeedlogic ./tests/tenant-storage.sh
#
# Creates and removes only throwaway pods (one per namespace). Reads the key through the Secret, never prints it.
set -uo pipefail
TENANT_NS="${TENANT_NS:-jodywan-dev}"
OTHERS="${OTHERS:-jodywan-stg zeedlogic-dev}"
FILES="${FILES:-jodywan-dev-zeedlogic-files}"
AUDIT="${AUDIT:-jodywan-dev-zeedlogic-audit}"
KEY="${KEY:-jodywan-dev-zeedlogic}"
SECRET="${SECRET:-zeedlogic-s3}"
IMG="${IMG:-amazon/aws-cli:2.38.1}"
EP=http://garage.garage.svc.cluster.local:3900
G="kubectl -n garage exec garage-0 -c garage -- /garage"
PASS=0; FAIL=0
ok()   { printf '  PASS  %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n' "$*"; FAIL=$((FAIL+1)); }
step() { printf '\n== %s\n' "$*"; }
POD="s3probe-$$"
cleanup() { for n in $TENANT_NS $OTHERS; do kubectl -n "$n" delete pod "$POD" --ignore-not-found --wait=false >/dev/null 2>&1; done; }
trap cleanup EXIT

# probe <namespace> <with-key 0|1> <bash script>: runs the script in a throwaway pod. Sets PHASE and LOGS; the script's own exit
# code is printed by the wrapper as "RC=<n>". A pod that never started (PHASE Pending) proves nothing.
probe() {
  local n="$1" withkey="$2" script="$3" env="" ph="" esc
  [ "$withkey" = 1 ] && env=',"env":[{"name":"AWS_ACCESS_KEY_ID","valueFrom":{"secretKeyRef":{"name":"'"$SECRET"'","key":"accessKey"}}},{"name":"AWS_SECRET_ACCESS_KEY","valueFrom":{"secretKeyRef":{"name":"'"$SECRET"'","key":"secretKey"}}},{"name":"AWS_DEFAULT_REGION","value":"garage"},{"name":"HOME","value":"/tmp"}]'
  PHASE=""; LOGS=""
  esc=$(python3 -I -c 'import json,sys;print(json.dumps("("+sys.argv[1]+"); echo RC=$?"))' "$script")
  kubectl -n "$n" delete pod "$POD" --ignore-not-found --wait=true >/dev/null 2>&1
  kubectl -n "$n" run "$POD" --restart=Never --image="$IMG" --image-pull-policy=IfNotPresent --overrides='{"spec":{"containers":[{"name":"'"$POD"'","image":"'"$IMG"'","command":["bash","-c"],"args":['"$esc"']'"$env"',"securityContext":{"allowPrivilegeEscalation":false,"runAsNonRoot":true,"runAsUser":1000,"capabilities":{"drop":["ALL"]},"seccompProfile":{"type":"RuntimeDefault"}},"resources":{"limits":{"cpu":"200m","memory":"256Mi"},"requests":{"cpu":"10m","memory":"64Mi"}}}]}}' >/dev/null 2>&1
  for _ in $(seq 1 60); do
    ph=$(kubectl -n "$n" get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null)
    [ "$ph" = Succeeded ] || [ "$ph" = Failed ] && break
    sleep 3
  done
  PHASE="$ph"; LOGS=$(kubectl -n "$n" logs "$POD" 2>/dev/null | tr -d '\r')
  kubectl -n "$n" delete pod "$POD" --ignore-not-found --wait=false >/dev/null 2>&1
}
rc() { printf '%s' "$LOGS" | sed -n 's/^RC=\([0-9]*\)$/\1/p' | tail -1; }
tcp() { echo "timeout 6 bash -c '</dev/tcp/garage.garage.svc.cluster.local/$1' 2>&1"; }

step "1. buckets, quotas and the key's grants (Garage CLI)"
for b in "$FILES" "$AUDIT"; do
  I=$($G bucket info "$b" 2>&1 | grep -v "garage_net")
  echo "$I" | grep -q "maximum size" && ok "bucket $b exists with a size quota" || bad "bucket $b missing or has no quota"
done
KI=$($G key info "$KEY" 2>&1 | grep -v "garage_net")
N=$(echo "$KI" | grep -cE "RW|R-|-W")
echo "$KI" | grep -q "$FILES" && echo "$KI" | grep -q "$AUDIT" && ! echo "$KI" | grep -q " thanos" && ok "key $KEY is granted on the two buckets and not on thanos" || bad "key $KEY grants are wrong"

step "2. $TENANT_NS uses its buckets over the S3 port"
probe "$TENANT_NS" 1 "echo probe-\$\$ > /tmp/o && aws s3api put-object --bucket $FILES --key probe.txt --body /tmp/o --endpoint-url $EP >/dev/null && aws s3api get-object --bucket $FILES --key probe.txt /tmp/back --endpoint-url $EP >/dev/null && [ \"\$(cat /tmp/o)\" = \"\$(cat /tmp/back)\" ] && aws s3api delete-object --bucket $FILES --key probe.txt --endpoint-url $EP >/dev/null"
[ "$(rc)" = 0 ] && ok "a pod in $TENANT_NS wrote, read back and deleted an object in $FILES" || bad "object round trip failed (phase ${PHASE:-none}, rc '$(rc)'): ${LOGS:0:200}"
probe "$TENANT_NS" 1 "aws s3api list-objects-v2 --bucket $AUDIT --endpoint-url $EP >/dev/null"
[ "$(rc)" = 0 ] && ok "the same key can list the audit bucket $AUDIT" || bad "audit bucket not reachable (phase ${PHASE:-none}): ${LOGS:0:200}"

step "3. the key is scoped to its own buckets"
probe "$TENANT_NS" 1 "aws s3api list-objects-v2 --bucket thanos --endpoint-url $EP"
if [ "$PHASE" != "" ] && [ -n "$(rc)" ] && [ "$(rc)" != 0 ] && printf '%s' "$LOGS" | grep -qiE "AccessDenied|Forbidden|not allowed"; then ok "the key is refused on the platform's thanos bucket"; else bad "thanos bucket not refused as expected (phase ${PHASE:-none}, rc '$(rc)'): ${LOGS:0:200}"; fi

step "4. the other Garage ports stay closed to the tenant"
probe "$TENANT_NS" 0 "$(tcp 3903)"
[ -n "$(rc)" ] && [ "$(rc)" != 0 ] && ok "the admin port 3903 is not reachable from $TENANT_NS" || bad "admin port 3903 reachable or the pod did not run (phase ${PHASE:-none}, rc '$(rc)')"
probe "$TENANT_NS" 0 "$(tcp 3901)"
[ -n "$(rc)" ] && [ "$(rc)" != 0 ] && ok "the cluster RPC port 3901 is not reachable from $TENANT_NS" || bad "RPC port 3901 reachable or the pod did not run (phase ${PHASE:-none}, rc '$(rc)')"

step "5. no other tenant namespace can connect"
for o in $OTHERS; do
  probe "$o" 0 "$(tcp 3900)"
  if [ -n "$PHASE" ] && [ -n "$(rc)" ] && [ "$(rc)" != 0 ]; then ok "a pod in $o started and could not connect to Garage's S3 port"
  elif [ "$(rc)" = 0 ]; then bad "a pod in $o CONNECTED to Garage's S3 port"
  else bad "inconclusive for $o (phase ${PHASE:-none}): ${LOGS:0:120}"; fi
done

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] && echo "TENANT STORAGE CHECK: OK"
exit "$FAIL"
