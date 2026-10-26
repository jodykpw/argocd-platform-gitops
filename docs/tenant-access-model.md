# Tenant access model: who can do what

- One page that answers "can role X do Y, and through which tool".
- Written from what is built and tested on k8s-1. Details and procedures are in the documents linked in section 9.
- Status: the kubectl/helm path, Capsule, the network baseline and the owners-only RBAC rule are **live and tested**.
- The Argo CD path for tenants (`tenant-gitops/`) is **live and tested** (`tests/tenant-gitops.sh`, 53 checks).
- Per-tenant Grafana access to metrics and logs is **live and tested** (`tenant-observability.md`); traces and OTLP for tenants are deferred until used.

## 1. The four roles

| Role | Who | Authentik group | Kubernetes identity (API server prefix `oidc:`) |
|---|---|---|---|
| **Cluster admin** | the platform team (adminjody) | `cluster-admin` | `oidc:cluster-admin`, bound to `cluster-admin`; ignored by Capsule |
| **Tenant owner** | the team lead of a tenant | `<tenant>-owners` | Capsule owner: `admin` + `capsule-namespace-deleter` in the tenant's namespaces |
| **Developer** | a team engineer | `<tenant>-developers` | `edit` in all three namespaces (dev, stg and prod, decided) |
| **Viewer** | QA, support | `<tenant>-viewers` | `view` only |

Tenants are `zeedlogic` and `jodywan`. Each has three namespaces: `<tenant>-dev`, `<tenant>-stg`, `<tenant>-prod`.
A user of one tenant has no rights in the other tenant or in any platform namespace.

**Words used in the tables below**

| Term | Meaning |
|---|---|
| "own namespaces" | the three namespaces of the user's own tenant: `<tenant>-dev`, `<tenant>-stg`, `<tenant>-prod` (for `zeedlogic`: `zeedlogic-dev`, `zeedlogic-stg`, `zeedlogic-prod`) |
| "own projects" (Argo CD) | the two Argo CD projects of the user's own tenant: `<tenant>-nonprod` (dev and stg) and `<tenant>-prod` |
| "all" (cluster admin) | every namespace or project in the cluster, platform and both tenants |

## 2. Two ways to deploy

| | **kubectl / helm** (live) | **Argo CD** (live) |
|---|---|---|
| Identity doing the change | the person, as themselves | the tenant's own deployer account `argocd-deployer-<tenant>` (role `edit`, owner of that tenant only) |
| Entry point | Capsule Proxy `https://10.1.5.171:9001`, login through Authentik (OIDC) | the Argo CD UI or CLI, login through Authentik |
| Who decides if a deploy is allowed | Kubernetes RBAC (the table in section 3) | the AppProject roles (table in section 4), then the deployer account's rights |
| Where the manifests live | wherever the user runs them from | Git repos in the tenant's own GitLab group |
| Roles and RoleBindings | **owners only** | **never**, not through Argo CD |
| Cluster-scoped objects (CRDs, ClusterRoles, Namespaces ...) | refused for tenants | refused (`clusterResourceWhitelist` empty) |
| Audit trail | Kubernetes audit log | Git history and Argo CD |
| Drift (a live edit that differs from Git) | invisible | shown as OutOfSync, optionally self-healed |
| Needs platform setup per tenant | no | yes (`tenant-gitops/register-deployers.sh`, AppProjects, a GitLab group) |

Both can be used together: for example `kubectl` for quick tests in dev and Argo CD for stg and prod. If Argo CD has
self-heal on, it reverts hand edits to the objects it manages.

## 3. kubectl and helm: what each role can do

`yes` / `no` below was verified with impersonation in `layer0/oidc/test-permissions.sh` (78 checks) and
`tests/tenant-rbac.sh` (66 checks). "Own namespaces" are defined in section 1.

