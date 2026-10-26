# Tenant guardrails (what a tenant may create)

- Part 4 of the tenant gate. Step 7a in `fresh-install-order.md`. Built and tested.
- Built with **Capsule's own Tenant fields and Kubernetes Pod Security Admission**, not a policy engine: they are already installed, enforced for owners too, and tenant users cannot edit the Tenant object. Image rules are Gatekeeper (`gatekeeper.md`).
- Test: `tests/tenant-guardrails.sh` (88 checks).

## 1. Why it matters

Before this change a tenant developer **and** an owner could create a privileged pod, mount the node's `/` with
`hostPath`, use `hostNetwork` or `hostPID` or add `SYS_ADMIN`. A pod like that is root on the node, and nodes hold the
kubelet and, on control planes, the etcd certificates: a path to the whole cluster. Network policies do not stop it.
Tenant namespaces had no Pod Security labels.

## 2. What is enforced now

| Control | Setting | Effect |
|---|---|---|
| **Pod Security Admission** `baseline` (enforce), `restricted` (warn and audit) | namespace labels from the Tenant (`namespaceOptions.additionalMetadata.labels`) | refuses privileged containers, hostPath, hostNetwork, hostPID, hostIPC, hostPorts and extra capabilities; users get a warning for what `restricted` would refuse |
| **Service types** | Tenant `serviceOptions.allowedServices`: LoadBalancer, NodePort, ExternalName all `false` | tenants cannot take a MetalLB address or a node port; they publish through Traefik (HTTPRoute) |
| Ingress class | Tenant `ingressOptions` (`traefik` only), earlier | other Ingress classes refused |
| **Ingress hostnames** | ValidatingAdmissionPolicy `tenant-ingress-not-platform-hosts` (`tenant-baseline/ingress-platform-hosts-policy.yaml`) | tenants may use **any** hostname (no per-tenant patterns) except the platform's own, and may not use a rule without a host or a defaultBackend. Before this a tenant Ingress for `grafana-k8s.jodywan.com` was accepted: Traefik serves both from one entry point, so it could have intercepted or phished a platform login |
| **Pods stay off the control planes** | ValidatingAdmissionPolicy `tenant-pods-stay-on-workers` (`tenant-baseline/pod-placement-policy.yaml`, app `tenant-baseline`) on every namespace that belongs to a tenant | refuses `spec.nodeName` on create and any toleration of a `node-role.kubernetes.io/*` taint or a catch-all toleration; ordinary tolerations and updates still work |
| Quota | Tenant `resourceQuotas` (CPU and memory limits, pods), earlier | pods without `limits.cpu` refused |
| Network | `tenant-network.md`, earlier | default-deny and platform ingress limits |

Capsule's Tenant `nodeSelector` was tried first and does **not** work here: it relies on the `PodNodeSelector` admission
plugin, which this API server does not run (only `NodeRestriction`), so the annotation Capsule sets is ignored.
Enabling the plugin needs an API server flag change and restart; the admission policy needs neither.

Verified for a developer and an owner of each tenant (checks in `tests/tenant-guardrails.sh`): privileged, hostPath, hostNetwork, hostPID, hostIPC,
hostPort, SYS_ADMIN/NET_ADMIN, LoadBalancer, NodePort and ExternalName are refused; a normal restricted pod and a
ClusterIP Service are allowed. The labels are what blocks it: the same privileged pod is accepted in an unlabelled
namespace.

## 3. Known gaps (reported by the test, not failures)

| Gap | Impact | Fix (needs a decision) |
|---|---|---|
| A container may run as **root (uid 0)** | baseline allows it; root in a container without privileges and without host access is contained | enforce `restricted` instead of `baseline` when tenants' images are ready for it; the warnings show which pods would fail |
| Images from **any registry** | supply chain and data exfiltration surface | **accepted** (tenants may use any registry). Tenant `containerRegistries.allowed` is the control if that changes |
| **`:latest`** tags | not reproducible | a policy engine (Gatekeeper, `gatekeeper.md`) or review; Capsule has `imagePullPolicies` only |
| A NetworkPolicy that **opens egress to everything** (can still be created) | harmless to the platform: nodes, the LAN and node ports are denied by the Calico policy `tenant-egress-guard`, and platform services refuse tenant pods themselves | none needed; the pod can only reach the internet and its own namespace |

## 4. Hostname policy: accepted choice and its limit

Tenants may claim any hostname, including names under `jodywan.com` and each other's domain (`hostnameCollisionScope`
is still `Disabled`): two tenants could claim the same name and the later or longer rule wins in Traefik. That is
accepted for now. The platform list is exact names; add a platform hostname to the policy when one is published.
If tenants start using real domains, switch to per-tenant patterns (Tenant `ingressOptions.allowedHostnames` and
`hostnameCollisionScope: Cluster`).

## 5. Operate

```bash
./tests/tenant-guardrails.sh        # about 2 minutes, dry runs only
kubectl get ns -l capsule.clastix.io/tenant -o custom-columns=NAME:.metadata.name,ENFORCE:.metadata.labels.pod-security\\.kubernetes\\.io/enforce
```

The Tenant objects are applied from `overlays/k8s-1/tenants/tenant-*.yaml` by the Argo CD app `tenants`. To change a guardrail, edit the Tenant file and merge.

A tenant workload that needs more than `baseline` (rare) is a platform decision: it must not be solved by removing the
label (owners cannot).
