# kube-prometheus-stack: metrics and alerts

- Layer 1, managed by Argo CD. Step 8c in `fresh-install-order.md`.
- Prometheus operator, Prometheus, Alertmanager, node-exporter, kube-state-metrics, and the default rules and dashboards.
- **Grafana is its own app** (`grafana.md`); this chart only renders the 28 default dashboards for it.
- Long-term metrics: Thanos (`thanos.md`) keeps 7 days in Garage; Prometheus keeps 12 h locally.
- Alert rules and the mail receiver: `alerting.md`. Scheduler, controller-manager and etcd targets: `control-plane-metrics.md`.
- Test: `tests/kube-prometheus-stack.sh` (26 checks).

## 1. At a glance

| Item | Value |
|---|---|
| Chart | `kube-prometheus-stack` 92.3.0 (operator v0.94.1), repo `https://prometheus-community.github.io/helm-charts` |
| Namespace | `monitoring` (labels `gateway-access=platform`, Pod Security **`privileged`**: node-exporter uses hostNetwork, hostPID and hostPath) |
| Prometheus | 1 replica, retention `12h` plus `retentionSize 3GB`, Thanos sidecar, 4 GiB volume on `longhorn`, request 200m / 768Mi, limit 1.5Gi, `addons-critical` |
| Alertmanager | 1 replica, 1 GiB volume, mail receiver (`alerting.md`) |
| Exporters | node-exporter on every node, kube-state-metrics |
| Control plane | `kubeEtcd`, `kubeControllerManager` and `kubeScheduler` targets are on (`control-plane-metrics.md`) |
| Argo CD | ApplicationSet `kube-prometheus-stack`, auto-sync (`prune: false`, no self-heal), `ServerSideApply` (large CRDs) |
| Dashboards from Git | `dashboards/platform/*.json` (a kustomize source, section 6): Traefik, Jaeger, Velero, Probes and Trivy, in the Grafana folder Platform |
| Extra objects | `extraManifests`: NetworkPolicy `thanos-query-ingress`, Service `thanos-query-lan` (`10.1.5.172`, docker-2 access), PodMonitor `traefik`, the `platform-alerts` rule |
| Also in `monitoring` | Thanos (query, store gateway, compactor), `blackbox-exporter`, and `prom-label-proxy-<tenant>` for the per-tenant metrics (`tenant-observability.md`) |
| Files | `appsets/kube-prometheus-stack.yaml`, `base/kube-prometheus-stack/values.yaml`, `dashboards/platform/`, `overlays/k8s-1/kube-prometheus-stack/values.yaml` |

## 2. Design choices

- **Retention 12 h.** The Thanos sidecar uploads 2 h blocks, so Prometheus keeps only the last 12 h and everything older is served by the Store Gateway through the Thanos Querier (it was 2 days before Thanos). Sizing came from the live cluster (about 100 pods, 50 to 80k series, an estimated 0.3 to 0.6 GB per day) with headroom for tenants: each extra pod adds roughly 100 to 150 series. `retentionSize` makes Prometheus drop old blocks before the volume fills.
- **No admission webhook** (`prometheusOperator.admissionWebhooks.enabled: false`): it needs patch Jobs and hook ordering under Argo CD. Bad rule syntax is then caught by Prometheus at reload, not at apply.
- **Everything is selected.** ServiceMonitors, PodMonitors, rules and probes are picked up from every namespace (`*NilUsesHelmValues: false`), so an app only needs its own ServiceMonitor switched on. Tenants cannot create these CRDs (no RBAC; the test checks it). Keep it that way until a controlled path for tenant metrics exists.
- **The tenant label as a metric label.** `kube-state-metrics` exposes `capsule.clastix.io/tenant` in `kube_namespace_labels`, so per-tenant dashboards can join on it.
- **Priority.** Prometheus and Alertmanager use `addons-critical` so tenant pods cannot evict them. Tenant quotas (16 CPU and 32 Gi of limits for zeedlogic) exceed the cluster, so this matters.
- **Grafana is separate** so it restarts, upgrades and rolls back on its own. This chart still renders the default dashboards (`grafana.enabled: false` with `forceDeployDashboards: true`), and Grafana's sidecar finds them by label in any namespace.

## 3. Dependencies

**Needs (must exist first)**

| Dependency | Why | Check |
|---|---|---|
| Longhorn, class `longhorn` | the Prometheus and Alertmanager volumes | `./tests/storage-longhorn.sh` |
| Argo CD with the `platform` AppProject, including the prometheus-community repo | deploys it | `kubectl apply -f bootstrap/platform-project.yaml` |
| Secrets `alertmanager-smtp` (namespace `monitoring`) and `thanos-objstore` | the mail receiver and the Thanos sidecar | created by External Secrets (step 5b) |

**Waiting for it:** Grafana (it needs the Prometheus data source), Thanos (sidecar), the ServiceMonitors of the other apps (their CRD is created here), and later the Gatekeeper and Trivy dashboards.

