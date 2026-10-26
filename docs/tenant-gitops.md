# Tenant GitOps (Argo CD for tenants)

- Argo CD for tenants: how a tenant deploys with Argo CD, as its own deployer account. Step 10 in `fresh-install-order.md`.
- The consolidated "who can do what" tables for all roles and both tools are in `tenant-access-model.md`.
- Status: **applied** and tested (`tests/tenant-gitops.sh`, 53 checks). The first real tenant application is synced: `zeedlogic/gitops/sample-app` into `zeedlogic-dev`, project `zeedlogic-nonprod` (sample in `examples/tenant-sample-app/`).
- Files: `tenant-gitops/`, `tests/tenant-gitops.sh`, `tests/fixtures/tenant-app/`.

Two things to know:

- Capsule creates the deployers' RoleBindings a few seconds after the patch, so a test run in the same second can fail with `no`; run it again after about 30 s.
- Every Capsule user, these accounts included, holds `create namespaces` through Capsule's namespace-provisioner role. The limits are Capsule's webhook (the tenant prefix is forced, quota of 3 namespaces) and the AppProject (no Namespace kind); the test checks the refusals.
- The Argo CD Helm values carry the two impersonation settings (`configs.cm."application.sync.impersonation.enabled"` and `...enforced`), so a Helm upgrade of Argo CD does not drop them.

## 1. Decisions

| # | Decision | Value |
|---|---|---|
| 1 | Prod deployment | auto-sync is allowed, and developers deploy to prod like owners. Protection is GitLab's: protect `main`, require a merge request and approval |
| 2 | Repos | each tenant has a GitLab group and creates as many repos and access tokens as it likes. Group path **decided**: a top-level GitLab group per tenant, `https://gitlab.jodywan.com/zeedlogic/**` and `.../jodywan/**`, with subgroups and repos below it (`**` matches any depth; a single `*` stops at `/`, found when `zeedlogic/gitops/sample-app` was refused); one line per AppProject. The groups still have to be created in GitLab |
| 3 | How Argo CD deploys into tenants | **Option B**: sync impersonation, one deployer ServiceAccount per tenant in the `argocd` namespace. Option A (see `cluster/capsule-argocd-integration.md`) is not used because it would make the shared controller a Capsule user, and the same controller creates the namespaces of nine platform apps |
| 4 | Applications | self-service: tenant owners (and nonprod developers) create them in the Argo CD UI or CLI inside their project |
| 5 | Roles and RoleBindings | **owners only, with kubectl or helm. Never through Argo CD**: not in the AppProject allowlist, and the deployer account is only `edit`, so Kubernetes refuses them too. Developers never |

## 2. Moving parts

| Piece | What | Where |
|---|---|---|
| Deployer accounts | `argocd-deployer-zeedlogic`, `argocd-deployer-jodywan` (ServiceAccounts, namespace `argocd`). Not people, nobody logs in as them. Argo CD applies a tenant's manifests as that tenant's account | `tenant-gitops/deployers.yaml` |
| Capsule | each account is a Capsule *user* and an *owner* (clusterRole `edit`) of **its own tenant only** | `register-deployers.sh` steps 2 and 3 (and `overlays/k8s-1/capsule/values.yaml`, `overlays/k8s-1/tenants/tenant-*.yaml`) |
| AppProjects | per tenant `<t>-nonprod` (dev, stg) and `<t>-prod` | `tenant-gitops/appprojects.yaml` |
| Argo CD setting | `application.sync.impersonation.enabled: "true"`, `enforced: "false"` | `register-deployers.sh` step 4 |

`enforced: false` is what keeps the platform apps unchanged: projects with no `destinationServiceAccounts` (the
`platform` project) keep using the controller.

## 3. What each person can do

| | owners | developers | viewers |
|---|---|---|---|
| create, edit, delete, sync applications in nonprod (dev, stg) | yes | yes | no |
| create, edit, delete, sync applications in prod | yes | **yes** | no (view) |
| add repositories and tokens (project-scoped) | yes | yes | no |
| logs / exec | logs + exec | logs + exec | logs (`zeedlogic`: nonprod only; `jodywan`: also prod), no exec |
| projects, clusters, accounts, other tenant's anything, Roles and RoleBindings | no | no | no |

