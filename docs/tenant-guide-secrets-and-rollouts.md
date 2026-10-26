# Tenant guide: Secrets and Rollouts

- For tenant owners and developers (`<tenant>-owners`, `<tenant>-developers`). Viewers can read everything here and change nothing.
- You work in your own namespaces (`<tenant>-dev`, `-stg`, `-prod`) with `kubectl` through the Capsule Proxy, as in `layer0/oidc/TENANT-KUBECONFIG.md`.
- Platform-side detail: `external-secrets.md`, `argo-rollouts.md`, `gatekeeper.md`.

## 1. Rules for every pod you run

These apply to Secrets and Rollouts alike (a Rollout's pods are checked like a Deployment's).

| Rule | What you see if you break it |
|---|---|
| CPU and memory **limits** on every container (your namespace quota requires them) | `failed quota: ... must specify limits.cpu` |
| Pod Security `baseline` is enforced, `restricted` warns: set `runAsNonRoot`, drop all capabilities, `allowPrivilegeEscalation: false`, `seccompProfile: RuntimeDefault` | refusal for baseline, a warning for restricted |
| Pods stay on the worker nodes: no `nodeName`, no control-plane tolerations | `tenant pods must not set spec.nodeName ...` |
| Images need a **version tag or digest**: no `:latest`, no untagged image | refused (Gatekeeper `tenant-image-tags`) |
| Images only from `docker.io`, `ghcr.io`, `registry.k8s.io`, `gitlab-registry.jodywan.com`, `quay.io` | refused (Gatekeeper `tenant-image-registries`) |

## 2. Secrets

Do not put secret values in Git or in a manifest you apply. Keep the value in **GitLab** (a CI/CD variable of your own
project) and let the cluster copy it into a Kubernetes Secret with an **ExternalSecret**. Git then holds only the name.

### What you can and cannot do

| You can | You cannot |
|---|---|
| create `SecretStore` and `ExternalSecret` in your own namespaces (owners and developers) | use a `ClusterSecretStore`, `ClusterExternalSecret`, `PushSecret` or a generator |
| point the store at `https://gitlab.jodywan.com` with your own project or group | use any other provider (the `kubernetes` provider, Vault, AWS, ...) or any other URL |
| keep the access token as a Secret in the same namespace | name a token Secret from another namespace |
| read the Secrets of your own namespaces | read the platform's variables or another tenant's |

### Steps

1. **GitLab, once per project:** keep deployment secrets in a **separate project** (a token with Maintainer on a
   project can read every variable of that project). Create a **project access token** there: role Maintainer, scope
   `read_api`, with an expiry. Note the project's numeric ID.
2. **GitLab, per secret:** Settings > CI/CD > Variables > Add variable. Key: letters, digits and underscore only
   (for the Secret `db-credentials` use `db_credentials`). Type **Variable**, scope `*`, **Protected** on, **Hidden**
   off (hidden values cannot be read back). Value: a JSON object, for example
   `{"username":"app","password":"..."}`: each key becomes a key of the Secret. For one plain value or a file, use the
   text itself.
3. **Cluster, once per namespace:** store the token. Type it at a silent prompt, never on the command line:

```
read -r -s -p "GitLab token: " T; echo
kubectl -n zeedlogic-prod create secret generic gitlab-token --from-literal=token="$T"
unset T
```

4. **Cluster, once per namespace:** the store.

```yaml
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata: {name: gitlab, namespace: zeedlogic-prod}
spec:
  provider:
    gitlab:
      url: https://gitlab.jodywan.com
      projectID: "1234"                      # your project's ID (or groupIDs: ["..."])
      auth:
        SecretRef:
          accessToken: {name: gitlab-token, key: token}    # no namespace field
```

5. **Per secret:** the ExternalSecret.

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata: {name: db-credentials, namespace: zeedlogic-prod}
spec:
  refreshInterval: 1h
  secretStoreRef: {name: gitlab, kind: SecretStore}        # kind must be SecretStore
  target: {name: db-credentials}                           # the Secret your pods use
  dataFrom:
    - extract: {key: db_credentials}                       # JSON variable: every key becomes a Secret key
