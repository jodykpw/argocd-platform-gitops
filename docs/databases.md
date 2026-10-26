# Databases for tenants

- Layer 1, Argo CD app `databases`, namespace `databases`. Step 8s in `fresh-install-order.md`. Needs the `cloudnative-pg` app first (`cloudnative-pg.md`).
- Files: `overlays/k8s-1/databases/` (namespace, network policies, one file per database), `appsets/databases.yaml`.
- Test: `tests/databases.sh` (11 checks).
- Status: synced and tested on k8s-1 on 2026-10-18: `tests/databases.sh` 11/11 (the newest checks are for the `zeedlogic_root` role, the `zeedlogic` database and the `keycloak` role and database). `jodywan-dev` reaches the database through `jodywan-dev-pg-rw` and runs `postgis_version()` (3.5); pods in `jodywan-stg` and `zeedlogic-dev` start and then time out, so the isolation holds. The first sync of the app ran before the operator's CRDs existed, failed once, and recovered on the automatic retry.
- The core seed was restored into `zeedlogic` on 2026-10-18 (`psql` as `postgres` through the primary pod, no errors): 35 tables, `alembic_version` = `044_publish_week_column_type`, PostGIS and `uuid-ossp` present, and `zeedlogic_root` reads the 56 `zlsys_column_types` rows over the `-rw` Service, can run DDL and use PostGIS. The one table it does not own is PostGIS's own `spatial_ref_sys`. **Not done yet:** the migration from `044` to head, which waits for an image of the application inside the cluster.
- Test note: a pod in a tenant namespace must set `limits.cpu` and `limits.memory`, or the Capsule ResourceQuota refuses it; the first version of the test did not, and every probe pod was refused.

## 1. The idea

A tenant namespace cannot run a CloudNativePG database: its pods cannot reach the Kubernetes API (default-deny egress, plus the Calico `tenant-egress-guard` that denies the nodes), and the operator cannot reach them (ingress is limited to the namespace, Traefik and Prometheus). Opening both would undo the isolation in `tenant-network.md`.

So the database runs in the platform namespace `databases`, and the tenant namespace is allowed to connect to its own database and nothing else. This is the pattern `tenant-network.md` section 3 describes: reaching a platform service is a platform decision, made with a policy on the destination side.

## 2. What exists

| Object | Where | Purpose |
|---|---|---|
| Namespace `databases` | platform, Pod Security `baseline` | not a tenant namespace; in the Gatekeeper exemption list |
| Cluster `jodywan-dev-pg` | `databases` | PostgreSQL 16.9 + PostGIS 3.5.2 (`ghcr.io/cloudnative-pg/postgis:16-3.5-177`, pinned by digest), 1 instance, 10Gi on `longhorn`, PodMonitor on, extensions `postgis` and `uuid-ossp` created at bootstrap |
| NetworkPolicy `database-ingress` | `databases` | allows the instances to each other, the operator (8000, 5432) and Prometheus (9187); everything else is refused |
| NetworkPolicy `allow-jodywan-dev` | `databases` | lets namespace `jodywan-dev` reach 5432 on the pods of `jodywan-dev-pg` only |
| NetworkPolicy `allow-egress-to-database` | `jodywan-dev` | lets that tenant namespace leave for the database pods on 5432 |

Connection details for an application in `jodywan-dev`:

| Item | Value |
|---|---|
| Host | `jodywan-dev-pg-rw.databases.svc.cluster.local` (primary; `-ro` replicas, `-r` any) |
| Port, database, user | `5432`, `app`, `app` |
| Password | Secret `jodywan-dev-pg-app`, key `password`, **in the `databases` namespace**. A Secret cannot be read across namespaces, so it has to be copied into `jodywan-dev` (section 4) |

### Storage (checked 2026-10-18)

| Item | Value |
|---|---|
| Claim | one PVC `jodywan-dev-pg-1` in `databases`, 10Gi, StorageClass `longhorn`, `ReadWriteOnce`. CloudNativePG keeps data and WAL on this one volume (there is no separate WAL volume unless the Cluster asks for one) |
| Reclaim policy | `Retain`: removing the Cluster leaves the PV and the Longhorn volume until someone deletes them |
| Longhorn | 2 replicas, on worker-node-2 and worker-node-3, attached to worker-node-3, `healthy` |
| Use | thin provisioned: about 331Mi really allocated per replica, the filesystem shows 102M used of 9.8G, the databases total 37MB |
| The operator | no PVC at all: a scratch `emptyDir` and its webhook certificate Secret. Nothing to back up there |

Growing the volume: raise `storage.size` in the Cluster (the `longhorn` class allows expansion). Shrinking is not possible.

## 3. Network flows

| From | To | Allowed by |
|---|---|---|
| `jodywan-dev` pods | database pods, 5432 | `allow-egress-to-database` (source side) and `allow-jodywan-dev` (destination side); both are needed |
| any other tenant namespace, including `jodywan-stg`, `jodywan-prod` and both `zeedlogic-*` | database pods | refused twice: no egress rule, and no ingress rule |
| operator (`cnpg-system`) | database pods, 8000 and 5432 | `database-ingress` |
| Prometheus (`monitoring`) | database pods, 9187 | `database-ingress` |
| database pods | Kubernetes API, DNS | not restricted (the namespace has no egress policy) |

