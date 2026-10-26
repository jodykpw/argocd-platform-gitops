# Alerting

- Alertmanager (part of kube-prometheus-stack, `kube-prometheus-stack.md`) sends warning and critical alerts by mail.
- Built. Part of step 8i in `fresh-install-order.md`.
- The rules are the chart's own plus the PrometheusRule `platform-alerts` (section 2).

## 1. Receiver

| Item | Value |
|---|---|
| Channel | email through Gmail SMTP `smtp.gmail.com:587` (STARTTLS), from and to `jody.kpw@gmail.com`, resolved notices on |
| Credential | a Google app password in the Secret `monitoring/alertmanager-smtp`, key `password`, created by External Secrets from the GitLab variable `alertmanager_smtp` (a separate password from the one docker-2's Grafana uses). Mounted at `/etc/alertmanager/secrets/alertmanager-smtp/` and read through `smtp_auth_password_file` |
| Routing | `severity` warning or critical goes to `mail`. `Watchdog` and `InfoInhibitor` go to `null`. Grouped by alertname and namespace, first mail after 30 s, repeat every 12 h |
| Config | `alertmanager.config` in `overlays/k8s-1/kube-prometheus-stack/values.yaml` (it replaces the chart default, so the inhibit rules are repeated) |

To replace the password: change the GitLab variable `alertmanager_smtp`, wait for the refresh (or force it, `external-secrets.md`), then restart Alertmanager:

```bash
kubectl -n monitoring rollout restart statefulset alertmanager-kube-prometheus-stack-alertmanager
```

The Secret must exist before the Alertmanager pod can start (it is mounted as a volume).

## 2. Rules

The chart's own rules (nodes, API server, kubelet, volumes filling, crash loops, certificate expiry, ...) are on. `platform-alerts` (a PrometheusRule in `extraManifests`) adds:

| Alert | Fires when | Severity |
|---|---|---|
| `VeleroBackupTooOld` | the last good `velero-daily` backup is older than 36 h for 15 min | warning |
| `VeleroBackupFailed` | the last scheduled backup failed for 5 min | warning |
| `VeleroBackupLocationUnavailable` | the S3 bucket is unreachable for 15 min | warning |
| `VeleroDown` | Velero is not running or not scraped for 10 min | warning |
| `ThanosCompactorHalted` | `thanos_compact_halted` is 1 for 5 min | warning |
| `LonghornVolumeDegraded` | a volume has a missing or rebuilding replica for 15 min | warning |
| `LonghornVolumeFaulted` | a volume has no usable replica for 1 min | critical |
| `LonghornNodeNotReady` | a Longhorn node is not ready for 10 min | warning |
| `LonghornDiskFilling` | a Longhorn data disk is above 80% for 30 min | warning |
| `LonghornBackupTargetUnavailable` | the TrueNAS NFS backup target is unavailable for 15 min | warning |
| `LonghornBackupTooOld` | the last backup of a volume in the backup group is older than 36 h (volumes never backed up are skipped; the PVC list in the rule must match the group) | warning |
| `ContainerOOMKilled` | a container restarted and its last end reason was OOMKilled | warning |

## 3. Test

Send a test alert straight to Alertmanager; it shows in the mail within about 30 s:

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093:9093 &
curl -s -XPOST localhost:9093/api/v2/alerts -H 'Content-Type: application/json' \
  -d '[{"labels":{"alertname":"TestAlert","severity":"warning","namespace":"monitoring"},"annotations":{"summary":"Test alert (docs/alerting.md). Safe to ignore."}}]'
```

The resolved mail follows after `resolve_timeout` (5 min).

## 4. Not covered

- Longhorn metrics are scraped through the chart's ServiceMonitor (`metrics.serviceMonitor`) and a NetworkPolicy `longhorn-manager-metrics` (the chart's own policy only admits Longhorn pods). The backup-age rule lists the PVC names of the backup group by hand.
- etcd snapshot upload failures only show as a failed systemd unit on the control plane (`etcd-backup.md`).
- Loki alert rules are off (`loki.md`, section 7); they can be added to `platform-alerts` when wanted.
