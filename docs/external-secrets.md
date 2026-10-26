# External Secrets

- Layer 1, Argo CD app `external-secrets`, namespace `external-secrets`.
- Chart `external-secrets/external-secrets` 2.12.0 (External Secrets Operator v2.12.0).
- Backend: **GitLab CI/CD variables**. Auto-sync, `prune: false`.
- Status: built and tested (`tests/external-secrets.sh`, 35 checks). The ClusterSecretStore `gitlab-platform` (group 625) is `Valid`.
- All by-hand platform Secrets are migrated (list in "What is migrated").

## 1. What it does

An `ExternalSecret` says "make Secret X from variable Y of store Z". The operator reads the variable from GitLab and creates and
refreshes the Secret. Git then holds only references (names), never values.

| Part | Role |
|---|---|
| `external-secrets` (operator) | reconciles ExternalSecrets and stores, writes the Secrets |
| `external-secrets-cert-controller` | creates the webhook certificate and injects its CA |
| `external-secrets-webhook` | validates stores and ExternalSecrets |
| `SecretStore` (namespaced) | how to reach GitLab: url, project or group, token Secret |
| `ClusterSecretStore` (platform) | the platform's own store, usable from platform namespaces only |

## 2. Settings and why

| Setting | Value | Why |
|---|---|---|
| Backend | GitLab Variables provider | nothing new to run or unseal; GitLab and its token handling already exist. A vault (OpenBao) stays an option if tenants need self-service, leases or audit |
| `processClusterExternalSecret` | **false** | it copies a Secret into every namespace a selector matches: not needed |
| `processPushSecret`, `processClusterPushSecret`, `processClusterGenerator` | **false** | nothing is written out to a store; no generators |
| `processClusterStore` | true | the platform's own store |
| `rbac.aggregateToView/Edit/Admin` | **false** | the chart would aggregate rights on stores and every generator into the built-in roles, so tenant owners and developers could create generators (found by the test). Tenants get exactly `ExternalSecret` and `SecretStore` from `tenant-baseline/external-secrets-rbac.yaml` |
| Namespace Pod Security | `baseline` | like the other platform apps |
| Replicas | 1 each | small cluster; a restart only delays a refresh |
| Argo CD | `ignoreDifferences` for the cert controller's Secret data and the CA bundles | otherwise OutOfSync forever |

## 3. How the variables are laid out in GitLab

The variables are **group CI/CD variables** on the group `servers/pcls.jodywan.com/k8s-1.jodywan.com` (the group of this repo),
read with `groupIDs` in the store. A dedicated `platform-secrets` project was the alternative: it keeps the token away from the
repos and their pipelines, at the cost of one more project.

Rules for every variable:

- **One variable per Secret.** The value is a JSON object whose keys become the Secret's keys, read with `dataFrom: extract`. A multi-line value (a Thanos `objstore.yml`, a Velero credentials file) is one variable read with `data` and `remoteRef.key`.
- **Name:** letters, digits and underscore only, so `grafana-oidc` becomes `grafana_oidc`. For `data:` keys the provider turns hyphens into underscores (not for `dataFrom`).
- **Type** Variable (not File), environment scope `*`, **Protected** on, **Hidden off** (a hidden variable cannot be read back through the API).

What follows from using group variables:

- Group variables are **inherited by every project in the group**, so a CI job in `platform-gitops` or a sibling repo can read them. Keep every platform variable Protected, and keep these repos free of pipelines that print the environment.
- The token is a **group access token** on `k8s-1.jodywan.com`. It can read every variable of the group. Treat it as the key to all platform secrets.
- Only the group's Owners (and Maintainers, depending on the GitLab version) see and edit the variables: keep the group's membership to the platform team.

## 4. First-time setup of the platform store

1. In GitLab, group `k8s-1.jodywan.com` > Settings > Access tokens: create a **group access token**, role **Owner** (the group's variables need it), scope **`read_api`**, with an expiry. Note the numeric **group ID** (on the group's overview page).
2. Create the one root secret by hand, never in Git (like the Argo CD GitLab token, `rotate-argocd-gitlab-token.md`):

   ```bash
   read -r -s -p "New token: " T; echo
   kubectl -n external-secrets create secret generic gitlab-token --from-literal=token="$T"
   unset T
   ```

