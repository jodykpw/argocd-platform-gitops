# Platform GitOps for k8s-1 (Argo CD)

- Status: **in use.** Argo CD runs every platform app from this repo: one ApplicationSet per app in `appsets/` (29), all auto-sync with `prune: false` and no self-heal, all Synced and Healthy.
- Only Argo CD itself is installed from outside (GitLab CI); MetalLB, Traefik, Capsule, Capsule Proxy and the Tenants are ordinary apps.
- Gate: met (network isolation, RBAC, guardrails, per-tenant metrics and logs, tenant GitOps). No real tenant users are onboarded yet.
- How layer 0, the CI job and the tenants app work, with diagrams: `../how-layer0-works.md`. The order for a fresh cluster: `../fresh-install-order.md`. Per-app plans, tests and dependencies: one document per app in `docs/`.
- This document covers the **platform side**: the layers, the repo layout, the apps by area and the decisions. The tenant side is `capsule-argocd-integration.md` (design) and `../tenant-gitops.md` (Argo CD for tenants).

## 1. Working approach

- **Build for k8s-1 first, split as you go.** One cluster, one repo. `base/` holds the generic part and `overlays/k8s-1/`
  what is specific to this cluster, so the repo can become a template later (`../repo-layout.md`).
- **Rehearse, then fork.** Rebuild on a test cluster, fix the gaps, then fork the repo for the next server.
- **Keep notes as we go.** Every manual step that is not in this document is a gap to fix here.
- **Changes go through Git.** Files are written and tested locally, the user pushes, Argo CD syncs. Anything that grants
  permissions or touches layer 0 is run by a person.

Repo: `https://gitlab.jodywan.com/servers/pcls.jodywan.com/k8s-1.jodywan.com/platform-gitops` (branch `main`, no `dev` branch). Local clone: `~/kubernetes/platform-gitops`. Argo CD reads it with the credential template `gitlab-group-creds` (rotation: `platform-gitops/docs/rotate-argocd-gitlab-token.md`).

## 2. Two layers

Argo CD reaches its UI through Traefik, and Traefik gets its address from MetalLB, so one bad sync of those could cut the
route to the tool needed to fix it. That is covered by break-glass access (the installer kubeconfig and
`kubectl -n argocd port-forward svc/argocd-server 8080:80`), a revert in Git, and `prune: false` everywhere, not by keeping
them outside Argo CD.

| Layer | Components | Applied by |
|---|---|---|
| **0** | Argo CD, the `oidc-cluster-admin` binding, the API server OIDC flags | Argo CD by GitLab CI (`layer0/argocd/`); the binding by a person; the flags by kubespray |
| **1** | everything in `appsets/`: Gateway API CRDs, MetalLB, Traefik, Capsule, Capsule Proxy, Tenants, storage (NFS, Longhorn, Garage), Grafana, Loki, Fluent Bit, kube-prometheus-stack, Thanos, blackbox-exporter, Jaeger, External Secrets, Velero, Gatekeeper, Trivy Operator, Argo Rollouts, KEDA, Reloader, Headlamp, Garage UI | Argo CD (ApplicationSets from the repo) |
| CI | Renovate | GitLab CI against the repo, not in the cluster |
| Out of scope | tenant workloads | tenant repos and AppProjects |

Test for layer 0: Argo CD cannot run without it, or it must never be prunable. Otherwise layer 1.
Capsule is layer 1 but deserves care: its webhooks are `failurePolicy: Fail` and several are cluster-wide, so a broken
Capsule blocks namespace operations everywhere; sync it alone. Capsule Proxy matches Capsule (proxy 0.15.1 with
Capsule 0.14.6). Layer 0 used to be larger; see Git history.

## 3. Repo layout

The rule for `base/` and `overlays/` is in `../repo-layout.md`.

```
platform-gitops/
├── appsets/                  # one ApplicationSet per app, same in every cluster (29 files)
├── base/<app>/values.yaml    # GENERIC: true on any cluster
├── overlays/k8s-1/           # SPECIFIC to this cluster: <app>/values.yaml, metallb-config/, tenants/
├── gateway-api-crds/         # vendored Gateway API CRDs (plain manifests)
├── layer0/                   # argocd/ (install, deploy.sh) and oidc/ (flags, break-glass binding, tests)
├── bootstrap/                # platform AppProject, OCI chart repo, top-level app: applied by the CI job
├── tenant-baseline/          # plain manifests: network gate, guardrail policies, RBAC   (cluster specific, to move)
├── tenant-gitops/            # tenant deployers and AppProjects, applied by a person      (cluster specific, to move)
├── tenant-observability/     # per-tenant Grafana orgs, label proxy, dashboards           (cluster specific, to move)
├── external-secrets/         # ClusterSecretStore and the platform ExternalSecrets        (cluster specific, to move)
├── gatekeeper-policies/      # Gatekeeper templates and constraints (third source of the gatekeeper app)
├── grafana/, dashboards/     # dashboard ConfigMaps (kustomize sources of the grafana and stack apps)
├── node-prep/                # host setup Kubernetes cannot do (disks, kernel modules), once per node
├── tests/                    # pass checks, run by hand; tests/overlay-split.sh guards base/
├── renovate.json
└── docs/                     # per-app plans; docs/cluster/ holds the cluster documents
```

