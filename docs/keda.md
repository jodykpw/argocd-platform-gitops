# KEDA

- Event-driven autoscaling. Layer 1, Argo CD app `keda`, namespace `keda`. Step 8n in `fresh-install-order.md`.
- Chart `kedacore/keda` 2.21.0 (KEDA 2.21.0). Auto-sync (`prune: false`).
- Test: `tests/keda.sh` (17 checks).
- Not enabled for tenants (section 3).

## 1. What it adds

A `ScaledObject` points at a Deployment or StatefulSet and lists triggers (cron, Prometheus query, CPU, memory, queues,
...). KEDA creates and drives a HorizontalPodAutoscaler for it, and can scale **to zero** and back, which a plain HPA
cannot. Metrics for the HPA are served from the external metrics API that KEDA registers.

| Part | Role |
|---|---|
| `keda-operator` | watches ScaledObjects, creates the HPA, scales 0 to 1 and 1 to 0, polls the triggers |
| `keda-operator-metrics-apiserver` | serves `external.metrics.k8s.io` to the HPA controller |
| `keda-admission-webhooks` | validates ScaledObjects (failurePolicy `Ignore`: an outage cannot block creating one) |

## 2. Fit with this cluster

| Question | Answer |
|---|---|
| Clash with metrics-server? | none: metrics-server owns `metrics.k8s.io`, KEDA registers `external.metrics.k8s.io` (checked before install, and by the test) |
| Prometheus as a scaler source | works with the Thanos Querier at `http://thanos-query.monitoring.svc:10902` (platform apps) |
| Footprint | three Deployments, one replica each, requests 50m CPU and 96Mi each (limits 384Mi) |
| Metrics | PodMonitors for the operator and the metrics API server |
| Argo CD | `ignoreDifferences` for the CA bundle KEDA writes into its APIService, webhook configuration and CRD conversion |

## 3. Tenants: not enabled (decision)

`rbac.aggregateToDefaultRoles: false`, so tenant owners and developers have **no** rights on `ScaledObject`,
`ScaledJob` or `TriggerAuthentication` (tested). Reason: a ScaledObject makes the **KEDA operator**, a cluster component
with its own network access and credentials, call whatever address the trigger names (for example a Prometheus
`serverAddress`). That is a way to reach internal services that the tenant network baseline otherwise blocks.

To enable KEDA for tenants later, first add guardrails:

1. A ValidatingAdmissionPolicy for `scaledobjects` in tenant namespaces allowing only safe trigger types (cpu,
   memory, cron) and Prometheus triggers whose `serverAddress` is that tenant's own `prom-label-proxy`
   (`tenant-observability.md`).
2. Deny `TriggerAuthentication` that reference Secrets of other namespaces (KEDA's own rules already forbid it, check).
3. Aggregate a ClusterRole for `scaledobjects` into `edit` (a `rbac.authorization.k8s.io/aggregate-to-edit: "true"`
   label), and add the new kinds to the Argo CD AppProject allowlist if they deploy with Argo CD.
4. Add the checks to `tests/tenant-guardrails.sh`.

## 4. Using it (platform)

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata: {name: my-app, namespace: my-ns}
spec:
  scaleTargetRef: {name: my-app}
  minReplicaCount: 0
  maxReplicaCount: 5
  triggers:
    - type: prometheus
      metadata:
        serverAddress: http://thanos-query.monitoring.svc.cluster.local:10902
        query: sum(rate(http_requests_total{namespace="my-ns"}[2m]))
        threshold: "50"
```

Check: `kubectl -n my-ns get scaledobject,hpa`; KEDA's own log: `kubectl -n keda logs deploy/keda-operator`.

A workload that Argo CD manages and KEDA scales needs the replica count left out of Git, or an `ignoreDifferences` on
`/spec/replicas`, or the sync resets it.

## 5. First start

On a fresh install `keda-operator` writes its certificates and then **exits once on purpose** (log: "Secrets have been
updated; exiting so pod can be restarted", exit code 0), so it shows one restart. That is normal; later restarts are not.

## 6. Install

1. `kubectl apply -f bootstrap/platform-project.yaml` (adds the kedacore chart repo).
2. Push, let `platform-gitops` create the ApplicationSet, sync `keda`.
3. `./tests/keda.sh` (about 2 to 3 minutes). Auto-sync is on in `appsets/keda.yaml`.

## 7. Test: `tests/keda.sh`

Components ready and not restarting; `external.metrics.k8s.io` Available and `metrics.k8s.io` still working;
webhook `Ignore`; tenants cannot create ScaledObjects; a cron ScaledObject scales a Deployment from 1 to 2; another
scales one to zero; the HPA is removed with its ScaledObject; Prometheus has `keda_*` series.