3. Put the store in Git as `external-secrets/clustersecretstore.yaml`, with the real group ID:

   ```yaml
   apiVersion: external-secrets.io/v1
   kind: ClusterSecretStore
   metadata: {name: gitlab-platform}
   spec:
     conditions:                         # only namespaces WITHOUT the Capsule tenant label may use it
       - namespaceSelector:
           matchExpressions:
             - {key: capsule.clastix.io/tenant, operator: DoesNotExist}
     provider:
       gitlab:
         url: https://gitlab.jodywan.com
         groupIDs: ["<group id>"]          # a store needs a project or a group
         auth:
           SecretRef:
             accessToken: {name: gitlab-token, key: token, namespace: external-secrets}
   ```

4. Check: `kubectl get clustersecretstore gitlab-platform` shows `Valid`, `Ready True`.

Check a token before using it: `GET /api/v4/user` must be a bot of the group with `is_admin` not true, and
`GET /api/v4/projects?membership=true` must list only the group's projects.

## 5. Day to day (platform)

Platform ExternalSecrets live in `external-secrets/` (one file per app, each names its own namespace), which the
`external-secrets` app syncs. Never type a secret value into chat, Git or a command line.

### Create a secret

1. **GitLab:** group `k8s-1.jodywan.com` > Settings > CI/CD > Variables > Add variable. Key `grafana_oidc` for the Secret `grafana-oidc`; value a JSON object such as `{"client-id":"abc","client-secret":"xyz"}` (or plain text for a single value or a file); type Variable, scope `*`, **Protected** on, **Hidden** off.
2. **Git:** add `external-secrets/<app>.yaml` and list it in `external-secrets/kustomization.yaml`:

   ```yaml
   apiVersion: external-secrets.io/v1
   kind: ExternalSecret
   metadata: {name: grafana-oidc, namespace: grafana}
   spec:
     refreshInterval: 1h
     secretStoreRef: {name: gitlab-platform, kind: ClusterSecretStore}
     target: {name: grafana-oidc}          # the Kubernetes Secret that the app already uses
     dataFrom:
       - extract: {key: grafana_oidc}      # JSON variable: every key becomes a key of the Secret
   ```

   For one plain value instead of JSON: `data: [{secretKey: password, remoteRef: {key: alertmanager_smtp}}]`.
3. Push. Argo CD syncs and the operator creates the Secret within seconds.
4. Check: `kubectl -n grafana get externalsecret` shows `SecretSynced` and `Ready True`, and `kubectl -n grafana get secret grafana-oidc` exists.

To take over a Secret that exists by hand: the ExternalSecret with the same `target.name` adopts it only with `creationPolicy: Merge` (then switch to `Owner`). The safer way is a new name, compare, then switch the app.

### Change a value (rotate a password or key)

1. Edit the **variable in GitLab**. Do not edit the Kubernetes Secret: it is overwritten at the next refresh.
2. Wait for the `refreshInterval` (1 h in the example), or force it now:
   `kubectl -n grafana annotate externalsecret grafana-oidc force-sync="$(date +%s)" --overwrite`
3. Apps that carry the Reloader annotation restart themselves when the Secret changes (`reloader.md`). Others need `kubectl -n <ns> rollout restart deploy/<name>`.
4. Check the app (login, scrape, backup) and that the ExternalSecret is still `SecretSynced`.

### Remove a secret

1. Delete the ExternalSecret file and its line in the kustomization.
2. Pruning is off, so delete the object by hand: `kubectl -n <ns> delete externalsecret <name>`. The Secret it owns goes with it, so stop the app first if it still needs it.
3. Delete the variable in GitLab.

### When it does not work

