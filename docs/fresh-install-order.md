# Fresh install order

- The order to bring the platform up on a new or rebuilt cluster, and what each step needs.
- Use it for a rebuild of k8s-1, a rehearsal on a test cluster, or a new server from the template (`repo-layout.md`).
- Status: every step is **built and tested on k8s-1**. Steps 4, 5 and 7 (CI for Argo CD, Argo CD for the rest of layer 0, the Tenants) were adopted in place and are **not yet rehearsed on a fresh cluster**.
- Do the manual prerequisites first: `prerequisites.md` (GitLab variables and tokens, Authentik, DNS, backup targets).
- How the pieces fit, with diagrams: `how-layer0-works.md`.

## Rules

- Argo CD has no "depends on" between apps, and sync waves do not gate ApplicationSet apps.
- Every app auto-syncs (`prune: false`) as soon as `bootstrap/` creates `platform-gitops`, so on a fresh cluster **all apps start at once**.
- An app that starts too early waits (a Pending PVC) or fails (a missing CRD or Secret). Each ApplicationSet retries a failed sync 10 times (15 s doubling to 5 min), then stops until someone syncs it.
- So work in the order below: run the check for a step, and sync by hand any app of that step that is still failed or `OutOfSync`.
- Secrets never go in Git: they come from External Secrets (5b) or are made by hand (see "Always manual").
- Cluster-specific values are in `overlays/<cluster>/`, never in `base/` (`repo-layout.md`).

## How to read the tables

- **Step**: the id used in the other documents.
- **Needs**: what must exist before this step.
- **Do**: what to run or sync.
- **Check**: what proves it works. The number in brackets is how many checks the test script has (`tests/tests-guide.md`).

## The order (after `prerequisites.md`)

### Phase 1. The cluster and access

Goal: nodes Ready, you can log in with Authentik, the workers are ready for Longhorn.

| Step | What | Needs | Do | Check |
|---|---|---|---|---|
| 0 | Before the cluster | Authentik reachable; GitLab read token; TrueNAS dataset `k8s-1-nfs`; raw `/dev/sdb` on each worker | keep the installer kubeconfig as break-glass | `curl` the issuer; `showmount -e 10.1.5.202`; `lsblk` |
| 1 | Cluster | kubespray inventory (branch `dev`) with the OIDC flags from `layer0/oidc/config.yaml` | kubespray | nodes Ready |
| 2 | OIDC login | step 1 | apply `layer0/oidc/oidc-cluster-admin.yaml`, `kubectl oidc-login` | `kubectl auth whoami` shows the OIDC user |
| 3 | Node prep (workers) | step 1 | `node-prep/longhorn-node-prep.sh` (dry run, then `--apply`) | `/mnt/longhorn` mounted, `iscsi_tcp` loaded, multipath blacklist |

### Phase 2. Argo CD and the base apps

Goal: Argo CD runs, MetalLB, Traefik, Capsule and the secrets store are in place.

| Step | What | Needs | Do | Check |
|---|---|---|---|---|
| 4 | Argo CD (GitLab CI) | steps 1 to 3; CI variables `KUBECONFIG`, `ARGOCD_AUTHENTIK_CLIENT_SECRET`; credential `gitlab-group-creds` (`argocd/gitlab-group-creds`, by hand, label `argocd.argoproj.io/secret-type=repo-creds`; the namespace `argocd` does not exist yet, so create it first or make the Secret right after the job: the repository shows an error until then) | play `deploy-argocd` (manual): it applies the Gateway API CRDs if missing, labels the namespace, installs Argo CD and applies `bootstrap/` (AppProject, OCI repo, `platform-gitops`) | Argo CD pods Ready; SSO works; ApplicationSets appear (`how-layer0-works.md`) |
| 5 | Layer 0 apps | step 4 | sync by hand in this order, diff first: `gateway-api-crds`, `metallb`, `metallb-config`, `traefik`, `capsule`, `capsule-proxy` (Argo CD has no depends-on, so the order is yours; Traefik and Capsule each alone) | LoadBalancer gets an address; `traefik-gateway` Programmed; `kubectl get crd tenants.capsule.clastix.io` |
| 5b | `external-secrets` | step 4; GitLab group variables; group access token (Owner, `read_api`, expiry) | create the namespace `external-secrets` if the app has not yet, then Secret `external-secrets/gitlab-token` by hand (silent prompt); sync | `./tests/external-secrets.sh` (35); ClusterSecretStore `Valid` |

