# LAN address for a cluster app (MetalLB), how it works

- Step 8f in `fresh-install-order.md`. Verified.
- This document explains, in plain terms, how an app gets a private LAN address with MetalLB, and a NetworkPolicy that limits who may use it.
- It is used twice, both for the central Grafana on docker-2: the Thanos Querier (`10.1.5.172`) and Loki (`10.1.5.173`).

## The problem

Apps in the cluster have addresses that only exist inside the cluster (`10.233.x.x`). A server outside it, such as
docker-2 (`10.1.5.123`), cannot reach them. There are three ways to let it in:

| Way | What it is | Good for |
|---|---|---|
| Traefik + HAProxy (`headlamp`, `garage-k8s`, `grafana-k8s`) | a hostname, TLS, optionally public | apps with their own login |
| `kubectl port-forward` | a temporary tunnel from one machine | quick tests |
| **A LAN address from MetalLB (this document)** | the app gets its own `10.1.5.x` address | a private service for known servers |

The Thanos Querier has no login and returns every metric, so it must not be on the public path. A LAN address
that only docker-2 may use fits.

## The parts

```
 docker-2 Grafana                         k8s-1 cluster
 (10.1.5.123)
      |
      |  http://10.1.5.172            1. MetalLB announces 10.1.5.172 on the LAN
      v                                  (one node answers for it)
 ┌──────────────────┐                 2. Service "thanos-query-lan" (type LoadBalancer)
 │ 10.1.5.172 : 80  │ ------------>      forwards port 80 to the pod's port 10902
 └──────────────────┘                 3. NetworkPolicy "thanos-query-ingress"
                                         lets in: docker-2, and the monitoring namespace
                                      4. Thanos Querier pod (thanos-query)
```

| Part | What it does | Where it is defined |
|---|---|---|
| **MetalLB** | gives a `LoadBalancer` Service a real LAN address from the pool `10.1.5.170-180` and announces it (layer 2: it answers ARP for the address from one node) | the `metallb` and `metallb-config` apps (`base/metallb/`, `overlays/k8s-1/metallb-config/`); the pool and the announcement are cluster settings |
| **Service of type `LoadBalancer`** | Kubernetes's "give this app an address outside the cluster"; here `thanos-query-lan`, port 80 to the pod's `http` port (10902) | `extraManifests` in `overlays/k8s-1/kube-prometheus-stack/values.yaml` |
| **Annotation `metallb.universe.tf/loadBalancerIPs: 10.1.5.172`** | pins the address, so it does not change. MetalLB also accepts the newer prefix `metallb.io/loadBalancerIPs` (Capsule Proxy uses it) | same Service |
| **`externalTrafficPolicy: Local`** | keeps the caller's own IP instead of replacing it with a node's IP, so the policy can tell docker-2 from other callers | same Service |
| **NetworkPolicy** | a firewall around the pod: once a policy selects a pod, everything it does not allow is refused. Enforced by Calico | same file, `thanos-query-ingress` |
| **DNS name** (optional) | `thanos-query-k8s.jodywan.com` -> `10.1.5.172`, only for readability | pfSense host override or Cloudflare |

"LoadBalancer" is only the Kubernetes name of this Service type. It does not mean traffic is balanced across
several pods (there is one Querier pod). Traefik (`10.1.5.170`) and Capsule Proxy (`10.1.5.171`) use the same
type, which is why they have LAN addresses too.

## What a request does

1. docker-2 sends `GET http://10.1.5.172/api/v1/query?...`.
2. The packet arrives at the node that MetalLB chose to answer for `10.1.5.172`. With `externalTrafficPolicy:
   Local` that must be a node that runs the Querier pod; MetalLB moves the address if the pod moves.
3. Calico checks the NetworkPolicy: the source is `10.1.5.123`, which is on the allow list, so it passes. A packet
   from any other address is dropped and the caller waits until it times out.
4. The Querier answers (it asks the Prometheus sidecar for the last 12 h and the Store Gateway for older data).

## Set it up for another app (the recipe)

1. **Pick a free address.** `kubectl get svc -A | grep LoadBalancer` lists those in use (the table "Addresses in use" below). The pool is `.170` to `.180`.
2. **Add a Service** of type `LoadBalancer` that selects the app's pods, with the annotation
   `metallb.universe.tf/loadBalancerIPs: <address>` and `externalTrafficPolicy: Local`.
3. **Add a NetworkPolicy** for the same pods that allows the namespace's own pods and the caller's `ipBlock`
   (`/32`). Without a policy, any host on the LAN can use the address.
4. **Test** from the allowed host (works) and from another host (does not).
5. **Document it** in the app's doc and in the table of used addresses (below).

## Addresses in use

