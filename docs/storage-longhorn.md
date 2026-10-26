# storage-longhorn: block storage

- Layer 1, managed by Argo CD (`argocd-gitops.md`, section 7). Step 6b in `fresh-install-order.md`.
- Chart `longhorn` 1.13.0, V1 data engine, namespace `longhorn-system`.
- StorageClass `longhorn` (ReadWriteOnce, also ReadWriteMany through NFSv4), reclaim policy `Retain`, not the default class.
- Backups go nightly to TrueNAS over NFS (section 8).
- Test: `tests/storage-longhorn.sh`.

## 1. At a glance

| Item | Value |
|---|---|
| Chart | `longhorn` 1.13.0 from `https://charts.longhorn.io`, version pinned in `appsets/storage-longhorn.yaml` |
| Runs on | the three workers only (the control planes are tainted; no tolerations on purpose) |
| Data path | `/mnt/longhorn`, a dedicated 100 GB disk (`/dev/sdb`) per worker |
| Replicas | 2 (`defaultReplicaCount` and `defaultClassReplicaCount`) |
| StorageClass | `longhorn`: `reclaimPolicy: Retain`, `dataEngine: v1`, not the default class |
| Namespace | `longhorn-system`, created by Argo CD with the Pod Security `privileged` label (Longhorn needs host access) |
| UI | not exposed; reach it with `kubectl port-forward` |
| Argo CD | ApplicationSet `storage-longhorn`, auto-sync (`prune: false`, `selfHeal: false`), `ignoreDifferences` for Longhorn's own settings and node objects |
| Files | `appsets/storage-longhorn.yaml`, `base/storage-longhorn/values.yaml`, `overlays/k8s-1/storage-longhorn/values.yaml` |

Why V1 only: V2 needs kernel 6.7 or later and raw NVMe-style disks; the nodes run kernel 5.15 on Ubuntu 22.04.
Kubernetes: Longhorn 1.13 lists v1.34 or newer; k8s-1 runs v1.36.4 and works.

## 2. Dependencies

**Longhorn needs (must exist first)**

| Dependency | Why | Check |
|---|---|---|
| Node prep on the three workers (`node-prep/longhorn-node-prep.sh`) | dedicated disk at `/mnt/longhorn`, `iscsi_tcp` loaded, multipath blacklisted | `findmnt /mnt/longhorn`, `lsmod \| grep iscsi_tcp` on each worker |
| `open-iscsi` (`iscsid` active), `nfs-common`, `cryptsetup`, `dmsetup` on the workers | iSCSI attach, RWX and backups | `systemctl is-active iscsid` |
| Argo CD with the `platform` AppProject | deploys it; `https://charts.longhorn.io` must be in `sourceRepos` | `kubectl -n argocd get appproject platform` |
| A working pod network (Calico) | the manager, instance managers and the CSI plugin talk across nodes | pods Ready on all workers |
| Resources on the workers | Longhorn reserves CPU for instance managers | workers are 4 CPUs and 16 GB; revisit with real load |

**Longhorn is needed by:** Garage (its two volumes), Loki, kube-prometheus-stack and the Thanos sidecar (Prometheus TSDB), Grafana,
any app with a ReadWriteOnce volume (class `longhorn`), and Velero (CSI snapshots).

**Does not depend on:** NFS or TrueNAS (separate class `nfs`), Garage, Capsule, Tenants, OIDC, Traefik, MetalLB or any route.

**If the order is wrong**

| What happens | Why / fix |
|---|---|
| Synced before the node prep | Longhorn would create its data path on the 60 GB OS disk, and `multipathd` can grab its devices and break mounts. The fix is a disk migration, not a re-sync, so check before the first sync |
| Dependent apps synced before Longhorn | their PVCs stay `Pending` and the pods wait; they start by themselves once the class exists |
| Removing Longhorn | do it last, with no volumes left. `deletingConfirmationFlag` is off on purpose, so an uninstall by a sync is blocked |

## 3. Node preparation (done)

Done once with `node-prep/longhorn-node-prep.sh` on all three workers (see `node-prep/node-prep.md`); by Ansible later, never by Argo CD.

