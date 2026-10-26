# Headlamp: web UI for the cluster

- Layer 1, managed by Argo CD (`argocd-gitops.md`, section 7).
- Replaces the Kubernetes Dashboard, which is archived (no security patches). Headlamp is the official successor, under Kubernetes SIG UI.
- Login is Authentik; each user acts with their **own** token, so RBAC decides what they see.
- Test: `tests/headlamp.sh`. It is step 6a in `fresh-install-order.md`.

## 1. At a glance

| Item | Value |
|---|---|
| Chart | `headlamp` 0.45.0 (app 0.45.0), repo `https://kubernetes-sigs.github.io/headlamp/` |
| Namespace | `headlamp` (labels `gateway-access=platform`, Pod Security `baseline`) |
| URL | `https://headlamp.jodywan.com/` (TLS ends at HAProxy on pfSense; HAProxy forwards to Traefik `10.1.5.170` over HTTP on the LAN) |
| Route | HTTPRoute through `traefik-gateway` (namespace `traefik`, listener `web`) |
| Login | Authentik OIDC, reusing the kube-apiserver client (a **confidential** client: it needs its secret), PKCE |
| Access | each user's own token; the Headlamp ServiceAccount has no cluster-admin |
| Secret | `headlamp-oidc`, created by External Secrets from the GitLab variable `headlamp_oidc` (section 5) |
| Storage | none (stateless, no PVC) |
| Argo CD | ApplicationSet `headlamp`, auto-sync (`prune: false`, no self-heal) |
| Files | `appsets/headlamp.yaml`, `base/headlamp/values.yaml`, `overlays/k8s-1/headlamp/values.yaml`, `external-secrets/headlamp.yaml` |

## 2. Design choices

- **No cluster-admin for the app.** The chart binds its ServiceAccount to `cluster-admin` by default (`clusterRoleBinding.create: true`). That is turned off. With OIDC, Headlamp calls the API server with the signed-in user's token, so `oidc:cluster-admin` sees everything and tenant groups see only their namespaces. If Headlamp were compromised it would not hold a cluster-admin token of its own.
- **Reuse the kube-apiserver Authentik client.** The API server accepts only tokens whose audience equals its `--oidc-client-id` (`BJf5...`, in `layer0/oidc/config.yaml`). A separate client would issue tokens with another audience and the API server would reject them. The client ID is a public identifier, not a secret.
- **Confidential client, so a secret is needed.** The provider `kube-apiserver-oauth2-provider` is a *Confidential* client. The client secret is shared with kubelogin users of the same client: rotate it in Authentik if it is ever exposed. PKCE is enabled as well.
- **All OIDC settings live in one Secret, `headlamp-oidc`** (chart option `externalSecret`). With that option the other `config.oidc.*` values are ignored.
- **Same route pattern as Argo CD:** a Gateway API HTTPRoute, not an Ingress.
- **Admin only for now.** Headlamp could later point at the Capsule Proxy so tenants see only their namespaces. Not set up.

## 3. What it needs

| Dependency | Why | Check |
|---|---|---|
| Traefik with `traefik-gateway` (listener `web`) | the route | `kubectl -n traefik get gateway traefik-gateway` is Programmed |
| MetalLB address `10.1.5.170` | Traefik's address | a LoadBalancer IP on the Traefik service |
| kube-apiserver OIDC flags (issuer, client ID, `groups` claim, `oidc:` prefix) | the API server must accept the Authentik token | `layer0/oidc/config.yaml`; `kubectl auth whoami` works with OIDC |
| `oidc-cluster-admin` binding | gives the platform admin group rights | `kubectl get clusterrolebinding oidc-cluster-admin` |
| Authentik redirect URIs on the kube-apiserver provider | the login callback | section 4 |
| Secret `headlamp-oidc` | OIDC settings and client secret | `kubectl -n headlamp get externalsecret` shows `SecretSynced` |
| DNS (Cloudflare, public) and an HAProxy frontend/backend on pfSense for `headlamp.jodywan.com` | the public hostname, TLS | DNS to `217.155.25.4`; HTTPS reaches Traefik |
| Argo CD with the `platform` AppProject | deploys it; the chart repo is in `sourceRepos` | `kubectl apply -f bootstrap/platform-project.yaml` |
| External Secrets (step 5b) | creates `headlamp-oidc` | `fresh-install-order.md` |

**Does not depend on:** Longhorn, NFS, Garage, Capsule, Tenants (no storage, no tenant namespace). **Nothing waits for it.**

If something is missing:

| Symptom | Cause |
|---|---|
| the URL gives 404 | the namespace is not labelled `gateway-access=platform`, so the HTTPRoute is not accepted |
| the browser cannot find the host | no DNS record (the test script uses `--resolve` to bypass DNS) |
| login fails with a redirect error from Authentik | wrong redirect URI |
| login works but every API call returns 401 `Unauthorized` | audience mismatch (a different client ID) |

## 4. Authentik

Provider `kube-apiserver-oauth2-provider` (application `kube-apiserver-oauth-app`, client ID `BJf5...`) on `authentik.jodywan.com`, which runs in Docker on docker-2 (`10.1.5.123`).

| Setting | Value |
|---|---|
| Redirect URIs | `regex http://localhost:8000` and `strict http://localhost:18000` (kubelogin), plus `strict https://headlamp.jodywan.com/oidc-callback` (public, through HAProxy) and `strict http://headlamp.jodywan.com/oidc-callback` (LAN tests) |
| Client type | Confidential |
| Property mappings | `kube email (verified)`, OpenID `openid`, OpenID `profile` (`groups` comes from the `profile` mapping) |

To undo: remove the two Headlamp redirect URIs in the Authentik admin UI (Applications > Providers > the provider > Redirect URIs). The `http` one can go once nobody tests over plain HTTP.