| Symptom | Likely cause | Look at |
|---|---|---|
| `SecretSyncedError`, "Secret does not exist" | variable name wrong (hyphen instead of underscore, spelling) or not in group 625 | `kubectl -n <ns> describe externalsecret <name>` |
| `SecretSyncedError`, 401 or 403 | token expired, revoked or role lost | `kubectl get clustersecretstore gitlab-platform`, section 6, "Rotating the platform token" |
| store `InvalidProviderConfig` | the Secret `external-secrets/gitlab-token` missing or wrong key | `kubectl -n external-secrets get secret gitlab-token` (key `token`) |
| `ClusterSecretStore ... not allowed`, namespace refused | the namespace carries the Capsule tenant label | tenants use their own SecretStore |
| Secret has the old value | refresh interval not reached | force-sync as above |
| JSON key missing in the Secret | the variable value is not valid JSON | check it in GitLab |

More checks: `kubectl -n external-secrets logs deploy/external-secrets --tail=50`.

## 6. Rotating the platform token

The token is a group access token of `servers/pcls.jodywan.com/k8s-1.jodywan.com` (a bot user), role Owner, scope `read_api`, with an
expiry. Rotate before it expires, or when it may have leaked:

1. GitLab: group > Settings > Access tokens: create the new token (`external-secrets`, Owner, `read_api`, a new expiry).
2. Replace the value (silent prompt, nothing on screen or in the shell history):

   ```bash
   read -r -s -p "New token: " T; echo
   printf '{"stringData":{"token":"%s"}}' "$T" | \
     kubectl -n external-secrets patch secret gitlab-token --type merge --patch-file /dev/stdin
   unset T
   ```

3. `kubectl get clustersecretstore gitlab-platform` must show `Valid`. If it still shows the old state after a minute: `kubectl annotate clustersecretstore gitlab-platform force-sync="$(date +%s)" --overwrite`.
4. Revoke the old token in GitLab (same page).

## 7. Tenants

A tenant uses **its own** GitLab: a namespaced `SecretStore` in its namespace with its own project or group IDs (`groupIDs` or
`inheritFromGroups`) and its own token in a Secret of its own namespace. The operator then reads exactly what that token can
read, and nothing of the platform's.

```yaml
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata: {name: gitlab, namespace: zeedlogic-prod}
spec:
  provider:
    gitlab:
      url: https://gitlab.jodywan.com           # the only url allowed
      projectID: "<the tenant's project id>"     # or groupIDs: ["<group id>"]
      auth:
        SecretRef:
          accessToken: {name: gitlab-token, key: token}   # Secret in the same namespace, made by the tenant
```

| Rule | Enforced by |
|---|---|
| tenant owners and developers can create `SecretStore` and `ExternalSecret` in their own namespaces; viewers read | `tenant-baseline/external-secrets-rbac.yaml` (aggregated into view, edit, admin) |
| only the `gitlab` provider, only `https://gitlab.jodywan.com`, the token Secret from the same namespace | ValidatingAdmissionPolicy `tenant-secretstore-gitlab-only` |
| an ExternalSecret may only use a `SecretStore` (never a `ClusterSecretStore`), no generator source | ValidatingAdmissionPolicy `tenant-externalsecret-own-store-only` |
| no `ClusterSecretStore`, `ClusterExternalSecret`, `PushSecret`, `ClusterPushSecret`, generators | no RBAC, and the controllers are off |
| the platform store cannot be used from a tenant namespace | `conditions` on the ClusterSecretStore (second lock behind the policy above) |

Why the provider and URL are fixed: the operator is a cluster component with its own network access and rights, and a store names
the address it calls and the credentials it uses. The `kubernetes` provider would let a tenant read Secrets of other namespaces
through the operator; a free URL would reach internal services the tenant network blocks (the same reasoning as KEDA, `keda.md`).

What a tenant must do (written for them in `tenant-guide-secrets-and-rollouts.md`):

1. Create a GitLab project or group access token (Maintainer, `read_api`).
2. Store it as a Secret in the namespace.
3. Create the SecretStore and the ExternalSecrets.

Caveat: a token with Maintainer on a tenant project can read all that project's variables, so tenants keep a separate project for
deployment secrets.

## 8. Install on a fresh cluster

