# Argo Rollouts

- Layer 1, Argo CD app `argo-rollouts`, namespace `argo-rollouts`. Step 8m in `fresh-install-order.md`.
- Chart `argo/argo-rollouts` 2.43.6 (Argo Rollouts v1.10.0), Gateway API plugin `rollouts-plugin-trafficrouter-gatewayapi` v0.17.0. Auto-sync (`prune: false`).
- Test: `tests/argo-rollouts.sh` (34 checks: canary through the Traefik Gateway, a failed analysis aborts, tenant guardrails).
- No Rollout exists until someone creates one.

## 1. What it adds

A `Rollout` replaces a `Deployment` and adds a delivery strategy:

| Strategy | What happens | Needs |
|---|---|---|
| **Canary** | the new version gets a share of the traffic in steps (`setWeight`, `pause`, `analysis`) and is promoted or rolled back | a traffic router for exact percentages (the Gateway plugin below); without one the share follows the replica counts |
| **Blue-green** | the new version runs next to the old one behind a preview Service, then the active Service is switched | two Services, no router |
| **Analysis** | an `AnalysisTemplate` queries Prometheus (here the Thanos Querier) or runs a Job and decides pass or fail; a fail aborts the update | the controller reaches the Querier (`thanos-query-ingress` allows `argo-rollouts`) |

| Part | Role |
|---|---|
| `argo-rollouts` controller (1 replica, leader election) | reconciles Rollouts, ReplicaSets, Services, HTTPRoutes and analysis runs |
| plugin `argoproj-labs/gatewayAPI` | changes the `weight` of an HTTPRoute's backend references (stable and canary Service) |
| CRDs `rollouts`, `analysistemplates`, `clusteranalysistemplates`, `analysisruns`, `experiments` | kept when the app is removed (`keepCRDs`) |

## 2. Decisions

| Setting | Value | Why |
|---|---|---|
| Plugin delivery | **init container** copying the binary from the plugin image (`ghcr.io/argoproj-labs/rollouts-plugin-trafficrouter-gatewayapi:v0.17.0`) | nothing is downloaded from GitHub when the controller starts; the version is pinned and pulled like any image |
| Traefik | works: Traefik 3.7 is a tested provider of the plugin (3.7.0, Gateway API 1.5.1) | the cluster runs 3.7.13 |
| `createClusterAggregateRoles` | **false** | the chart would aggregate rights on Rollout, AnalysisTemplate, AnalysisRun and Experiment into the built-in view, edit and admin roles; same trap as the External Secrets generators. Tenants get `rollouts` only from `tenant-baseline/argo-rollouts-rbac.yaml` |
| `providerRBAC` | Gateway API only | the other traffic routers (Istio, SMI, ALB, ...) are not installed |
| Dashboard, notifications | off | the dashboard has no login; alerts go through Alertmanager |
| Replicas | 1 | small cluster; a restart only delays a rollout step |
| Namespace Pod Security | `baseline` | like the other platform apps |

## 3. Tenants (Rollouts yes, traffic routing and analysis not yet)

| Tenant can | Tenant cannot | Why |
|---|---|---|
| create, update, delete `Rollout` in own namespaces (canary by replica weight, blue-green by Service switch); Argo CD may deploy the kind (`tenant-gitops/appprojects.yaml`) | `trafficRouting` in a Rollout | the plugin config names an HTTPRoute **and its namespace**, and the controller can update HTTPRoutes cluster wide: a tenant Rollout could rewrite a platform route such as Grafana's. Tenants publish with an Ingress and have no HTTPRoute anyway |
| viewers read Rollouts | `analysis`, `experiment` steps, `AnalysisTemplate`, `ClusterAnalysisTemplate`, `AnalysisRun`, `Experiment` | the `web` and `prometheus` providers make the controller call any URL, `job` runs arbitrary Jobs (the same reasoning as KEDA, `keda.md`) |

Enforced by `ValidatingAdmissionPolicy tenant-rollout-no-routing-or-analysis` (`tenant-baseline/argo-rollouts-policy.yaml`)
and by the RBAC file above. The pods of a Rollout are held to Pod Security `baseline`, the placement policy and the
network gate like a Deployment's.

To give tenants analysis later: a policy that allows only `prometheus` templates whose `address` is the tenant's own
`prom-label-proxy` (`tenant-observability.md`), a ClusterRole for the three analysis kinds, and tests for both.
KEDA can also scale a Rollout (`scaleTargetRef.kind: Rollout`).

## 4. Quick start: turn a Deployment into a Rollout (platform and tenants)

1. Change `apiVersion: apps/v1` / `kind: Deployment` to `apiVersion: argoproj.io/v1alpha1` / `kind: Rollout`, keep
   `replicas`, `selector` and the pod `template` as they are, and add a `strategy`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata: {name: my-app, namespace: my-ns}
spec:
  replicas: 3
  selector: {matchLabels: {app: my-app}}
  template:                       # the pod template of the old Deployment
    metadata: {labels: {app: my-app}}
    spec:
      containers: [{name: web, image: myimage:1.0}]
  strategy:
    canary:                       # no trafficRouting: the share follows the pod counts (allowed for tenants)
      steps:
        - setWeight: 25
        - pause: {duration: 2m}
        - setWeight: 50
        - pause: {}               # waits until promoted by hand
