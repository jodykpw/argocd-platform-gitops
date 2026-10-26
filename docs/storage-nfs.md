# storage-nfs: shared (ReadWriteMany) storage from TrueNAS

- Layer 1, managed by Argo CD (`argocd-gitops.md`, section 7). Step 6c in `fresh-install-order.md`.
- Gives pods shared volumes (ReadWriteMany) on the TrueNAS dataset `byte-haven/k8s-1-nfs`, through the `nfs-subdir-external-provisioner` Helm chart.
- Block storage is Longhorn: see `storage-longhorn.md`.
- Test: `tests/storage-nfs.sh`.

## 1. At a glance

| Item | Value |
|---|---|
| StorageClass | `nfs` (not the default class) |
| Access mode | ReadWriteMany (also works for ReadWriteOnce) |
| Reclaim policy | `Retain`: a deleted PVC keeps its directory on TrueNAS |
| NFS server and export | TrueNAS `10.1.5.202`, `/mnt/byte-haven/k8s-1-nfs` (dataset `byte-haven/k8s-1-nfs`) |
| NFS version and options | v4.2, `hard` |
| Chart | `nfs-subdir-external-provisioner` 4.0.18 (app v4.0.2), repo `https://kubernetes-sigs.github.io/nfs-subdir-external-provisioner/` |
| Namespace | `nfs-provisioner` (Pod Security `baseline`), created by Argo CD |
| Provisioner name | `cluster.local/nfs-subdir-external-provisioner` |
| Argo CD | ApplicationSet `storage-nfs`, auto-sync (`prune: false`, `selfHeal: false`) |
| Files | `appsets/storage-nfs.yaml`, `base/storage-nfs/values.yaml`, `overlays/k8s-1/storage-nfs/values.yaml` |

## 2. How it works

