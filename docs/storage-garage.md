# storage-garage: S3 object storage in the cluster

- Layer 1, managed by Argo CD (`argocd-gitops.md`, section 7). Step 6d in `fresh-install-order.md`.
- A **new Garage S3 server** inside k8s-1, used by Thanos (long-term metrics), optionally Loki chunks, Velero and apps.
- File storage is `nfs` (`storage-nfs.md`); block storage is `longhorn` (`storage-longhorn.md`).
- Why Garage: MinIO's community edition went source-only and is archived; SeaweedFS has more components (master, volume, filer, S3); Garage is one small StatefulSet.
- Test: `tests/storage-garage.sh`.

## 1. At a glance

| Item | Value |
|---|---|
| Namespace | `garage` (Pod Security `baseline`) |
| Chart | folder `script/helm/garage` in `https://git.deuxfleurs.fr/Deuxfleurs/garage.git`, tag `v2.4.1` (chart 0.10.2, Garage v2.4.1). There is no Helm repo |
| Workload | StatefulSet `garage`, 1 replica (`garage.singleNode: true`, `replication_factor = 1`) |
| Redundancy | Longhorn volumes (2 replicas), not Garage replication |
| Storage | PVCs on `longhorn`: metadata 2 Gi, data 30 Gi (expandable). One volume shared by every bucket, not one per app |
| S3 endpoint (in cluster) | `http://garage.garage.svc.cluster.local:3900`, region `garage`, path-style |
| Exposure | `ClusterIP` only, no Gateway route |
| RPC secret | existing Secret `garage-rpc-secret` (key `rpcSecret`), created by hand, never in Git |
| Argo CD | ApplicationSet `storage-garage`, auto-sync (`prune: false`, no self-heal) |
| Files | `appsets/storage-garage.yaml`, `base/storage-garage/values.yaml`, `overlays/k8s-1/storage-garage/values.yaml` |

## 2. Design choices

- **Single node on Longhorn, not 3 replicas.** Garage's default is 3 replicas with replication factor 3. On Longhorn with 2 replicas that is 6 copies of every byte. One pod on a Longhorn volume gives 2 copies and survives a node failure (the volume re-attaches elsewhere, with a short interruption). Good enough for Thanos, Loki and Velero; revisit if S3 must be highly available.
- **Not a DaemonSet.** The chart can run one pod per node (`deployment.kind: DaemonSet`, `hostPath` storage). Not used: the data would be tied to nodes.
- **Existing RPC secret.** The chart generates a random `rpcSecret` and keeps it with Helm `lookup`. Argo CD renders with `helm template`, where `lookup` returns nothing, so the secret would change on every sync. `existingRpcSecret` avoids that.
- **Kubernetes discovery** is part of the chart (a ClusterRole and node CRDs). With a single node it is not needed; it stays on the chart default.
- **Backups.** Longhorn replicas are not backups. The Garage volumes are in the nightly Longhorn backup (`storage-longhorn.md`, section 8).

## 3. Dependencies

**Garage needs (must exist first)**

| Dependency | Why | Check |
|---|---|---|
| **Longhorn** (StorageClass `longhorn`) | its two volumes | `kubectl get storageclass longhorn`; `./tests/storage-longhorn.sh` passes |
| Node prep on the workers (`/mnt/longhorn`, `iscsi_tcp`, multipath) | Longhorn needs it | `storage-longhorn.md` |
| Argo CD with the `platform` AppProject | deploys it; the Garage Git repo must be in `sourceRepos` | `kubectl apply -f bootstrap/platform-project.yaml` |
| Namespace `garage` and Secret `garage-rpc-secret` (key `rpcSecret`) | the pod mounts it at start; never in Git | `kubectl -n garage get secret garage-rpc-secret` |
| Network access from Argo CD to `git.deuxfleurs.fr` | the chart is a folder in Garage's Git repo | the Application renders (no `ComparisonError`) |
| Workers with 5 GB or more free for the pod (limit 1 Gi) | resources | `kubectl top nodes` |

**Garage is needed by**

| App | Use | Note |
|---|---|---|
| Thanos | bucket `thanos`, key `thanos-key`, **quota 15 GiB**, 7 days of raw metrics (about 7 GiB, measured 0.7 to 1.1 GiB per day) | required (`thanos.md`) |
| Loki | optional: chunks instead of the local filesystem | not required to start |
| Velero | backup target | an in-cluster S3 is not an off-cluster backup; Velero uses the backup Garage on docker-2 (`backup-target.md`) |
| Apps and tenants | buckets and keys, created by hand | per app |
| Garage UI (`garage-ui.md`) | web console | reads the admin API with `GARAGE_ADMIN_TOKEN`; the Secret `garage-admin-token` must exist first |

**Does not depend on:** NFS or TrueNAS (its metadata is a database, which does not suit NFS); Capsule, Tenants or OIDC (a platform app in
its own namespace); Traefik or a route (`ClusterIP` only; if a route is added later, label the namespace `gateway-access=platform`).

**If the order is wrong**

| What happens | Fix |
|---|---|
| Synced before Longhorn exists: the PVCs stay `Pending` and the pod waits | it starts by itself once the `longhorn` class appears |
| Synced before the RPC secret exists: `CreateContainerConfigError` | create the secret; the pod then starts |

