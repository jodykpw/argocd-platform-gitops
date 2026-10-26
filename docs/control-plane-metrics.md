# Control-plane metrics

- Scheduler, controller-manager and etcd targets are scraped by Prometheus: 3 targets up each. Part of step 8i in `fresh-install-order.md`.
- The kubespray inventory setting `etcd_metrics_port: 2381` is in `inventory/k8s-1.jodywan.com/group_vars/all/etcd.yml` on branch `dev` (commit `555c6339b`).
- kube-proxy stays off on purpose (metrics on 127.0.0.1:10249; low value).

## 1. kube-scheduler and kube-controller-manager

- They listen on all addresses (`--bind-address=::`, ports 10259 and 10257) and answer HTTPS to the Prometheus ServiceAccount token.
- The chart's Services (in `kube-system`, selector `component=...`) and ServiceMonitors are on through `kubeScheduler.enabled` and `kubeControllerManager.enabled` in `base/kube-prometheus-stack/values.yaml` (`insecureSkipVerify: true`: the certificates are signed by the cluster CA for other names).
- 6 targets are up, along with the chart's scheduler, controller-manager and API-server rules and dashboards. No node change was needed.

## 2. etcd

etcd had `ETCD_METRICS=basic` but no `ETCD_LISTEN_METRICS_URLS`, so metrics were only on the client port 2379, which needs a client certificate. The fix is a plain-HTTP listener on 2381 (node IP and localhost) on each control plane.

All three answer `:2381/metrics` with 200, and `etcdctl endpoint health` shows 3 of 3.

**To add the listener on a node** (one member at a time, followers first and the leader last; check that all three are healthy between nodes, because two nodes restarted 19 seconds apart worked but left no margin):

```bash
# on each control plane, with sudo; backs up /etc/etcd.env, adds the line, restarts etcd, waits for health
bash node-prep/etcd-metrics-node.sh
# health from any control plane:
sudo etcdctl --endpoints=https://10.1.5.151:2379,https://10.1.5.152:2379,https://10.1.5.153:2379 \
  --cacert=/etc/ssl/etcd/ssl/ca.pem --cert=/etc/ssl/etcd/ssl/admin-control-plane-1.pem \
  --key=/etc/ssl/etcd/ssl/admin-control-plane-1-key.pem endpoint health
```

Take a fresh snapshot first (`/var/backups/etcd-snapshots`, also in the Garage bucket; `etcd-backup.md`). The old `/etc/etcd.env` is kept as `/etc/etcd.env.bak-2026-10-10` on each control plane.

## 3. Scraping etcd

`kubeEtcd` in `overlays/k8s-1/kube-prometheus-stack/values.yaml`:

- `endpoints: [10.1.5.151, 10.1.5.152, 10.1.5.153]`, `service.port` and `targetPort` 2381, `serviceMonitor.scheme: http`.
- etcd is a systemd service, not a pod, so the chart builds a selector-less Service with explicit Endpoints in `kube-system`.
- The chart's etcd rules and dashboard are on.
- The ServiceMonitor still sends the Prometheus ServiceAccount token as a bearer header over plain HTTP on the LAN (chart default); etcd ignores it.

## 4. Kubespray

Without `etcd_metrics_port: 2381` in the inventory, the next kubespray run rewrites `/etc/etcd.env` without `ETCD_LISTEN_METRICS_URLS` and restarts etcd, and the etcd target goes down. The inventory is on branch `dev` of `gitlab.jodywan.com/servers/pcls.jodywan.com/test.jodywan.com/kubespray` (local clone `~/kubernetes/kubespray`; push with `git push origin dev` from that clone).
