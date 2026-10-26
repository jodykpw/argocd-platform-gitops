# Gatekeeper (OPA)

- Admission policy for what Capsule, Pod Security and ValidatingAdmissionPolicy do not cover. Step 8k in `fresh-install-order.md`.
- It replaced Kyverno: the platform keeps one policy language with Azure Policy for AKS, which is Gatekeeper underneath, so Rego templates are shared between k8s-1 and AKS.
- Status: applied; both Constraints are in `deny`.
- Test: `tests/gatekeeper.sh` (16 checks; 18 with `RESILIENCE=1`).

## 1. What is deployed

| Piece | Where | Notes |
|---|---|---|
| Chart `gatekeeper/gatekeeper` 3.23.1 (app v3.23.1) | `appsets/gatekeeper.yaml`, `base/gatekeeper/`, `overlays/k8s-1/gatekeeper/` | namespace `gatekeeper-system`, Pod Security `restricted`, auto-sync, `prune: false` |
| Controller manager (admission webhook) | 3 replicas, PodDisruptionBudget `minAvailable: 2` | the only part on the request path |
| Audit | 1 replica, every 60 s | results in the Constraint `status.violations` |
| Mutation | **off** (`disableMutation`) | not used |
| ConstraintTemplates | `gatekeeper-policies/*.template.yaml` | Rego, sync wave 0 |
| Constraints | `gatekeeper-policies/tenant-image-*.yaml` | sync wave 1, `deny` (0 violations in `dryrun`) |

## 2. The rules

| Constraint | Rule | Scope |
|---|---|---|
| `tenant-image-tags` (`TenantImageTags`) | no `:latest`, no untagged image; a digest is accepted | Pods (init and ephemeral containers too) in namespaces with the label `capsule.clastix.io/tenant` |
| `tenant-image-registries` (`TenantImageRegistries`) | image host in `docker.io`, `index.docker.io`, `registry-1.docker.io`, `ghcr.io`, `registry.k8s.io`, `gitlab-registry.jodywan.com`, `quay.io`; no host means Docker Hub | same |

The registry host is the first path segment when it holds a `.` or `:` or is `localhost`. To add a registry, add it to
`parameters.registries` in `gatekeeper-policies/tenant-image-registries.yaml` and to this table.

## 3. Failure behaviour (fail closed)

- `validatingWebhookFailurePolicy: Fail`: while Gatekeeper is down, Pods cannot be created in a namespace the webhook
  covers.
- The webhook only receives **Pod CREATE and UPDATE** (`validatingWebhookCustomRules`).
- The chart cannot select "tenant namespaces only" for the webhook, so every **platform namespace is exempted by name**
  in `overlays/k8s-1/gatekeeper/values.yaml` (`validatingWebhookExemptNamespacesLabels`). Left to the webhook: the
  tenant namespaces and `default`.

### Adding a namespace

A new **platform** namespace must be added to that exemption list in the same change that creates it. Otherwise an
outage of Gatekeeper blocks that namespace's pods, and the namespace is also checked against the Constraints only if it
carries the tenant label (so no wrong refusals, only the outage risk). Tenant namespaces need nothing.

## 4. Rollout (the order for a rebuild)

1. **Sync** the `gatekeeper` app (needs `bootstrap/platform-project.yaml` applied first: the chart repo is in
   `sourceRepos`). Start both Constraints in `dryrun`.
2. `./tests/gatekeeper.sh`, then read the audit:
   `kubectl get tenantimagetags,tenantimageregistries -o custom-columns=NAME:.metadata.name,VIOLATIONS:.status.totalViolations`.
   Expect 0.
3. Change `enforcementAction` to `deny` in both Constraints, push, sync; repeat the test (it checks the mode).
4. `RESILIENCE=1 ./tests/gatekeeper.sh` (deletes one controller-manager pod while a tenant pod is admitted).

## 5. Gotchas

- **A Constraint kind exists only after its template is compiled.** The app applies templates in wave 0 and Constraints
  in wave 1 with `retry`; a first sync that shows the Constraints `OutOfSync` for a minute is normal.
- **Rego is checked by Gatekeeper, not by Git.** The templates are plain v0 Rego with no imports (Gatekeeper refuses `import rego.v1`). `kubectl get constrainttemplate
  <name> -o jsonpath='{.status.byPod[*].errors}'` shows compile errors. `tests/gatekeeper.sh` fails step 2 on them.
- **Audit sees running Pods too**: a violation on a pod that already existed shows in `status.violations` (the first
  20 in the chart default; the chart value is `constraintViolationsLimit: 100`).
- **The webhook needs the node tunnel addresses** reachable like other webhooks (`tenant-network.md`); platform
  namespaces have no default-deny, so nothing to add today.
- If creates are stuck, look at `kubectl get validatingwebhookconfiguration | grep gatekeeper` first; deleting the Constraint (not the webhook) lifts a wrong refusal.

## 6. Test

`./tests/gatekeeper.sh`: controllers ready, no restarts, CRDs and templates compiled, constraints enforced, `:latest`
and an unapproved registry reported (dryrun) or refused (deny), a pinned approved image admitted, `default` untouched;
`RESILIENCE=1` for the replica loss.

Refusals come from `validation.gatekeeper.sh` and name the Constraint (`[tenant-image-tags]`, `[tenant-image-registries]`).
