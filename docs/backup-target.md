# Backup target: Garage on docker-2

- An S3 endpoint outside the cluster, for Velero (`velero.md`) and the etcd snapshot copies (`etcd-backup.md`).
- Built. Part of step 8h in `fresh-install-order.md`.

## 1. Why a second Garage

- The Garage in the cluster (`storage-garage`) lives on Longhorn volumes in the same cluster: a lost cluster takes
  its backups with it.
- docker-2 already runs `zeedlogic-microservices-garage-1` for the zeedlogic app stack. It is **not** used: platform
  backups stay separate from a tenant's application data.

## 2. What runs on docker-2 (`10.1.5.123`)

| Item | Value |
|---|---|
| Files | `/home/adminjody/k8s-1-backups-garage/` (`compose.yaml`, `garage.toml`, `.env` mode 600 with RPC secret and admin token) |
| Container | `k8s-1-backups-garage`, `dxflrs/garage:v2.3.0`, `restart: unless-stopped`, single node, `replication_factor = 1`, region `garage` |
| Metadata (LMDB) | `/mnt/new_home/k8s-1-backups-garage/meta` (local xfs; LMDB stays off NFS) |
| Data | `/data/nas/docker-2/k8s-1-backups/garage-data` = TrueNAS `10.1.5.202:/mnt/byte-haven/docker-2` (4.2 TB free) |
| S3 endpoint | `http://10.1.5.123:3910` (LAN). Admin API only on `127.0.0.1:3913` |
| Buckets | `velero` (quota 100 GiB), `etcd-snapshots` (quota 20 GiB) |
| Key (limited) | `etcd-snapshots-key` (`GKef3076dcda8ff32649b45ce9`): read and write on `etcd-snapshots` only, used by the control planes (`etcd-backup.md`) |
| Key | `k8s-1-backups-key` (`GK0ba2f355bdbf5b78d451dd8c`), read, write and owner on both buckets. Secret key: `sudo docker exec k8s-1-backups-garage /garage key info k8s-1-backups-key --show-secret` |

## 3. Checks

From a pod in the cluster (`amazon/aws-cli`): put, get, delete on `s3://velero` and `s3 ls` listing both buckets. Passed.

Bucket `etcd-snapshots` has a lifecycle rule `expire-7d` (set with `aws s3api put-bucket-lifecycle-configuration`).
Bucket `velero` expiry is handled by Velero (`ttl`).

## 4. Notes

- Single node, no replication: the protection is the TrueNAS pool under the data directory (set up ZFS snapshots on
  `byte-haven/docker-2` or a dedicated dataset).
- The `.env` RPC secret protects the Garage layout; if `meta` is lost the data in `garage-data` is unreadable.
  Back up `/mnt/new_home/k8s-1-backups-garage/meta` (stop the container or use `garage meta snapshot`).
- Plain HTTP on the LAN. Restrict `10.1.5.123:3910` to the node subnet with the host firewall if needed.
