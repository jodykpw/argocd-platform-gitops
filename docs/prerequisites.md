# Prerequisites: do these before Argo CD deploys the apps

- Everything manual that can be done **before** the first sync, so every app finds what it needs when Argo CD creates its namespace.
- The order inside a section does not matter. Afterwards follow `fresh-install-order.md`.
- How secrets work: an app's Secrets come from GitLab variables through External Secrets (`external-secrets.md`). The ExternalSecret waits until the app's namespace exists, then the Secret appears by itself. No Secret is made by hand per app.
- Sections: A GitLab, B Authentik, C DNS and HAProxy, D storage and backup targets, E what is done by hand at install time.

## A. GitLab (group `servers/pcls.jodywan.com/k8s-1.jodywan.com`)

| Item | Value | Used for |
|---|---|---|
| Group access token `external-secrets` | role Owner, scope `read_api`, expiry | by-hand Secret `external-secrets/gitlab-token` (E) |
| Read token for Argo CD | `read_repository` on `platform-gitops`, expiry | by-hand Secret `argocd/gitlab-group-creds` (E) |
| Top-level groups `<tenant>` (`zeedlogic`, `jodywan`), with subgroups below them | one group per tenant | tenant repos; needed for step 10 (tenant GitOps) |
| Project token `renovate` (optional) | project `platform-gitops`, role Developer, scope `api`, expiry | `renovate/renovate-env` (E) |
| Group CI/CD variables | the 9 below, **Type Variable, scope `*`, Protected on, Hidden off** | one Kubernetes Secret each |

### The 9 variables

| Variable | Value (text, JSON, or file) | Where the value comes from | Becomes |
|---|---|---|---|
| `alertmanager_smtp` | the password, plain text | Gmail app password | `monitoring/alertmanager-smtp` |
| `grafana_admin` | `{"admin-user":"admin","admin-password":"…"}` | generate: `openssl rand -base64 24` | `grafana/grafana-admin` |
| `grafana_oidc` | `{"GF_AUTH_GENERIC_OAUTH_CLIENT_ID":"…","GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET":"…"}` | Authentik provider `grafana-k8s-oauth2-provider` (B) | `grafana/grafana-oidc` |
| `headlamp_oidc` | JSON with 8 keys: `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET`, `OIDC_ISSUER_URL`, `OIDC_VALIDATOR_ISSUER_URL`, `OIDC_VALIDATOR_CLIENT_ID`, `OIDC_CALLBACK_URL`, `OIDC_SCOPES`, `OIDC_USE_PKCE` | Authentik provider `kube-apiserver-oauth2-provider`; shape in `headlamp.md` | `headlamp/headlamp-oidc` |
| `garage_ui_oidc` | `{"client-secret":"…"}` | Authentik provider `garage-ui-oauth2-provider` | `garage/garage-ui-oidc` |
| `garage_admin_token` | `{"admin-token":"…"}` | generate: `openssl rand -hex 32` | `garage/garage-admin-token` |
| `garage_ui_jwt` | the PEM, multi-line plain text | generate: `openssl genpkey -algorithm ed25519` | `garage/garage-ui-jwt` (key `jwt-key.pem`) |
| `thanos_objstore` | the `objstore.yml` text (type S3, bucket `thanos`, endpoint `garage.garage.svc.cluster.local:3900`, key id and secret) | **needs the in-cluster Garage** (see "Cannot be earlier") | `monitoring/thanos-objstore` |
| `velero_s3` | AWS credentials file (`[default]`, `aws_access_key_id`, `aws_secret_access_key`) | backup Garage on docker-2 (D) | `velero/velero-s3` |

Never paste values into chat, Git or a command line. Add them in the GitLab UI, or with the silent prompt.

## B. Authentik (docker-2, `10.1.5.123`)

