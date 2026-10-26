# Permission test results

Run: 2026-10-11 00:21 on control-plane-1 as cluster-admin, with `layer0/oidc/test-permissions.sh` (read-only: `kubectl auth can-i` and namespace lists by impersonation, no logins).
Earlier runs: 74 passed. Changed: developers get `edit` in prod too (deploy, exec and read Secrets everywhere in their tenant); they still cannot create Roles or RoleBindings. Four rows flipped to yes, four rows added. Re-run after the Capsule Proxy memory change (128Mi to 256Mi), the platform apps (Longhorn, Garage, Velero, observability), the backup and alerting work and the control-plane metrics change: nothing regressed.
Cluster: Kubernetes v1.36.4, Capsule 0.14.6, Capsule Proxy 0.15.0 (2 replicas, 256Mi), tenants `zeedlogic` and `jodywan`.

**Result: 78 passed, 0 failed.**

`yes`/`no` is the answer to "can this user do it". For the proxy rows the value is the list of namespaces the user sees. Rerun after any change: `cd ~/kubernetes/oidc && ./test-permissions.sh`.

## tenant zeedlogic

| Check | User | Expected | Actual | Result |
|---|---|---|---|---|
| `create deployments -n zeedlogic-dev` | owner@zeedlogic.com | yes | yes | PASS |
| `create rolebindings -n zeedlogic-dev` | owner@zeedlogic.com | yes | yes | PASS |
| `create deployments -n zeedlogic-stg` | owner@zeedlogic.com | yes | yes | PASS |
| `create rolebindings -n zeedlogic-stg` | owner@zeedlogic.com | yes | yes | PASS |
| `create deployments -n zeedlogic-prod` | owner@zeedlogic.com | yes | yes | PASS |
| `create rolebindings -n zeedlogic-prod` | owner@zeedlogic.com | yes | yes | PASS |
| `get secrets -n zeedlogic-prod` | owner@zeedlogic.com | yes | yes | PASS |
| `create clusterroles` | owner@zeedlogic.com | no | no | PASS |
| `create clusterrolebindings` | owner@zeedlogic.com | no | no | PASS |
| `list namespaces` | owner@zeedlogic.com | no | no | PASS |
| `get pods -n jodywan-dev` | owner@zeedlogic.com | no | no | PASS |
| `get pods -n argocd` | owner@zeedlogic.com | no | no | PASS |
| `get secrets -n capsule-system` | owner@zeedlogic.com | no | no | PASS |
| `create deployments -n zeedlogic-dev` | dev@zeedlogic.com | yes | yes | PASS |
| `create pods/exec -n zeedlogic-dev` | dev@zeedlogic.com | yes | yes | PASS |
| `create rolebindings -n zeedlogic-dev` | dev@zeedlogic.com | no | no | PASS |
| `create deployments -n zeedlogic-stg` | dev@zeedlogic.com | yes | yes | PASS |
| `create pods/exec -n zeedlogic-stg` | dev@zeedlogic.com | yes | yes | PASS |
| `create rolebindings -n zeedlogic-stg` | dev@zeedlogic.com | no | no | PASS |
| `get pods -n zeedlogic-prod` | dev@zeedlogic.com | yes | yes | PASS |
| `update deployments -n zeedlogic-prod` | dev@zeedlogic.com | yes | yes | PASS |
| `create pods/exec -n zeedlogic-prod` | dev@zeedlogic.com | yes | yes | PASS |
| `get secrets -n zeedlogic-prod` | dev@zeedlogic.com | yes | yes | PASS |
| `create rolebindings -n zeedlogic-prod` | dev@zeedlogic.com | no | no | PASS |
| `create roles -n zeedlogic-prod` | dev@zeedlogic.com | no | no | PASS |
| `get pods -n jodywan-dev` | dev@zeedlogic.com | no | no | PASS |
| `create serviceaccounts/token -n zeedlogic-dev` | dev@zeedlogic.com | yes | yes | PASS |
| `get pods -n zeedlogic-prod` | viewer@zeedlogic.com | yes | yes | PASS |
| `get secrets -n zeedlogic-prod` | viewer@zeedlogic.com | no | no | PASS |
| `create deployments -n zeedlogic-dev` | viewer@zeedlogic.com | no | no | PASS |
| `get pods -n jodywan-dev` | viewer@zeedlogic.com | no | no | PASS |

## tenant jodywan

