# ZeedLogic observability (metrics, logs, traces, dashboards) for the tenant environments

- Part of the tenant observability work (`tenant-observability.md`). Applies to the ZeedLogic environments `zeedlogic-dev` (and, for metrics and dashboards, the lab `jodywan-dev`).
- Status: files written 2026-10-19; **read the "Verified" section for what has been seen working**.
- Files: `appsets/zeedlogic-observability.yaml`, `overlays/k8s-1/zeedlogic-observability/`, `grafana/` (dashboards and their ConfigMaps), `overlays/k8s-1/jaeger/values.yaml` (the third `jaeger-ingress` rule), `overlays/k8s-1/grafana/values.yaml` and `base/grafana/values.yaml` (the provider and the mount).
- Test: `tests/zeedlogic-observability.sh`.
- The application side (the Helm values, and the step-by-step) is in the zeedlogic-microservices repository: `docs/setup/kubernetes-walkthrough.md`, step "Observability".

## 1. What each signal needs

| Signal | Source | Who must provide it | Why |
|---|---|---|---|
| **Metrics: fastapi** | `/metrics` on the fastapi Service (port `http`), job `zeedlogic-fastapi` | the platform: ServiceMonitor `zeedlogic-fastapi` in `monitoring` | tenants cannot create a ServiceMonitor; the chart's own (`global.monitoring.serviceMonitor`) stays off on k8s-1 |
| **Metrics: Kong** | Kong's Prometheus plugin on the status listener (pod port `status`, 8100), job `zeedlogic-kong` | the platform: PodMonitor `zeedlogic-kong` | the Kong chart does not put the status port on its Service |
| **Metrics: database** | CloudNativePG (`cnpg_*`), job `databases/<cluster>` | already there: `enablePodMonitor: true` on the Cluster | |
| **Metrics: containers** | cAdvisor and kube-state-metrics | already there | |
| **Logs** | Fluent Bit, Loki tenant `zeedlogic` (labels `namespace`, `pod`, `container`; each line is JSON with a `log` field) | already there | |
| **Traces** | the app's OTLP exporter to `jaeger.jaeger.svc.cluster.local` 4317 (fastapi, gRPC) and 4318 (Studio's browser traces and Kong, HTTP; Kong also needs `kong.env.tracing_instrumentations: all` in the Helm values) | the environment's Helm values (`global.observability.otlpEndpoint`, `otlpHttpEndpoint`) **and** the platform: two network rules | see section 3 |
| **Dashboards** | ConfigMaps in the `grafana` namespace | the platform: `grafana/kustomization.yaml` | |

All of the scrape objects match the namespaces `zeedlogic-dev` and `jodywan-dev`. A new environment namespace is one more name in `namespaceSelector.matchNames` of both monitors.

## 2. Dashboards

