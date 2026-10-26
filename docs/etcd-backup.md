# etcd snapshots

- Scheduled snapshots of etcd on each control plane, copied off the node to the backup Garage on docker-2.
- Built. Host level (`node-prep/`), not an Argo CD app. Part of step 8h in `fresh-install-order.md`.

## 1. What runs

| Item | Value |
|---|---|
| Installer | `node-prep/etcd-snapshot-node-prep.sh` (dry run by default, `--apply` does it) |
| Script | `/usr/local/bin/etcd-snapshot.sh`: `etcdctl snapshot save` against `127.0.0.1:2379` with the node's own `admin-<node>.pem`, then `etcdutl snapshot status` to verify, then prune |
| Timer | `etcd-snapshot.timer`: 00:15, 06:15, 12:15, 18:15 (+ up to 10 min random delay), `Persistent=true` |
| Where | `/var/backups/etcd-snapshots/etcd-<node>-<UTC time>.db`, root only (mode 600) |
| Retention | newest 28 per node (7 days). Size about 65 MB each, so under 2 GB per node (root disks have 42 GB free) |
| Failure | a snapshot that fails verification is not kept and the unit fails (`systemctl --failed`); older snapshots stay |

All three control planes snapshot, so there are three copies on three machines.

## 2. Off-node copy

After each verified snapshot the script uploads it to bucket `etcd-snapshots` on the backup Garage on docker-2
(`backup-target.md`) as `<node>/<file>`, then checks the stored size with a HEAD request. A failed upload fails the
unit (the local copy stays), so `systemctl --failed` shows it.

| Item | Value |
|---|---|
| Uploader | `/usr/local/bin/etcd-snapshot-upload.py` (from `node-prep/etcd-snapshot-upload.py`): Python standard library only, SigV4. curl 7.81's `--aws-sigv4` does not sign `x-amz-content-sha256`, so Garage rejects it |
| Credentials | `/etc/etcd-snapshot-s3.env` on each control plane, mode 600, root: key `etcd-snapshots-key`, **read and write on `etcd-snapshots` only** (not owner, no access to `velero`). Not in Git |
| Retention in the bucket | lifecycle rule `expire-7d`, quota 20 GiB. About 4 snapshots a day x 3 nodes x 65 MB x 7 days = 5.5 GB |
| Without the env file | the snapshot stays local and the unit succeeds |

Recreate the env file on a rebuilt node:
```bash
ssh adminjody@10.1.5.123 "sudo docker exec k8s-1-backups-garage /garage key info etcd-snapshots-key --show-secret"
# then write S3_ENDPOINT=http://10.1.5.123:3910, S3_BUCKET=etcd-snapshots, S3_KEY_ID, S3_SECRET to the file
```

Together with the Garage on docker-2 (data on TrueNAS) this survives losing all three control planes. Losing both
the cluster and docker-2 or the TrueNAS pool does not: nothing copies this off the NAS.

Kubespray's own `/var/backups/etcd-*` directories are pre-upgrade copies taken by upgrade runs; unrelated.

## 3. Check

```bash
ssh adminjody@10.1.5.151 'systemctl list-timers etcd-snapshot.timer --no-pager; sudo ls -lh /var/backups/etcd-snapshots; sudo journalctl -u etcd-snapshot.service -n 8 --no-pager'
```

## 4. Restore (outline, rehearse before you need it)

A restore replaces the data of the whole cluster with the snapshot's state. Do it only for etcd loss or corruption.

1. Snapshots are on each control plane in `/var/backups/etcd-snapshots`; if all are lost, fetch one from the
   bucket (`etcd-snapshots/<node>/`) with any S3 client and the `k8s-1-backups-key`.
2. Stop kube-apiserver and etcd on all control planes (kubespray: stop the static pod / `systemctl stop etcd`).
3. On each member: `etcdutl snapshot restore <file> --name <member> --initial-cluster <m1=https://...,m2=...,m3=...>
   --initial-advertise-peer-urls https://<ip>:2380 --data-dir /var/lib/etcd-restored`, using the **same** snapshot file
   on every member, then move it into `ETCD_DATA_DIR` (keep the old directory).
4. Start etcd on all three, then the API server.
Kubespray also has a recovery playbook (`recover-control-plane`) for a lost member, which is the more common case.

## 5. Where it is installed

| Node | Result |
|---|---|
| control-plane-1 (10.1.5.151) | timer enabled, first snapshot 64 MB verified; upload to Garage verified |
| control-plane-2 (10.1.5.152) | same, 63 MB, upload verified |
| control-plane-3 (10.1.5.153) | same, 61 MB, upload verified |

Not in the kubespray inventory yet: a rebuilt control plane needs the script run again.