```

   For one plain value: `data: [{secretKey: password, remoteRef: {key: db_password}}]`.
6. **Check:**

```
kubectl -n zeedlogic-prod get secretstore gitlab          # STATUS Valid, READY True
kubectl -n zeedlogic-prod get externalsecret db-credentials   # SecretSynced, READY True
kubectl -n zeedlogic-prod get secret db-credentials
```

### Change or remove a value

- **Change:** edit the variable in GitLab, not the Kubernetes Secret (it is overwritten at the next refresh). Wait for
  `refreshInterval`, or force it:
  `kubectl -n zeedlogic-prod annotate externalsecret db-credentials force-sync="$(date +%s)" --overwrite`.
- **Restart the app:** pods read a Secret's environment variables only at start. Either
  `kubectl -n zeedlogic-prod rollout restart deploy/<name>`, or add the Reloader annotation
  `reloader.stakater.com/auto: "true"` to your Deployment or Rollout and it restarts itself when the Secret changes
  (only for your own namespace, `reloader.md`).
- **Remove:** `kubectl -n zeedlogic-prod delete externalsecret db-credentials` (the Secret it made goes with it), then
  delete the variable in GitLab.
- **Rotate the token:** create a new project token, replace the Secret with the same silent prompt
  (`kubectl -n <ns> create secret generic gitlab-token --from-literal=token="$T" --dry-run=client -o yaml | kubectl apply -f -`),
  then revoke the old one. Do it before the expiry.

### When it does not work

| You see | Likely cause |
|---|---|
| `SecretSyncedError`, "Secret does not exist" | variable name wrong (hyphen instead of underscore) or in another project |
| `SecretSyncedError`, 401 or 403 | token expired, revoked, or too weak (needs `read_api`, Maintainer) |
| store `InvalidProviderConfig` | the `gitlab-token` Secret is missing or its key is not `token` |
| refused: "must use the gitlab provider", "url must be", "no namespace field" | the rules in the table above |
| refused: "must use a SecretStore of its own namespace" | `kind: ClusterSecretStore`, or a generator in `dataFrom` |
| the Secret has the old value | the refresh interval has not passed: force-sync |
| a key is missing in the Secret | the variable value is not valid JSON |

### Where to apply these objects

`SecretStore` and `ExternalSecret` are on your Argo CD project's allowed kinds, so they can live in Git and be deployed
like a Deployment. They hold only names and IDs, never a value. **Never put the `gitlab-token` Secret in Git**: create
it by hand with the silent prompt above (Argo CD would otherwise need the token in the repository). A `ClusterSecretStore`,
`ClusterExternalSecret` or `PushSecret` is refused by the project.

## 3. Rollouts

A `Rollout` replaces a `Deployment` and adds a delivery strategy: the new version is introduced step by step (canary) or
next to the old one (blue-green) and is promoted or rolled back.

### What you can and cannot do

| You can | You cannot |
|---|---|
| create, update and delete `Rollout` in your own namespaces | `trafficRouting` in a Rollout (it could rewrite a platform route) |
| **canary** with `setWeight` and `pause` steps (share follows the pod counts) | `analysis`, `experiment` steps, `AnalysisTemplate`, `AnalysisRun`, `Experiment` |
| **blue-green** with an active and a preview Service | exact traffic percentages through Traefik |
| deploy Rollouts through your Argo CD project | create other tenants' or platform Rollouts |

Your apps are published with an Ingress of class `traefik`. Traffic weights need an HTTPRoute, which tenants do not
have, so a canary is **replica-weighted**: with 4 replicas, `setWeight: 25` runs 1 new and 3 old pods.

### Turn a Deployment into a Rollout

1. Change `apiVersion: apps/v1` / `kind: Deployment` to `apiVersion: argoproj.io/v1alpha1` / `kind: Rollout`. Keep
   `replicas`, `selector` and the pod `template` as they are, and add a `strategy`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata: {name: my-app, namespace: zeedlogic-prod}
spec:
  replicas: 4
  selector: {matchLabels: {app: my-app}}
  template:                       # the pod template of the old Deployment (limits, tagged image, security context)
    metadata: {labels: {app: my-app}}
    spec:
      containers:
        - name: web
          image: gitlab-registry.jodywan.com/zeedlogic/my-app:1.4.2
          resources: {requests: {cpu: 50m, memory: 64Mi}, limits: {cpu: 200m, memory: 128Mi}}
  strategy:
    canary:
      steps:
        - setWeight: 25
        - pause: {duration: 2m}
        - setWeight: 50
        - pause: {}               # waits until you promote it
```

2. Delete the old Deployment (two controllers must not own the same pods), then apply the Rollout.
3. Update by changing the image tag in Git (or `kubectl edit rollout my-app`): it moves through the steps.

**Blue-green** instead: two Services, and
`strategy: {blueGreen: {activeService: my-app, previewService: my-app-preview, autoPromotionEnabled: false}}`. The new
version runs behind the preview Service until you promote it, then the active Service switches.

### Watch and control it

```
kubectl -n zeedlogic-prod get rollout my-app -w         # Progressing, Paused, Healthy, Degraded
kubectl -n zeedlogic-prod describe rollout my-app       # current step, events, why it aborted
kubectl -n zeedlogic-prod get rs -l app=my-app          # old and new ReplicaSet and pod counts
```

| Action | Command |
|---|---|
| promote a paused step | `kubectl -n zeedlogic-prod patch rollout my-app --subresource=status --type merge -p '{"status":{"pauseConditions":null}}'` |
| abort (back to the stable version, phase `Degraded`) | `kubectl -n zeedlogic-prod patch rollout my-app --subresource=status --type merge -p '{"status":{"abort":true}}'` |
| go back to the previous version | change the image back in Git |
| restart the pods | `kubectl -n zeedlogic-prod patch rollout my-app --type merge -p '{"spec":{"restartAt":"<now, RFC 3339>"}}'` |

Promote and abort live in `status`, so they need `--subresource=status`. After an abort, change the pod template again
to start a new attempt. If you install the optional `kubectl argo rollouts` plugin, the same actions are
`promote`, `abort`, `undo`, `restart`.

### Good to know

- **Autoscaling:** if KEDA or an HPA scales the Rollout, leave `replicas` out of Git, as for a Deployment.
- **Secrets and restarts:** a Rollout that uses an ExternalSecret restarts with the Reloader annotation like a
  Deployment (section 2).
- **Refusals:** `tenant Rollouts must not use trafficRouting` or `... analysis` come from a platform policy; remove that
  part of the strategy.
- **Failed updates:** a Rollout stuck in `Progressing` usually has pods that do not become ready (image tag, limits,
  probes). `describe rollout` and `kubectl get events` show it.