Five dashboards, titled `ZeedLogic ... (Kubernetes)`: **Platform** (fastapi and Kong), **Containers**, **Logs**, **ERP Demo** (the demo jobs' log), and **Postgres** (CloudNativePG metrics, selectable cluster). Each has a `Namespace` selector (and Postgres a `Database cluster` selector). They are generated from the Compose dashboards by `deploy/shared/grafana-dashboards/k8s/make-k8s-dashboards.py` in the zeedlogic-microservices repository, and copied here with `grafana/sync-zeedlogic-dashboards.sh <checkout>`. Not converted: the two k6 dashboards and the website dashboard. The Compose dashboard's trace-derived row (Jaeger spanmetrics) is dropped, because k8s-1's Jaeger has no spanmetrics connector.

| Where | How | What |
|---|---|---|
| **Platform organization (Main Org.)**, folder `ZeedLogic` | ConfigMap `zeedlogic-dashboards-platform`, label `grafana_dashboard: "1"`, annotation `grafana_folder: ZeedLogic`, loaded by Grafana's sidecar | all five, including Postgres |
| **Organization `zeedlogic` (id 2)**, folder `ZeedLogic` | ConfigMap `zeedlogic-dashboards`, mounted at `/var/lib/grafana/dashboards/zeedlogic` and loaded by the provider `zeedlogic-dashboards` (orgId 2) | four, read-only. No Postgres: the tenant's metrics proxy pins `namespace` to the tenant's namespaces, and the databases live in `databases` |

The ConfigMap `zeedlogic-dashboards` is a volume of the Grafana pod, so it must exist before the pod starts (same rule as `tenant-dashboards`): on a rebuild, `kubectl apply -k grafana` first.

## 3. Traces: the decision

Jaeger has no tenancy and no authentication on OTLP or on the query API (`jaeger.md`), which is why tenants were kept out. On 2026-10-19 `zeedlogic-dev` was let **send** (4317 and 4318) and nothing else:

| Rule | Where |
|---|---|
| ingress from `zeedlogic-dev` to 4317 and 4318 | third rule of `jaeger-ingress`, `overlays/k8s-1/jaeger/values.yaml` |
| egress from `zeedlogic-dev` to the Jaeger pods on 4317 and 4318 only | `allow-egress-to-jaeger`, `overlays/k8s-1/zeedlogic-observability/network-policies.yaml` |

Reading stays platform-only: the query API (16686) is reachable from `jaeger`, `monitoring` and `grafana` only, and the `Jaeger` data source exists in the platform organization only, not in the tenant organizations. The residual risk is that a tenant pod can push arbitrary spans (anyone in the namespace could fill Jaeger's 5 GiB volume or forge traces); the 3-day retention bounds it. Do not copy this rule for a tenant you do not trust: that tenant needs Tempo.

## 4. Adding another environment (stg, prod, a second tenant)

1. Add the namespace to `matchNames` in both monitors.
2. If it should send traces: one more `from` in `jaeger-ingress` and a copy of `allow-egress-to-jaeger` in its namespace. This is a decision, not a default.
3. Add it to the `Namespace` list in `make-k8s-dashboards.py` (the variable is a fixed list), regenerate, sync, commit.
4. In the Helm values of the environment: the OTLP endpoints (section 1). Leave `global.monitoring.serviceMonitor` and `global.keda` off.
5. Run `tests/zeedlogic-observability.sh` with `NS=<namespace>`.

## 5. Not done

| Item | Note |
|---|---|
| Trace-derived metrics panels | needs Jaeger's spanmetrics connector and a scrape of it; the Compose stack has it |
| Alerting rules for ZeedLogic | none yet (`alerting.md`) |
| `external-developer-demo` and the k6 dashboards | not on Kubernetes |
| Studio browser traces | go through Studio's nginx to 4318; check once with a browser session |

## 6. Verified (2026-10-19, zeedlogic-dev)

`tests/zeedlogic-observability.sh`: 15 checks passed, 0 failed.

| Check | Seen |
|---|---|
| Prometheus targets | `zeedlogic-fastapi` (zeedlogic-dev, jodywan-dev) and `zeedlogic-kong` up; fastapi request counters, Kong plugin metrics, CloudNativePG and container metrics present |
| Loki | 374 lines of `zeedlogic-dev` in 10 minutes, under the tenant `zeedlogic` |
| Jaeger | the services `zeedlogic-fastapi` and `zeedlogic-kong` appear after the upgrade with the OTLP endpoints and, for Kong, `kong.env.tracing_instrumentations: all` (without it Kong only propagates the header and exports nothing); a pod in `zeedlogic-dev` sends (OTLP/HTTP 200) and cannot read the query API; a pod in `jodywan-stg` reaches neither |
| Grafana | Main Org.: 5 dashboards, organization `zeedlogic`: 4 (searched through the dashboard sidecar) |
| Panels | every PromQL query of the Platform, Containers and Postgres dashboards run against Prometheus with `zeedlogic-dev`: all return series. Every LogQL query of Logs and ERP Demo is valid; three are empty because the value is zero (no error-level lines, no Tracebacks, no `[erp-sim]` line in the last 5 minutes) |

Found and fixed while verifying: the Postgres dashboard first selected `cluster=`, a label only `cnpg_collector_up` carries (now `job="databases/<cluster>"`); the PodMonitor's relabeling lacked the CRD default `action: replace`, so Argo CD showed it OutOfSync.

Not seen: the dashboards rendered in a browser (their queries were run directly) and Studio's browser traces (they need a browser session).
