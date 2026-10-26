# MacBook setup: kubectl contexts for k8s-1 (platform admin and six test users)

- For a person (or Claude) on the MacBook. Do the steps below.
- The MacBook can ssh to the server, so fetch the files from there.
- Stop and ask the user where it says so.

## Goal

Create one kubeconfig on the Mac with seven contexts, so the user can switch between them for testing:

| Context | API address | Login (Authentik) | Group in Kubernetes |
|---|---|---|---|
| `adminjody` | `https://10.1.5.151:6443` (API server directly) | `adminjody@jodywan.com` | `oidc:cluster-admin` (cluster-admin) |
| `zeedlogic-owner` | `https://10.1.5.171:9001` (Capsule Proxy) | `owner@zeedlogic.com` | `oidc:zeedlogic-owners` |
| `zeedlogic-dev` | Capsule Proxy | `dev@zeedlogic.com` | `oidc:zeedlogic-developers` |
| `zeedlogic-viewer` | Capsule Proxy | `viewer@zeedlogic.com` | `oidc:zeedlogic-viewers` |
| `jodywan-owner` | Capsule Proxy | `owner@jodywan.dev` | `oidc:jodywan-owners` |
| `jodywan-dev` | Capsule Proxy | `dev@jodywan.dev` | `oidc:jodywan-developers` |
| `jodywan-viewer` | Capsule Proxy | `viewer@jodywan.dev` | `oidc:jodywan-viewers` |

The Authentik users and groups already exist (the user created them).

## Facts

| Item | Value |
|---|---|
| Server (ssh) | `adminjody@10.1.5.151` (control-plane-1) |
| Files on the server | `/home/adminjody/kubernetes/platform-gitops/layer0/oidc/tenant-contexts.sh`, `/home/adminjody/k8s-ca.crt` |
| OIDC issuer | `https://authentik.jodywan.com/application/o/kube-apiserver-oauth-app/` |
| Client ID | `BJf5svepOPOag0dbh48rzIvGOhg6I9UagQ0QxQjJ` |
| Authentik provider | `kube-apiserver-oauth2-provider`, Client type **Confidential** (client secret stored in `~/.kube/config`) |
| Username claim | `email`, groups claim `groups`, Kubernetes adds the prefix `oidc:` |
| Redirect URIs allowed | `http://localhost:8000`, `http://localhost:18000` |
| Working folder on the Mac | `~/Projects/k8s/` (already holds `k8s-ca.crt`) |

## Steps

### 1. Check the tools

```bash
kubectl version --client
kubectl oidc-login --help >/dev/null && echo "kubelogin OK"
```

If `oidc-login` is missing: `brew install kubelogin`.

### 2. Fetch the two public CA certificates

```bash
cd ~/Projects/k8s
ssh adminjody@10.1.5.151 "kubectl get secret -n capsule-system capsule-proxy -o jsonpath='{.data.tls\.crt}' | base64 -d" > proxy-ca.crt
ssh adminjody@10.1.5.151 "cat /home/adminjody/k8s-ca.crt" > k8s-ca.crt   # skip if k8s-ca.crt is already here
openssl x509 -in proxy-ca.crt -noout -subject -enddate -ext subjectAltName
openssl x509 -in k8s-ca.crt -noout -subject -enddate
```

Expected: `proxy-ca.crt` has `IP Address:10.1.5.171` in its SANs; `k8s-ca.crt` is `CN=kubernetes`. Both are **public certificates**, safe to copy.

### 3. Fetch and run the context script

```bash
scp adminjody@10.1.5.151:/home/adminjody/kubernetes/platform-gitops/layer0/oidc/tenant-contexts.sh .
chmod +x tenant-contexts.sh
cat tenant-contexts.sh          # read it before running
./tenant-contexts.sh
kubectl config get-contexts
```

The script creates the clusters `k8s-1` and `k8s-1-proxy`, seven users and seven contexts, each with its own token cache (`~/.kube/cache/oidc-login-users/<user>`). It prints login URLs instead of opening a browser (`--skip-open-browser`).

The old context `oidc-context` from an earlier attempt can be removed: `kubectl config delete-context oidc-context`. Ask the user first.

### 4. Switch contexts and log in

Use `kctx` (defined in `~/.zshrc`) to switch users. It clears the token cache, switches the context, and opens a **fresh Chrome incognito window** with no existing Authentik session — so login always prompts for the right user:

```bash
source ~/.zshrc   # first time only
kctx              # shows numbered menu, pick a context
```

Or switch directly by name:

```bash
kctx adminjody
kctx zeedlogic-dev
```

Log in as the matching Authentik user from the goal table above. Do **not** use a normal browser window — Authentik will reuse the existing session and log in as the wrong user.

Test `adminjody` first:

```bash
kctx adminjody
kubectl auth whoami
kubectl get nodes
```

Expected: user `adminjody@jodywan.com`, groups include `oidc:cluster-admin`, and 6 nodes Ready.

Then `zeedlogic-dev` (log in as `dev@zeedlogic.com`):

