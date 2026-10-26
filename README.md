# platform-gitops

Platform for the Kubernetes cluster `k8s-1.jodywan.com`: the apps the platform team runs (storage, observability,
backups, secrets, policies) and the multi-tenant setup (two tenants, `zeedlogic` and `jodywan`). Argo CD deploys the
apps from this repo. Login is Authentik (OIDC) everywhere.

## Documents

- Every document in this repository is listed, **in the order to read it**.
- New to the platform: read section 1 top to bottom.
- Building a cluster: section 2.
- Working on one app: find it in section 3.
- Working on tenants: section 4.
- Runbooks and reference: section 5.

### 1. Understand it (read these first, in order)

| # | Document | What you learn |
|---|---|---|
| 1 | [docs/how-layer0-works.md](docs/how-layer0-works.md) | How Argo CD is installed, how everything else is deployed, how the tenants app works (diagrams) |
| 2 | [docs/repo-layout.md](docs/repo-layout.md) | Where things go: `base/` versus `overlays/<cluster>/`, the template rule |
| 3 | [docs/cluster/cluster-overview.md](docs/cluster/cluster-overview.md) | The cluster itself: nodes, OIDC login, access and roles, lessons learned |
| 4 | [docs/cluster/argocd-gitops.md](docs/cluster/argocd-gitops.md) | The platform GitOps design: layers, repo layout, apps by area, open decisions |
| 5 | [docs/tenant-access-model.md](docs/tenant-access-model.md) | Who can do what: the four roles, kubectl and Argo CD, the network, the limits |

### 2. Build or rebuild the platform

| # | Document | What it covers |
|---|---|---|
| 6 | [docs/prerequisites.md](docs/prerequisites.md) | What to prepare by hand first: GitLab variables and tokens, Authentik, DNS, backup targets |
| 7 | [docs/fresh-install-order.md](docs/fresh-install-order.md) | The step-by-step order with the check for each step |
| 8 | [node-prep/node-prep.md](node-prep/node-prep.md) | Host setup Kubernetes cannot do: disks, etcd snapshots (step 3) |
| 9 | [layer0/argocd/argocd-install.md](layer0/argocd/argocd-install.md) | The Argo CD install: values, `deploy.sh`, from scratch (step 4) |
| 10 | [tests/tests-guide.md](tests/tests-guide.md) | The checks, one script per app or area: how to prove each step |

### 3. The platform apps, in install order

Read the app you are installing or changing; the order follows `docs/fresh-install-order.md`.

| # | Step | Document | What it is |
|---|---|---|---|
| 11 | 5b | [external-secrets](docs/external-secrets.md) | Secrets from GitLab CI/CD variables into the cluster |
| 12 | 6a | [headlamp](docs/headlamp.md) | The cluster web UI, with Authentik login |
| 13 | 6b | [storage-longhorn](docs/storage-longhorn.md) | Block storage |
| 14 | 6c | [storage-nfs](docs/storage-nfs.md) | Shared (ReadWriteMany) storage from TrueNAS |
| 15 | 6d | [storage-garage](docs/storage-garage.md) | S3 object storage |
| 16 | 6f | [garage-ui](docs/garage-ui.md) | The Garage web console |
| 17 | 8a | [loki](docs/loki.md) | Log store |
| 18 | 8b | [fluent-bit](docs/fluent-bit.md) | Log shipper |
| 19 | 8c | [kube-prometheus-stack](docs/kube-prometheus-stack.md) | Metrics, alerts, Prometheus and Alertmanager |
| 20 | 8c2 | [grafana](docs/grafana.md) | Dashboards (its own app) |
| 21 | 8d | [thanos](docs/thanos.md) | Long-term metrics in Garage |
| 22 | 8e | [jaeger](docs/jaeger.md) | Distributed tracing |
| 23 | 8f | [lan-access-metallb](docs/lan-access-metallb.md) | Giving an app a LAN address (MetalLB) |
| 24 | 8h | [backup-target](docs/backup-target.md) | The S3 backup endpoint outside the cluster (Garage on docker-2) |
| 25 | 8h | [velero](docs/velero.md) | Backups of the cluster objects |
| 26 | 8h | [etcd-backup](docs/etcd-backup.md) | Scheduled etcd snapshots |
| 27 | 8i | [alerting](docs/alerting.md) | Alert rules and the mail receiver |
| 28 | 8i | [control-plane-metrics](docs/control-plane-metrics.md) | Scheduler, controller-manager and etcd metrics |
| 29 | 8j | [blackbox-exporter](docs/blackbox-exporter.md) | Probes and certificate expiry |
| 30 | 8k | [gatekeeper](docs/gatekeeper.md) | Admission policy on top of Capsule |
| 31 | 8l | [trivy-operator](docs/trivy-operator.md) | Continuous security scanning |
| 32 | 8m | [argo-rollouts](docs/argo-rollouts.md) | Canary and blue-green releases |
| 33 | 8n | [keda](docs/keda.md) | Event-driven autoscaling |
| 34 | 8p | [reloader](docs/reloader.md) | Rolling restart when a ConfigMap or Secret changes |
| 35 | 8q | [renovate](docs/renovate.md) | Merge requests for new chart and image versions |
| 36 | 8r | [cloudnative-pg](docs/cloudnative-pg.md) | PostgreSQL operator (databases as Kubernetes resources) |
| 37 | 8s | [databases](docs/databases.md) | PostgreSQL databases for tenants, in a platform namespace |
| 38 | 8t | [tenant-storage](docs/tenant-storage.md) | A tenant's buckets in the platform's Garage, with the network path |