| Item | Value |
|---|---|
| Provider `kube-apiserver-oauth2-provider` | **Confidential**; redirect URIs: `regex http://localhost:8000`, `strict http://localhost:18000` (kubelogin), `strict https://headlamp.jodywan.com/oidc-callback` |
| Application and provider for Argo CD | `argocd-oauth-app`; client secret goes into `layer0/argocd/patch-secret.yaml` (E) |
| Application and provider for Grafana | `grafana-k8s-oauth-app` (only group `cluster-admin`; tenant groups added by `tenant-observability`) |
| Application and provider for Garage UI | `garage-ui-oauth-app` |
| Groups | `cluster-admin`, `ArgoCD Admins`, and per tenant `<tenant>-owners`, `-developers`, `-viewers` |
| Users | real users, in the groups above |

## C. DNS and HAProxy (pfSense)

| Hostname | Points to | Notes |
|---|---|---|
| `argocd.jodywan.com` | `10.1.5.170` (Traefik) via HAProxy | TLS ends at HAProxy |
| `headlamp.jodywan.com` | same | public behind login only; restrict the source in HAProxy (open item) |
| `garage-k8s.jodywan.com` | same | same |
| `grafana-k8s.jodywan.com` | same | |
| `thanos-query-k8s.jodywan.com` (optional) | `10.1.5.172` | LAN only, DNS only |

## D. Storage and backup targets

| Item | Value |
|---|---|
| TrueNAS dataset `byte-haven/k8s-1-nfs` | NFS export for the workers only, quota set |
| TrueNAS export `k8s-1-longhorn-backup` | for the Longhorn backup target |
| Backup Garage on docker-2 | container `k8s-1-backups-garage`; buckets `velero` (100 GiB) and `etcd-snapshots` (20 GiB, 7 day expiry); limited key for the control planes (`backup-target.md`) |
| Workers | raw 100 GB `/dev/sdb`, NFS client installed |
| Gateway API CRDs | standard channel (v1.5.1), file `gateway-api-crds/`; `layer0/argocd/deploy.sh` applies them if missing, nothing to do by hand |

## E. By hand, at install time (needs the cluster, so cannot be earlier)

| Secret or file | When | How |
|---|---|---|
| `layer0/argocd/patch-secret.yaml` | before `layer0/argocd/deploy.sh` by hand | copy `patch-secret.example.yaml`, add the Argo CD client secret (git-ignored). In GitLab CI use the Masked, Protected variable `ARGOCD_AUTHENTIK_CLIENT_SECRET` instead |
| CI variable `KUBECONFIG` (File, Protected) | before the first `deploy-argocd` job | kubeconfig of a dedicated cluster-admin ServiceAccount, scope to environment `k8s-1-layer0` (`how-layer0-works.md`) |
| `argocd/gitlab-group-creds` | before step 4 (it is needed by `platform-gitops`) | label `argocd.argoproj.io/secret-type=repo-creds`; `url`, `username`, `password` (the read token) |
| `external-secrets/gitlab-token` | step 5b | silent prompt (`external-secrets.md`, section 6) |
| `garage/garage-rpc-secret` (key `rpcSecret`) | before `storage-garage` | `openssl rand -hex 32`; never change it later |
| `renovate/renovate-env` (optional) | when enabling Renovate | key `RENOVATE_TOKEN` |

## Cannot be earlier (needs a running component)

| Item | Needs | Do |
|---|---|---|
| Bucket `thanos`, key `thanos-key`, quota 15 GiB, then variable `thanos_objstore` | in-cluster Garage (step 6d) | `garage bucket create`, `garage key create`; then add the variable; Prometheus picks it up |
| Data sources in the docker-2 Grafana | LAN addresses `.172`, `.173` | `lan-access-metallb.md` |
| Tenant Grafana organizations | Grafana running | `tenant-observability/grafana-orgs.sh` |

## Check before step 4

| Check | Command or place |
|---|---|
| 9 variables exist and are Protected | GitLab group > Settings > CI/CD > Variables |
| Group token can read them | `curl -H "PRIVATE-TOKEN: …" …/groups/<id>/variables` (silent), or the store `Valid` later |
| Authentik issuer answers | `curl https://authentik.jodywan.com/application/o/kube-apiserver-oauth-app/.well-known/openid-configuration` |
| DNS resolves | `getent hosts argocd.jodywan.com` |
| Backup Garage answers | `curl http://10.1.5.123:3910` (an S3 error means it is up) |
