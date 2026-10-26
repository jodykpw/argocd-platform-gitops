# Velero

- Backs up the cluster's Kubernetes objects (all namespaces and cluster-scoped objects, including Secrets) to an S3 bucket outside the cluster.
- Layer 1, Argo CD app `velero`, auto-sync (`prune: false`). Step 8h in `fresh-install-order.md`.
- Test: `tests/velero.sh` (15 checks).
- Volume data is **not** in these backups: it is a Longhorn backup job (`storage-longhorn.md`, section 8).

## 1. Decisions

| Decision | Choice | Why |
|---|---|---|
| Target | bucket `velero` on the Garage at `http://10.1.5.123:3910` (docker-2, data on TrueNAS NFS) | off-cluster; see `backup-target.md` |
| Scope | objects only. No node agent, no volume snapshots | there are no CSI snapshot CRDs here; volume data is a Longhorn backup job |
| Schedule | `velero-daily` at 02:30 UTC, TTL 7 days (dev cluster; backups are small), all namespaces, cluster resources included | |
| Credentials | Secret `velero-s3` (key `cloud`, AWS credentials file format), created by External Secrets from the GitLab variable `velero_s3` | never in Git |
| CRDs | from the chart's `crds/` directory, upgrade job off | Argo CD installs them |
| Chart | `vmware-tanzu/velero` 12.2.1 = Velero 1.18.2, plugin `velero-plugin-for-aws:v1.14.4` | |

## 2. Retention

- Dev cluster: 7 days (`ttl: 168h` on the schedule, `defaultBackupTTL: 168h` for manual backups). Velero deletes expired backups from the bucket itself.
- Objects only, so a backup is a few MB; the bucket quota is 100 GiB.
- To keep more, change `ttl` (`schedules.daily.template.ttl`) in `overlays/k8s-1/velero/values.yaml`. A manual backup can set its own `spec.ttl`.

## 3. Grafana dashboard and alerts

- `Velero (k8s-1)` in the folder Platform (`dashboards/platform/velero.json`): Velero up, backup location status, last scheduled backup status and age, succeeded and failed counts, backups per hour, duration, size, items, backups kept, restores. Metrics come from the ServiceMonitor `velero` (port 8085). The age panel turns orange after 36 h and red after 60 h.
- Alerts (`alerting.md`): `VeleroBackupTooOld` (last good `velero-daily` backup older than 36 h), `VeleroBackupFailed`, `VeleroBackupLocationUnavailable`, `VeleroDown`.

## 4. Install

1. Garage on docker-2 is running with the bucket `velero` (`backup-target.md`).
2. The GitLab variable `velero_s3` exists: the AWS credentials file for the key `k8s-1-backups-key`.

   ```ini
   [default]
   aws_access_key_id=GK0ba2f355bdbf5b78d451dd8c
   aws_secret_access_key=<the secret key>
   ```

   Get the secret key with `ssh adminjody@10.1.5.123 "sudo docker exec k8s-1-backups-garage /garage key info k8s-1-backups-key --show-secret"` (the line `Secret key:`). External Secrets creates `velero/velero-s3` (`external-secrets.md`; the file is a multi-line value, so check it with a hash).
3. `kubectl apply -f bootstrap/platform-project.yaml` (adds the vmware-tanzu repo), push, let `platform-gitops` create the ApplicationSet, then sync `velero`.
4. Run `./tests/velero.sh`.

## 5. Restore

A restore recreates objects from a backup; existing objects with the same name are skipped, not overwritten.

```bash
kubectl -n velero get backups
kubectl -n velero apply -f - <<YAML
apiVersion: velero.io/v1
kind: Restore
metadata: {name: restore-<date>, namespace: velero}
spec: {backupName: <backup>, includedNamespaces: [<ns>]}
YAML
kubectl -n velero get restore restore-<date> -o jsonpath='{.status.phase}'
```

For a whole lost cluster: rebuild (`fresh-install-order.md`), install Velero pointing at the same bucket, and the backups appear within a minute; then restore. Argo CD's own objects come back too; Longhorn volume data needs the Longhorn backup.

## 6. Limits

- Secrets in the bucket are not encrypted by Velero; the protection is the Garage key and the TrueNAS permissions.
- Volume contents (Loki, Prometheus, Garage, Jaeger data) are **not** in these backups.
- Garage on docker-2 is a single node; see `backup-target.md` for its own protection.

## 7. Secret rotation (Reloader)

`annotations` in `base/velero/values.yaml` make Reloader restart Velero when `velero-s3` changes (the plugin reads the credentials at start). After a new access key, update the GitLab variable, then check that `kubectl -n velero get backupstoragelocations.velero.io` shows `Available`. See `reloader.md`.