| Action | Cluster admin | Tenant owner | Developer | Viewer |
|---|---|---|---|---|
| See namespaces (`kubectl get ns` through the proxy) | all (about 20) | only own namespaces (3) | only own namespaces (3) | only own namespaces (3) |
| Read pods, services, logs (dev, stg, prod) | yes | yes | yes | yes (no secrets) |
| Read Secrets | yes | yes, in all own namespaces | yes, in all own namespaces | **no** |
| Create or change workloads (Deployments, Services, ConfigMaps ...) in dev, stg **and prod** | yes | yes | yes | no |
| `kubectl exec` | yes | yes | yes, in all own namespaces | no |
| Create or edit **Roles and RoleBindings** | yes | **yes, in all own namespaces** | **no** | no |
| Create namespaces, change quotas, owners or the network baseline (the tenant itself) | yes | namespaces only (up to 3, prefix `<tenant>-`); the rest is managed by Capsule and the platform team | no | no |
| Hand a developer extra rights (create a Role and a RoleBinding) | yes | yes, up to what the owner holds | no | no |
| Bind `cluster-admin` or any role the user does not hold | yes | **refused** | refused | refused |
| Create namespaces | yes | yes, up to 3 per tenant (quota), name must start with `<tenant>-` | no | no |
| Delete a namespace of their own tenant | yes | yes | no | no |
| ClusterRoles, ClusterRoleBindings, CRDs, Nodes, other cluster-scoped objects | yes | **no** | no | no |
| Anything in the other tenant | yes | no | no | no |
| Anything in platform namespaces (argocd, monitoring, capsule-system ...) | yes | no | no | no |
| ServiceMonitor, PrometheusRule | yes | **no** | no | no |
| Mint a token for a ServiceAccount in an own namespace | yes | yes | yes (known risk of `edit`: keep privileged ServiceAccounts out of the tenant namespaces) | no |

**What developers cannot do.** `edit` is "everything in the namespace except RBAC". A developer deploys, changes,
execs and reads Secrets in all three namespaces like an owner, but cannot create or edit Roles and RoleBindings, cannot
create namespaces or delete them, and cannot change the tenant (quotas, owners, the network baseline). Those belong to
the owner (RBAC, namespaces) and to Capsule and the platform team (the tenant itself).

**Delegation (extra rights).** Because developers already deploy everywhere, owners rarely need to hand out more. When
they do (for example to let a ServiceAccount or another group do something specific), the owner creates a Role and a
RoleBinding in the namespace; an owner cannot grant more than an owner holds (`cluster-admin` is refused).

### Helm specifics

| Situation | Result |
|---|---|
| `helm install` of a namespaced chart as a developer, in dev, stg or prod | works |
| A chart that creates a Role or RoleBinding, as a developer | refused; as an owner it works |
| A chart with CRDs, ClusterRoles, Namespaces or webhooks | refused for every tenant role (use `crds.install=false` or ask the platform team) |
| `--create-namespace` | does not work; owners create namespaces with `kubectl create ns` through the proxy |
| Pods without `limits.cpu` | refused by the tenant ResourceQuota |

## 4. Argo CD: what each role can do

Two Argo CD projects per tenant: `<tenant>-nonprod` (dev and stg) and `<tenant>-prod` (prod only). Applications are
self-service: tenants create their own inside their project. Repositories and access tokens are **project-scoped**.

| Action | Cluster admin (Argo CD admin) | Tenant owner | Developer | Viewer |
|---|---|---|---|---|
| See applications | all projects | applications of own projects | applications of own projects | applications of own projects |
| **nonprod**: create, edit, delete applications | yes | yes | yes | no |
| **nonprod**: sync, rollback, restart | yes | yes | yes | no |
| **prod**: create, edit, delete, sync applications | yes | yes | **yes** | no (view) |
| Add repositories and access tokens (project-scoped) | yes | nonprod and prod | nonprod and prod | no (list only) |
| Read logs | yes | yes | yes (nonprod and prod) | nonprod; prod only for `jodywan` |
| Exec into pods | yes | yes | yes, nonprod and prod | no |
| Edit projects, roles, clusters, accounts, settings | yes | **no** | no | no |
| See or use another tenant's repositories, tokens or applications | yes | **no** | no | no |
| Deploy Role or RoleBinding | yes | **no** (use kubectl) | no | no |
| Deploy ClusterRole, CRDs, Namespaces, NetworkPolicy, Ingress | yes | no | no | no |

What an application may contain (allowlist): Deployment, StatefulSet, Job, CronJob, HorizontalPodAutoscaler,
PodDisruptionBudget, Service, ConfigMap, Secret, ServiceAccount, PersistentVolumeClaim, Ingress (class traefik).

**Two safety nets.** Each tenant's applications are applied as that tenant's deployer account, which is an owner of
that tenant only, so an AppProject mistake still cannot reach another tenant. And that account is `edit`, so Argo CD
cannot create RBAC objects even if the allowlist were wrong.

