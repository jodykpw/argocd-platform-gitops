# Tenant observability (metrics and logs per tenant)

- Part 3 of the tenant gate. Step 9 in `fresh-install-order.md`.
- Status: metrics, logs, the login mapping and a starter dashboard are **built and tested**; traces are not offered.
- Files: `tenant-observability/`, the tenant data sources in `overlays/k8s-1/grafana/values.yaml`.
- Test: `tests/tenant-observability.sh` (17 checks).

## 1. What a tenant gets

| Signal | Source | How it is restricted |
|---|---|---|
| **Metrics** | Thanos Querier (Prometheus, 12 h local + 7 days in Garage) | a `prom-label-proxy` per tenant fixes `namespace` to the tenant's three namespaces. The values are in the proxy's arguments: a client cannot choose, replace or widen them (regex, explicit namespace, query-parameter override all tested) |
| **Logs** | Loki | the data source of the tenant's Grafana organization sends `X-Scope-OrgID: <tenant>`; Fluent Bit already files each tenant's logs under its own Loki tenant. A client-supplied header is not forwarded (tested) |
| **Traces** | Jaeger | **not offered to tenants**: Jaeger has no tenancy. One deliberate exception: `zeedlogic-dev` may send (write-only), and traces are read in the platform organization only (`zeedlogic-observability.md`). Other tenants need Tempo (multi-tenant) |
| Platform and other tenant's data | | invisible: series without a `namespace` label (nodes, cluster components) are removed by the proxy, and the platform logs are in the Loki tenant `platform` |

## 2. How it is built

```
tenant user -> Grafana organization <tenant> (Editor, never Admin)
                 |- data source Prometheus (read-only, provisioned) -> prom-label-proxy-<tenant> -> thanos-query
                 '- data source Loki       (read-only, provisioned) -> loki, header X-Scope-OrgID: <tenant>
```

| Piece | Where |
|---|---|
| Organizations `zeedlogic` (id 2) and `jodywan` (id 3) | `tenant-observability/grafana-orgs.sh` (API, idempotent). Create them **before** syncing the data sources: provisioning into a missing org stops Grafana from starting |
| Metric proxies | `tenant-observability/prom-label-proxy.yaml`, app `tenant-observability` |
| Data sources per organization (`orgId` 2 and 3, `editable: false`) | `overlays/k8s-1/grafana/values.yaml` (`datasources`, list) |
| Platform data sources and dashboards | organization 1 (Main Org.), unchanged and not visible to tenant organizations |

**Why tenants must never be organization Admin:** an Admin can edit data sources (the header or the URL) and so
could read another tenant's logs. Editor can build dashboards and use Explore but cannot change data sources.

## 3. Login (decided and prepared)

| Step | What | Where |
|---|---|---|
| 1 | Grafana maps the token's `groups` to organizations and roles: `<tenant>-owners`, `-developers` and `-viewers` all become **Editor** in their tenant's organization only (viewers too: Grafana's Viewer role cannot use Explore); `cluster-admin` is Admin everywhere. New users are not added to Main Org. and cannot create organizations. A group that is not listed gets no role and cannot log in | `auth.generic_oauth.org_attribute_path` / `org_mapping` and `[users]` in `base/grafana/values.yaml` and `overlays/k8s-1/grafana/values.yaml` (`grafana.md`) |
| 2 | Authentik: one policy binding per tenant group on the application `Grafana k8s` only | `tenant-observability/authentik-grafana-bindings.py` (run through `ak shell` on docker-2 after step 1 is live) |
| 3 | One real login as a tenant test user, then check the user's organizations through the Grafana API | below |

Verify after the first login (as the platform admin):

```bash
# the user must be in exactly one organization, as Editor, not in Main Org.
curl -s -u admin:$PW localhost:3000/api/users/lookup?loginOrEmail=owner@zeedlogic.com     # note the id
curl -s -u admin:$PW localhost:3000/api/users/<id>/orgs
```

## 4. Not done yet

| Item | Note |
|---|---|
| Traces | Jaeger has no tenancy; needs Tempo |
| More starter dashboards | one is provided (below); tenants can build their own as Editors, they are saved in their organization |

## 5. Starter dashboard: `Namespace overview`

Every tenant organization gets one read-only dashboard (`grafana/dashboards/overview.json`, UID
`tenant-namespace-overview`): pods running and not ready, container restarts, memory in use, CPU, memory, restarts and
network per pod, log volume, and a log viewer, all filtered by a `Namespace` selector (the tenant's three
namespaces). Delivered as ConfigMap `tenant-dashboards` (kustomize source `grafana/` of the `grafana` app), mounted into Grafana
and provisioned by one file provider per organization (`orgId` 2 and 3). The ConfigMap must exist before the Grafana
pod starts: apply `kubectl apply -k tenant-observability` first on a rebuild. Panels stay empty until the tenant runs
workloads in its namespaces.

## 6. Verified login

`owner@zeedlogic.com` logged in through Authentik and was placed in organization `zeedlogic` as **Editor**: not in
Main Org., not a server admin. Explore shows only the tenant's logs (labels `container`, `namespace`, `pod`).

## 7. Operate

```bash
./tenant-observability/grafana-orgs.sh        # once, or after a Grafana rebuild
./tests/tenant-observability.sh               # 17 checks, about 1 minute; TEMP=1 before the data sources are synced
```

A new tenant namespace needs one more `-label-value` in `prom-label-proxy.yaml`. A new tenant needs a proxy, an
organization, two data sources and a Loki tenant name (Fluent Bit takes it from the Capsule tenant label).
