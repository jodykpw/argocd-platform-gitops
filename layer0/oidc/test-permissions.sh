#!/usr/bin/env bash
# Permission regression test for the Capsule tenants. Read-only: only `kubectl auth can-i` and
# list calls with impersonation (--as/--as-group), so it needs no logins and creates nothing.
# Run on the server as cluster-admin:  ./test-permissions.sh
# Exit code is the number of failed checks.
set -uo pipefail

PROXY="https://10.1.5.171:9001"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
kubectl get secret -n capsule-system capsule-proxy -o jsonpath='{.data.tls\.crt}' | base64 -d > "$TMP/proxy-ca.crt" 2>/dev/null

fail=0
# usage: check <expected yes|no> <user> <group> <can-i args...>
check() {
  local want="$1" user="$2" group="$3"; shift 3
  local got
  got=$(kubectl auth can-i "$@" --as="$user" --as-group="oidc:$group" --as-group=system:authenticated 2>/dev/null | grep -E '^(yes|no)' | head -1)
  if [ "$got" = "$want" ]; then printf 'PASS  %-3s %-24s %s\n' "$got" "$user" "$*"
  else printf 'FAIL  want %-3s got %-3s %-24s %s\n' "$want" "${got:-?}" "$user" "$*"; fail=$((fail+1)); fi
}
# usage: ns_list <user> <group> <expected space-separated namespaces> (through the proxy)
ns_list() {
  local user="$1" group="$2" want="$3" got
  got=$(kubectl --server="$PROXY" --certificate-authority="$TMP/proxy-ca.crt" get ns -o name --as="$user" --as-group="oidc:$group" --as-group=system:authenticated 2>&1 | sed 's#namespace/##' | sort | tr '\n' ' ' | sed 's/ $//')
  want=$(echo "$want" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')
  if [ "$got" = "$want" ]; then printf 'PASS  proxy get ns %-24s %s\n' "$user" "$got"
  else printf 'FAIL  proxy get ns %-24s want [%s] got [%s]\n' "$user" "$want" "$got"; fail=$((fail+1)); fi
}

for T in zeedlogic jodywan; do
  if [ "$T" = zeedlogic ]; then OTHER=jodywan; EO=owner@zeedlogic.com; ED=dev@zeedlogic.com; EV=viewer@zeedlogic.com
  else OTHER=zeedlogic; EO=owner@jodywan.dev; ED=dev@jodywan.dev; EV=viewer@jodywan.dev; fi
  echo "== tenant $T"
  # owner: admin everywhere in own namespaces, no cluster-scoped writes, nothing in the other tenant
  for e in dev stg prod; do
    check yes "$EO" "$T-owners" create deployments -n "$T-$e"
    check yes "$EO" "$T-owners" create rolebindings -n "$T-$e"
  done
  check yes "$EO" "$T-owners" get secrets -n "$T-prod"
  check no  "$EO" "$T-owners" create clusterroles
  check no  "$EO" "$T-owners" create clusterrolebindings
  check no  "$EO" "$T-owners" list namespaces                      # direct API: Forbidden (the proxy filters)
  check no  "$EO" "$T-owners" get pods -n "$OTHER-dev"
  check no  "$EO" "$T-owners" get pods -n argocd
  check no  "$EO" "$T-owners" get secrets -n capsule-system
  # developer: edit in dev, stg and prod, never Roles or RoleBindings
  for e in dev stg; do
    check yes "$ED" "$T-developers" create deployments -n "$T-$e"
    check yes "$ED" "$T-developers" create pods/exec -n "$T-$e"
    check no  "$ED" "$T-developers" create rolebindings -n "$T-$e"   # only owners edit RBAC
  done
  check yes "$ED" "$T-developers" get pods -n "$T-prod"
  check yes "$ED" "$T-developers" update deployments -n "$T-prod"
  check yes "$ED" "$T-developers" create pods/exec -n "$T-prod"
  check yes "$ED" "$T-developers" get secrets -n "$T-prod"
  check no  "$ED" "$T-developers" create rolebindings -n "$T-prod"
  check no  "$ED" "$T-developers" create roles -n "$T-prod"
  check no  "$ED" "$T-developers" get pods -n "$OTHER-dev"
  check yes "$ED" "$T-developers" create serviceaccounts/token -n "$T-dev"   # known risk of `edit`, see doc
  # viewer: read only, no secrets
  check yes "$EV" "$T-viewers" get pods -n "$T-prod"
  check no  "$EV" "$T-viewers" get secrets -n "$T-prod"
  check no  "$EV" "$T-viewers" create deployments -n "$T-dev"
  check no  "$EV" "$T-viewers" get pods -n "$OTHER-dev"
done

echo "== platform namespaces are invisible to tenants"
for ns in argocd traefik grafana capsule-system metallb-system; do
  check no owner@zeedlogic.com zeedlogic-owners get pods -n "$ns"
  check no dev@jodywan.dev jodywan-developers get pods -n "$ns"
done

echo "== Capsule Proxy: each user sees only their own namespaces"
Z="zeedlogic-dev zeedlogic-stg zeedlogic-prod"; J="jodywan-dev jodywan-stg jodywan-prod"
ns_list owner@zeedlogic.com  zeedlogic-owners "$Z"
ns_list dev@zeedlogic.com    zeedlogic-developers "$Z"
ns_list viewer@zeedlogic.com zeedlogic-viewers "$Z"
ns_list owner@jodywan.dev    jodywan-owners "$J"
ns_list dev@jodywan.dev      jodywan-developers "$J"
ns_list viewer@jodywan.dev   jodywan-viewers "$J"

echo
if [ "$fail" -eq 0 ]; then echo "ALL CHECKS PASSED"; else echo "$fail CHECK(S) FAILED"; fi
exit "$fail"
