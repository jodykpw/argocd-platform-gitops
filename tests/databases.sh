#!/usr/bin/env bash
# Databases pass check: the CloudNativePG Cluster for jodywan-dev is healthy, carries the label the network policies
# select on, has PostGIS and uuid-ossp, and is scraped; a pod in jodywan-dev connects through the -rw Service and
# runs postgis_version(); pods in the other namespaces (another environment of the same tenant, the other tenant)
# cannot connect.
#
#   ./tests/databases.sh
#   NAME=jodywan-dev-pg TENANT_NS=jodywan-dev ./tests/databases.sh
#   NAME=zeedlogic-dev-pg TENANT_NS=zeedlogic-dev OTHERS="jodywan-dev zeedlogic-stg" ./tests/databases.sh
#
# The probe pods set limits.cpu and limits.memory because the tenant ResourceQuota (Capsule) refuses a pod without them.
# Creates and removes: one temporary Secret and three short-lived pods (in jodywan-dev, jodywan-stg and zeedlogic-dev).
# The password is read from the Secret and never printed.
set -uo pipefail
NS="${NS:-databases}"
NAME="${NAME:-jodywan-dev-pg}"
TENANT_NS="${TENANT_NS:-jodywan-dev}"
OTHERS="${OTHERS:-jodywan-stg zeedlogic-dev}"
PASS=0; FAIL=0
ok()   { printf '  PASS  %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n' "$*"; FAIL=$((FAIL+1)); }
step() { printf '\n== %s\n' "$*"; }
IMG=$(kubectl -n "$NS" get cluster "$NAME" -o jsonpath='{.spec.imageName}' 2>/dev/null)
SEC="dbprobe-$$"
cleanup() {
  for n in $TENANT_NS $OTHERS; do
    kubectl -n "$n" delete pod "$SEC" --ignore-not-found --wait=false >/dev/null 2>&1
    kubectl -n "$n" delete secret "$SEC" --ignore-not-found >/dev/null 2>&1
  done
}
trap cleanup EXIT

# probe <namespace> <sql>: run psql from a throwaway pod in <namespace>. Sets OUT (the result), PHASE (the pod's end
# phase; Pending means it never started, so the run proves nothing) and LOGS. Not run in a subshell, so the globals stay.
probe() {
  local n="$1" sql="$2" pw ph=""
  OUT=""; PHASE=""; LOGS=""
  pw=$(kubectl -n "$NS" get secret "$NAME-app" -o jsonpath='{.data.password}' 2>/dev/null)
  [ -n "$pw" ] || return 1
  kubectl -n "$n" apply -f - >/dev/null 2>&1 <<YAML
apiVersion: v1
kind: Secret
metadata: {name: $SEC}
data: {password: $pw}
YAML
  kubectl -n "$n" delete pod "$SEC" --ignore-not-found --wait=true >/dev/null 2>&1
  kubectl -n "$n" run "$SEC" --restart=Never --image="$IMG" --image-pull-policy=IfNotPresent \
    --overrides='{"spec":{"containers":[{"name":"'"$SEC"'","image":"'"$IMG"'","command":["psql","-h","'"$NAME"'-rw.'"$NS"'.svc.cluster.local","-U","app","-d","app","-tAc","'"$sql"'"],"env":[{"name":"PGPASSWORD","valueFrom":{"secretKeyRef":{"name":"'"$SEC"'","key":"password"}}},{"name":"PGCONNECT_TIMEOUT","value":"6"}],"securityContext":{"allowPrivilegeEscalation":false,"runAsNonRoot":true,"capabilities":{"drop":["ALL"]},"seccompProfile":{"type":"RuntimeDefault"}},"resources":{"limits":{"cpu":"100m","memory":"128Mi"},"requests":{"cpu":"10m","memory":"32Mi"}}}]}}' \
    >/dev/null 2>&1
  for _ in $(seq 1 40); do
    ph=$(kubectl -n "$n" get pod "$SEC" -o jsonpath='{.status.phase}' 2>/dev/null)
    [ "$ph" = Succeeded ] || [ "$ph" = Failed ] && break
    sleep 3
  done
  PHASE="$ph"
  LOGS=$(kubectl -n "$n" logs "$SEC" 2>/dev/null | tr -d '\r')
  [ "$ph" = Succeeded ] && OUT="$LOGS"
  kubectl -n "$n" delete pod "$SEC" --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl -n "$n" delete secret "$SEC" --ignore-not-found >/dev/null 2>&1
}

