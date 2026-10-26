# Argo CD

Helm release `argocd` (chart `argo-cd` 10.10.1, Argo CD v3.5.4) on k8s-1, SSO through Authentik, local admin **off**.
This is layer 0: Argo CD cannot manage its own installation. The GitLab CI job `deploy-argocd` runs `deploy.sh` (with the
Authentik client secret from the protected variable `ARGOCD_AUTHENTIK_CLIENT_SECRET` instead of `patch-secret.yaml`);
running it by hand works too. CI, upgrades and the whole picture: `../../docs/how-layer0-works.md`.

| Item | Value |
|---|---|
| Chart | `argo/argo-cd` 10.10.1 (Argo CD v3.5.4) |
| URL | `https://argocd.jodywan.com` (pfSense HAProxy terminates TLS, then Traefik, plain HTTP to `argocd-server` with `server.insecure`) |
| Login | Authentik through Dex, application `argocd-oauth-app` (redirect URI `https://argocd.jodywan.com/api/dex/callback`) |
| Admins | Authentik groups `cluster-admin` and `ArgoCD Admins` (both `role:admin`) |
| Tenants | No global rights (`policy.default` is empty). Their rights live in their own AppProjects (`../../docs/tenant-gitops.md`) |
| Repo credential | secret `gitlab-group-creds` (type `repo-creds`, prefix `https://gitlab.jodywan.com/servers/pcls.jodywan.com/`). Rotation: `../platform-gitops/docs/rotate-argocd-gitlab-token.md` |
| Applications | every app in `appsets/` (`kubectl -n argocd get applications`); project `platform` |

## Files

- `values.yaml`: chart values (Dex, RBAC, HTTPRoute, 2 replicas for server and repo-server, local admin off).
- `deploy.sh`: installs or upgrades the chart (`helm upgrade --install --atomic`), patches the Authentik client secret
  into `argocd-secret` and restarts Dex. `./deploy.sh platform` applies the `platform` AppProject from
  `../../bootstrap/platform-project.yaml`.
- `patch-secret.yaml`: the Authentik client secret (`dex.authentik.clientSecret`). **Not in Git** (`.gitignore`, mode 600).
  Needed by `deploy.sh`; keep a backup outside the cluster.
- `backup-values-*.yaml`: copies of the Helm values taken by `deploy.sh` before each upgrade.
- `layer0/.gitignore` also keeps keys, certificate bundles, `.env` files and `backup-*` copies out of Git. In CI the secret is the
  Masked, Protected variable `ARGOCD_AUTHENTIK_CLIENT_SECRET` and no file is needed. `patch-secret.example.yaml` shows the shape.
  Run each script from its own folder.

## Installing from scratch

Order for a whole cluster: `../../docs/fresh-install-order.md`. For Argo CD alone:

1. Authentik is up and the application `argocd-oauth-app` exists (provider `argocd-oauth2-provider`, confidential,
   redirect URI `https://argocd.jodywan.com/api/dex/callback`).
2. CI: set the variables (`../../docs/how-layer0-works.md`, section 3) and play `deploy-argocd`. By hand: create
   `patch-secret.yaml` here (`stringData: dex.authentik.clientSecret`, `chmod 600`) and run `./deploy.sh`.
   `deploy.sh` first applies the Gateway API CRDs if missing and labels the `argocd` namespace `gateway-access=platform`
   (the chart renders an HTTPRoute, and the Traefik listener accepts routes only from labelled namespaces).
3. Check:
   ```bash
   kubectl -n argocd get pods
   kubectl -n argocd get httproute argocd-server -o jsonpath='{.status.parents[*].conditions}'   # Accepted True
   kubectl -n argocd get cm argocd-cm -o jsonpath='{.data.admin\.enabled}'                        # false
   kubectl -n argocd get secret argocd-initial-admin-secret                                       # NotFound; delete it if it exists
   ```
4. Log in at `https://argocd.jodywan.com` with Authentik.
5. Create the repo credential `gitlab-group-creds` (`../../docs/rotate-argocd-gitlab-token.md`, which also covers the
   label). The CI job applies the AppProject, the OCI repository and `platform-gitops`; by hand:
   `./deploy.sh platform` and `kubectl apply -f ../../bootstrap/platform-gitops.yaml`.

## Why things are the way they are

- **Label on the namespace:** the Gateway's `web` listener accepts routes only from namespaces labelled
  `gateway-access=platform`. `Same` (the chart default) refuses Argo CD in its own namespace; `All` would let any
  namespace that can create an HTTPRoute take over a platform hostname.
- **`$dex.authentik.clientSecret`:** a reference to a key in `argocd-secret`, not a secret. The chart creates
  `argocd-secret`; `deploy.sh` adds the key from `patch-secret.yaml` and restarts Dex.
- **AppProject in the platform repo:** its `sourceRepos` list grows with every new chart (`kubectl apply` it again
  after adding one; the CI job does it). It is not synced by Argo CD itself, on purpose.

## Known false diffs

Argo CD shows `OutOfSync` for fields the API server fills in. The ApplicationSets carry `ignoreDifferences` for them:
HTTPRoute `parentRefs`/`backendRefs` defaults and StatefulSet `volumeClaimTemplates`. Add the same rule to a new app
when you see an app that is OutOfSync with no real change.