```

2. Delete the old Deployment (two controllers must not own the same pods), apply the Rollout.
3. Update by changing the image in Git (or `kubectl edit rollout my-app`): it moves through the steps.

Blue-green instead (no router needed, also allowed for tenants): two Services and
`strategy: {blueGreen: {activeService: my-app, previewService: my-app-preview, autoPromotionEnabled: false}}`; the new
version runs behind the preview Service until it is promoted, then the active Service switches.

### Watch and control a rollout

```
kubectl -n my-ns get rollout my-app -w            # phase: Progressing, Paused, Healthy, Degraded
kubectl -n my-ns describe rollout my-app          # current step, events, why it aborted
kubectl -n my-ns get rs -l app=my-app             # old and new ReplicaSet and their pod counts
```

| Action | Without the `kubectl argo rollouts` plugin (checked on a test Rollout) | With it |
|---|---|---|
| promote a paused step | `kubectl -n my-ns patch rollout my-app --subresource=status --type merge -p '{"status":{"pauseConditions":null}}'` | `kubectl argo rollouts promote my-app` |
| abort (back to the stable version, phase `Degraded`) | `kubectl -n my-ns patch rollout my-app --subresource=status --type merge -p '{"status":{"abort":true}}'` | `kubectl argo rollouts abort my-app` |
| go back to the previous version | change the image back in Git | `kubectl argo rollouts undo my-app` |
| restart the pods | `kubectl -n my-ns patch rollout my-app --type merge -p '{"spec":{"restartAt":"<now, RFC 3339>"}}'` | `kubectl argo rollouts restart my-app` |

Abort and promote live in `status`, so they need `--subresource=status`; a patch of `spec.abort` is silently ignored
(the field does not exist). A tenant developer can patch the status of their own Rollouts (the `edit` role).
After an abort, change the pod template again (or `kubectl argo rollouts retry`) to start a new attempt.

The plugin is one binary from the Argo Rollouts releases (not installed on the control planes). It is optional; it is
the easy way to promote and abort, and `kubectl argo rollouts get rollout my-app --watch` draws the steps.

## 5. Using it (platform): canary through the Traefik Gateway

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata: {name: my-app, namespace: my-ns}       # my-ns carries gateway-access=platform
spec:
  replicas: 3
  selector: {matchLabels: {app: my-app}}
  template: {...same as a Deployment pod template...}
  strategy:
    canary:
      stableService: my-app-stable
      canaryService: my-app-canary
      trafficRouting:
        plugins:
          argoproj-labs/gatewayAPI: {httpRoute: my-app, namespace: my-ns}
      steps:
        - setWeight: 20
        - pause: {duration: 2m}
        - analysis: {templates: [{templateName: error-rate}]}
        - setWeight: 60
        - pause: {duration: 2m}
```

The HTTPRoute `my-app` has the two Services as backends (stable 100, canary 0); the plugin moves the weights. Both
Services select the same label; Rollouts adds the pod-template hash to tell the versions apart. Watch it:
`kubectl -n my-ns get rollout my-app -w` (phase `Progressing`, `Paused`, `Healthy`, `Degraded`); abort with
`kubectl argo rollouts abort my-app` (the plugin for `kubectl`, optional) or by patching `spec.abort`.

An `AnalysisTemplate` against the Thanos Querier:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata: {name: error-rate, namespace: my-ns}
spec:
  metrics:
    - name: errors
      interval: 30s
      count: 4
      failureLimit: 1
      successCondition: "result[0] < 0.05"
      provider:
        prometheus:
          address: http://thanos-query.monitoring.svc.cluster.local:10902
          query: |
            sum(rate(traefik_service_requests_total{code=~"5..", service=~"my-ns-my-app.*"}[2m]))
            / sum(rate(traefik_service_requests_total{service=~"my-ns-my-app.*"}[2m]))
```

Argo CD manages Rollouts like Deployments (built-in health check). A workload that KEDA or an HPA scales needs
`replicas` left out of Git, as for a Deployment (`keda.md`).

## 6. Limits

- The plugin changes HTTPRoutes only: Ingress-based tenant apps cannot use traffic weights through Traefik (the Traefik
  Ingress provider has no weighted router in Rollouts); they use replica-weighted canary or blue-green.
- One controller replica: while it restarts, a paused Rollout stays paused.
- A Rollout whose HTTPRoute is changed by hand or by Argo CD sync fights the plugin: leave `spec.rules[].backendRefs[].weight`
  out of Git or add an `ignoreDifferences` on it.

## 7. Install

1. `kubectl apply -f bootstrap/platform-project.yaml` (adds `argoproj.github.io/argo-helm`; also needed by
   `tenant-baseline` only for the policies).
2. Push; `platform-gitops` creates the ApplicationSet; `argo-rollouts` syncs (auto). `tenant-baseline` carries the
   RBAC, the policy and the namespace's `refuse-tenant-ingress` (it retries until the namespace exists), and the
   `kube-prometheus-stack` app the `thanos-query-ingress` change.
3. `./tests/argo-rollouts.sh` (about 3 to 5 minutes).
4. Tenants: `tenant-gitops/appprojects.yaml` already lists `Rollout` (applied with the rest of the tenant GitOps setup).

## 8. Test: `tests/argo-rollouts.sh`

Controller ready, no restarts, CRDs, plugin configured and loaded, chart roles not aggregated; a canary Rollout behind
the Traefik Gateway moves the route to 50 / 50 and ends Healthy on the new version (checked through Traefik by
hostname); an update whose analysis fails (a Thanos query that returns 0) is aborted, the route returns to 100 / 0 and
the old version keeps answering; a tenant developer can create canary and blue-green Rollouts and is refused
traffic routing that names a platform HTTPRoute, analysis steps and blue-green analysis, the other tenant's namespace,
and the analysis kinds; viewers read; Prometheus holds the controller's metrics.
