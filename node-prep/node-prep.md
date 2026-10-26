# node-prep: host setup that Kubernetes and Argo CD cannot do

- Run once per node, outside Kubernetes. Argo CD only creates Kubernetes objects; formatting a disk, loading a kernel module or editing `/etc` on a node is done here.
- Later this should move into the provisioning (kubespray inventory / Ansible, or Terraform cloud-init) so rebuilt nodes come up prepared.
- Used in steps 3 and 8h of `fresh-install-order.md`.

| Script | For | What it does |
|---|---|---|
| `longhorn-node-prep.sh` | Longhorn workers (V1 engine) | loads `iscsi_tcp`, blacklists `sd*` in multipath, formats `/dev/sdb` (ext4) and mounts it at `/mnt/longhorn`, removes old `/var/lib/longhorn` data |
| `etcd-snapshot-node-prep.sh` (+ `etcd-snapshot-upload.py`, same directory) | control planes | installs `etcd-snapshot.service` and a 6-hourly timer that saves, verifies and prunes snapshots in `/var/backups/etcd-snapshots`, then uploads each to Garage if `/etc/etcd-snapshot-s3.env` exists (`docs/etcd-backup.md`) |

```bash
scp node-prep/longhorn-node-prep.sh adminjody@<worker>:/tmp/
ssh adminjody@<worker> 'bash /tmp/longhorn-node-prep.sh'            # dry run
ssh adminjody@<worker> 'bash /tmp/longhorn-node-prep.sh --apply'    # does it
```

The script refuses to run if iSCSI sessions or Longhorn mounts exist, if `/dev/sdb` has a filesystem, partitions or signatures, or if it is the root disk.

## Where it was applied

| Node | Script | Result |
|---|---|---|
| worker-node-1 (10.1.5.161) | longhorn-node-prep.sh | `/dev/sdb` ext4 at `/mnt/longhorn`, `iscsi_tcp` loaded, multipath blacklisted, old data removed |
| worker-node-2 (10.1.5.162) | longhorn-node-prep.sh | same |
| worker-node-3 (10.1.5.163) | longhorn-node-prep.sh | same |
| control-plane-1/2/3 (10.1.5.151-153) | etcd-snapshot-node-prep.sh | timer enabled, first snapshot verified on each |

Control planes are not prepared for Longhorn (it does not run there). Backup of the original multipath config:
`/etc/multipath.conf.bak-<date>` on each worker.
