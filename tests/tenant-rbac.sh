#!/usr/bin/env bash
# Tenant RBAC check (kubectl and helm, no Argo CD): ONLY owners create Roles and RoleBindings; developers deploy in
# all three namespaces (including prod) but never touch RBAC.
#
#   ./tests/tenant-rbac.sh
#
# Read-only: `kubectl auth can-i` and server-side dry runs with impersonation.
set -uo pipefail
PASS=0; FAIL=0
ok()   { printf '  PASS  %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n' "$*"; FAIL=$((FAIL+1)); }
step() { printf '\n== %s\n' "$*"; }
can() { # can <want> <user> <group> <verb> <resource> <ns>
  local got; got=$(kubectl auth can-i "$4" "$5" -n "$6" --as="$2" --as-group="oidc:$3" --as-group=system:authenticated 2>/dev/null | head -1)
  [ "$got" = "$1" ] && ok "$2 $4 $5 in $6: $1" || bad "$2 $4 $5 in $6: wanted $1, got '$got'"
}

step "1. who may create Roles and RoleBindings"
for t in zeedlogic jodywan; do
  other=$([ "$t" = zeedlogic ] && echo jodywan || echo zeedlogic)
  case $t in zeedlogic) DEV=dev@zeedlogic.com; OWN=owner@zeedlogic.com; VIEW=viewer@zeedlogic.com;;
             jodywan)   DEV=dev@jodywan.dev;   OWN=owner@jodywan.dev;   VIEW=viewer@jodywan.dev;; esac
  for e in dev stg prod; do
    for r in roles rolebindings; do
      can yes "$OWN"  "$t-owners"     create $r "$t-$e"
      can no  "$DEV"  "$t-developers" create $r "$t-$e"      # developers never edit RBAC, only owners do
      can no  "$VIEW" "$t-viewers"    create $r "$t-$e"
    done
  done
  for r in roles rolebindings; do can no "$OWN" "$t-owners" create $r "$other-dev"; done
  can no "$OWN" "$t-owners" create clusterroles ""
done

step "2. an owner cannot hand out more than an owner holds"
for t in zeedlogic jodywan; do
  case $t in zeedlogic) OWN=owner@zeedlogic.com;; jodywan) OWN=owner@jodywan.dev;; esac
  A="--as=$OWN --as-group=oidc:$t-owners --as-group=system:authenticated"
  out=$(kubectl create rolebinding rbac-test --clusterrole=cluster-admin --group="oidc:$t-developers" -n "$t-dev" $A --dry-run=server 2>&1)
  echo "$out" | grep -qi -E "forbidden|escalat" && ok "$OWN cannot bind cluster-admin to the developers (refused)" || bad "$OWN could bind cluster-admin: $out"
done

step "3. developers deploy everywhere in their tenant, but never touch RBAC or the tenant itself"
for t in zeedlogic jodywan; do
  case $t in zeedlogic) DEV=dev@zeedlogic.com;; jodywan) DEV=dev@jodywan.dev;; esac
  for e in dev stg prod; do
    can yes "$DEV" "$t-developers" create deployments "$t-$e"
    can yes "$DEV" "$t-developers" update deployments "$t-$e"
    can yes "$DEV" "$t-developers" create services "$t-$e"
  done
  can no "$DEV" "$t-developers" create rolebindings "$t-prod"
  can no "$DEV" "$t-developers" create resourcequotas "$t-prod"      # tenant quotas belong to Capsule and the platform
  # NetworkPolicies are part of `edit`: developers may add their own. The baseline cannot be changed (Capsule) and the
  # platform namespaces refuse tenant pods themselves (tests/tenant-network.sh section B).
done

echo; echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] && echo "TENANT RBAC CHECK: OK"
exit "$FAIL"
