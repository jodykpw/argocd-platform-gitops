# Sample tenant app

Three plain manifests for the first Argo CD test of a tenant: a ConfigMap (the page), a Deployment (two replicas of
`nginxinc/nginx-unprivileged`) and a ClusterIP Service. No namespace is set in the files: Argo CD puts them in the
application's destination namespace (for example `zeedlogic-dev`).

## Use

1. In GitLab, as a group owner: create a repo under the tenant's group, for example `zeedlogic/apps/sample-app`
   (protect `main`), and push these three files at the root.
2. Create a **group access token** on the group `zeedlogic` (role Reporter, scope `read_repository`, an expiry).
3. In Argo CD, as a tenant owner (for example `owner@zeedlogic.com`): Settings > Repositories > Connect repo, HTTPS,
   the repo URL, username `token` (any non-empty name), password = the token. Project `zeedlogic-nonprod`.
4. New application: project `zeedlogic-nonprod`, repository above, path `.`, cluster `https://kubernetes.default.svc`,
   namespace `zeedlogic-dev`. Sync.
5. Check: `kubectl -n zeedlogic-dev get deploy,svc,pods -l app.kubernetes.io/name=sample-app`, and
   `kubectl -n zeedlogic-dev port-forward svc/sample-app 8080:80` then open http://localhost:8080.

## What it demonstrates

| Rule | Where |
|---|---|
| limits on every container (quota) | `deployment.yaml` `resources.limits` |
| image with a version tag, from an allowed registry (Gatekeeper) | `nginxinc/nginx-unprivileged:1.27.3` on docker.io |
| Pod Security baseline, restricted-clean | `securityContext` on pod and container |
| only allowed kinds in Git (AppProject allowlist) | Deployment, Service, ConfigMap |

## Things that are refused on purpose (try them to see the message)

- change the image to `nginx:latest` or to `quay.example.com/x:1` (Gatekeeper denies it);
- add a `Role` or `RoleBinding` to the repo (not in the AppProject allowlist);
- set `type: LoadBalancer` on the Service (tenant guardrail).

To publish it with an Ingress later: class `traefik`, a hostname that is not a platform name, DNS and HAProxy outside
the cluster (`tenant-guide-secrets-and-rollouts.md` covers Secrets and Rollouts).
