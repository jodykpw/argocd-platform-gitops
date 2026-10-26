#!/usr/bin/env bash
# Garage UI pass check (phase 1: ClusterIP + token login): the pod is ready, its Secrets exist, the UI answers
# on its Service, and Garage's admin API accepts the admin token (the token the UI uses).
#
#   ./tests/garage-ui.sh
#
# Read-only apart from one short-lived curl pod. The token is read from the cluster at run time and is
# never printed. The browser login is a manual check: kubectl -n garage port-forward svc/garage-ui 8080:80
# (phase 1 only; with OIDC enabled the login is https://garage-k8s.jodywan.com/, see docs/garage-ui.md).
# Phase 2 checks: the HTTPRoute is accepted, the public URL answers, and the Authentik issuer answers.
set -uo pipefail
NS="${NS:-garage}"
SVC="${SVC:-garage-ui}"
ADMIN_URL="${ADMIN_URL:-http://garage-0.garage-headless.garage.svc.cluster.local:3903}"
PASS=0; FAIL=0
ok()   { printf '  PASS  %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n' "$*"; FAIL=$((FAIL+1)); }
step() { printf '\n== %s\n' "$*"; }

step "1. workload and Secrets"
R=$(kubectl -n "$NS" get deploy "$SVC" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[ "${R:-0}" -ge 1 ] && ok "deployment $SVC ready ($R)" || bad "deployment $SVC not ready"
for s in garage-admin-token garage-ui-jwt garage-ui-oidc; do
  kubectl -n "$NS" get secret "$s" >/dev/null 2>&1 && ok "Secret $s exists" || bad "Secret $s missing"
done
kubectl -n "$NS" get svc "$SVC" >/dev/null 2>&1 && ok "Service $SVC exists" || bad "Service $SVC missing"

step "2. UI answers on its Service"
PF_LOG=$(mktemp)
kubectl -n "$NS" port-forward "svc/$SVC" 18080:80 >"$PF_LOG" 2>&1 &
PF=$!
sleep 3
CODE=$(curl -s -o /dev/null -m 10 -w '%{http_code}' http://127.0.0.1:18080/health)
kill "$PF" >/dev/null 2>&1; wait "$PF" 2>/dev/null; rm -f "$PF_LOG"
[ "$CODE" = "200" ] && ok "GET /health returns 200" || bad "GET /health returned $CODE"

step "2b. route, public URL and Authentik (phase 2)"
HOST="${HOST:-garage-k8s.jodywan.com}"
ISSUER="${ISSUER:-https://authentik.jodywan.com/application/o/garage-ui-oauth-app/}"
ACC=$(kubectl -n "$NS" get httproute "$SVC" -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null)
[ "$ACC" = "True" ] && ok "HTTPRoute accepted by the Gateway" || bad "HTTPRoute not accepted (Accepted=$ACC)"
[ "$(kubectl get ns "$NS" -o jsonpath='{.metadata.labels.gateway-access}' 2>/dev/null)" = "platform" ] \
  && ok "namespace $NS labelled gateway-access=platform" || bad "namespace $NS not labelled gateway-access=platform"
PC=$(curl -s -o /dev/null -m 15 -w '%{http_code}' "https://$HOST/health")
case "$PC" in 200|301|302|307) ok "public https://$HOST answers (HTTP $PC)";; *) bad "public https://$HOST returned HTTP $PC (DNS, HAProxy or TLS)";; esac
LOC=$(curl -s -o /dev/null -m 15 -w '%{http_code} %{redirect_url}' "https://$HOST/auth/oidc/login")
echo "  login start: $LOC" | cut -c1-160
echo "$LOC" | grep -q 'authentik.jodywan.com' && ok "login redirects to Authentik" || bad "login does not redirect to Authentik"
DC=$(curl -s -m 10 -o /dev/null -w '%{http_code}' "${ISSUER}.well-known/openid-configuration")
[ "$DC" = "200" ] && ok "issuer discovery answers (HTTP 200)" || bad "issuer discovery returned HTTP $DC"

step "3. Garage admin API accepts the admin token"
TOKEN=$(kubectl -n "$NS" get secret garage-admin-token -o jsonpath='{.data.admin-token}' 2>/dev/null | base64 -d)
if [ -z "$TOKEN" ]; then
  bad "cannot read the admin token"
else
  POD="garage-ui-test-$$"
  # run to completion, then read the logs (with --rm the last output line can be lost)
  kubectl -n "$NS" run "$POD" --restart=Never --quiet --image=curlimages/curl:8.10.1 \
    --command -- sh -c "
      echo NOAUTH=\$(curl -s -o /dev/null -m 8 -w '%{http_code}' $ADMIN_URL/v2/GetClusterHealth)
      echo AUTH=\$(curl -s -o /dev/null -m 8 -w '%{http_code}' -H 'Authorization: Bearer $TOKEN' $ADMIN_URL/v2/GetClusterHealth)
    " >/dev/null 2>&1
  for i in $(seq 1 30); do
    PH=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null)
    [ "$PH" = "Succeeded" ] || [ "$PH" = "Failed" ] && break
    sleep 2
  done
  OUT=$(kubectl -n "$NS" logs "$POD" 2>&1)
  kubectl -n "$NS" delete pod "$POD" --wait=false >/dev/null 2>&1
  echo "$OUT" | grep -E 'NOAUTH|AUTH' | sed 's/^/  /'
  echo "$OUT" | grep -q '^AUTH=200' && ok "admin API answers 200 with the token" || bad "admin API did not accept the token"
  echo "$OUT" | grep -q '^NOAUTH=\(401\|403\)' && ok "admin API refuses requests without the token" || bad "admin API answered without a token (check GARAGE_ADMIN_TOKEN)"
fi
unset TOKEN

step "result"
echo "  passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] && echo "  GARAGE UI BASIC CHECK: OK" || echo "  GARAGE UI BASIC CHECK: FAILED"
[ "$FAIL" -eq 0 ]
