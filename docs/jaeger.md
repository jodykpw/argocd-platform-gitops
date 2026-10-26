# jaeger: distributed tracing

- Layer 1, managed by Argo CD (`cluster/argocd-gitops.md`, "Tracing: Jaeger"). Step 8e in `fresh-install-order.md`.
- Jaeger receives traces (OTLP), stores them and answers queries.
- People read traces **through Grafana**: the cluster Grafana has a `Jaeger` data source. There is no Jaeger UI hostname.
- Test: `tests/jaeger.sh` (14 checks).

## 1. At a glance

| Item | Value |
|---|---|
| Chart | `jaeger` **4.13.1** (app **2.20.0** = Jaeger v2, built on the OpenTelemetry Collector), repo `https://jaegertracing.github.io/helm-charts`. Not 4.14 / 2.21, see the first risk in section 8 |
| Namespace | `jaeger` (Pod Security `baseline`) |
| Mode | all-in-one: OTLP receiver, storage and query API in one pod, 1 replica (Badger allows one writer) |
| Storage | **Badger** (embedded database) on the PVC `jaeger-badger`, 5 GiB, class `longhorn` (2 replicas = 10 GiB raw; the class is Retain) |
| Retention | **3 days** of spans (`ttl.spans: 72h`) |
| Send traces to | OTLP gRPC `jaeger.jaeger.svc.cluster.local:4317`, OTLP HTTP `...:4318` (inside the cluster) |
| Read traces | query API `jaeger.jaeger.svc.cluster.local:16686`, used by the Grafana data source `Jaeger` (UID `jaeger`) |
| Who can connect | pods of the namespaces `jaeger` and `monitoring`, and the namespace `traefik` on port 4317 only (NetworkPolicy `jaeger-ingress`) |
| Resources | request 50m / 128Mi, limit 512Mi memory |
| Metrics | ServiceMonitor `jaeger` (port 8888) |
| Argo CD | ApplicationSet `jaeger`, auto-sync (`prune: false`, no self-heal) |
| Files | `appsets/jaeger.yaml`, `base/jaeger/values.yaml`, `overlays/k8s-1/jaeger/values.yaml` |

## 2. Decisions

