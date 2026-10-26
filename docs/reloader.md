# Reloader

- Restarts a Deployment, StatefulSet or DaemonSet (rolling) when a ConfigMap or Secret it uses changes.
- Layer 1, Argo CD app `reloader`, namespace `reloader`. Step 8p in `fresh-install-order.md`.
- Chart `stakater/reloader` 2.2.18 (Reloader v1.4.22). Auto-sync (`prune: false`).
- Test: `tests/reloader.sh` (13 checks).
- Grafana is the first platform app that uses it.

## 1. Why

Kubernetes does not restart pods when a ConfigMap or Secret they consume changes: an environment variable keeps its old
value, and a mounted file is updated but the application may not re-read it. Reloader closes that gap for workloads
that ask for it.

## 2. How a workload opts in

Annotate the workload (the Deployment, not the pod template). Reloader never acts on a workload without one of these:

| Annotation | Meaning |
|---|---|
| `reloader.stakater.com/auto: "true"` | restart when **any** ConfigMap or Secret the workload uses changes (volumes, envFrom, env valueFrom) |
| `configmap.reloader.stakater.com/reload: "name1,name2"` | restart only when these ConfigMaps change |
| `secret.reloader.stakater.com/reload: "name1"` | restart only when these Secrets change |
| `reloader.stakater.com/search: "true"` + `reloader.stakater.com/match: "true"` on the ConfigMap or Secret | opt in from the resource side |

Example:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  annotations:
    reloader.stakater.com/auto: "true"
```

## 3. Settings and why

| Setting | Value | Why |
|---|---|---|
| `autoReloadAll` | `false` | opt-in only: nothing restarts unless an owner asked for it, so a ConfigMap edit cannot cause a surprise rollout of a platform app |
| `reloadStrategy` | `annotations` | the change is recorded as a pod-template annotation `reloader.stakater.com/last-reloaded-from`, not as a `STAKATER_*` environment variable in the container spec that Helm and Argo CD own |
| `watchGlobally` | `true` | one instance serves the platform and the tenants |
| replicas | 1 | it only restarts workloads; a missed event is caught after its restart |
| metrics | PodMonitor `reloader-reloader` | the chart renders no Service, so a PodMonitor is used |
| namespace | `reloader`, Pod Security `baseline` | |

## 4. What it can do (security)

Its ClusterRole is broad and cluster-wide, so treat the namespace as platform-only:

| Resource | Verbs |
|---|---|
| Secrets, ConfigMaps (all namespaces) | get, list, watch |
| Deployments, DaemonSets, StatefulSets (all namespaces) | get, list, update, patch |
| CronJobs | get, list; Jobs: create, delete, get, list (to re-run a CronJob) |
| Events | create, patch |

- **It acts only inside one namespace:** a change to a ConfigMap or Secret restarts workloads of **that same
  namespace**. A tenant cannot make it restart another tenant's or a platform workload (tested).
- **A tenant can use it for its own workloads:** tenant owners and developers (`edit`) may add the annotations to
  their Deployments; Reloader patches them with its own account, so Pod Security, the quota and the placement policy
  still apply to the new pods.
- The tenant network baseline does not affect it: it talks to the API server from the `reloader` namespace.

## 5. With Argo CD

A restart changes the pod template (an annotation), so Argo CD shows such a workload as OutOfSync until the next
sync. For a workload that Argo CD manages and that uses Reloader, add an ignore rule on the Application:

```yaml
ignoreDifferences:
  - group: apps
    kind: Deployment
    jqPathExpressions:
      - .spec.template.metadata.annotations."reloader.stakater.com/last-reloaded-from"
```

## 6. Who uses it (platform)

A survey of every platform workload for the Secrets it reads gave this list (most Secrets are created by External Secrets, so a refreshed value triggers the restart). A workload is annotated only when a changed Secret really needs a restart.

| Workload | Secret(s) | Annotation lives in | Decision |
|---|---|---|---|
| Grafana | `grafana-admin`, `grafana-oidc` | `grafana.annotations` (Deployment) | **on** |
| Headlamp | `headlamp-oidc` | `deploymentAnnotations` | **on** |
| Garage UI | `garage-admin-token`, `garage-ui-jwt`, `garage-ui-oidc` | `podAnnotations` (pod template) | **on** |
| Garage | `garage-admin-token`, `garage-rpc-secret` | `podAnnotations` (pod template) | **on** |
| Thanos compactor, store gateway | `thanos-objstore` | `compact.podAnnotations`, `storeGateway.podAnnotations` | **on** |
| Velero | `velero-s3` | `annotations` (Deployment) | **on** |
| Alertmanager | `alertmanager-smtp` | | **not needed**: the password is a mounted file that Alertmanager re-reads on every send (`getPassword()` in `notify/email`), and the kubelet updates mounted Secrets by itself |
| Prometheus (operator-managed StatefulSet) | `thanos-objstore` (env, sidecar) | | **off on purpose**: the operator owns the StatefulSet template and can revert what Reloader writes. After rotating `thanos-objstore`: `kubectl -n monitoring rollout restart statefulset prometheus-kube-prometheus-stack-prometheus` |
| Loki | none | | there is no object-store Secret: Loki uses a Longhorn volume |
| Capsule Proxy (`capsule-proxy` TLS) | created by its certgen Job | | out of scope; restart by hand after rotating the certificate |
| Argo CD (`argocd-redis`, TLS Secrets) | created by the Argo CD chart | | out of scope (installed by CI) |

Notes:
- The first sync after adding a **pod-template** annotation (Garage UI, Garage, Thanos) restarts that workload once;
  Deployment-level annotations (Grafana, Headlamp, Velero) do not.
- Each of these apps has an Argo CD `ignoreDifferences` rule for the one annotation Reloader writes
  (`reloader.stakater.com/last-reloaded-from`), so a Reloader restart does not show as OutOfSync.
- Rotating a Secret now means: update the Secret, nothing else. Check with
  `kubectl -n reloader logs deploy/reloader-reloader --tail=5`.
- Rotating `garage-rpc-secret` is not a normal operation (it changes how Garage nodes talk to each other); Reloader
  only performs the restart that such a change needs.

## 7. Install

1. `kubectl apply -f bootstrap/platform-project.yaml` (adds the stakater chart repo).
2. Push, let `platform-gitops` create the ApplicationSet, sync `reloader`.
3. `./tests/reloader.sh`. Auto-sync is on in `appsets/reloader.yaml`.

## 8. Check by hand

```bash
kubectl -n reloader get pods
kubectl -n reloader logs deploy/reloader-reloader --tail=20
kubectl -n <ns> get deploy <name> -o jsonpath='{.spec.template.metadata.annotations}'
```