This is the **first layer 1 app** after the Argo CD wiring (`fresh-install-order.md`, step 5b), so the Secrets of every other app
already exist or appear by themselves.

1. `kubectl apply -f bootstrap/platform-project.yaml` (adds `charts.external-secrets.io`).
2. Push. `platform-gitops` creates the ApplicationSet and `external-secrets` syncs. `tenant-baseline` carries the policies, the RBAC and the namespace's `refuse-tenant-ingress`; it retries until the namespace exists.
3. Run `./tests/external-secrets.sh` (about 2 minutes).
4. Create the group access token, the `gitlab-token` Secret and the store (section 4). The ExternalSecrets in `external-secrets/` then create the other Secrets.

## 9. What is migrated, and what stays by hand

Method used for each Secret: the variable was added in GitLab; a temporary ExternalSecret in a scratch namespace read it into a
copy; a **hash of every key was compared** with the live Secret (identical, nothing printed); only then the real ExternalSecret
was applied with `creationPolicy: Merge`, which adopts the existing Secret, so no pod restarted and no value changed.

| Secret | Variable | Form |
|---|---|---|
| `monitoring/alertmanager-smtp` | `alertmanager_smtp` | plain text, key `password` |
| `grafana/grafana-admin` | `grafana_admin` | JSON `{"admin-user","admin-password"}` |
| `grafana/grafana-oidc` | `grafana_oidc` | JSON `{"GF_AUTH_GENERIC_OAUTH_CLIENT_ID","GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET"}` |
| `headlamp/headlamp-oidc` | `headlamp_oidc` | JSON of the 8 `OIDC_*` keys (`external-secrets/headlamp.yaml`) |
| `garage/garage-ui-oidc` | `garage_ui_oidc` | JSON (`external-secrets/garage.yaml`) |
| `garage/garage-admin-token` | `garage_admin_token` | JSON |
| `garage/garage-ui-jwt` | `garage_ui_jwt` | the PEM, multi-line plain text |
| `monitoring/thanos-objstore` | `thanos_objstore` | the whole `objstore.yml` (`external-secrets/thanos-velero.yaml`) |
| `velero/velero-s3` | `velero_s3` | the credentials file |

All nine variables are **Protected** (checked through the API).

**Still by hand, by design:** `garage-rpc-secret` (changing it breaks the Garage layout), `gitlab-token` (this operator's own root of trust) and the Argo CD repo token.

**PEM gotcha.** GitLab's variable editor drops the trailing newline of a multi-line value, so a PEM came back one byte shorter and the hash check refused to switch. The ExternalSecret restores it with a template (`{{ .pem | trimSuffix "\n" }}\n`), and the hash then matched. Check every multi-line secret with a hash before switching.

## 10. Limits

- GitLab is the store of record. If GitLab is down, existing Secrets keep working; only the refresh and new Secrets wait. Backups: GitLab's own (the variables are in its database).
- Read-only: nothing is written back to GitLab.
- A deleted or renamed variable makes the ExternalSecret `SecretSyncedError`; the existing Secret is kept (default).
- Not a vault: no leases, no per-read audit log. If that is needed later, add OpenBao as a second store; the ExternalSecrets only change their `secretStoreRef`.

## 11. Test

`tests/external-secrets.sh` checks:

- components ready, no restarts, CRDs, webhook CA, Pod Security, cluster-wide controllers off;
- a fake-provider store fills a Secret, a changed value is picked up, the Secret goes with its ExternalSecret;
- tenants can create a GitLab SecretStore and an ExternalSecret in their own namespace, and are refused: another provider, another URL, a token from another namespace, a ClusterSecretStore reference, ClusterSecretStore, ClusterExternalSecret, PushSecret, generators, and the other tenant's namespace;
- viewers read but do not create;
- Prometheus holds `externalsecret_*`.

Round trip checked on the live store: a protected group variable was read into a Secret from a platform namespace (`SecretSynced`),
then deleted. From a tenant namespace an ExternalSecret that names `gitlab-platform` is refused by the admission policy (even for the
cluster admin).