**If something is missing**

- No `longhorn` class: the PVCs stay `Pending`.
- Do **not** enable `monitoring.serviceMonitor` in the Loki or Fluent Bit values before this app has synced: the ServiceMonitor CRD does not exist yet and their sync would fail.
- The Loki and Fluent Bit charts only render a ServiceMonitor when the cluster has the `ServiceMonitor` kind. Argo CD passes the cluster's API list; plain `helm template` needs `--api-versions monitoring.coreos.com/v1/ServiceMonitor`.

## 4. Deploy

1. Commit and push.
2. `kubectl apply -f bootstrap/platform-project.yaml` (adds the prometheus-community repo).
3. Sync `platform-gitops` (creates the ApplicationSet), then sync `kube-prometheus-stack`. The namespace is created with its labels.
4. Run `./tests/kube-prometheus-stack.sh`.
5. Then install Grafana (`grafana.md`, step 8c2).

## 5. Test: `tests/kube-prometheus-stack.sh`

1. The operator, kube-state-metrics, Prometheus and Alertmanager are ready; node-exporter runs on every node; the volumes are Bound on `longhorn`; no restarts.
2. Every Prometheus scrape target is up (a summary per job); the `Watchdog` alert fires.
3. The Grafana checks of the "own app" (`grafana.md`): `/api/health` is 200, the `prometheus` and `loki` data sources are healthy, default dashboards are loaded, the route answers.
4. Tenant developers cannot create ServiceMonitors or PrometheusRules.

## 6. Dashboards from Git

Dashboards live in three places:

| Dashboards | Where they live | Survive a Grafana restart or a fresh install? |
|---|---|---|
| The 28 default Kubernetes and Prometheus dashboards (with etcd, scheduler and controller-manager) | ConfigMaps rendered by this chart (label `grafana_dashboard`), folder Kubernetes | yes, recreated from Git |
| **Traefik** (grafana.com dashboard 17346 revision 9, vendored, no download at startup), **Jaeger**, **Velero**, **Probes**, **Trivy** (written for this repo) | `dashboards/platform/*.json`, folder Platform | **yes, from Git** |
| Anything created or imported by hand in the Grafana UI | only in Grafana's 2 GiB volume | survives a restart; **lost if the volume is lost**, and not in Git |

How the platform dashboards get into Grafana:

- Each JSON file in `dashboards/platform/` becomes a ConfigMap through kustomize (`dashboards/platform/kustomization.yaml`, a third source of this ApplicationSet; no Helm, no generated file).
- The ConfigMaps carry `grafana_dashboard: "1"` and `grafana_folder: Platform`. Grafana's sidecar loads them into the folder Platform (`grafana.sidecar.dashboards.folderAnnotation` and `provider.foldersFromFilesStructure` in the values).
- The chart's own 28 dashboards get `grafana_folder: Kubernetes` from `grafana.sidecar.dashboards.annotations`, so the General folder stays empty.

To change or add a dashboard:

1. Edit the JSON (change) or add `<name>.json` and a `configMapGenerator` entry named `platform-dashboard-<name>` (new). To keep a dashboard made in the UI: Dashboard > Share > Export > Export as JSON.
2. Push. Grafana picks the ConfigMap up within about a minute, with no restart. Provisioned dashboards cannot be saved from the UI: change the JSON in Git.
3. Preview with `kubectl kustomize dashboards/platform`. A ConfigMap is limited to 1 MiB; the largest file here is 33 KB.

The Traefik dashboard needs Traefik's metrics. Traefik already serves them on its `metrics` entry point (port 9100); the PodMonitor `traefik` in `extraManifests` makes Prometheus scrape them, with no change to Traefik.

The docker-2 Grafana is separate: its dashboards and data sources live in its own volume, not in this repo. To use the Traefik dashboard there, import `dashboards/platform/traefik.json` and choose `Prometheus K8s-1`.

## 7. Risks and open items

- **Memory:** the Prometheus limit is 1.5Gi. `OOMKilled` in `RESTARTS` means more series than expected (tenants growing): raise the limit, and check the biggest jobs in Prometheus first.
- **Volume full:** `retentionSize` guards it; Longhorn can expand the PVC. Measure real use with `kubectl -n monitoring exec prometheus-kube-prometheus-stack-prometheus-0 -c prometheus -- du -sh /prometheus`.
- **Single replicas:** a Prometheus restart leaves a short gap.
- **Tenant isolation is built.** Prometheus and Loki have no authentication towards pods, so the control is network and organization based: the tenant baseline and the platform ingress limits (`tenant-network.md`), and a Grafana organization per tenant with read-only data sources fixed to the tenant (`tenant-observability.md`). Tenants cannot create ServiceMonitors or PrometheusRules.
- **ServiceMonitors** exist for Loki, Fluent Bit, Longhorn, Jaeger, Grafana, Argo Rollouts, External Secrets and blackbox-exporter. Garage does not have one yet.
