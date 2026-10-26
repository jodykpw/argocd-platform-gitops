#!/usr/bin/env bash
# Register the per-tenant Argo CD deployer accounts. Run as cluster-admin on a control plane.
#
#   ./tenant-gitops/register-deployers.sh            # dry run: shows what it would change
#   ./tenant-gitops/register-deployers.sh --apply    # does it
#
# This grants permissions, so it is NOT run by the Argo CD app: a person reviews and runs it.
#   1. ServiceAccounts argocd-deployer-<tenant> in namespace argocd        (tenant-gitops/deployers.yaml)
#   2. Capsule users: the two accounts are added (without this Capsule would not apply tenant policies to them)
#   3. Tenant owners: each account becomes an owner (clusterRole edit, so no Roles or RoleBindings) of its own
#      tenant ONLY
#   4. argocd-cm: sync impersonation on, enforced=false so the `platform` project keeps using the controller
#   5. the AppProjects (tenant-gitops/appprojects.yaml), last. They are deliberately NOT an Argo CD app: applied
#      before step 4 a tenant application would run as the cluster-admin controller.
# Afterwards run tests/tenant-gitops.sh (add E2E=1 once tests/fixtures/tenant-app is pushed). Git copies of steps 2 and 3 are in overlays/<cluster>/capsule/values.yaml and
# overlays/<cluster>/tenants/tenant-*.yaml; keep them in step, a Helm upgrade of Capsule would otherwise drop step 2.
set -euo pipefail
APPLY=0; [ "${1:-}" = "--apply" ] && APPLY=1
DIR="$(cd "$(dirname "$0")" && pwd)"
TENANTS="zeedlogic jodywan"
say() { printf '%s\n' "$*"; }
run() { say "+ $*"; [ "$APPLY" = 1 ] && eval "$@"; return 0; }
say "mode: $([ "$APPLY" = 1 ] && echo APPLY || echo dry-run)"

say; say "== 1. ServiceAccounts"
run "kubectl apply -f '$DIR/deployers.yaml'"

say; say "== 2. Capsule users"
for t in $TENANTS; do
  SA="system:serviceaccount:argocd:argocd-deployer-$t"
  if kubectl get capsuleconfiguration default -o jsonpath='{range .spec.users[*]}{.name}{"\n"}{end}' | grep -qx "$SA"; then say "already a Capsule user: $SA"
  else run "kubectl patch capsuleconfiguration default --type json -p '[{\"op\":\"add\",\"path\":\"/spec/users/-\",\"value\":{\"kind\":\"ServiceAccount\",\"name\":\"$SA\"}}]'"; fi
done

say; say "== 3. Tenant owners (edit in the tenant's own namespaces only)"
for t in $TENANTS; do
  SA="system:serviceaccount:argocd:argocd-deployer-$t"
  if kubectl get tenant "$t" -o jsonpath='{range .spec.owners[*]}{.name}{"\n"}{end}' | grep -qx "$SA"; then say "already an owner of $t: $SA"
  else run "kubectl patch tenant $t --type json -p '[{\"op\":\"add\",\"path\":\"/spec/owners/-\",\"value\":{\"kind\":\"ServiceAccount\",\"name\":\"$SA\",\"clusterRoles\":[\"edit\"]}}]'"; fi
done

say; say "== 4. Argo CD sync impersonation"
CUR=$(kubectl -n argocd get cm argocd-cm -o jsonpath='{.data.application\.sync\.impersonation\.enabled}')
if [ "$CUR" = "true" ]; then say "impersonation already enabled"
else
  run "kubectl -n argocd patch cm argocd-cm --type merge -p '{\"data\":{\"application.sync.impersonation.enabled\":\"true\",\"application.sync.impersonation.enforced\":\"false\"}}'"
  run "kubectl -n argocd rollout restart statefulset argocd-application-controller"
fi

say; say "== 5. AppProjects (last, so a tenant application can never run before impersonation is on)"
run "kubectl apply -f '$DIR/appprojects.yaml'"

say; say "== check (needs --apply to have effect)"
for t in $TENANTS; do
  other=$([ "$t" = zeedlogic ] && echo jodywan || echo zeedlogic)
  A="--as=system:serviceaccount:argocd:argocd-deployer-$t"
  printf '%-10s create rolebindings in %s-dev: %s | in %s-dev: %s | clusterroles: %s\n' "$t" "$t" \
    "$(kubectl auth can-i create rolebindings -n $t-dev $A 2>/dev/null)" "$other" \
    "$(kubectl auth can-i create rolebindings -n $other-dev $A 2>/dev/null)" \
    "$(kubectl auth can-i create clusterroles $A 2>/dev/null)"
done
