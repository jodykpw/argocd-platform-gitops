#!/usr/bin/env bash
# Loki pass check: the StatefulSet is ready, its volume is a bound Longhorn PVC, the API answers on the Service,
# multi-tenancy is enforced (no X-Scope-OrgID header is refused), a pushed line is returned to its own tenant
# and not to another, and retention is on.
#
#   ./tests/loki.sh
#   NS=loki SVC=loki ./tests/loki.sh
#
# Pushes one line into a throwaway Loki tenant (`loki-test`); the line ages out with the normal retention.
# Uses a port-forward to the Service (local port 13100).
set -uo pipefail
NS="${NS:-loki}"
SVC="${SVC:-loki}"
TENANT="${TENANT:-loki-test}"
PORT="${PORT:-13100}"
PASS=0; FAIL=0
ok()   { printf '  PASS  %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n' "$*"; FAIL=$((FAIL+1)); }
step() { printf '\n== %s\n' "$*"; }

step "1. workload and volume"
R=$(kubectl -n "$NS" get statefulset loki -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[ "${R:-0}" -ge 1 ] && ok "StatefulSet loki ready ($R)" || bad "StatefulSet loki not ready"
PH=$(kubectl -n "$NS" get pvc -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
SC=$(kubectl -n "$NS" get pvc -o jsonpath='{.items[0].spec.storageClassName}' 2>/dev/null)
[ "$PH" = "Bound" ] && [ "$SC" = "longhorn" ] && ok "volume is Bound on class longhorn" || bad "volume is $PH on class '$SC' (expected Bound, longhorn)"
kubectl -n "$NS" get svc "$SVC" >/dev/null 2>&1 && ok "Service $SVC exists" || bad "Service $SVC missing"

step "2. API, tenants, push and query"
PF_LOG=$(mktemp)
kubectl -n "$NS" port-forward "svc/$SVC" "$PORT:3100" >"$PF_LOG" 2>&1 &
PF=$!
trap 'kill $PF >/dev/null 2>&1; rm -f "$PF_LOG"' EXIT
sleep 3
B="http://127.0.0.1:$PORT"
CODE=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$B/ready")
[ "$CODE" = "200" ] && ok "/ready returns 200" || bad "/ready returned $CODE"
CODE=$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$B/loki/api/v1/labels")
[ "$CODE" = "401" ] && ok "request without X-Scope-OrgID is refused (401)" || bad "request without a tenant returned $CODE (expected 401)"

MARK="loki-test-$(date +%s)-$RANDOM"
NOW=$(date +%s)000000000
CODE=$(curl -s -o /dev/null -m 10 -w '%{http_code}' -H "X-Scope-OrgID: $TENANT" -H 'Content-Type: application/json' \
  -X POST "$B/loki/api/v1/push" \
  -d "{\"streams\":[{\"stream\":{\"job\":\"loki-test\"},\"values\":[[\"$NOW\",\"$MARK\"]]}]}")
[ "$CODE" = "204" ] && ok "push accepted (204)" || bad "push returned $CODE"
sleep 2
Q() { curl -s -m 15 -G -H "X-Scope-OrgID: $1" "$B/loki/api/v1/query_range" \
        --data-urlencode "query={job=\"loki-test\"} |= \"$MARK\"" --data-urlencode "since=10m"; }
Q "$TENANT" | grep -q "$MARK" && ok "own tenant reads the line back" || bad "own tenant does not see the line"
Q "other-$TENANT" | grep -q "$MARK" && bad "ANOTHER tenant sees the line (isolation broken)" || ok "another tenant does not see the line"
MQ=$(curl -s -m 15 -G -H "X-Scope-OrgID: $TENANT|other-$TENANT" "$B/loki/api/v1/query_range" \
      --data-urlencode "query={job=\"loki-test\"} |= \"$MARK\"" --data-urlencode "since=10m")
echo "$MQ" | grep -q "$MARK" && ok "multi-tenant query (a|b) works" || bad "multi-tenant query returned nothing (multi_tenant_queries_enabled?)"

step "3. configuration"
CFG=$(kubectl -n "$NS" get configmap loki -o jsonpath='{.data.config\.yaml}' 2>/dev/null)
echo "$CFG" | grep -q 'retention_enabled: true' && ok "compactor retention enabled" || bad "compactor retention not enabled"
echo "$CFG" | grep -q 'retention_period: 168h' && ok "retention_period 168h" || bad "retention_period is not 168h"
RT=$(kubectl -n "$NS" get pods -o json | python3 -I -c 'import json,sys; print(sum(c["restartCount"] for p in json.load(sys.stdin)["items"] for c in p["status"].get("containerStatuses",[])))')
[ "${RT:-1}" -eq 0 ] && ok "no container restarts" || bad "containers restarted $RT times (OOMKilled? check the limit)"

step "4. LAN access for the central Grafana (docker-2)"
LANIP=$(kubectl -n "$NS" get svc loki-lan -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
if [ -z "$LANIP" ]; then echo "  NOTE  Service loki-lan has no address yet (not deployed?)"; else
  [ "$LANIP" = "10.1.5.173" ] && ok "loki-lan has address $LANIP" || bad "loki-lan has address $LANIP (expected 10.1.5.173)"
  EP=$(kubectl -n "$NS" get svc loki-lan -o jsonpath='{.spec.externalTrafficPolicy}')
  [ "$EP" = "Local" ] && ok "externalTrafficPolicy is Local (source IP kept)" || bad "externalTrafficPolicy is '$EP'"
  kubectl -n "$NS" get networkpolicy loki-ingress >/dev/null 2>&1 && ok "NetworkPolicy loki-ingress exists" || bad "NetworkPolicy loki-ingress missing"
  C=$(curl -s -m 8 -o /dev/null -w '%{http_code}' "http://$LANIP/ready" 2>/dev/null)
  case "$C" in 000|"") ok "this host is refused (not docker-2): no answer";; 200) bad "this host can reach Loki on $LANIP (policy not applied?)";; *) echo "  NOTE  this host got HTTP $C from $LANIP";; esac
  echo "  NOTE  after any policy change also run tests/fluent-bit.sh: Fluent Bit must still be able to push"
fi

step "result"
echo "  passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] && echo "  LOKI BASIC CHECK: OK" || echo "  LOKI BASIC CHECK: FAILED"
[ "$FAIL" -eq 0 ]