### Phase 3. The cluster UI and storage

Goal: Headlamp, block, shared and S3 storage.

| Step | What | Needs | Do | Check |
|---|---|---|---|---|
| 6a | `headlamp` | 5b (`headlamp-oidc`); Authentik redirect URIs; DNS, HAProxy | sync | `./tests/headlamp.sh`; browser login |
| 6b | `storage-longhorn` | step 3 | sync | `./tests/storage-longhorn.sh` (9) |
| 6c | `storage-nfs` | TrueNAS export reachable | sync | `./tests/storage-nfs.sh` (9) |
| 6d | `storage-garage` | 6b; `garage-rpc-secret` by hand | create ns `garage` and the Secret; sync | `./tests/storage-garage.sh` (9) |
| 6f | `garage-ui` | 6d; 5b (`garage-admin-token`, `garage-ui-jwt`, `garage-ui-oidc`) | sync; DNS, HAProxy | `./tests/garage-ui.sh` (13) |

### Phase 4. The tenants

Goal: both tenants exist with their namespaces, network rules and RBAC.

| Step | What | Needs | Do | Check |
|---|---|---|---|---|
| 7 | Tenants | step 5 (`capsule` Synced and Ready) | sync the `tenants` app: it applies the Tenants, runs the Job that creates the 3 namespaces per tenant (impersonating an owner), then the `developers-edit` RoleBindings (sync waves 0, 1, 2) | 3 namespaces per tenant; `layer0/oidc/test-permissions.sh` (78) |
| 7a | `tenant-baseline` | step 7; Calico | sync | `./tests/tenant-network.sh` (46), `./tests/tenant-guardrails.sh` (88) |
| 7c | RBAC | step 7 | `developers-edit.yaml` is part of the `tenants` app | `./tests/tenant-rbac.sh` (66) |

### Phase 5. Observability

Goal: logs, metrics, dashboards, long-term metrics and traces.