```bash
kctx zeedlogic-dev
kubectl auth whoami
kubectl get ns
kubectl get pods -n zeedlogic-dev
kubectl get pods -n jodywan-dev
kubectl auth can-i update deployments -n zeedlogic-prod
kubectl auth can-i create rolebindings -n zeedlogic-dev
```

Expected: group `oidc:zeedlogic-developers`; `get ns` lists only `zeedlogic-dev`, `zeedlogic-stg`, `zeedlogic-prod`; pods in `zeedlogic-dev` are allowed (probably "No resources found"); pods in `jodywan-dev` are **Forbidden**; `update deployments` in prod prints `yes` (developers have `edit` in all three namespaces); `create rolebindings` prints `no`.

### 5. Expected results for the other users

| Context | `get ns` shows | May create/edit in its tenant's dev, stg and prod | Roles and RoleBindings | Secrets |
|---|---|---|---|---|
| `*-owner` | its tenant's 3 namespaces | everything (`admin`) | yes | yes |
| `*-dev` | its tenant's 3 namespaces | `edit` | no | yes |
| `*-viewer` | its tenant's 3 namespaces | read only | no | no |

Nobody in a tenant can access the other tenant, create ClusterRoles, or see platform namespaces (`argocd`, `traefik`, `capsule-system`, ...).

## If something fails

| Symptom | Likely cause | What to check |
|---|---|---|
| `invalid_client` | Client secret missing or wrong | Re-run `set-credentials` for all 7 users with the current secret from Authentik |
| `whoami` shows wrong user (e.g. `adminjody` context shows `owner@zeedlogic.com`) | Authentik reused a browser session from a previous login | Always use `kctx` to switch — it opens Chrome incognito with a fresh profile. Never use a normal browser window for tenant logins |
| Chrome opens but Authentik auto-logs in as the wrong user | Fresh profile wasn't used | Check that `kctx` is from `~/.zshrc` (run `source ~/.zshrc`); the `--user-data-dir` flag creates a blank profile per switch |
| `whoami` works but `oidc:<group>` is missing | User not in the group, or the group is not passed in the token | Ask the user to check group membership in Authentik; do not change Authentik yourself |
| Authentication error right after login | `email_verified` is not true for the user | The user must mark the email verified in Authentik |
| Timeout to `10.1.5.171:9001` or `10.1.5.151:6443` | No route to the LAN | Join the LAN or the VPN |
| `x509: certificate signed by unknown authority` | Wrong or stale CA file | Redo step 2; check `proxy-ca.crt` has `IP Address:10.1.5.171`; the API server uses `k8s-ca.crt` |
| `unknown command "oidc-login"` | kubelogin missing | `brew install kubelogin` |
| `localhost:8080 refused` | No current context | `kubectl config use-context adminjody` |
| Tenant user gets Forbidden on `get ns` | Using the API server instead of the proxy | The context's cluster must be `k8s-1-proxy` |

## Rules (important)

- On the server, run **only read-only commands** (`kubectl get`, `cat` of public files). Do not run `kubectl apply`, `delete`, `helm`, or any deploy script there. Cluster changes are done by the user or by Claude on the server.
- **Never copy** `/etc/kubernetes/admin.conf`, the server's `~/.kube/config`, any `*.key` file, or any Secret other than the public `tls.crt` of `capsule-proxy`. The `kubernetes-admin` certificate kubeconfig is break-glass access and stays on the server.
- Do not use `--insecure-skip-tls-verify`. Both CAs are embedded in the kubeconfig.
- Do not print, log or paste tokens or the contents of `~/.kube/cache/oidc-login-users/`.
- Authentik changes (groups, users, client type) are made by the user in the Authentik admin UI. Do not try to work around them.
- Do not publish the API server (`10.1.5.151:6443`) outside the LAN. Tenant users reach the cluster only through the proxy.

## Report back

When finished, give the user a short table: context, `whoami` user and groups, `get ns` result, and any step that failed with the exact error. The user will paste it to the server's Claude to verify.

## Background

- The platform team is the Authentik group `cluster-admin`: global, bound to the `cluster-admin` ClusterRole by `oidc-cluster-admin`, not part of any tenant. Platform admins use the API server directly.
- Tenants `zeedlogic` and `jodywan` are managed by Capsule 0.14.6, with Capsule Proxy 0.15.1 for filtered `kubectl` lists. Design and access model: `docs/cluster/capsule-argocd-integration.md`, `docs/tenant-access-model.md` and `docs/cluster/cluster-overview.md` in the repo (`~/kubernetes/platform-gitops` on the server).
- The single-user setup used earlier (one `oidc-context` for adminjody) was verified working. The provider remains **Confidential**; the client secret is stored in `~/.kube/config` (mode 600, never commit to git).
- `kctx` is defined in `~/.zshrc`. It clears the token cache, switches the context, and opens Chrome incognito with `--user-data-dir=/tmp/chrome-kctx-$$` so each login starts with no Authentik session. `kswtich` and `kswitch` are aliases for `kctx`.