- **One ApplicationSet per app.** Components differ a lot, and a mistake in one cannot affect the others. Each generates one
  Application per cluster and has two sources for Helm apps: the pinned chart and the values from the repo (`$values`).
- **A second cluster** is a new `overlays/<cluster>/` folder and one entry in each ApplicationSet's list.
- **No `dev/prod` level.** The platform is one cluster; dev, stg and prod are tenant namespaces in the tenant repos.
- **Ordering:** ApplicationSets do not order Applications; sync by hand in the order of `../fresh-install-order.md`, and use
  sync waves inside one app (the `tenants` app does). `SkipDryRunOnMissingResource=true` where CRDs come from another app.
- **Default sync:** manual first, then `prune: false` auto-sync after the app has proven itself.

## 4. Bootstrap order (new cluster)

`../fresh-install-order.md` is the living version (dependencies, checks, what is always manual). In short: cluster with the
OIDC flags (kubespray) → `oidc-cluster-admin` and OIDC login → node prep → GitLab CI `deploy-argocd` (CRDs, label, Argo CD,
`bootstrap/`) → sync by hand: Gateway API CRDs, MetalLB, Traefik, Capsule, Capsule Proxy, Tenants → storage → observability →
the rest → `layer0/oidc/test-permissions.sh`.

## 5. OIDC and access

| Piece | Lives in | Layer |
|---|---|---|
| kube-apiserver OIDC flags | kubespray inventory | out of scope (Ansible) |
| `oidc-cluster-admin` binding | cluster | **0**: break-glass, must never be prunable |
| Authentik providers and applications | Authentik | not in the repo; document redirect URIs, claims, groups |
| Argo CD Dex connector and role policy | `layer0/argocd/values.yaml` | 0 |
| Capsule `CapsuleConfiguration` (user groups, ignored group) | `overlays/k8s-1/capsule/values.yaml` | 1 |
| Capsule Proxy OIDC settings | `overlays/k8s-1/capsule-proxy/values.yaml` | 1 |
| Tenant owners, developers, viewers | Tenant objects (`overlays/k8s-1/tenants/`) | 1: changes most |
| Grafana login | `overlays/k8s-1/grafana/values.yaml` | 1 |
| `test-permissions.sh`, `tenant-contexts.sh`, the Mac login guide | `layer0/oidc/` | tooling, not deployed |

- Anything that gives cluster-admin through OIDC is layer 0 or the cluster build. Tenant and Grafana roles are layer 1.
- Group names differ: Kubernetes sees `oidc:<group>`, Argo CD and Grafana see the raw name.
- Authentik client secrets stay out of Git (section 8).

## 6. Layer 0 pipeline (GitLab CI)

Running; design, variables, decisions and the upgrade procedure are in `../how-layer0-works.md`, section 3. Deviation from the original advice here (use the GitLab Agent, avoid a kubeconfig in a variable): the Agent is itself a component that needs a cluster, so the job runs on an instance runner outside the cluster with a Protected kubeconfig variable (a dedicated cluster-admin ServiceAccount). Mitigations: protected branch, Protected variables, a manual job, nothing deploys from a merge request. Revisit the Agent when more than one cluster is managed.

## 7. Platform apps (layer 1)

All managed by Argo CD; the details, tests and dependencies of each are in its own document. The order is `../fresh-install-order.md`.

