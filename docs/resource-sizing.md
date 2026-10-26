# Resource sizing: requests and limits of the platform apps

- The result of one review of memory and CPU use against the requests and limits of every platform container.
- The values live in `overlays/k8s-1/<app>/values.yaml` (cluster-specific, `repo-layout.md`).
- Use the "How to re-check" section to repeat the review after a few months or a big change.
- One living document: sections 2 and 3 describe the **latest** review, and section 7 keeps a one-line history of every review.

## 1. How it was measured

- Data: one week of container metrics, read from the Thanos Querier (the same data Grafana shows in its `Kubernetes / Compute Resources` dashboards).
- Memory: the **peak** of `container_memory_working_set_bytes` (the number the kernel compares with the limit).
- CPU: the **95th percentile** and the **peak** of the 5-minute rate.
- Nodes at the time: memory 31 to 49% used, CPU under 15%, so there is room to raise.

Rules used:

| Situation | Action |
|---|---|
| Peak at or above about 80% of the memory limit | raise the limit (to about 2 times the peak) and the request |
| Peak well above the memory request | raise the request to about the peak (the scheduler then places the pod correctly) |
| Request more than about 3 times the peak and the limit far above it | lower the request (and the limit if it is far too high) |
| CPU | change only where steady use is above the request; unused CPU requests cost nothing |

## 2. Raised (latest review: 2026-10-17)

| App | Peak memory | Before (request / limit) | After | File |
|---|---|---|---|---|
| capsule-proxy | 657Mi and rising about 21Mi/h (2026-10-20); OOM-killed at 1024Mi on 2026-10-19 | 256 / 512Mi, then 384 / 1024Mi | 512 / 2048Mi (2026-10-20) | `overlays/k8s-1/capsule-proxy/` |
| prometheus | 1465Mi (95% of limit) | 768 / 1536Mi | 1280 / 2304Mi | `overlays/k8s-1/kube-prometheus-stack/` |
| trivy-operator (the operator) | 490Mi (96%) | 128 / 512Mi | 384 / 1024Mi | `overlays/k8s-1/trivy-operator/` |
| metallb controller | 118Mi (92%) | 64 / 128Mi | 96 / 256Mi | `overlays/k8s-1/metallb/` |
| thanos-sidecar | 159Mi (83%) | 64 / 192Mi | 128 / 320Mi | `overlays/k8s-1/kube-prometheus-stack/` |
| grafana | 489Mi | 192 / 768Mi | request 384 | `overlays/k8s-1/grafana/` |
| garage | 417Mi | 256 / 1024Mi | request 384 | `overlays/k8s-1/storage-garage/` |
| jaeger | 270Mi | 128 / 512Mi | request 256 | `overlays/k8s-1/jaeger/` |
| thanos-compact | 393Mi | 192 / 768Mi | request 320 | `overlays/k8s-1/thanos/` |
| gatekeeper audit | CPU 91m steady | CPU request 50m | CPU request 100m | `overlays/k8s-1/gatekeeper/` |

The cluster's OOM-killed metric showed no kills for these, so the memory raises are about safety margin, except capsule-proxy (restarts at its limit) and Prometheus (95% of its limit).