1. Partition and format `sdb` (ext4 or XFS), mount it at `/mnt/longhorn`, add it to `/etc/fstab` by UUID.
2. Load `iscsi_tcp` and persist it in `/etc/modules-load.d/`.
3. Blacklist `sd*` in multipath and restart `multipathd`, because multipath can claim `/dev/sd*` devices and make volumes fail to mount.
4. Remove the old Longhorn data in `/var/lib/longhorn` (it carried an old disk identity and must not be reused).
5. Run `longhornctl check preflight`; it reports what is missing.

Worker facts (all three identical): 4 CPUs and 16 GB RAM; OS disk `sda` 60 GB (not for Longhorn data); `sdb` 100 GB for Longhorn;
`sdc` 20 GB xfs at `/mnt/new_home` (leave alone); `open-iscsi` 2.1.5 (avoid the bad 2.1.12); `nfs-common`, `cryptsetup` and
`dmsetup` present; passwordless `sudo` for `adminjody`.

Node prerequisites for the V1 engine: `open-iscsi` with `iscsid` running, the `iscsi_tcp` module, an NFSv4 client (RWX and NFS backups),
`cryptsetup` and `dmsetup` only for volume encryption, the tools `bash curl findmnt grep awk blkid lsblk`, mount propagation (default
with containerd), and a dedicated formatted disk per worker.

## 4. Capacity

Longhorn is one shared pool: every volume is a separate block device carved from the same three disks.

| | Per worker | Three workers |
|---|---|---|
| Raw disk (`/mnt/longhorn`, `sdb`) | 97.9 GiB | 293.6 GiB |
| Reserved by Longhorn (30% default) | 29.4 GiB | 88.1 GiB |
| **Schedulable** (over-provisioning 100%) | 68.5 GiB | **205.5 GiB** |
| Usable for volumes at 2 replicas | | **about 103 GiB** (a 10 GiB volume takes 20 GiB) |

Settings in use: `storage-over-provisioning-percentage` 100, `storage-minimal-available-percentage` 25, `default-replica-count` 2.

Budget for dev (estimates; check against real use):

| Item | Volume | Raw (with replicas) |
|---|---|---|
| Prometheus (12 h, about 1 GB/day at most) | 3 GiB | 6 GiB |
| Garage metadata + data (Thanos 7 days raw is about 7 GiB, bucket quota 15 GiB; shared by all buckets) | 2 + 30 GiB | 64 GiB |
| Thanos compactor (8 GiB) and store gateway cache (3 GiB), 1 replica each, 2 Longhorn replicas | 11 GiB | 22 GiB |
| Loki (7 to 10 days) | 10 GiB | 20 GiB |
| Alertmanager, Grafana, Jaeger | 5 GiB | 10 GiB |
| **Platform total** | **60 GiB** | **110 GiB** of 205 GiB |
| Left for apps | | about 95 GiB raw (about 47 GiB of volumes) |

Ways to get more room, in order of effort:

1. Lower the reserved percentage to 10 to 15%.
2. Use 1 replica for rebuildable volumes (compactor, store cache) with a `longhorn-single` class.
3. Grow `sdb` in Proxmox (100 to 200 GB) and the filesystem, which about doubles the pool.

Watch real usage in Grafana first, and grow when the used space passes about 60%.

## 5. Settings in use (overlay `overlays/k8s-1/storage-longhorn/values.yaml`)

| Setting | Value |
|---|---|
| `defaultSettings.defaultDataPath` | `/mnt/longhorn` |
| `defaultSettings.defaultReplicaCount`, `persistence.defaultClassReplicaCount` | 2 |
| `persistence.defaultClass` | `false` (NFS or another class may become the default) |
| `persistence.reclaimPolicy`, `defaultFsType`, `dataEngine` | `Retain`, `ext4`, `v1` |
| `defaultBackupStore.backupTarget` | `nfs://10.1.5.202:/mnt/byte-haven/k8s-1-longhorn-backup`, `pollInterval` 300 |
| `preUpgradeChecker.jobEnabled` (base) | `false`: Argo CD renders the chart itself, and the pre-upgrade check job is turned off for that |
| `metrics.serviceMonitor.enabled` (base) | `true` |