| Question | Choice | Why |
|---|---|---|
| Which Jaeger? | a new one in k8s-1 | traces stay in the cluster and do not depend on docker-2 |
| Storage | Badger on a Longhorn volume | one small pod, little memory, fits a dev cluster. Not S3: Jaeger cannot write to S3; that would need Grafana Tempo (more components, and it shares Garage's 29 GiB with Thanos) |
| Access | through Grafana only | Authentik login already works there; Jaeger's own UI has no login and would need a proxy |

Not touched: the Jaeger on docker-2 (`jaeger` 2.20.0) and its Authentik application `jaeger`. They are a separate system; the new one has no connection to them.

## 3. Design notes

- **Jaeger v2 is configured by one file** (`userconfig` in the values): receiver, pipeline, storage backend and query extension. The chart does not know Badger; it is a block in that file. The config is checked with `jaeger validate` and by starting the image with it.
- **Badger = one writer.** Two pods on one volume would fail, so `replicas: 1` and the Deployment strategy is `Recreate` (the old pod stops before the new one starts: a short gap in trace ingestion on every change).
- **The volume survives removal.** The Longhorn class is `Retain`, so the data is kept if the app is deleted.
- **No `ui.config_file`.** The chart mounts the UI config only when `uiconfig` is set, and a path to a missing file stops Jaeger at startup.
- **No authentication on OTLP or the query API.** Anyone who can reach the pod can push spans or read traces. The NetworkPolicy is the control: only `jaeger`, `monitoring` and (4317 only) `traefik` may connect. This also keeps tenants out.

## 4. What sends traces

Jaeger is empty until something sends spans: apps must be instrumented.

| Source | How | State |
|---|---|---|
| The test (`tests/jaeger.sh`) | one span for `jaeger-test` over OTLP/HTTP | works |
| Traefik (every request through the Gateway) | OpenTelemetry tracing in Traefik's configuration, endpoint `jaeger.jaeger.svc.cluster.local:4317`, sample rate 10%. Set in `base/traefik/values.yaml` and `overlays/k8s-1/traefik/values.yaml` (sample rate) | **applied**: the service `traefik` is in Jaeger |
| Argo CD, Grafana, Loki, Thanos | each has an optional OTLP tracing setting | not done |
| Tenant apps | OpenTelemetry SDK or auto-instrumentation, endpoint as above | `zeedlogic-dev` only (2026-10-19, write-only, see `zeedlogic-observability.md` section 3); any other tenant needs a deliberate change to open 4317 and 4318 to its namespaces |

### Traefik tracing

- **What it adds:** exactly six arguments on the Traefik pods:

  ```
  --tracing.sampleRate=0.1
  --tracing.serviceName=traefik
  --tracing.otlp=true
  --tracing.otlp.grpc=true
  --tracing.otlp.grpc.endpoint=jaeger.jaeger.svc.cluster.local:4317
  --tracing.otlp.grpc.insecure=true
  ```

- **Order:** the Jaeger NetworkPolicy must allow the namespace `traefik` on 4317 before Traefik exports (`kubectl -n jaeger get networkpolicy jaeger-ingress -o yaml | grep -A8 traefik`). A change to the Traefik values rolls its 2 replicas one at a time (PodDisruptionBudget `minAvailable: 1`).
- **Check:** send some requests, then look for the service:

  ```bash
  for i in $(seq 1 60); do curl -s -o /dev/null -H 'Host: headlamp.jodywan.com' http://10.1.5.170/; done
  kubectl -n jaeger port-forward svc/jaeger 16686:16686 &   # then
  curl -s http://127.0.0.1:16686/api/services               # contains "traefik"
  ```

  In Grafana: Explore > Jaeger > service `traefik`. Traces for `GET headlamp.jodywan.com` with status 200 have 2 spans each.
- **Sampling:** 10% of requests, because the HAProxy health checks and polling are frequent and would otherwise be most of the traces. Raise it to see every request of a test. At 5 GiB and 3 days, a span of about 1 KiB is far below the limit at this traffic; watch the volume anyway (use Longhorn's volume usage; `kubectl exec` is not available in the image).
- **Risk:** low. The export is asynchronous: if Jaeger is down or the policy is wrong, Traefik logs errors (`kubectl -n traefik logs deploy/traefik | grep -i otel`) and keeps routing. Spans contain the method, host, path (query parameters are redacted by default) and status code, no bodies and no headers (`capturedRequestHeaders` is empty on purpose).
- **Roll back:** revert the `tracing:` change in Git and merge.

## 5. Grafana dashboard: `Jaeger (k8s-1)`

Folder **Platform** in the cluster Grafana, defined in `dashboards/platform/jaeger.json` (UID `platform-jaeger`; change it in Git, it is not editable in the UI). It has 12 panels:

| Row | Panels |
|---|---|
| Health | Jaeger up, spans received since start, spans refused or failed (should be 0), free space on the Badger volume, memory |
| Pipeline | spans received per second by transport (gRPC 4317, HTTP 4318), spans written to storage per second |
| Storage | latency p50, p95, p99; requests per second by operation and result; Badger index size and free space |
| Resources | memory and CPU |
| Traces | a table of recent traces from the Jaeger data source, for the service chosen in the `Service` variable |

- The metric names in this version have **no `_total` suffix** (`otelcol_receiver_accepted_spans`, `otelcol_exporter_sent_spans`, `jaeger_storage_requests`). A Jaeger upgrade can rename them.
- Badger's value-log size metric (`jaeger_storage_badger_size_bytes_vlog`, about 2 GiB) is a **preallocated sparse file**, not data in use, so the dashboard shows the free space of the volume instead.
- `result=err` on `get_trace` in "Storage requests" is a lookup of a trace that does not exist (for example a test with a made-up ID), not a storage fault.
- The `Service` variable is a fixed list (`traefik`, `jaeger-test`, `jaeger`); add a service name to it in `jaeger.json` when a new source starts sending traces.

## 6. Dependencies

**Needs (must exist first)**

| Dependency | Why | Check |
|---|---|---|
| Longhorn, class `longhorn` | the Badger volume | `./tests/storage-longhorn.sh` |
| kube-prometheus-stack | the ServiceMonitor CRD | `./tests/kube-prometheus-stack.sh` |
| Grafana | reading traces | `grafana.md` |
| The `jaegertracing` chart repo in the `platform` AppProject | deploys it | `kubectl apply -f bootstrap/platform-project.yaml` |
| The Grafana data source `Jaeger` | reading traces | `datasources:` in `overlays/k8s-1/grafana/values.yaml` |

**Waiting for it:** trace sources (section 4), and later a Loki to Jaeger link in Grafana.

**If something is missing**

- No `longhorn` class: the PVC stays `Pending` and the pod waits.
- Synced before kube-prometheus-stack: the ServiceMonitor is rejected (no CRD); sync the stack first.
- A Grafana data source without Jaeger: its health shows an error until the pod is up; nothing else breaks.

## 7. Deploy and test

1. Commit and push (the Grafana overlay holds the `Jaeger` data source, so Grafana restarts for about a minute).
2. `kubectl apply -f bootstrap/platform-project.yaml` (adds the jaegertracing repo).
3. Sync `platform-gitops`, then sync `jaeger`.
4. Run `./tests/jaeger.sh`. Then open Grafana > Explore > `Jaeger` > search the service `jaeger-test`.

`tests/jaeger.sh`:

1. The Deployment is ready, the Badger volume Bound on `longhorn`, no restarts, and the Services expose 4317, 4318 and 16686.
2. A span pushed over OTLP/HTTP from a pod in `jaeger` is accepted, found again by trace ID through the query API, and its service `jaeger-test` is listed (the legacy endpoint `/api/services` is checked).
3. A pod in the namespace `default` cannot reach OTLP (the policy).
4. Prometheus scrapes Jaeger (`up{job="jaeger"}` = 1), and the Grafana data source `jaeger` is healthy.

## 8. Risks and open items

- **Version pin.** Jaeger 2.21 removed the legacy query endpoints `/api/services`, `/api/operations` and the trace search (404). Grafana's Jaeger data source (13.2.3) uses exactly those, so with 2.21 its health check fails with `404 Not Found` and search returns an error; only `/api/v3/*` and `/api/traces/<id>` remain. 2.20.0 serves both, so the chart is pinned to 4.13.1. **Before bumping**, run `./tests/jaeger.sh` and check whether Grafana's Jaeger plugin supports `/api/v3`.
- **Badger is not a durable archive.** It is a single-node embedded store: fine for a dev cluster, not for traces that must be kept or searched at scale. Moving to Elasticsearch, OpenSearch or Tempo later is a storage change in `userconfig`; spans already stored are not migrated.
- **Single point of failure, and a gap on every restart** (`Recreate`).
- **Disk:** 5 GiB. Badger needs room to compact; watch the volume once real traces arrive and grow the PVC (Longhorn allows it) or lower `ttl.spans`.
- **No sampling policy yet** beyond Traefik's 10%. Every span another source sends is stored: decide a rate at the source or add a sampling processor before turning on a busy source.
