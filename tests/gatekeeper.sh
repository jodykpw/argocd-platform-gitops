#!/usr/bin/env bash
# Gatekeeper pass check: admission and audit replicas ready, no restarts, CRDs, both templates and constraints exist
# and are enforced, a `:latest` pod and an unapproved registry in a tenant namespace are reported (dryrun) or refused
# (deny) according to the constraint mode, a pinned image from an approved registry is accepted, the same `:latest`
# pod in `default` is untouched.
#
#   ./tests/gatekeeper.sh
#   NS=gatekeeper-system TENANT_NS=zeedlogic-dev ./tests/gatekeeper.sh
#
# RESILIENCE=1 also deletes one admission pod and checks that tenant pods are still admitted (run it before relying on
# validatingWebhookFailurePolicy: Fail).
# Creates and removes pods `gk-test-*` in $TENANT_NS and one in `default`.
set -uo pipefail
NS="${NS:-gatekeeper-system}"
TENANT_NS="${TENANT_NS:-zeedlogic-dev}"
PASS=0; FAIL=0
ok()   { printf '  PASS  %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n' "$*"; FAIL=$((FAIL+1)); }
step() { printf '\n== %s\n' "$*"; }
# Tenant namespaces have a quota that demands limits, and Pod Security warns without these fields.
ov() { # ov <name> <image>
  printf '{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":65534,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"%s","image":"%s","securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}},"resources":{"requests":{"cpu":"5m","memory":"8Mi"},"limits":{"cpu":"20m","memory":"16Mi"}}}]}}' "$1" "$2"
}
cleanup() {
  kubectl -n "$TENANT_NS" delete pod gk-test-latest gk-test-pinned gk-test-registry gk-test-resilience --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl -n default delete pod gk-test-latest --ignore-not-found --wait=false >/dev/null 2>&1
}
trap cleanup EXIT