step "1. the database"
PH=$(kubectl -n "$NS" get cluster "$NAME" -o jsonpath='{.status.phase}' 2>/dev/null)
[ "$PH" = "Cluster in healthy state" ] && ok "Cluster $NAME: $PH" || bad "Cluster $NAME phase is '$PH'"
N=$(kubectl -n "$NS" get pods -l "cnpg.io/cluster=$NAME" -o name 2>/dev/null | wc -l)
[ "$N" -ge 1 ] && ok "$N pod(s) carry the label cnpg.io/cluster=$NAME (the network policies select on it)" || bad "no pod carries cnpg.io/cluster=$NAME: the network policies match nothing"
PRIMARY=$(kubectl -n "$NS" get cluster "$NAME" -o jsonpath='{.status.currentPrimary}' 2>/dev/null)
EXT=$(kubectl -n "$NS" exec "$PRIMARY" -c postgres -- psql -U postgres -d app -tAc "select string_agg(extname, ',' order by extname) from pg_extension" 2>/dev/null)
case ",$EXT," in *,postgis,*) ok "extension postgis present";; *) bad "postgis missing ($EXT)";; esac
case ",$EXT," in *,uuid-ossp,*) ok "extension uuid-ossp present";; *) bad "uuid-ossp missing ($EXT)";; esac
[ "$(kubectl -n "$NS" get podmonitor -o name 2>/dev/null | wc -l)" -ge 1 ] && ok "PodMonitor exists" || bad "PodMonitor missing"
# The ZeedLogic core seed assigns ownership to the role zeedlogic_root (ADR-0123), so the role and its database must exist.
CANLOGIN=$(kubectl -n "$NS" exec "$PRIMARY" -c postgres -- psql -U postgres -tAc "select rolcanlogin from pg_roles where rolname='zeedlogic_root'" 2>/dev/null | tr -d '[:space:]')
[ "$CANLOGIN" = t ] && ok "role zeedlogic_root exists and can log in" || bad "role zeedlogic_root missing or cannot log in ('$CANLOGIN')"
OWNER=$(kubectl -n "$NS" exec "$PRIMARY" -c postgres -- psql -U postgres -tAc "select pg_get_userbyid(datdba) from pg_database where datname='zeedlogic'" 2>/dev/null | tr -d '[:space:]')
[ "$OWNER" = zeedlogic_root ] && ok "database zeedlogic exists, owned by zeedlogic_root" || bad "database zeedlogic missing or owned by '$OWNER'"
# The chart's seed Job runs as zeedlogic_root (not a superuser), so the Database resource must have installed the extensions
# the core seed needs; nobody creates them by hand.
ZEXT=$(kubectl -n "$NS" exec "$PRIMARY" -c postgres -- psql -U postgres -d zeedlogic -tAc "select string_agg(extname, ',' order by extname) from pg_extension" 2>/dev/null)
for e in fuzzystrmatch postgis postgis_topology postgis_tiger_geocoder uuid-ossp; do
  case ",$ZEXT," in *,$e,*) ok "database zeedlogic has extension $e";; *) bad "database zeedlogic lacks extension $e ($ZEXT)";; esac
done
# Keycloak keeps its own role and database, so identity data does not share the application's.
KCLOGIN=$(kubectl -n "$NS" exec "$PRIMARY" -c postgres -- psql -U postgres -tAc "select rolcanlogin from pg_roles where rolname='keycloak'" 2>/dev/null | tr -d '[:space:]')
KCOWNER=$(kubectl -n "$NS" exec "$PRIMARY" -c postgres -- psql -U postgres -tAc "select pg_get_userbyid(datdba) from pg_database where datname='keycloak'" 2>/dev/null | tr -d '[:space:]')
[ "$KCLOGIN" = t ] && [ "$KCOWNER" = keycloak ] && ok "role keycloak can log in and owns the database keycloak" || bad "keycloak role/database wrong (login '$KCLOGIN', owner '$KCOWNER')"

step "2. the tenant namespace $TENANT_NS reaches it"
probe "$TENANT_NS" "select postgis_version()"
case "$OUT" in 3.5*) ok "a pod in $TENANT_NS ran postgis_version(): ${OUT%% *}";; *) bad "pod in $TENANT_NS ended $PHASE: ${LOGS:0:160}";; esac

step "3. other namespaces cannot"
# The pod must have STARTED and then failed to connect (a timeout). A pod that never started (image pull, admission)
# proves nothing, so it counts as a failure of the test, not as isolation.
for o in $OTHERS; do
  probe "$o" "select 1"
  if [ "$PHASE" = Failed ] && echo "$LOGS" | grep -qiE "timeout|timed out"; then
    ok "a pod in $o started and its connection timed out"
  elif [ "$PHASE" = Succeeded ]; then
    bad "a pod in $o CONNECTED (result '$OUT')"
  else
    bad "inconclusive for $o: pod ended '$PHASE' ${LOGS:0:120}"
  fi
done

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] && echo "DATABASES CHECK: OK"
exit "$FAIL"
