# CloudNativePG

- PostgreSQL operator. Layer 1, Argo CD app `cloudnative-pg`, namespace `cnpg-system`. Step 8r in `fresh-install-order.md`.
- Chart `cloudnative-pg` 0.29.1 (operator 1.30.1). Auto-sync (`prune: false`).
- Test: `tests/cloudnative-pg.sh`.
- **The app installs only the operator.** A database is a `Cluster` resource created where it is needed. Not enabled for tenants (section 3).
- Status: synced and tested on k8s-1 on 2026-10-18: `tests/cloudnative-pg.sh` 12/12. On the first sync the Cluster and Pooler CRDs showed `OutOfSync` for about ten minutes (the live CRDs carry `spec.conversion: {strategy: None}`, a default the API server adds and the chart does not set), then settled to `Synced`. If it comes back, add `.spec.conversion` for CustomResourceDefinitions to `ignoreDifferences` in `appsets/cloudnative-pg.yaml`.
- Also learned: the test's first version queried the instant the Cluster turned Ready and failed once, because the `-rw` Service can lag a few seconds; it now retries for 45 s.

## 1. What it adds

A `Cluster` resource describes one primary and optional replicas. The operator creates the pods and their volumes
(PersistentVolumeClaims, not StatefulSets), runs failover, rolling updates and backups, and creates the connection
Services and Secrets.

| Part | Role |
|---|---|
| `cnpg-cloudnative-pg` (2 replicas, leader election) | the operator: watches every namespace, reconciles `Cluster`, `Backup`, `Pooler`, `Database` and the other kinds |
| 11 CRDs | `postgresql.cnpg.io` and related groups; installed by the chart, server-side apply |
| mutating and validating webhooks | check and default CNPG resources only |
| PodMonitor | Prometheus scrapes the operator (the stack accepts monitors from any namespace) |

For each `Cluster` named `<c>` the operator makes Services `<c>-rw` (primary), `<c>-ro` (replicas), `<c>-r` (any), and a
Secret `<c>-app` with the application user's credentials.

## 2. Fit with this cluster

| Question | Answer |
|---|---|
| Storage | `storageClass` must be set on every `Cluster`: **there is no default StorageClass**. `longhorn` keeps 2 replicas per volume and has `reclaimPolicy: Retain`, so a deleted `Cluster` leaves its PersistentVolumes behind until someone removes them (this is on purpose: no silent data loss). CloudNativePG also replicates, so an N-instance cluster on `longhorn` stores each row about 2N times; use `instances: 2` or `3` for real databases and `1` for tests |
| Operator storage | none: the operator pods mount only a scratch `emptyDir` and the webhook certificate Secret (checked 2026-10-18). Only a `Cluster` creates volumes |
| Spread | 3 workers: three instances fit one per worker. Memory per worker is the limit to check before sizing a database |
| Metrics | PodMonitor for the operator. Per-database metrics need `monitoring` on the `Cluster`; no dashboard is shipped (platform dashboards are ConfigMaps in `dashboards/platform/`) |
| Gatekeeper | `cnpg-system` is in the webhook exemption list (`overlays/k8s-1/gatekeeper/values.yaml`), as `gatekeeper.md` requires for a new platform namespace. The image policies apply to tenant namespaces only |
| Pod security | the namespace is `baseline`; the operator itself runs non-root, read-only root filesystem, no capabilities |
| Argo CD | `ignoreDifferences` for the CA bundle the operator writes into its two webhook configurations |

## 3. Tenants: not enabled (decision)

`rbac.aggregateClusterRoles: false`, so tenant owners and developers have **no** rights on CloudNativePG kinds (the test
checks it). Reason: a `Cluster` lets its author choose the container image, import data from an external server and write
backups to an object store, all executed by the operator, a cluster component with its own network access.

To enable it for the `zeedlogic` tenant (it is the reason this app exists: ADR-0123 expects the database from here), first:

1. Decide who creates `Cluster` resources: the platform team on request (no change needed), or tenant developers with
   Argo CD (then the tenants' AppProject allowlists must include the CNPG kinds).
2. Add a ValidatingAdmissionPolicy for `clusters.postgresql.cnpg.io` in tenant namespaces: an image allowlist
   (`ghcr.io/cloudnative-pg/*`), no `externalClusters`, no backup destination outside the tenant's own bucket.
3. Check the **tenant network baseline** (`tenant-network.md`): the operator in `cnpg-system` has to reach the database
   pods (their status port and 5432), and the database pods have to reach the Kubernetes API. **Not checked yet**; a
   default-deny baseline will block this until a rule is added.
4. Aggregate a ClusterRole for the kinds into `edit` (`rbac.authorization.k8s.io/aggregate-to-edit: "true"`), or set
   `rbac.aggregateClusterRoles: true` after steps 2 and 3.
5. Add the checks to `tests/tenant-guardrails.sh`.

## 4. Using it (platform)

An example, for a database that needs PostGIS (ZeedLogic does). **Check the image tag against the operator's PostGIS
documentation before using it**; this was not verified here, and ZeedLogic production runs PostgreSQL 16 with PostGIS 3.5.

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata: {name: zeedlogic-main, namespace: zeedlogic-dev}
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgis:<postgresql>-<postgis>-system-trixie   # pick a tag, do not guess
  storage: {size: 10Gi, storageClass: longhorn}
  bootstrap:
    initdb: {database: zeedlogic, owner: zeedlogic_root}
```

Extensions are enabled with a `Database` resource listing them (`postgis`, `uuid-ossp`, ...). A new, empty database still
needs the ZeedLogic core seed before the first migration (ADR-0123 section 4, BF-044). The application then connects to
`zeedlogic-main-rw` with the password from the Secret `zeedlogic-main-app`.

## 5. Risks

| Risk | Detail |
|---|---|
| Operator outage blocks CNPG changes | both webhooks have `failurePolicy: Fail` (checked in the rendered chart): while the operator is down, creating or editing a CNPG resource is refused. Pods and running databases are not affected. Two replicas on different workers reduce it |
| Operator upgrade | after the operator upgrades, each database's instance manager is updated by a rolling restart of its pods (a switchover; a single-instance cluster restarts). Read the release notes before each minor version; the chart is pinned and Renovate proposes bumps |
| Retained volumes | `longhorn` is `Retain`: removing a `Cluster` leaves volumes (section 2) |
| No backups configured | the app configures none. Backups and point-in-time recovery run through the Barman Cloud plugin to an S3 store (Garage is S3-compatible, untested here). A database holding real data needs this first |
| Data on the cluster | replication is not a backup; Longhorn backups (`storage-longhorn.md`, `velero.md`) cover the volumes, but a PostgreSQL volume copied while running is only crash-consistent |

## 6. Test

`./tests/cloudnative-pg.sh` (12 checks): operator Deployment ready with 2 replicas on different nodes, CRDs, webhooks,
PodMonitor, no failed restarts, tenants have no CloudNativePG rights, then a real single-instance `Cluster` in the
throwaway namespace `cnpg-test` (a query through the `-rw` Service with the generated password), and cleanup including the
retained PersistentVolume and Longhorn volume it created.