**capsule-proxy leaked memory (found and fixed 2026-10-20).** Raising its limit was needed three times because capsule-proxy 0.15.0 leaks about 3 goroutines on every call of its readiness endpoint `/readyz/` (measured: 100 requests gave +303 goroutines; `/healthz/` gave +1). The kubelet probes every 10 s, so both replicas grew at about 22Mi an hour and were OOM-killed about every 46 h at 1024Mi (`ContainerOOMKilled`, 2026-10-19). Upstream fixed it in v0.15.1 ("reuse readiness probe transport to prevent memory leaks", #1124); the chart is pinned to 0.15.1. The limit stays at 2048Mi until the goroutine and heap metrics (ServiceMonitor `capsule-proxy-monitor`) stay flat for a week; then lower it. Prometheus, for comparison, is flat at about 1.9GB of 2.3GB with 343k series.

## 3. Lowered (latest review: 2026-10-17)

| App | Peak memory | Before (request / limit) | After | File |
|---|---|---|---|---|
| loki | 208Mi | 512 / 1024Mi | request 256 | `overlays/k8s-1/loki/` |
| thanos-store-gateway | 52Mi | 192 / 768Mi | 96 / 384Mi | `overlays/k8s-1/thanos/` |
| keda operator | 35Mi | 96 / 384Mi | 64 / 192Mi | `overlays/k8s-1/keda/` |
| keda metrics apiserver | 38Mi | 96 / 384Mi | 64 / 192Mi | `overlays/k8s-1/keda/` |
| keda admission webhooks | 12Mi | 64 / 256Mi | 32 / 128Mi | `overlays/k8s-1/keda/` |

Loki keeps its 1Gi limit because queries spike.

## 4. Left as they are

- Small Deployments that use 5 to 130Mi and fit their requests: argo-rollouts, external-secrets, fluent-bit, headlamp, garage-ui, blackbox-exporter, kube-state-metrics, node-exporter, reloader, traefik, velero, capsule controller, calico, coredns, the metrics-server, the NFS provisioner.
- Control-plane pods and Longhorn instance-managers: they have no memory request or limit by design.
- CPU requests that are higher than use: harmless.

### New since the review: sized, not measured

Added on 2026-10-18 and **not yet part of any review**. The requests and limits were chosen, and use on the first day is small; recheck them at the next review.

| App | First-day use | Request / limit | File |
|---|---|---|---|
| cloudnative-pg operator (2 pods) | 27 and 46Mi, 2 to 4m CPU | 50m, 128Mi / 512Mi each | `overlays/k8s-1/cloudnative-pg/` |
| jodywan-dev-pg (database, 1 pod) | 55Mi, 5m CPU | 100m, 256Mi / 1Gi (in the Cluster, `overlays/k8s-1/databases/`) | `overlays/k8s-1/databases/jodywan-dev-pg.yaml` |
| zeedlogic-dev-pg (database, 1 pod) | not measured yet | 100m, 256Mi / 1Gi (in the Cluster, `overlays/k8s-1/databases/`) | `overlays/k8s-1/databases/zeedlogic-dev-pg.yaml` |

Together they reserve 200m CPU and 512Mi memory (limits 2Gi). Nodes were at 33 to 54% memory when they were added. A database uses more memory as it grows (shared buffers, connections): look at it first at the next review.

## 5. After changing

- A values change restarts the pods of that app (Prometheus, Grafana and Loki have one replica: a short gap in metrics, dashboards or logs).
- Raising a request needs room on a node: check `kubectl top nodes` first. Net effect of the first review: memory requests +1.25 GiB (raised +1.65, lowered -0.4) and limits +2.0 GiB. Real use does not change; only the reserved amounts do.
- Watch the pods for a day: `kubectl get pods -A | grep -v Running`, and the restart column.

## 6. How to re-check

Port-forward the Thanos Querier (`kubectl -n monitoring port-forward svc/thanos-query 19090:10902`), then query:

| What | PromQL |
|---|---|
| Memory peak per container, 7 days | `max by (namespace,pod,container)(max_over_time(container_memory_working_set_bytes{container!="",container!="POD"}[7d]))` |
| CPU 95th percentile | `max by (namespace,pod,container)(quantile_over_time(0.95, rate(container_cpu_usage_seconds_total{container!="",container!="POD"}[5m])[7d:5m]))` |
| Requests and limits | `kube_pod_container_resource_requests{resource="memory"}` and `kube_pod_container_resource_limits{resource="memory"}` |
| Kills | `kube_pod_container_status_last_terminated_reason{reason="OOMKilled"}` |

Or open Grafana, folder Kubernetes, `Compute Resources / Namespace (Pods)`, and set the range to 7 days.

## 7. Review history

Add a row at the top after each review. Replace sections 2 and 3 with the new changes (the old ones stay in this table and in Git).

| Date | Data used | Changes | Result |
|---|---|---|---|
| 2026-10-17 | 7 days, Thanos | 10 raised, 5 lowered (sections 2 and 3) | first review; applied by the branch `resources-tuning`. Check after a week: restarts of capsule-proxy, trivy-operator and Prometheus |

Next review: about a month after the cluster has run with these values, or after a new app or a big tenant load. Include the two apps in "New since the review" (section 4).