**Where tenants keep code.** Each tenant has its own GitLab group and may create as many repositories and access
tokens as it wants there (a top-level group per tenant, `https://gitlab.jodywan.com/<tenant>/`, with subgroups below it). Put
the groups **outside** `servers/pcls.jodywan.com/` (the platform's credential template matches that prefix). Tokens
expire (GitLab maximum one year): the tenant rotates them.

## 5. Platform services

| Service | Cluster admin | Tenant users |
|---|---|---|
| Argo CD UI | admin | own projects only (`<tenant>-nonprod`, `<tenant>-prod`), once enabled |
| Grafana (`grafana-k8s.jodywan.com`) | admin (group `cluster-admin`), every organization | own tenant's organization only, as Editor (Explore, dashboards; never data source admin): metrics and logs of their own namespaces. Built and tested, see `tenant-observability.md`. Traces not offered |
| Garage UI | yes (SSO) | no: only Authentik group `cluster-admin` may open it |
| Headlamp | yes (SSO) | not set up for tenants (it would show only what their own Kubernetes rights allow, through the API server, not through the Capsule Proxy) |
| Prometheus, Alertmanager, Loki, Thanos, Jaeger | yes | **no**: refused at network level, not exposed |
| Kubernetes API | direct | only through the Capsule Proxy, filtered to their namespaces |
| Capsule Proxy | yes | yes, this is their `kubectl` and `helm` endpoint |
| Object storage (the platform's Garage S3, `tenant-storage.md`) | creates the buckets, keys and network rules | **use only** their own buckets with their own key, over the S3 port; no other tenant and no other Garage port is reachable |
| Databases (CloudNativePG, namespace `databases`) | creates and runs the `Cluster` resources | **connect only**, to their own database from their own namespace (`jodywan-dev` reaches `jodywan-dev-pg`); they cannot create `Cluster` resources or reach any other database. `databases.md` |

## 6. Network (applies to every pod of every role)

| | |
|---|---|
| A tenant pod can reach | DNS, internet addresses (not private ranges), pods of its own namespace, and its own database in `databases` where the platform has allowed it (5432) |
| A tenant pod cannot reach | other environments of its own tenant, the other tenant, any platform service, the Kubernetes API, the LAN, TrueNAS. Node ports are refused only while an owner has not opened egress with a NetworkPolicy of their own (see the known gaps below) |
| Reaches a tenant pod | pods of its own namespace, Traefik, Prometheus |
| Who can change the baseline | the platform team only (Capsule `replications` webhook refuses tenant owners) |

An owner may add NetworkPolicies of their own, but the Calico policy `tenant-egress-guard` still denies the nodes, the
LAN and node ports (kubelet, node-exporter, etcd metrics, scheduler) in front of them. Accepted:
Argo CD server is reachable by design (SSO). Details: `tenant-network.md`.

## 7. Limits and conventions

| | `zeedlogic` | `jodywan` |
|---|---|---|
| Namespaces | 3 (`zeedlogic-dev`, `-stg`, `-prod`) | 3 |
| Quota for the whole tenant | 16 CPU limits, 32 Gi memory limits, 100 pods | 8 CPU limits, 16 Gi, 50 pods |
| Ingress classes | `traefik` only | `traefik` only |
| Argo CD prod logs for viewers | no | yes |

Tenants publish applications with an **Ingress** of class `traefik` (HTTPRoute is not usable by tenants: no RBAC, and the
Gateway accepts platform namespaces only). Any hostname is allowed except the platform's own
(`grafana-k8s`, `argocd`, `headlamp`, `garage-k8s` at jodywan.com), host-less rules and a
defaultBackend. DNS, the HAProxy rule and the certificate for a tenant hostname are set up outside the cluster.
Every pod must set `limits.cpu` (and memory), or the quota refuses it. Tenant namespaces enforce Pod Security `baseline`
(no privileged pods, hostPath, hostNetwork, hostPID, extra capabilities) and refuse Services of type LoadBalancer,
NodePort and ExternalName: see `tenant-guardrails.md`.

## 8. Proof: which test covers which rows

| Test | Covers |
|---|---|
| `layer0/oidc/test-permissions.sh` (78) | section 3 for owners, developers, viewers, across namespaces and tenants, the proxy namespace lists |
| `tests/tenant-rbac.sh` (66) | Roles and RoleBindings owner-only, no escalation, developers deploy in all three namespaces |
| `tests/tenant-network.sh` (39, 4 known gaps) | section 6 |
| `tests/tenant-gitops.sh` | section 4: deployer accounts, AppProjects tenant-bound, impersonation setting, with `E2E=1` a real sync and a refused cross-tenant sync |
| `tests/kube-prometheus-stack.sh` | tenants cannot create ServiceMonitors or PrometheusRules |

## 9. Related documents

`capsule-argocd-integration.md` (design and rationale), `tenant-network.md`, `tenant-gitops.md` (Argo CD decisions
and the registration procedure), `argocd-gitops.md` (platform GitOps), `layer0/oidc/TENANT-KUBECONFIG.md`
(how a tenant sets up `kubectl`), `layer0/oidc/TEST-RESULTS.md`.