| Step | What | Needs | Do | Check |
|---|---|---|---|---|
| 8a | `loki` | 6b | AppProject (grafana repo); sync | `./tests/loki.sh` (16) |
| 8b | `fluent-bit` | 8a | sync | `./tests/fluent-bit.sh` (11) |
| 8c | `kube-prometheus-stack` | 6b; 5b (`alertmanager-smtp`, `thanos-objstore`) | sync | `./tests/kube-prometheus-stack.sh` (26) |
| 8c2 | `grafana` | 8c, 8a; 5b (`grafana-admin`, `grafana-oidc`); Authentik app `Grafana k8s`; DNS, HAProxy | sync | `./tests/kube-prometheus-stack.sh` |
| 8d | `thanos` | 8c; 6d (bucket `thanos` and key) | create bucket and key, then sync | `./tests/thanos.sh` (20) |
| 8e | `jaeger` | 6b, 8c; chart pinned 4.13.1 (2.21 breaks Grafana's data source) | sync | `./tests/jaeger.sh` (14) |
| 8f | LAN addresses | MetalLB, Calico, the Services in the Loki and stack overlays | data sources `Prometheus K8s-1`, `Loki K8s-1` in the docker-2 Grafana by hand | curl from docker-2 answers, from elsewhere times out |
| 8g | Traefik tracing | 8e | `tracing:` in `base/traefik/values.yaml` (sample rate in `overlays/<cluster>/traefik/`); merge, Argo CD applies it | service `traefik` in Jaeger |

### Phase 6. Backups, alerting, security and automation

Goal: the cluster can be restored, watched, scanned and updated.

| Step | What | Needs | Do | Check |
|---|---|---|---|---|
| 8h | Backups | backup Garage on docker-2; 5b (`velero-s3`); TrueNAS export `k8s-1-longhorn-backup` | etcd snapshot node prep; sync `velero`; Longhorn backup target | `./tests/velero.sh` (15), `./tests/longhorn-backup.sh` |
| 8i | Alerting and control-plane metrics | 8c; `etcd_metrics_port: 2381` in kubespray | values in the overlay | test alert arrives; etcd, scheduler, controller-manager targets up |
| 8j | `blackbox-exporter` | 8c | sync | `./tests/blackbox-exporter.sh` (16) |
| 8k | `gatekeeper` (`gatekeeper.md`) | 7 (tenant label); AppProject (gatekeeper chart repo) | sync; templates and constraints in `gatekeeper-policies/` | `RESILIENCE=1 ./tests/gatekeeper.sh` |
| 8l | `trivy-operator` | 8c; memory on workers | AppProject (aquasecurity repo); sync | `./tests/trivy-operator.sh` (19) |
| 8m | `argo-rollouts` | step 4, 8c, Traefik Gateway | AppProject (argo-helm repo); sync | `./tests/argo-rollouts.sh` (34) |
| 8n | `keda` | 8c | AppProject (kedacore repo); sync | `./tests/keda.sh` (17) |
| 8p | `reloader` | none | sync | `./tests/reloader.sh` (13) |
| 8q | `renovate` | GitLab project token (Secret `renovate/renovate-env`) | sync; CronJob stays suspended until the token exists | `./tests/renovate.sh` (6) |
| 8r | `cloudnative-pg` (`cloudnative-pg.md`) | 8c | AppProject (CloudNativePG chart repo); sync | `./tests/cloudnative-pg.sh` (12) |
| 8s | `databases` (`databases.md`) | 8r, 7 (tenant namespaces) | sync | `./tests/databases.sh` (11) |
| 8t | `tenant-storage` (`tenant-storage.md`) | 8s's pattern; `storage-garage` (Garage up); a bucket and a key made with the Garage CLI | sync | `./tests/tenant-storage.sh` (10) |

### Phase 7. Tenant observability and tenant GitOps

Goal: tenants see their own metrics and logs and can deploy with Argo CD.

| Step | What | Needs | Do | Check |
|---|---|---|---|---|
| 9 | `tenant-observability` | 8a to 8d, Authentik groups | `tenant-observability/grafana-orgs.sh` first, then sync, then the Authentik bindings | `./tests/tenant-observability.sh` (17) |
| 10 | Tenant GitOps | 4, 7, GitLab groups `<tenant>` | a person runs `tenant-gitops/register-deployers.sh --apply` | `./tests/tenant-gitops.sh` (53), then `E2E=1` for the sync test |

## Always manual

| Item | Why |
|---|---|
| The cluster, the OIDC flags, node prep | host level, outside Kubernetes |
| `oidc-cluster-admin` binding | break-glass, never prunable |
| `garage-rpc-secret` | changing it breaks the Garage layout |
| Secrets `external-secrets/gitlab-token` and `argocd/gitlab-group-creds`, CI variables `KUBECONFIG` and `ARGOCD_AUTHENTIK_CLIENT_SECRET` (or the file `layer0/argocd/patch-secret.yaml` by hand) | the roots of trust; never in Git |
| Garage buckets and S3 keys (`thanos`, `velero`, `etcd-snapshots`) | one-time `garage` commands; the values go to GitLab variables |
| `bootstrap/` (applied by the manual CI job), `tenant-gitops/register-deployers.sh`, the `oidc-cluster-admin` binding | they give Argo CD, its tenants' deployers or the platform team their power: a person starts them |
| First sync of each app | keeps the order and gives a test point |

## When a node is added or rebuilt

1. Update the node tunnel addresses in `tenant-baseline/platform-ingress.yaml` and `tenant-baseline/tenant-egress-guard.yaml` (`tenant-network.md`).
2. Run `./tests/tenant-network.sh`.

## Rehearsal

Run this order on a throwaway cluster before relying on it. Every manual step that is not in this file is a gap.

Write down while you run it:

- The time each phase takes.
- Every manual step that was not in this file.
- Every app that failed its first sync, and which dependency it lacked.

## See also

`how-layer0-works.md`, `repo-layout.md`, `node-prep/node-prep.md`, `tests/tests-guide.md`, one document per app in `docs/`.
