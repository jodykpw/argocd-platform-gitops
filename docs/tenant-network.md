# Tenant network isolation (NetworkPolicies)

- Part 1 of the tenant gate. Step 7a in `fresh-install-order.md`. Built and tested.
- Files: `tenant-baseline/`, the app `tenant-baseline` (`appsets/tenant-baseline.yaml`).
- Test: `tests/tenant-network.sh` (46 checks, checked 2026-10-18).
- The consolidated "who can do what" tables for all roles are in `tenant-access-model.md`.

## 1. Why

Before this, a pod in a tenant namespace could reach Prometheus, Alertmanager, Grafana, the Kubernetes API, TrueNAS
NFS, the backup Garage, the Capsule Proxy, the other tenant and the rest of the LAN. Only Loki, the Thanos Querier,
Jaeger and a few Argo CD parts already refused (they have their own policies). Calico enforces NetworkPolicy here.

## 2. Two layers

| Layer | Where | What | Who can change it |
|---|---|---|---|
| **Tenant baseline** | every namespace of every tenant, from one Capsule `GlobalTenantResource` (`scope: Namespace`, all tenants) | default-deny (ingress and egress), then allow: own namespace, DNS (CoreDNS and NodeLocal DNS `169.254.25.10`), internet addresses only (not `10/8`, `172.16/12`, `192.168/16`, `100.64/10`, `169.254/16`); inbound from Traefik and from Prometheus pods | platform admin only: Capsule's `replications` webhook refuses update and delete by tenant owners (tested) |
| **Platform ingress** | platform namespaces without a narrower policy (`garage`, `headlamp`, `velero`, `nfs-provisioner`, `fluent-bit`, most of `monitoring`) and `traefik` | `refuse-tenant-ingress`: allow only namespaces without a `capsule.clastix.io/tenant` label, and every source address outside the pod network, plus the node tunnel addresses (below). `traefik` also lets anyone reach its entry points 8000 and 8443 | platform admin (plain NetworkPolicies) |

Why two: tenant owners may add NetworkPolicies of their own (the baseline cannot stop that), for example to open
egress. The platform side then still refuses them.

## 3. What a tenant pod can do now

Resolve DNS, reach the internet, reach pods of its **own namespace** only. **Not** the other environments of its own
tenant (dev, stg and prod are separate on purpose), not the other tenant, no platform service, no API server, no LAN
address. Inbound: from pods of its namespace, Traefik and Prometheus.

To let two namespaces of one tenant talk, or to reach a platform service, the owner needs a platform decision (a
policy on the destination side), not only an egress policy of their own.

A worked example is the tenant database: `jodywan-dev` may reach `jodywan-dev-pg` in the platform namespace `databases` on 5432 and nothing else there. The platform adds the egress rule in the tenant namespace and the ingress rule on the database pods, and every other tenant namespace stays refused (`databases.md`). A database cannot run **inside** a tenant namespace, because its pods would need the Kubernetes API and the operator would need to reach them, which this baseline and the Calico guard forbid.

## 4. Calico guard `tenant-egress-guard`

A tenant owner can add NetworkPolicies, including one that opens egress. The Calico policy sits in front of those (order 10)
and denies the nodes, the LAN and the tunnel addresses for every namespace that belongs to a tenant. The tunnel address list
is the same one as in `platform-ingress.yaml`: **update both when a node is added or rebuilt** (section C of the test
checks the platform side; look at this file too). Rollback: `kubectl delete globalnetworkpolicy tenant-egress-guard`.

## 5. Node tunnel addresses (important)

The Kubernetes API server (webhooks, `kubectl logs`/pod proxy) and other node-originated traffic reach pods from the
node's Calico VXLAN tunnel address, which is **inside the pod network** (`10.233.64.0/18`) that the platform
policies exclude. They are therefore listed as `/32` entries (annotation `projectcalico.org/IPv4VXLANTunnelAddr`):

| Node | Address |
|---|---|
| control-plane-1 | 10.233.108.128 |
| control-plane-2 | 10.233.101.192 |
| control-plane-3 | 10.233.89.0 |
| worker-node-1 | 10.233.84.192 |
| worker-node-2 | 10.233.83.128 |
| worker-node-3 | 10.233.108.192 |

**When a node is added or rebuilt its address changes**: update `tenant-baseline/platform-ingress.yaml`. Section C of
`tests/tenant-network.sh` compares the list with the nodes and fails if it is out of date. Without the right address
the API server cannot reach pods that carry these policies (webhooks and pod proxy fail). This showed up on first
rollout: `tests/thanos.sh` could not read the compactor.

## 6. Not covered (accepted or known)

| Item | State |
|---|---|
| Argo CD server | its chart policy allows any source (SSO login). Reachable from a tenant pod only if the owner opens egress |
| Node ports (kubelet 10250, node-exporter 9100, etcd metrics 2381, scheduler 10259) and the LAN | **closed** by the Calico `GlobalNetworkPolicy` `tenant-egress-guard` (`tenant-baseline/tenant-egress-guard.yaml`): it denies, ahead of any tenant policy and where owners cannot edit it, egress from tenant namespaces to every private and link-local range except the cluster's own networks (pod `10.233.64.0/18`, service `10.233.0.0/18`) and NodeLocal DNS, and to the node tunnel addresses. It only denies, so it cannot open anything. Tested with an owner's open-egress policy in place |
| Tenant owner opens egress | possible and visible: with Gatekeeper (a Constraint, not yet written) a rule can refuse egress to private ranges in tenant NetworkPolicies |

## 7. Tenant workloads need CPU limits

Each tenant has a ResourceQuota (`capsule-<tenant>-0`) that requires `limits.cpu` on every pod: a pod without it is
refused (`must specify limits.cpu`). The test pods set it. Tell tenant teams.

## 8. Operate

```bash
./tests/tenant-network.sh                 # 46 checks, about 2 minutes, temporary pods only
kubectl get networkpolicy -A -l app.kubernetes.io/part-of=tenant-network-gate   # platform side
kubectl get globaltenantresource network-baseline                               # tenant side
kubectl -n zeedlogic-dev get networkpolicy                                      # what a tenant namespace has
```

Change a tenant policy: edit `tenant-baseline/network-baseline.yaml`, push; Capsule replicates within the
`resyncPeriod` (60 s). Removing a policy from the file does not delete it from namespaces until `pruningOnDelete`
runs on deletion of the whole resource: delete it by hand after review (and ask first).

## 9. Rollback

`kubectl delete globaltenantresource network-baseline` removes the baseline (`pruningOnDelete: true`), and
`kubectl delete networkpolicy -A -l app.kubernetes.io/part-of=tenant-network-gate` removes the platform side.