## 5. The OIDC Secret (External Secrets)

`headlamp-oidc` is created and refreshed by the ExternalSecret in `external-secrets/headlamp.yaml` from the GitLab group variable `headlamp_oidc`. Nothing is created by hand in the cluster. Details of the mechanism: `external-secrets.md`.

The variable is one JSON object with 8 keys:

| Key | Value |
|---|---|
| `OIDC_CLIENT_ID` | `BJf5svepOPOag0dbh48rzIvGOhg6I9UagQ0QxQjJ` |
| `OIDC_CLIENT_SECRET` | the provider's client secret (below) |
| `OIDC_ISSUER_URL` | `https://authentik.jodywan.com/application/o/kube-apiserver-oauth-app/` |
| `OIDC_VALIDATOR_CLIENT_ID` | the same client ID |
| `OIDC_VALIDATOR_ISSUER_URL` | the same issuer URL |
| `OIDC_CALLBACK_URL` | `https://headlamp.jodywan.com/oidc-callback` |
| `OIDC_USE_PKCE` | `true` |
| `OIDC_SCOPES` | `openid profile email groups` |

**Read the client secret** from Authentik without printing it (prints only its length):

```bash
CS=$(ssh adminjody@10.1.5.123 "sudo docker exec authentik-server-1 ak shell -c \"from authentik.providers.oauth2.models import OAuth2Provider as P; print('CLIENT_SECRET=' + P.objects.get(client_id='BJf5svepOPOag0dbh48rzIvGOhg6I9UagQ0QxQjJ').client_secret)\"" 2>/dev/null | sed -n 's/^CLIENT_SECRET=//p')
echo "length: ${#CS}"        # expect a number, not 0
```

Put the value into the GitLab variable (group `k8s-1.jodywan.com` > Settings > CI/CD > Variables, type Variable, **Protected**, **Hidden off**), then `unset CS`.

**To change a value or rotate the client secret:**

1. Rotate it in Authentik first (it is shared with kubelogin users of the same client).
2. Edit the variable `headlamp_oidc` in GitLab.
3. Wait for the refresh (1 h) or force it: `kubectl -n headlamp annotate externalsecret headlamp-oidc force-sync="$(date +%s)" --overwrite`.
4. Reloader restarts Headlamp when the Secret changes (`deploymentAnnotations` in `base/headlamp/values.yaml`, `reloader.md`).

Check (names only, no values): `kubectl -n headlamp get secret headlamp-oidc` shows DATA 8, and `kubectl -n headlamp get pods` shows `1/1 Running`.

## 6. DNS, TLS and exposure

- **Path:** Cloudflare DNS (`headlamp.jodywan.com` to `217.155.25.4`, DNS only) to **HAProxy on pfSense**, which terminates TLS and forwards to Traefik `10.1.5.170` over HTTP on the LAN, then to Headlamp. It is the same path as `argocd.jodywan.com`.
- **The public URL is HTTPS** and the OIDC callback is `https://headlamp.jodywan.com/oidc-callback`. The plain-HTTP frontend answers 503 (nothing behind it): fine.
- **Reachable from the internet.** The protection is the Authentik login: an unauthenticated visitor sees the sign-in page, and after login every action uses the user's own token. Consider an HAProxy ACL that allows only the LAN or VPN source ranges.
- The hop from pfSense to Traefik is plain HTTP on the LAN. Acceptable on a trusted LAN; use HTTPS to the backend if that changes.
- Traefik routes by Host, so the HTTPRoute hostname must match exactly: `headlamp.jodywan.com`.

## 7. Deploy

1. Commit and push.
2. Apply the AppProject: `kubectl apply -f bootstrap/platform-project.yaml`.
3. Make sure the Authentik redirect URIs, DNS and HAProxy exist (sections 4 and 6) and the variable `headlamp_oidc` exists (section 5).
4. Sync `platform-gitops` (creates the ApplicationSet), then sync `headlamp`. It creates the namespace, with the labels from `managedNamespaceMetadata`. External Secrets creates the Secret and the pod starts within a minute.
5. Run `./tests/headlamp.sh`, then sign in from a browser (manual check).

## 8. Test

`tests/headlamp.sh` is read-only and creates nothing. It checks:

1. The Secret `headlamp-oidc` has its keys, the Deployment is ready, the Service exists, the namespace has `gateway-access=platform`, and there are no PVCs.
2. The HTTPRoute is `Accepted=True`, and the UI answers through Traefik (`--resolve headlamp.jodywan.com:80:10.1.5.170`) and on the public URL `https://headlamp.jodywan.com/`.
3. The Headlamp ServiceAccount has no ClusterRoleBinding and cannot read Secrets cluster-wide.
4. The Authentik issuer's discovery document answers HTTP 200.

**Manual check** (cannot be scripted): open the URL, sign in with Authentik as an `oidc:cluster-admin` user and confirm that namespaces and nodes list. Then sign in as a tenant user (for example `dev@zeedlogic.com`): through the API server directly a tenant user can read little, which is expected.

## 9. Risks and open items

- **False OutOfSync on the HTTPRoute:** the Gateway API server adds defaults (parentRefs `group`/`kind`, backendRefs `group`/`kind`/`weight`). An `ignoreDifferences` rule for them is in `appsets/headlamp.yaml`.
- **First browser login:** if login fails with a client or secret error, check the Headlamp pod log, that `headlamp-oidc` has all 8 keys, and the redirect URI.
- **Tenants:** to give a tenant a UI later, run a second Headlamp (or a second context) that points at the Capsule Proxy `https://10.1.5.171:9001`. Not done.
- **Plugins** are not enabled (`pluginsManager` off).
- **Version bumps:** review `targetRevision` changes like any chart.
