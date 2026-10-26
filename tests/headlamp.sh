#!/usr/bin/env bash
# Headlamp pass check: the pod is ready, the HTTPRoute is accepted by the Traefik Gateway, the UI answers
# through Traefik, its ServiceAccount has no cluster-admin binding, and the OIDC issuer is reachable.
#
#   ./tests/headlamp.sh                  # run the check
#   HOST=headlamp.jodywan.com TRAEFIK=10.1.5.170 ./tests/headlamp.sh
#
# Read-only: it creates nothing. It checks the route through Traefik (LAN) and the public HTTPS URL
# (Cloudflare DNS, HAProxy on pfSense). The browser login itself (Authentik) is a manual check, see docs/headlamp.md.
set -uo pipefail
NS="${NS:-headlamp}"
HOST="${HOST:-headlamp.jodywan.com}"
TRAEFIK="${TRAEFIK:-10.1.5.170}"
ISSUER="${ISSUER:-https://authentik.jodywan.com/application/o/kube-apiserver-oauth-app/}"
PASS=0; FAIL=0
ok()   { printf '  PASS  %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n' "$*"; FAIL=$((FAIL+1)); }
step() { printf '\n== %s\n' "$*"; }

step "1. workload"
N=$(kubectl -n "$NS" get secret headlamp-oidc -o json 2>/dev/null | python3 -I -c 'import json,sys; print(len(json.load(sys.stdin).get("data",{})))' 2>/dev/null)
[ "${N:-0}" -ge 7 ] && ok "Secret headlamp-oidc exists (${N} keys)" || bad "Secret headlamp-oidc missing or incomplete (${N:-0} keys, expected 8)"
R=$(kubectl -n "$NS" get deploy headlamp -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[ "${R:-0}" -ge 1 ] && ok "deployment ready ($R)" || bad "deployment not ready"
kubectl -n "$NS" get svc headlamp >/dev/null 2>&1 && ok "service exists" || bad "service missing"
[ "$(kubectl get ns "$NS" -o jsonpath='{.metadata.labels.gateway-access}' 2>/dev/null)" = "platform" ] \
  && ok "namespace labelled gateway-access=platform" || bad "namespace not labelled gateway-access=platform"
echo "  volumes: $(kubectl -n "$NS" get pvc --no-headers 2>/dev/null | wc -l) PVCs (expected 0: stateless)"

step "2. route"
ACC=$(kubectl -n "$NS" get httproute headlamp -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null)
[ "$ACC" = "True" ] && ok "HTTPRoute accepted by the Gateway" || bad "HTTPRoute not accepted (Accepted=$ACC)"
CODE=$(curl -s -o /dev/null -m 10 -w '%{http_code}' --resolve "$HOST:80:$TRAEFIK" "http://$HOST/")
case "$CODE" in 200|301|302|307) ok "UI answers through Traefik (HTTP $CODE)";; *) bad "UI did not answer through Traefik (HTTP $CODE)";; esac
PCODE=$(curl -s -o /dev/null -m 15 -w '%{http_code}' "https://$HOST/")
case "$PCODE" in 200|301|302|307) ok "UI answers on the public HTTPS URL (HTTP $PCODE)";; *) bad "public https://$HOST/ returned HTTP $PCODE (DNS, HAProxy or TLS)";; esac

step "3. security"
CRB=$(kubectl get clusterrolebinding -o json 2>/dev/null | python3 -I -c '
import json,sys
n=0
for b in json.load(sys.stdin)["items"]:
    for s in b.get("subjects") or []:
        if s.get("kind")=="ServiceAccount" and s.get("namespace")=="'"$NS"'" and s.get("name")=="headlamp":
            n+=1; print("   binding:", b["metadata"]["name"], "->", b["roleRef"]["name"], file=sys.stderr)
print(n)')
[ "$CRB" = "0" ] && ok "ServiceAccount has no ClusterRoleBinding (users act with their own token)" || bad "ServiceAccount is bound to a ClusterRole ($CRB)"
kubectl auth can-i --as="system:serviceaccount:$NS:headlamp" get secrets -A >/dev/null 2>&1 \
  && bad "ServiceAccount can read secrets cluster-wide" || ok "ServiceAccount cannot read secrets cluster-wide"

step "4. OIDC issuer reachable"
DC=$(curl -s -m 10 -o /dev/null -w '%{http_code}' "${ISSUER}.well-known/openid-configuration")
[ "$DC" = "200" ] && ok "issuer discovery document answers (HTTP 200)" || bad "issuer discovery returned HTTP $DC"
kubectl -n "$NS" logs deploy/headlamp --tail=50 2>/dev/null | grep -i -E 'oidc.*(error|fail)|error.*oidc' | head -3 | sed 's/^/  log: /'

step "result"
echo "  passed: $PASS   failed: $FAIL"
echo "  Manual: open https://$HOST/ and sign in with Authentik (see docs/headlamp.md)."
[ "$FAIL" -eq 0 ] && echo "  HEADLAMP BASIC CHECK: OK" || echo "  HEADLAMP BASIC CHECK: FAILED"
[ "$FAIL" -eq 0 ]