step "1. controllers"
for d in gatekeeper-controller-manager:3 gatekeeper-audit:1; do
  n=${d%%:*}; want=${d##*:}
  r=$(kubectl -n "$NS" get deploy "$n" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  [ "${r:-0}" -ge "$want" ] && ok "$n ready ($r of $want)" || bad "$n ready ${r:-0} of $want"
done
RT=$(kubectl -n "$NS" get pods -o json | python3 -I -c 'import json,sys
n=0
for p in json.load(sys.stdin)["items"]:
    for c in p["status"].get("containerStatuses",[]): n+=c["restartCount"]
print(n)')
[ "${RT:-1}" -eq 0 ] && ok "no container restarts" || bad "containers restarted $RT times"
L=$(kubectl get ns "$NS" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}')
[ "$L" = restricted ] && ok "namespace $NS enforces Pod Security restricted" || bad "namespace $NS Pod Security is '$L'"
kubectl get crd constrainttemplates.templates.gatekeeper.sh >/dev/null 2>&1 && ok "CRDs installed" || bad "CRDs missing"
kubectl get mutatingwebhookconfiguration gatekeeper-mutating-webhook-configuration >/dev/null 2>&1 \
  && bad "mutating webhook exists (mutation is off by decision)" || ok "no mutating webhook"
FP=$(kubectl get validatingwebhookconfiguration gatekeeper-validating-webhook-configuration -o jsonpath='{.webhooks[?(@.name=="validation.gatekeeper.sh")].failurePolicy}' 2>/dev/null)
echo "  webhook failurePolicy: $FP"

step "2. templates and constraints"
for t in tenantimagetags tenantimageregistries; do
  kubectl get constrainttemplate "$t" >/dev/null 2>&1 && ok "ConstraintTemplate $t exists" || bad "ConstraintTemplate $t missing"
  CRT=$(kubectl get constrainttemplate "$t" -o jsonpath='{.status.created}' 2>/dev/null)
  [ "$CRT" = true ] && ok "template $t compiled (its Constraint kind exists)" || bad "template $t not created ('$CRT')"
done
for c in tenantimagetags/tenant-image-tags tenantimageregistries/tenant-image-registries; do
  k=${c%%/*}; n=${c##*/}
  ACT=$(kubectl get "$k" "$n" -o jsonpath='{.spec.enforcementAction}' 2>/dev/null)
  BYP=$(kubectl get "$k" "$n" -o jsonpath='{.status.byPod[*].enforced}' 2>/dev/null)
  [[ "$BYP" == *true* ]] && ok "constraint $n enforced by a pod (mode: $ACT)" || bad "constraint $n not enforced yet ('$BYP')"
  eval "ACT_${k}=\"$ACT\""
done

step "3. a :latest pod and a pinned pod in $TENANT_NS"
OUT=$(kubectl -n "$TENANT_NS" run gk-test-latest --image=registry.k8s.io/pause:latest --restart=Never --overrides="$(ov gk-test-latest registry.k8s.io/pause:latest)" 2>&1); RC=$?
if [ "$ACT_tenantimagetags" = deny ]; then
  [ $RC -ne 0 ] && ok "the :latest pod is refused" || bad "the :latest pod was admitted in deny mode"
else
  if [ $RC -ne 0 ] && [[ "$OUT" == *admission\ webhook* && "$OUT" != *gatekeeper* ]]; then
    echo "  note  another admission webhook refused the pod first: the dryrun audit cannot be tested"
    V=-1
  else
    [ $RC -eq 0 ] && ok "the :latest pod is admitted (dryrun)" || bad "the :latest pod was refused in dryrun mode: $OUT"
    V=0
  fi
  [ "$V" = -1 ] || for _ in $(seq 1 30); do   # the audit runs every 60 s
    V=$(kubectl get tenantimagetags tenant-image-tags -o json 2>/dev/null | python3 -I -c 'import json,sys
try:
  d=json.load(sys.stdin)
except Exception:
  print(0); sys.exit()
print(sum(1 for v in d.get("status",{}).get("violations",[]) if v.get("name")=="gk-test-latest"))' 2>/dev/null)
    [ "${V:-0}" -ge 1 ] && break; sleep 5
  done
  [ "$V" = -1 ] || { [ "${V:-0}" -ge 1 ] && ok "the audit lists the :latest pod as a violation" || bad "no audit violation for the :latest pod after 150 s"; }
fi
OUT=$(kubectl -n "$TENANT_NS" run gk-test-pinned --image=registry.k8s.io/pause:3.10 --restart=Never --overrides="$(ov gk-test-pinned registry.k8s.io/pause:3.10)" 2>&1) \
  && ok "a pinned image is admitted" || bad "a pinned image was refused: $OUT"

step "3b. an image from an unapproved registry"
OUT=$(kubectl -n "$TENANT_NS" run gk-test-registry --image=unapproved.example.com/pause:1 --restart=Never --overrides="$(ov gk-test-registry unapproved.example.com/pause:1)" 2>&1); RC=$?
if [ "$ACT_tenantimageregistries" = deny ]; then
  [ $RC -ne 0 ] && ok "an image from an unapproved registry is refused" || bad "an unapproved registry was admitted in deny mode"
else
  V=0
  if [ $RC -ne 0 ]; then
    if [[ "$OUT" == *admission\ webhook* && "$OUT" != *gatekeeper* ]]; then echo "  note  another admission webhook refused the pod first: the dryrun audit cannot be tested"; V=-1
    else bad "the pod was refused in dryrun mode: $OUT"; fi
  fi
  [ "$V" = -1 ] || for _ in $(seq 1 30); do
    V=$(kubectl get tenantimageregistries tenant-image-registries -o json 2>/dev/null | python3 -I -c 'import json,sys
try:
  d=json.load(sys.stdin)
except Exception:
  print(0); sys.exit()
print(sum(1 for v in d.get("status",{}).get("violations",[]) if v.get("name")=="gk-test-registry"))' 2>/dev/null)
    [ "${V:-0}" -ge 1 ] && break; sleep 5
  done
  [ "$V" = -1 ] || { [ "${V:-0}" -ge 1 ] && ok "the audit lists the unapproved registry as a violation" || bad "no audit violation for the unapproved registry after 150 s"; }
fi

step "4. platform namespace is not matched"
kubectl -n default run gk-test-latest --image=registry.k8s.io/pause:latest --restart=Never >/dev/null 2>&1 \
  && ok "the :latest pod in default is admitted (not tenant scope)" || bad "the :latest pod in default was refused"

if [ "${RESILIENCE:-0}" = 1 ]; then
  step "5. one admission replica is lost (RESILIENCE=1; deletes one controller-manager pod)"
  P=$(kubectl -n "$NS" get pod -l control-plane=controller-manager -o jsonpath='{.items[0].metadata.name}')
  kubectl -n "$NS" delete pod "$P" --wait=false >/dev/null 2>&1
  OUT=$(kubectl -n "$TENANT_NS" run gk-test-resilience --image=registry.k8s.io/pause:3.10 --restart=Never --overrides="$(ov gk-test-resilience registry.k8s.io/pause:3.10)" 2>&1) \
    && ok "a pod is admitted while one admission replica is gone" || bad "pod creation failed while one replica was gone: $OUT"
  kubectl -n "$NS" rollout status deploy/gatekeeper-controller-manager --timeout=120s >/dev/null 2>&1 \
    && ok "the controller manager is back to three replicas" || bad "the controller manager did not recover"
fi

printf '\npassed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