| Check | User | Expected | Actual | Result |
|---|---|---|---|---|
| `create deployments -n jodywan-dev` | owner@jodywan.dev | yes | yes | PASS |
| `create rolebindings -n jodywan-dev` | owner@jodywan.dev | yes | yes | PASS |
| `create deployments -n jodywan-stg` | owner@jodywan.dev | yes | yes | PASS |
| `create rolebindings -n jodywan-stg` | owner@jodywan.dev | yes | yes | PASS |
| `create deployments -n jodywan-prod` | owner@jodywan.dev | yes | yes | PASS |
| `create rolebindings -n jodywan-prod` | owner@jodywan.dev | yes | yes | PASS |
| `get secrets -n jodywan-prod` | owner@jodywan.dev | yes | yes | PASS |
| `create clusterroles` | owner@jodywan.dev | no | no | PASS |
| `create clusterrolebindings` | owner@jodywan.dev | no | no | PASS |
| `list namespaces` | owner@jodywan.dev | no | no | PASS |
| `get pods -n zeedlogic-dev` | owner@jodywan.dev | no | no | PASS |
| `get pods -n argocd` | owner@jodywan.dev | no | no | PASS |
| `get secrets -n capsule-system` | owner@jodywan.dev | no | no | PASS |
| `create deployments -n jodywan-dev` | dev@jodywan.dev | yes | yes | PASS |
| `create pods/exec -n jodywan-dev` | dev@jodywan.dev | yes | yes | PASS |
| `create rolebindings -n jodywan-dev` | dev@jodywan.dev | no | no | PASS |
| `create deployments -n jodywan-stg` | dev@jodywan.dev | yes | yes | PASS |
| `create pods/exec -n jodywan-stg` | dev@jodywan.dev | yes | yes | PASS |
| `create rolebindings -n jodywan-stg` | dev@jodywan.dev | no | no | PASS |
| `get pods -n jodywan-prod` | dev@jodywan.dev | yes | yes | PASS |
| `update deployments -n jodywan-prod` | dev@jodywan.dev | yes | yes | PASS |
| `create pods/exec -n jodywan-prod` | dev@jodywan.dev | yes | yes | PASS |
| `get secrets -n jodywan-prod` | dev@jodywan.dev | yes | yes | PASS |
| `create rolebindings -n jodywan-prod` | dev@jodywan.dev | no | no | PASS |
| `create roles -n jodywan-prod` | dev@jodywan.dev | no | no | PASS |
| `get pods -n zeedlogic-dev` | dev@jodywan.dev | no | no | PASS |
| `create serviceaccounts/token -n jodywan-dev` | dev@jodywan.dev | yes | yes | PASS |
| `get pods -n jodywan-prod` | viewer@jodywan.dev | yes | yes | PASS |
| `get secrets -n jodywan-prod` | viewer@jodywan.dev | no | no | PASS |
| `create deployments -n jodywan-dev` | viewer@jodywan.dev | no | no | PASS |
| `get pods -n zeedlogic-dev` | viewer@jodywan.dev | no | no | PASS |

## platform namespaces are invisible to tenants

| Check | User | Expected | Actual | Result |
|---|---|---|---|---|
| `get pods -n argocd` | owner@zeedlogic.com | no | no | PASS |
| `get pods -n argocd` | dev@jodywan.dev | no | no | PASS |
| `get pods -n traefik` | owner@zeedlogic.com | no | no | PASS |
| `get pods -n traefik` | dev@jodywan.dev | no | no | PASS |
| `get pods -n grafana` | owner@zeedlogic.com | no | no | PASS |
| `get pods -n grafana` | dev@jodywan.dev | no | no | PASS |
| `get pods -n capsule-system` | owner@zeedlogic.com | no | no | PASS |
| `get pods -n capsule-system` | dev@jodywan.dev | no | no | PASS |
| `get pods -n metallb-system` | owner@zeedlogic.com | no | no | PASS |
| `get pods -n metallb-system` | dev@jodywan.dev | no | no | PASS |

## Capsule Proxy: each user sees only their own namespaces

| Check | User | Expected | Actual | Result |
|---|---|---|---|---|
| `proxy: get ns` | owner@zeedlogic.com | zeedlogic-dev zeedlogic-prod zeedlogic-stg | zeedlogic-dev zeedlogic-prod zeedlogic-stg | PASS |
| `proxy: get ns` | dev@zeedlogic.com | zeedlogic-dev zeedlogic-prod zeedlogic-stg | zeedlogic-dev zeedlogic-prod zeedlogic-stg | PASS |
| `proxy: get ns` | viewer@zeedlogic.com | zeedlogic-dev zeedlogic-prod zeedlogic-stg | zeedlogic-dev zeedlogic-prod zeedlogic-stg | PASS |
| `proxy: get ns` | owner@jodywan.dev | jodywan-dev jodywan-prod jodywan-stg | jodywan-dev jodywan-prod jodywan-stg | PASS |
| `proxy: get ns` | dev@jodywan.dev | jodywan-dev jodywan-prod jodywan-stg | jodywan-dev jodywan-prod jodywan-stg | PASS |
| `proxy: get ns` | viewer@jodywan.dev | jodywan-dev jodywan-prod jodywan-stg | jodywan-dev jodywan-prod jodywan-stg | PASS |

## Notes

- `create serviceaccounts/token` is expected `yes` for developers: the built-in `edit` role allows it (known risk, see `capsule-argocd-integration.md`).
- `list namespaces` directly against the API server is expected `no` for tenant users. The Capsule Proxy returns their own namespaces instead (last section).
- Real logins from the MacBook (Authentik, kubelogin, one context per user; see `MACBOOK-OIDC-LOGIN.md`) were tested by the user and work.
- Not covered here: quotas, NetworkPolicies and Argo CD behaviour. Test those with real workloads later.
- Known and accepted: through the proxy, owners can list nodes (read-only).