### 4. Tenants (teams)

| # | Document | What it covers |
|---|---|---|
| 36 | [docs/cluster/capsule-argocd-integration.md](docs/cluster/capsule-argocd-integration.md) | Why the tenant design is what it is: Capsule, Argo CD RBAC, Option A or B, Capsule Proxy |
| 37 | [docs/tenant-network.md](docs/tenant-network.md) | Network isolation (step 7a) |
| 38 | [docs/tenant-guardrails.md](docs/tenant-guardrails.md) | What a tenant may create (step 7a) |
| 39 | [docs/tenant-observability.md](docs/tenant-observability.md) | Metrics and logs per tenant (step 9) |
| 39a | [docs/zeedlogic-observability.md](docs/zeedlogic-observability.md) | ZeedLogic metrics, logs, traces and dashboards for the tenant environments |
| 40 | [docs/tenant-gitops.md](docs/tenant-gitops.md) | Argo CD for tenants: deployer accounts, registration (step 10) |
| 41 | [layer0/oidc/TENANT-KUBECONFIG.md](layer0/oidc/TENANT-KUBECONFIG.md) | For tenant users: `kubectl` through Capsule Proxy |
| 42 | [docs/tenant-guide-secrets-and-rollouts.md](docs/tenant-guide-secrets-and-rollouts.md) | For tenant users: Secrets and Rollouts |
| 43 | [docs/examples/tenant-sample-app/](docs/examples/tenant-sample-app/README.md) | A sample tenant app for the first Argo CD test |

### 5. Reference and runbooks (when you need them)

| # | Document | When |
|---|---|---|
| 44 | [docs/rotate-argocd-gitlab-token.md](docs/rotate-argocd-gitlab-token.md) | Rotating the GitLab token that Argo CD uses |
| 45 | [layer0/oidc/MACBOOK-OIDC-LOGIN.md](layer0/oidc/MACBOOK-OIDC-LOGIN.md) | Setting up `kubectl` contexts on a MacBook |
| 46 | [layer0/oidc/TEST-RESULTS.md](layer0/oidc/TEST-RESULTS.md) | The result of the permission tests |
| 47 | [docs/resource-sizing.md](docs/resource-sizing.md) | Requests and limits of the platform apps: what was measured and changed |

## Layout

| Folder | What | Who applies it |
|---|---|---|
| `layer0/` | Argo CD (install, SSO) and OIDC (API server flags, break-glass binding, tests) | GitLab CI job for Argo CD; a person for OIDC |
| `bootstrap/` | the platform AppProject, the OCI chart repository and the root application | the CI job (a person by hand) |
| `appsets/` | one ApplicationSet per app (29) | Argo CD |
| `base/<app>/` | the minimum values of each app, true on any cluster | Argo CD |
| `overlays/k8s-1/` | everything specific to this cluster (hostnames, addresses, sizes, retention, providers, the Tenants, the MetalLB pool) | Argo CD |
| `gateway-api-crds/` | the vendored Gateway API CRDs | Argo CD |
| `tenant-baseline/`, `tenant-observability/`, `external-secrets/`, `gatekeeper-policies/`, `dashboards/`, `grafana/` | plain manifests that the apps need | Argo CD |
| `tenant-gitops/` | deployer accounts and the tenant AppProjects | a person (`register-deployers.sh`) |
| `node-prep/` | host setup that Kubernetes cannot do (disks, etcd snapshots) | a person, once per node |
| `tests/` | pass checks, one script per app or area | a person, after a change |
| `docs/` | one document per app, plus `docs/cluster/` for the cluster-wide ones | |

## Rules

- **`base/` is the minimum; cluster data goes in `overlays/`.** `./tests/overlay-split.sh` enforces it.
- **No secrets in Git.** Values live in GitLab variables and reach the cluster through External Secrets.
- **Argo CD auto-syncs every app, with `prune: false` and no self-heal.** A merged change is applied by itself, a removed file
  never deletes anything, and a manual `kubectl` fix is not reverted. Only on a fresh cluster is the first sync of each app done
  by hand, in the install order (Argo CD has no depends-on).
- **Changes that grant rights are run by a person**, never by Argo CD.