| Area | App | The decision in one line | Document |
|---|---|---|---|
| Storage | Longhorn | block storage, V1 engine, workers only, 2 replicas, `Retain`, a dedicated disk per worker | `../storage-longhorn.md` |
| | NFS provisioner | shared (RWX) volumes from TrueNAS; not for databases | `../storage-nfs.md` |
| | Garage | S3 in the cluster, single node on Longhorn (MinIO and SeaweedFS rejected) | `../storage-garage.md` |
| | Garage UI | web console for Garage, Authentik login | `../garage-ui.md` |
| Logs | Loki + Fluent Bit | single binary on Longhorn, 7 days, one Loki tenant per Capsule tenant; Loki has no authentication of its own, so NetworkPolicies are the control | `../loki.md`, `../fluent-bit.md` |
| Metrics | kube-prometheus-stack + Thanos | Prometheus keeps 12 h, Thanos 7 days raw in Garage; Grafana reads through the Thanos Querier | `../kube-prometheus-stack.md`, `../thanos.md` |
| | blackbox-exporter | outside-in probes of the public URLs, dependencies and TCP ports, with certificate expiry | `../blackbox-exporter.md` |
| | Alerting | Alertmanager mails warning and critical alerts; platform rules in `platform-alerts` | `../alerting.md`, `../control-plane-metrics.md` |
| Traces | Jaeger | Jaeger v2 all-in-one on Badger, 3 days, pinned below 2.21; read through Grafana only | `../jaeger.md` |
| Dashboards | Grafana | its own app, Authentik login, one organization per tenant | `../grafana.md` |
| Security | Gatekeeper | image tags and registries for tenants; the webhook fails closed | `../gatekeeper.md` |
| | Trivy Operator | detects vulnerabilities and misconfigurations; blocks nothing | `../trivy-operator.md` |
| | External Secrets | secrets from GitLab CI/CD variables; Git holds only references | `../external-secrets.md` |
| Backup | Velero | Kubernetes objects to the backup Garage on docker-2; Longhorn backs up the volumes to TrueNAS; etcd snapshots to the same Garage | `../velero.md`, `../storage-longhorn.md`, `../etcd-backup.md`, `../backup-target.md` |
| Delivery | Argo Rollouts, KEDA, Reloader, Renovate | canary and blue-green, event-driven scaling, restart on config change, version-bump merge requests | `../argo-rollouts.md`, `../keda.md`, `../reloader.md`, `../renovate.md` |
| UI | Headlamp | cluster web UI, each user acts with their own token | `../headlamp.md` |

**Why these are layer 1:** none of them can lock you out of Argo CD. The risk is data loss, handled by the safeguards: `prune: false`, no cascade-delete finalizer, `reclaimPolicy: Retain`, one minor version at a time for Longhorn, and `ignoreDifferences` for fields the API server fills in.

**Not chosen:** Rook-Ceph (needs raw disks on 3+ nodes and 4+ CPUs and several GB of RAM per node; hard to run on 3 nodes; about 100 GB usable either way).

**Team separation** (decided where it applies): Loki is multi-tenant by header and Fluent Bit sets the tenant from the Capsule label; Grafana has one organization per tenant with read-only data sources fixed to the tenant (`../tenant-observability.md`); Jaeger has no tenancy, so tenants get no traces yet (one Jaeger per tenant, or Tempo, when needed).