The Calico guard does not interfere: it denies private ranges except the cluster's own pod and service networks, and the database pods are inside them.

## 4. Using it from a tenant namespace

Copy the password into the namespace once, without printing it:

```bash
kubectl -n databases get secret jodywan-dev-pg-app -o json \
  | python3 -I -c 'import json,sys; s=json.load(sys.stdin); print(json.dumps({"apiVersion":"v1","kind":"Secret","metadata":{"name":"jodywan-dev-pg","namespace":"jodywan-dev"},"type":"Opaque","data":{"password":s["data"]["password"],"username":s["data"]["username"]}}))' \
  | kubectl apply -f -
```

A copy goes stale if the password is rotated. A proper fix is an External Secrets `ClusterSecretStore` with the Kubernetes provider, scoped to the `databases` namespace; not built yet.

## 4a. The ZeedLogic database

The core seed of ZeedLogic assigns ownership of everything to a role called `zeedlogic_root` (ADR-0123 in zeedlogic-microservices, section 4), and CloudNativePG created this cluster with the default database and owner `app`. So the cluster also declares, in Git:

| Object | What |
|---|---|
| role `zeedlogic_root` | `spec.managed.roles` in `jodywan-dev-pg.yaml`; can log in; password from the Secret `jodywan-dev-pg-zeedlogic-root` |
| Secret `jodywan-dev-pg-zeedlogic-root` | `kubernetes.io/basic-auth` in `databases`, label `cnpg.io/reload`. **Created by hand with a random password, never in Git**: `kubectl -n databases create secret generic jodywan-dev-pg-zeedlogic-root --type=kubernetes.io/basic-auth --from-literal=username=zeedlogic_root --from-literal=password="$(openssl rand -hex 24)"`, then `kubectl -n databases label secret jodywan-dev-pg-zeedlogic-root cnpg.io/reload=true` |
| database `zeedlogic` | the `Database` resource in `jodywan-dev-pg-zeedlogic.yaml`, owner `zeedlogic_root`, created **empty** |

The database is empty on purpose: ZeedLogic cannot build one from nothing (BF-044). Restore its core seed once, as the superuser through the primary pod (a new `zeedlogic` database has no tables, and the seed creates PostGIS and `uuid-ossp` itself). Run it from a checkout of zeedlogic-microservices, and **do not** add `-v ON_ERROR_STOP=1`: the seed logs three harmless `schema ... already exists` errors.

```bash
kubectl -n databases exec -i jodywan-dev-pg-1 -c postgres -- \
  psql -U postgres -d zeedlogic < docker/core-seed/core-zeedlogic-2026-08-24.sql   # or the newest file in that folder
```

Then the application's own migration brings it to head. Connect as `zeedlogic_root` to database `zeedlogic` on the same `-rw` Service. Copy the Secret into the tenant namespace as in section 4, under a name of your choice.

A known follow-up: the operator warns that `spec.monitoring.enablePodMonitor` is deprecated in 1.30 and will be removed; the replacement is a PodMonitor managed by hand.

## 4b. The Keycloak database

ZeedLogic's Keycloak (the `keycloak` release of the zeedlogic chart) keeps its data in PostgreSQL. It gets its own role and database in the same server, so identity data is separate from the application's:

| Object | What |
|---|---|
| role `keycloak` | `spec.managed.roles` in `jodywan-dev-pg.yaml`; password from the Secret `jodywan-dev-pg-keycloak` |
| Secret `jodywan-dev-pg-keycloak` | `kubernetes.io/basic-auth` in `databases`, label `cnpg.io/reload`. **Created by hand with a random password, never in Git**: `kubectl -n databases create secret generic jodywan-dev-pg-keycloak --type=kubernetes.io/basic-auth --from-literal=username=keycloak --from-literal=password="$(openssl rand -hex 24)"`, then `kubectl -n databases label secret jodywan-dev-pg-keycloak cnpg.io/reload=true` |
| database `keycloak` | the `Database` resource in `jodywan-dev-pg-keycloak.yaml`, owner `keycloak`, empty: Keycloak creates its own tables on first start |

The lab was moved onto it on 2026-10-18: Keycloak started on the empty database, imported the realm again (new signing keys), and sign-in, Kong and the application worked after Kong and fastapi were restarted; the old `app` database was left untouched. Copy the Secret into `jodywan-dev` as in section 4 and point `global.database.keycloak` of the zeedlogic release at it (`username: keycloak`, `database: keycloak`). **Moving Keycloak onto a new, empty database starts it fresh:** it imports the realm again, with new signing keys, so restart Kong (it reads the realm key at start) and fastapi, and everyone signs in again. Nothing is removed from the old `app` database.

## 4c. The `zeedlogic-dev-pg` cluster (second environment, namespace `zeedlogic-dev`)