| Address | What | Pinned by |
|---|---|---|
| `10.1.5.170` | Traefik | MetalLB default pool |
| `10.1.5.171` | Capsule Proxy | MetalLB default pool |
| `10.1.5.172` | Thanos Querier (`thanos-query-lan`), allowed: `10.1.5.123` and the `monitoring` namespace | annotation, `overlays/k8s-1/kube-prometheus-stack/values.yaml` |
| `10.1.5.173` | Loki (`loki-lan`), allowed: `10.1.5.123`, and the namespaces `loki`, `fluent-bit`, `monitoring` | annotation, `overlays/k8s-1/loki/values.yaml` (`extraObjects`) |

## How to check it

```bash
# 1. the Service got its address (EXTERNAL-IP must be 10.1.5.172, not <pending>)
kubectl -n monitoring get svc thanos-query-lan

# 2. the policy exists and selects the Querier
kubectl -n monitoring get networkpolicy thanos-query-ingress

# 3. from docker-2: must print "Thanos Query is Ready."
curl http://10.1.5.172/-/ready

# 4. from any other host (for example control-plane-1): must hang or fail, then press Ctrl+C
curl -m 8 http://10.1.5.172/-/ready
```

`./tests/thanos.sh` checks the Service, the policy, the traffic policy, and that the host it runs on is refused.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `EXTERNAL-IP` stays `<pending>` | the address is taken by another Service, or MetalLB is unhealthy: `kubectl -n metallb-system get pods`, `kubectl -n monitoring describe svc thanos-query-lan` |
| works from other hosts too | the policy is not applied or does not select the pods: `kubectl -n monitoring describe networkpolicy thanos-query-ingress`; also check `externalTrafficPolicy` is `Local` (with `Cluster` the source IP is lost) |
| docker-2 gets no answer | docker-2 is not on `10.1.5.0/24`, or its address differs from `10.1.5.123`; check `ip addr` on docker-2 and the `ipBlock` in the values |
| answers only after a long wait, then fails | the pod is on a node MetalLB does not announce from; with `Local` the address follows the pod, give it a minute after a restart |
| the name does not resolve | use the IP in the data source; check the DNS record; a Docker container ignores the host's `/etc/hosts` |

## Security notes

- The address is **private**: nothing is published to Cloudflare or HAProxy for it. A DNS name pointing to a
  private address reveals the address only.
- The Querier has **no authentication**; the policy is the control. Anything that can use `10.1.5.123`'s address
  (another container on docker-2, for example) can read all metrics.
- **What "limited to 10.1.5.123" means exactly:** the cluster decides by the packet's source IP address (Calico
  `ipBlock`). It is a network control, not a login. A host that can send packets with docker-2's address (an
  attacker on the same network segment who spoofs it, or another container or process on docker-2 itself) is
  treated as docker-2. That is acceptable for a read-only API on a trusted LAN; it is not enough for anything that
  must be protected from the LAN itself.
- The traffic is plain HTTP on the LAN. Acceptable for a read-only metrics API on a trusted network; use the
  Traefik and HAProxy path (TLS, whitelist) if that changes.
- This is the first NetworkPolicy in the cluster. It only selects the `thanos-query` pods. The wider rollout
  (default-deny per tenant namespace, ingress limits on the platform namespaces, a Calico guard for nodes and the
  LAN) was done: `tenant-network.md`.

## Undo

Remove `thanos-query-lan` and `thanos-query-ingress` from `extraManifests`, push, and delete the data source in
the docker-2 Grafana. The address returns to the pool. `prune: false` means Argo CD will not delete them by
itself: `kubectl -n monitoring delete svc thanos-query-lan` and
`kubectl -n monitoring delete networkpolicy thanos-query-ingress`.

## Status

Applied and verified:

| Test | Result |
|---|---|
| Service `thanos-query-lan` | got `10.1.5.172`, `externalTrafficPolicy: Local` |
| From docker-2 (`10.1.5.123`) | `GET /-/ready` HTTP 200; `count(up)` query returns data |
| From control-plane-1 (`10.1.5.151`) | no answer, `curl` timed out after 8 s (exit 28) |
| From a pod in namespace `default` | blocked |
| From a pod in namespace `monitoring` | HTTP 200 |

So the policy sees the real source IP and only docker-2 and the `monitoring` namespace get through.

The same checks for Loki (`10.1.5.173`):

| Test | Result |
|---|---|
| Service `loki-lan` | got `10.1.5.173`, `externalTrafficPolicy: Local` |
| From docker-2 | `GET /ready` HTTP 200; the `Loki K8s-1` data source in its Grafana is healthy |
| From control-plane-1 and from a pod in `default` | no answer (timeout) |
| Fluent Bit, which must still push to Loki | `./tests/fluent-bit.sh` 11 of 11; 0 errors, 0 retries, 0 dropped records |