**Other candidates (not decided):** cert-manager (routes use the HTTP `web` listener today; TLS ends at HAProxy), an image registry or pull-through cache (GitLab's registry may be enough).

## 8. Access and secrets

**`platform` AppProject** (`bootstrap/platform-project.yaml`)

- Allows cluster-scoped resources and all namespaces; only `cluster-admin` and `ArgoCD Admins` can use it.
- `sourceRepos` = the platform-gitops repo URL plus the Helm repos used.
- The repo must **not** be readable by tenants: `gitlab-group-creds` is a `repo-creds` Secret that covers a GitLab group. Check who can read that group.

**Secrets**

- External Secrets reads GitLab CI/CD variables (`../external-secrets.md`). The roots of trust stay by hand: `external-secrets/gitlab-token`, `argocd/gitlab-group-creds`, `garage-rpc-secret`.
- Keep these out of Git: Authentik client secrets (`layer0/argocd/patch-secret.yaml`, or the CI variable), any `*.key`, `backup-*.yaml`.
- Argo CD's GitLab token (`gitlab-group-creds`): rotation runbook in `../rotate-argocd-gitlab-token.md`.

**Rules for the existing releases**

- Never prune Tenants or Capsule CRDs: deleting a Tenant deletes its namespaces (the Tenants carry `Delete=false`).
- Do not `helm upgrade` an adopted component; do not `helm uninstall` its old release record (it would delete the objects).

## 9. Rehearsal on a test cluster

Run the bootstrap from nothing on a throwaway cluster (1 control plane, 2 workers; `bpg-proxmox-module-cicd` and kubespray) so that k8s-1 keeps running. A rebuild of k8s-1 itself is a planned outage for the tenants.

| # | Step | Pass if |
|---|---|---|
| 0 | Authentik reachable, OIDC flags in the test inventory, secrets in place | the issuer URL answers from a control plane |
| 1 | Create the cluster with kubespray | all nodes Ready (certificate kubeconfig) |
| 2 | `oidc-cluster-admin` binding, `kubectl oidc-login` | `kubectl auth whoami` shows the OIDC user; `get nodes` works |
| 3 | Node prep, then GitLab CI `deploy-argocd` | Argo CD pods Ready; SSO login; `admin.enabled` is `false` |
| 4 | Sync: Gateway API CRDs, MetalLB (+ pool), Traefik | a test `LoadBalancer` gets an address; `traefik-gateway` Programmed |
| 5 | Sync: Capsule, then Capsule Proxy | pods Running, 0 restarts; `get tenants` works; the proxy has its address |
| 6 | Sync: `tenants` | Tenants, 3 namespaces per tenant, RoleBindings; no `OutOfSync` |
| 6a | Storage: NFS, Longhorn, Garage | RWX and RWO PVCs bind and a pod writes; S3 put and get work; Longhorn survives a worker reboot |
| 7 | `layer0/oidc/test-permissions.sh` | all 78 checks pass |
| 8 | Observability: Loki, Fluent Bit, kube-prometheus-stack, Grafana, Thanos | `tests/loki.sh`, `fluent-bit.sh`, `kube-prometheus-stack.sh`, `thanos.sh` pass; Grafana login works |
| 9 | Time the run, list the manual steps found | the documents and scripts match what you did |

Then break something on purpose: sync a bad value for a layer 1 app, confirm you can still reach the cluster as the break-glass admin, and revert in Git.

## 10. Template and fork (later)

Not now. Once k8s-1 and the test cluster work:

- **Template repo** (`servers/templates/platform-gitops`): `appsets/`, `base/`, example `layer0/` files, and one fixed `cluster/` folder in place of `overlays/<cluster>/`.
- **Fork per server** (for example `servers/pve.jodywan.com/<cluster>/platform-gitops`): edit only `cluster/` and `layer0/`, so template updates merge cleanly.
- **ApplicationSets** read the fork's repo URL and cluster name from `cluster/cluster.yaml` (a Git file generator), so `appsets/` is identical in every fork.
- **Updates:** `git merge upstream/main`, ideally from tagged releases. Alternative: multi-source Applications pinned to a template tag (no merge step).
- **Status:** the Helm values are split (`../repo-layout.md`, `tests/overlay-split.sh`). Still to do: the repo URL in every ApplicationSet, and the plain-manifest folders that name this cluster's hostnames, addresses and tenants.

## 11. Decisions

**Open**

| # | Decision | Notes |
|---|---|---|
| 1 | Source restriction at HAProxy for `headlamp.jodywan.com` and `garage-k8s.jodywan.com` | both are public behind a login; allow only LAN or VPN ranges |
| 2 | Trace storage, sampling and team separation | Badger today; OpenSearch or Cassandra, or Tempo, if tenants send traces |
| 3 | Per-tenant access to Garage buckets through the UI | an Authentik policy on `garage-ui-oauth-app` plus `access_control` teams |
| 4 | CPU and RAM sizing | postponed: all nodes are 4 CPUs and 16 GB; revisit with real numbers |
| 5 | Who can read the repo's GitLab group | the repo path is settled (section 1) |

**Decided**

| Topic | Decision |
|---|---|
| Layers | layer 0 is only Argo CD and OIDC; everything else is an ordinary app |
| Secret backend | External Secrets reading GitLab CI/CD variables |
| Alerts | Alertmanager mail receiver |
| Gatekeeper | layer 1; its webhook sees Pods only and the platform namespaces are exempt |
| TLS inside the LAN | TLS ends at HAProxy on pfSense; the hops to Traefik are plain HTTP on the LAN; cert-manager is not installed |
| Branch rules | protected `main`, merge requests, the `validate` pipeline |
| Layer 0 CI | an instance runner plus a Protected kubeconfig variable |
| Sync | every app auto-syncs with `prune: false` |

## 12. Next steps

1. Onboard real tenant users (Argo CD for tenants, the tenant gate and the Capsule Proxy are built and tested).
2. Tenant traces (Jaeger has no tenancy), and `restricted` instead of `baseline` Pod Security.
3. Housekeeping: HAProxy source restrictions (open decision 1), TrueNAS export hosts, the NFS dataset quota and snapshots.
4. The Longhorn worker reboot test (create a fresh volume first with `tests/storage-longhorn.sh KEEP=1`).
5. Rehearse the full bootstrap on a test cluster (section 9) and record the gaps.
6. Convert to a template and fork for this server (section 10).
