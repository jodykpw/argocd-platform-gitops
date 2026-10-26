#!/usr/bin/env bash
# Create the Grafana organizations of the tenants (idempotent). Run BEFORE the data sources of base/kube-prometheus-stack
# are synced: provisioning a data source into an organization that does not exist stops Grafana from starting.
# The organization IDs are referenced as `orgId` in the values (zeedlogic = 2, jodywan = 3): create them in this order
# on a fresh Grafana, and check the printed IDs.
#
#   ./tenant-observability/grafana-orgs.sh
#
# Uses the admin account from the Secret grafana/grafana-admin through a port-forward; never prints the password.
set -euo pipefail
PW=$(kubectl -n grafana get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d)
kubectl -n grafana port-forward svc/grafana 13999:80 >/dev/null 2>&1 & PF=$!
trap 'kill $PF 2>/dev/null; unset PW' EXIT
until curl -s -m 2 localhost:13999/api/health >/dev/null; do sleep 1; done
for t in zeedlogic jodywan; do
  id=$(curl -s -u "admin:$PW" "localhost:13999/api/orgs/name/$t" | python3 -I -c 'import json,sys;print(json.load(sys.stdin).get("id",""))')
  if [ -z "$id" ]; then
    id=$(curl -s -u "admin:$PW" -X POST -H 'Content-Type: application/json' -d "{\"name\":\"$t\"}" localhost:13999/api/orgs | python3 -I -c 'import json,sys;print(json.load(sys.stdin).get("orgId"))')
    echo "created organization $t (id $id)"
  else echo "organization $t exists (id $id)"; fi
done