## 4. Install

**Before the first sync (by a person)**

1. Apply the AppProject (the Garage Git repo is in `sourceRepos`; `bootstrap/` is applied by the CI job, not synced by Argo CD):

   ```bash
   kubectl apply -f bootstrap/platform-project.yaml
   ```

2. Create the namespace and the RPC secret by hand (the secret must exist before the pod starts):

   ```bash
   kubectl create namespace garage
   kubectl -n garage create secret generic garage-rpc-secret \
     --from-literal=rpcSecret="$(openssl rand -hex 32)"
   ```

   Argo CD's `CreateNamespace=true` accepts an existing namespace. Never change this secret later: it breaks the Garage layout.
3. Commit and push, sync `platform-gitops` (creates the ApplicationSet), then sync `storage-garage`.

**After the first sync: the layout.** In single-node mode (`garage.singleNode: true`) the layout is created automatically: the node comes
up with zone `dc1`, tag `default` and capacity 29.4 GiB (from the 30 Gi data volume). No manual step.

```bash
kubectl -n garage exec garage-0 -c garage -- /garage status
kubectl -n garage exec garage-0 -c garage -- /garage layout show
```

Only with a multi-node Garage (3 replicas) do you assign nodes by hand: `garage layout assign -z <zone> -c <capacity> <node_id>`, then
`garage layout apply --version <n>`. After growing the data volume, the capacity in the layout stays at the old value until you change it
(`garage layout assign` with the new `-c`, then `apply`).

## 5. Capacity and quotas

- The data volume (30 Gi) and the metadata volume (2 Gi) are **shared by every bucket**. Apps do not get their own volume; they get buckets and keys in this one Garage.
- Raw cost on Longhorn: (30 + 2) GiB x 2 replicas = 64 GiB of the 205 GiB schedulable pool (`storage-longhorn.md`, section 4).
- Give each bucket a size quota and one key per app, so one app cannot fill the volume: `garage bucket set-quotas --max-size <size> <bucket>` (check `--help` for the flags of your version).
- Check usage with `garage bucket info <bucket>`; later in Grafana.
- Grow the data volume by raising `persistence.data.size` in the overlay and expanding the PVC (Longhorn allows it). Retention in Thanos is the first lever when it fills.

## 6. Create a bucket and a key for an app

```bash
G="kubectl -n garage exec garage-0 -- /garage"
$G bucket create thanos
$G key create thanos-key                 # prints Key ID and Secret key: save them in the app's secret
$G bucket allow --read --write --owner thanos --key thanos-key
$G bucket info thanos
```

Apps in the cluster use the endpoint `http://garage.garage.svc.cluster.local:3900`, region `garage`, path-style addressing. Keep the key out
of Git: store it as a GitLab variable and let External Secrets create the Secret (`external-secrets.md`; for Thanos that is the variable `thanos_objstore`).

## 7. Test: `tests/storage-garage.sh`

Run it after the layout exists, and after changes to the chart or the volumes:

```bash
./tests/storage-garage.sh          # about a minute
KEEP=1 ./tests/storage-garage.sh   # leave the bucket, key and pod to inspect
```

It checks that the StatefulSet is ready and the layout is applied, creates a temporary bucket and key, runs a short-lived pod (aws CLI image)
that PUTs, GETs, LISTs and DELETEs an object through the in-cluster endpoint, then removes the bucket, key and pod. A good run ends with
`GARAGE S3 BASIC CHECK: OK` (9 checks).

Pass checks for a fresh install:

1. Pod `garage-0` Running, PVCs `meta-garage-0` and `data-garage-0` Bound on `longhorn`.
2. `garage status` shows the node with zone `dc1`.
3. `tests/storage-garage.sh` passes.
4. Argo CD shows `Synced` and `Healthy`.

## 8. Risks and open items

- **Single pod:** S3 is unavailable while the pod restarts or the volume re-attaches (usually seconds to a minute). Thanos and Loki retry; do not put anything on it that cannot wait.
- **Metadata (LMDB)** on a volume: take Garage's metadata snapshots (`metadata_auto_snapshot_interval`) once data matters. The volumes are in the nightly Longhorn backup.
- **S3 API is partial by design.** Basic operations and multipart work; check Garage's S3 compatibility page for versioning and lifecycle before relying on them.
- **Secrets:** the RPC secret stays by hand by design; app keys go through External Secrets.
- **Exposure:** no route outside the cluster. If tenants need S3, add a Gateway route with TLS and per-tenant keys.
- **The image is amd64 only** (`dxflrs/amd64_garage`), fine for the current nodes.
- **The chart source is a Git repo** at another site (`git.deuxfleurs.fr`): Argo CD must reach it, and the tag is pinned (`v2.4.1`). Review bumps like any chart version.

## 9. Secret rotation (Reloader)

`podAnnotations` makes Reloader restart Garage when `garage-admin-token` or `garage-rpc-secret` changes (both are read as environment
variables). Rotating the RPC secret is a deliberate act; the restart is the one it needs. Thanos uploads and the UI wait for about a minute.
See `reloader.md`.