## 6. Argo CD and Helm

- Argo CD renders the chart itself (like `helm template`) and applies the objects. There is no `helm install` and no Helm release in `helm list`; look in the Argo CD UI.
- Upgrades are a `targetRevision` bump in Git. A bump syncs automatically, so review every bump in a merge request.
- Helm hooks become Argo CD hooks.
- Never enable the `deleting-confirmation-flag` (uninstall).

## 7. Test

`tests/storage-longhorn.sh` (9 checks): a volume binds, a pod writes a file, the pod is deleted, and a NEW pod on a DIFFERENT worker
reads the file back. Everything it created is removed, including the retained PV and the Longhorn volume. `KEEP=1` skips the cleanup.

Pass checks for a fresh install:

1. All Longhorn pods Running on the workers only, none on the control planes.
2. The `longhorn` StorageClass exists, and nodes and disks show Ready and Schedulable in `nodes.longhorn.io`.
3. A test RWO PVC binds, a pod writes a file, and the file survives deleting and recreating the pod.
4. Optional: an RWX PVC (NFSv4 share manager), and a backup to the target followed by a restore.
5. Argo CD shows `Synced` and `Healthy` with no permanent drift.

**Open:** the worker reboot test is not done yet (reboot one worker; the volume must stay available through the replica on another node and
rebuild after the node returns). Do it before relying on Longhorn for important data; create a fresh volume first with `tests/storage-longhorn.sh KEEP=1`.

## 8. Backups

| Item | Value |
|---|---|
| Target | `nfs://10.1.5.202:/mnt/byte-haven/k8s-1-longhorn-backup` (TrueNAS dataset `byte-haven/k8s-1-longhorn-backup`, NFS share, mounted by the Longhorn manager on the workers) |
| Where it is set | `defaultBackupStore.backupTarget` in the overlay (the chart applies it on first install). On the running cluster the BackupTarget `default` was patched by hand, no restart needed |
| Job | RecurringJob `backup-daily` (`extraObjects` in the overlay): task `backup`, 01:30 UTC daily, retain 7, concurrency 1, group `backup` |
| Which volumes | only those labelled `recurring-job-group.longhorn.io/backup=enabled` **on the Longhorn Volume object** (a label on the PVC is not copied): Grafana, Alertmanager, `data-garage-0`, `meta-garage-0` |
| Not backed up | Prometheus (12 h, Thanos has it), Loki (7 days of logs), Jaeger (3 days), Thanos store-gateway and compactor (cache and scratch). Add the label to include one |
| Test | `tests/longhorn-backup.sh`: target Available, job present, a real backup of the smallest labelled volume restored into a scratch volume |

```bash
# add a volume to the backup group
kubectl -n longhorn-system label volumes.longhorn.io <pvc-...> recurring-job-group.longhorn.io/backup=enabled
# what is backed up
kubectl -n longhorn-system get backups.longhorn.io
```

Notes:

- The label lives only in the cluster. A PVC that is deleted and recreated gets a new volume without it, and a rebuilt cluster needs the labels set again (the list above).
- Garage data and meta are two volumes backed up at different moments: crash-consistent, not application consistent. The Garage layout and keys are in `meta`; restore both from the same night.
- Restore: the Longhorn UI (or a Volume with `fromBackup`), then a PV and PVC that point at it. Longhorn retains the PVs here (class `longhorn` is `Retain`).
- Use `backups.longhorn.io`: `kubectl get backups` can mean Velero's or Longhorn's depending on the kubectl version.
- The TrueNAS dataset quota is not visible from the workers (`df` shows the whole pool): check it in TrueNAS.

## 9. Metrics and alerts

- `metrics.serviceMonitor.enabled: true` creates `longhorn-prometheus-servicemonitor` (the manager's port 9500, three targets).
- The chart's `longhorn-manager` NetworkPolicy blocks Prometheus, so `longhorn-manager-metrics` (in `extraObjects`) allows pods `app.kubernetes.io/name=prometheus` in `monitoring` on port 9500 only.
- Alerts for volumes, nodes, disks and backups are in `platform-alerts` (`alerting.md`).