Applications are named by their creator, so prod is kept apart by the **separate project** (it can only target
`<t>-prod`), not by a naming convention. The protection for production is GitLab: protect `main` and require a merge
request and approval.

## 4. Why a tenant cannot reach another tenant's repositories or settings

- Repositories are **project-scoped** and RBAC is `repositories, <action>, <project>/*`: a tenant sees and uses only
  the repositories of its own projects; tokens are never returned by the API.
- Tenants have no permission on projects, clusters, accounts, certificates or the AppProject itself.
- `sourceRepos` is the tenant's GitLab group (no platform repo) and, for `zeedlogic`, its one Harbor project `harbor.jodywan.com/zeedlogic` (released Helm charts; `tests/tenant-gitops.sh` accepts exactly that path and nothing wider). The destinations are the tenant's namespaces.
- Even if an AppProject were wrong, the deployer account is an owner of its own tenant only: Kubernetes and Capsule
  refuse anything in another tenant (tested, `tests/tenant-gitops.sh` section D).
- **GitLab group location matters:** the platform credential template `gitlab-group-creds` matches every URL under
  `https://gitlab.jodywan.com/servers/pcls.jodywan.com/`. Put the tenant groups **outside** that path.

## 5. Roles and RoleBindings: owners only (kubectl and helm, no Argo CD)

Decided: **only tenant owners create and change Roles and RoleBindings**, in all of their own namespaces
(dev, stg, prod). Developers cannot, in any namespace; viewers cannot. This is what the `admin` role already gives
owners, so nothing extra is installed. (A developer self-service role was tried and removed.)

An owner gives developers rights by creating a Role and a RoleBinding. Example tested in `tests/tenant-rbac.sh`:
the owner creates `app-deployer` (deployments, services, configmaps) in `<tenant>-prod` and binds it to the
developers group; the developers can then deploy those kinds there, still cannot touch secrets or RBAC, and lose
the rights when the owner deletes the Role.

| Who | Roles and RoleBindings in |
|---|---|
| owners | their own dev, stg and prod |
| developers | nowhere |
| viewers | nowhere |

An owner cannot hand out more than an owner holds: a binding to `cluster-admin` is refused. Rights never cross
tenants. Test: `tests/tenant-rbac.sh` (60 checks).

## 6. Roles and RoleBindings and Argo CD

Argo CD deploys workloads, Rollouts, Services, ConfigMaps, Secrets, and `SecretStore` and `ExternalSecret` of External Secrets (`external-secrets.md`; the cluster-wide kinds are not allowed). It does **not** deploy Role or RoleBinding:

- they are not in the AppProject allowlist (a Role in a repo makes the sync fail with "not permitted in project"),
- and the deployer account holds only `edit`, which Kubernetes does not allow to create Roles or RoleBindings, so
  even a wrong AppProject could not deploy them.

The owner creates and edits Roles and RoleBindings with `kubectl` or `helm` (section above). A developer therefore
can never raise their own rights through Git, and Argo CD's own project roles (who may sync what) are edited by the
platform team only, never by tenants.

## 7. Apply (a person runs it)

```bash
cd ~/kubernetes/platform-gitops
./tenant-gitops/register-deployers.sh            # dry run
./tenant-gitops/register-deployers.sh --apply    # ServiceAccounts, Capsule users and owners, argocd-cm, AppProjects
./tests/tenant-gitops.sh                         # A to C
E2E=1 ./tests/tenant-gitops.sh                   # D: real syncs in temporary projects (fixture must be pushed)
```

Rollback: delete the AppProjects, remove the two owner and user entries, set `application.sync.impersonation.enabled`
back to `"false"` and restart `argocd-application-controller`.

## 8. Open

- A GitLab token expiry reminder (group access tokens expire, one year at most) and an alert for failed syncs.
- Per-tenant traces and OTLP (Jaeger has no tenancy); metrics and logs are done (`tenant-observability.md`).