Same shape as `jodywan-dev-pg`: 1 instance, 10Gi `longhorn`, PodMonitor on, roles `zeedlogic_root` and `keycloak`, databases `zeedlogic` and `keycloak`, policies `allow-zeedlogic-dev` (in `databases`) and `allow-egress-to-database` (in `zeedlogic-dev`). Files: `zeedlogic-dev-pg.yaml`, `zeedlogic-dev-pg-zeedlogic.yaml`, `zeedlogic-dev-pg-keycloak.yaml`.

One difference, on purpose: the `Database` resource for `zeedlogic` **declares the extensions** (`fuzzystrmatch`, `postgis`, `postgis_topology`, `postgis_tiger_geocoder`, `uuid-ossp`). The ZeedLogic chart's seed Job connects as `zeedlogic_root`, which is not a superuser and cannot create them, so the platform must. (On `jodywan-dev-pg` the extensions were created by hand as superuser when the seed was restored.)

Passwords are created by hand and never in Git. Type them at a silent prompt, or generate them, so no value reaches the shell history:

```
for r in zeedlogic-root keycloak; do
  u=${r//-/_}
  kubectl -n databases create secret generic zeedlogic-dev-pg-$r --type=kubernetes.io/basic-auth \
    --from-literal=username=$u --from-literal=password="$(openssl rand -hex 24)"
  kubectl -n databases label secret zeedlogic-dev-pg-$r cnpg.io/reload=true
done
```

Create the Secrets **before** the Argo CD sync, because the managed roles refer to them. Then copy what the application needs into `zeedlogic-dev` (section 4). Check with `NAME=zeedlogic-dev-pg TENANT_NS=zeedlogic-dev OTHERS="jodywan-dev zeedlogic-stg" ./tests/databases.sh`.

### Starting over (empty the databases of one environment)

`zeedlogic-microservices/deploy/helm/zeedlogic/examples/k8s-1/reset.sh` does this as part of resetting an environment. By hand, for `zeedlogic-dev-pg`:

```
kubectl -n databases exec zeedlogic-dev-pg-1 -c postgres -- psql -U postgres -d postgres \
  -c "DROP DATABASE zeedlogic WITH (FORCE)" -c "DROP DATABASE keycloak WITH (FORCE)"
for d in zeedlogic keycloak; do kubectl -n databases patch database zeedlogic-dev-pg-$d --type merge -p '{"spec":{"ensure":"absent"}}'; done
# wait until .status.observedGeneration equals .metadata.generation, then:
for d in zeedlogic keycloak; do kubectl -n databases patch database zeedlogic-dev-pg-$d --type merge -p '{"spec":{"ensure":"present"}}'; done
```

CloudNativePG reconciles a `Database` only when its spec changes (an annotation is not enough, tested 2026-10-20), so the database is recreated, empty and with the declared extensions, by switching `ensure` to `absent` and back. The live object ends up equal to Git, so Argo CD shows no drift. Both clusters (`zeedlogic-dev-pg` and, since 2026-10-20, `jodywan-dev-pg`) declare the five extensions; a `Database` that does not leaves the chart's seed Job unable to run, because it connects as a non-superuser.

## 5. Adding another database

1. Add `overlays/k8s-1/databases/<tenant>-<env>-pg.yaml` (copy `jodywan-dev-pg.yaml`, change the name).
2. Add an `allow-<namespace>` policy in `network-policies.yaml` for it (selector on `cnpg.io/cluster`), and an `allow-egress-to-database`-style policy in the tenant namespace. Do not widen the existing ones.
3. Run `tests/databases.sh` with the new names (`NAME`, `TENANT_NS`).

## 6. Risks

| Risk | Detail |
|---|---|
| One shared platform namespace | the instances of different tenants run side by side. The network policies keep tenants apart, but a platform admin sees all of them. A database per tenant would be a namespace per tenant |
| Retained volumes | `longhorn` is `Retain`. Deleting the `Cluster` (and the app has `prune: false`) leaves the PersistentVolumes behind; remove them by hand after confirming |
| No backups | none configured. A database holding real data needs backup and point-in-time recovery first (`cloudnative-pg.md`, section 5) |
| One instance | no failover; a node loss means downtime until the pod is rescheduled. The volume has two Longhorn replicas, so the data survives a node |
| The `cnpg.io/cluster` label | the policies select the pods by it. It is the label CloudNativePG sets on its pods; `tests/databases.sh` fails if the pods do not carry it |
| Copied Secret | section 4 |
| Image tag | pinned by tag and digest; bump both together, and read the operator's notes for a major version |

## 7. Test

`./tests/databases.sh` (11 checks): the Cluster is healthy, its pods carry the `cnpg.io/cluster` label, PostGIS and `uuid-ossp` exist, the PodMonitor exists, the role `zeedlogic_root` and the database `zeedlogic` it owns exist; then a throwaway pod in `jodywan-dev` connects through the `-rw` Service and runs `postgis_version()`, while throwaway pods in `jodywan-stg` and `zeedlogic-dev` cannot connect. It creates and removes only those pods and one temporary Secret.