- The provisioner is one pod. For each new PVC of class `nfs` it creates a subdirectory on the share (`<namespace>-<pvc>-<pv>`) and the PV that points at it.
- Pods mount their own subdirectory through Kubernetes (the kubelet) when the pod starts.
- **No `/etc/fstab` change and no node-side mount** is needed. Nodes only need the NFS client (`nfs-common`, installed on all workers) and network access to `10.1.5.202`. (Longhorn's `/mnt/longhorn` entry in fstab is a different thing: a local disk.)

## 3. Dependencies

**NFS needs (must exist first)**

| Dependency | Why | Check |
|---|---|---|
| TrueNAS dataset `byte-haven/k8s-1-nfs` shared over NFS | the storage itself | `showmount -e 10.1.5.202` lists `/mnt/byte-haven/k8s-1-nfs` |
| Export authorized for the workers `10.1.5.161-163`, Maproot `root`/`wheel`, NFSv4 on | mounts and root writes | tested from all workers: v4.2, root can write |
| Network from the workers to `10.1.5.202` (TCP 2049) | the kubelet mounts on the worker | `nc -vz 10.1.5.202 2049` from a worker |
| `nfs-common` on the workers | the NFS client | installed |
| Argo CD with the `platform` AppProject | deploys it; the NFS chart repo must be in `sourceRepos` | `kubectl -n argocd get appproject platform` |

There is no secret.

**NFS is needed by:** apps that need ReadWriteMany volumes (class `nfs`); later, tenant shared storage (per tenant dataset and class); Velero could use an NFS backup target (not decided).

**Does not depend on:** Longhorn, Garage, Capsule, Tenants, OIDC, Traefik or MetalLB. It can be installed first or last. No node disk is involved.

**If something is missing**

| Symptom | Cause |
|---|---|
| the provisioner pod runs, PVCs stay `Pending`, pods using `nfs` stay `ContainerCreating` | TrueNAS unreachable or the share not authorized |
| running pods hang, then recover | TrueNAS is rebooting (`hard` mounts wait) |
| volumes mount but writes fail with `permission denied` | Maproot is not `root` |

Verified from all three workers with a temporary mount and one small write: ping, TCP 2049 and 111 reachable, the export listed, mount NFS v4.2 `rw` `sec=sys`, root can write.

## 4. TrueNAS side

| Setting | Value | State |
|---|---|---|
| Dataset | `byte-haven/k8s-1-nfs` | exists |
| NFS share path | `/mnt/byte-haven/k8s-1-nfs` | exists |
| Maproot User / Group | `root` / `wheel` (root is not squashed) | works: root writes files as `root:root` |
| NFSv4 | enabled | mounts with v4.2 |
| **Authorized hosts/networks** | should be `10.1.5.161`, `.162`, `.163` | **open to `*`: restrict it** |
| **Dataset quota** | for example 200 GiB | **none: the dataset reports the whole pool (4.2 TB)** |
| Snapshot task | daily, keep a few | not set up |

- Sizes in PVCs are only labels on NFS. The **dataset quota is the real limit**, and Capsule quotas only count requests. Without a quota, one runaway volume can fill the pool that also holds other shares.
- The server also exports `zeedlogic-dev`, `devbox-1`, `docker-2`, `pv-backup`, `pcls-fs` and `temporary`, all open to `*`. They are not part of this work, but the same restriction applies. Keep tenant storage separate from them.
- Single point of failure: pods that use `nfs` hang while TrueNAS is down or rebooting.

## 5. Settings

In `base/storage-nfs/values.yaml` and `overlays/k8s-1/storage-nfs/values.yaml`:

| Setting | Value | Why |
|---|---|---|
| `nfs.server`, `nfs.path` (overlay) | `10.1.5.202`, `/mnt/byte-haven/k8s-1-nfs` | k8s-1 only |
| `nfs.mountOptions` | `nfsvers=4.2`, `hard` | tested from all workers; `hard` avoids silent data loss on a timeout |
| `storageClass.name` | `nfs` | the chart default is `nfs-client` |
| `storageClass.accessModes` | `ReadWriteMany` | NFS is for shared volumes |
| `storageClass.reclaimPolicy` | `Retain` | data survives a deleted PVC |
| `storageClass.archiveOnDelete` | `true` | used only if the class is ever changed to `Delete` |
| `storageClass.defaultClass` | `false` | no default class until you decide |
| `replicaCount` | `1` | leader election is on |
| `resources` | 25m / 32Mi request, 128Mi limit | the chart default is empty |

## 6. Use it

```yaml
spec:
  storageClassName: nfs
  accessModes: [ReadWriteMany]
  resources:
    requests:
      storage: 5Gi
```

| Need | Class |
|---|---|
| Shared files for several pods, media, config | `nfs` |
| One pod's database, Prometheus, Loki | `longhorn` |
| Throwaway data that should vanish | a future `nfs-scratch` class (Delete); not created yet |

**Clean up Released volumes.** After a PVC is deleted its PV is `Released` and the directory stays on TrueNAS:

```bash
kubectl get pv | grep Released
kubectl delete pv <name>           # removes the PV object only
# then remove the directory on TrueNAS if the data is not needed:
#   /mnt/byte-haven/k8s-1-nfs/<namespace>-<pvc>-<pv>
```

## 7. Deploy

1. Commit and push the files.
2. Apply the AppProject: `kubectl apply -f bootstrap/platform-project.yaml` (the NFS chart repo is in `sourceRepos`; `bootstrap/` is applied by the CI job, not synced by Argo CD).
3. Sync `platform-gitops` (creates the `storage-nfs` ApplicationSet), then sync `storage-nfs`.
4. Run `./tests/storage-nfs.sh` and expect `NFS BASIC CHECK: OK`.
5. After the test passes, the app auto-syncs.

## 8. Test: `tests/storage-nfs.sh`

Run it after the first sync, and again after any change to the class, the chart version or the TrueNAS share.

```bash
cd ~/kubernetes/platform-gitops
./tests/storage-nfs.sh            # about a minute
KEEP=1 ./tests/storage-nfs.sh     # leave the test objects to inspect, then clean up by hand
```

What it does:

1. Checks that the `nfs` StorageClass exists, the provisioner pod is ready, and at least 2 workers are Ready.
2. Creates a **temporary** class `nfs-test` (same provisioner, reclaim `Delete`, `archiveOnDelete: false`), so the test never leaves a directory on TrueNAS. The real `nfs` class (Retain) is not used.
3. Creates a 1 GiB ReadWriteMany PVC and **two pods that must run on different workers** (anti-affinity).
4. Each pod writes a file; each pod then reads the other pod's file.
5. Prints the mount options, then removes the namespace, the PV (the provisioner deletes the directory) and the temporary class.

Expected output of a good run:

```
== preflight
  PASS  StorageClass nfs exists
  PASS  provisioner pod ready
  PASS  at least 2 Ready worker nodes
== 1. temporary StorageClass, RWX volume, two pods on different nodes
  PASS  RWX PVC bound
  PASS  both pods running
  PASS  pods on different nodes
== 2. each pod reads the other's file
  PASS  pod-a sees pod-b's file
  PASS  pod-b sees pod-a's file
== result
  passed: 8   failed: 0
  NFS BASIC CHECK: OK
```

The exit code is 0 on success and 1 on any failure.

| Failure | Likely cause |
|---|---|
| `StorageClass nfs missing` | `storage-nfs` is not synced yet |
| PVC does not bind in 90 s | the provisioner is not running, or it cannot mount the share (check its logs) |
| pods stay `ContainerCreating` | the worker cannot mount: server unreachable, export not authorized for that node, NFS version |
| `permission denied` in the pod | Maproot is not `root`/`wheel`, or the dataset permissions do not allow writes |
| a PV is left at the end | the provisioner could not delete the directory; remove the PV and the directory by hand |

Not covered by the script (do by hand): TrueNAS reboot behaviour (pods hang with `hard` mounts, then recover), quota behaviour (fill the dataset in a scratch directory and watch the error), snapshot and restore.

## 9. Risks and open items

- Restrict the export's authorized hosts and set the dataset quota (section 4).
- The provisioner image is v4.0.2 and the chart changes rarely. A more actively developed driver is `csi-driver-nfs`; switching later means new volumes use the new class.
- Per tenant: one dataset (with its own quota) and one StorageClass each is the clean way to give teams hard limits. Not done yet. Decide which classes tenants may use (Capsule can restrict this per Tenant).
- Backups: TrueNAS snapshots of the dataset, replicated off the box.
