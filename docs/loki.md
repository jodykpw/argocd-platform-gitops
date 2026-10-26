# loki: log store

- Layer 1, managed by Argo CD (`argocd-gitops.md`, "Logging: Fluent Bit + Loki"). Step 8a in `fresh-install-order.md`.
- Fluent Bit (`fluent-bit.md`) ships logs to it. The cluster Grafana (data source `Loki`) and the Grafana on docker-2 (`Loki K8s-1`) read from it.
- Test: `tests/loki.sh` (16 checks).

## 1. At a glance

| Item | Value |
|---|---|
| Chart | `loki` 7.3.0 (app 3.6.x), repo `https://grafana.github.io/helm-charts` |
| Mode | `SingleBinary`, 1 replica, filesystem storage (TSDB index v13), no gateway, no caches, no canary |
| Namespace | `loki` (Pod Security `baseline`) |
| Endpoint | `http://loki.loki.svc.cluster.local:3100` (ClusterIP, no route, no UI) |
| Storage | one 10 GiB volume, class `longhorn` (2 replicas = 20 GiB raw); the PVC is kept when the StatefulSet goes |
| Retention | 168 h (7 days), enforced by the compactor |
| Tenants | `auth_enabled: true`: every request needs `X-Scope-OrgID`. Tenants: `zeedlogic`, `jodywan`, `platform` |
| Resources | request 100m / 512Mi, limit 1Gi memory |
| Argo CD | ApplicationSet `loki`, auto-sync, `prune: false`, no self-heal |
| Files | `appsets/loki.yaml`, `base/loki/values.yaml`, `overlays/k8s-1/loki/values.yaml` |

## 2. Design choices

- **Single binary.** Loki's scalable modes need object storage and several pods; this cluster has 3 workers and light log volume. One pod is enough, and it is easy to move to Garage S3 chunks later (change `loki.storage` and the schema `object_store`, add a new `from:` date; never edit an existing schema period).
- **Filesystem on Longhorn, not NFS.** Loki's index and chunks need a real block volume (`storage-nfs.md`).
- **Multi-tenant from the start.** Retrofitting tenants later means re-labelling old data. A tenant is the Capsule tenant name; everything outside a tenant (kube-system, argocd, longhorn-system, ...) is `platform`. Grafana gets one data source per tenant (header `X-Scope-OrgID`), and a platform-team data source with `X-Scope-OrgID: platform|zeedlogic|jodywan` (`multi_tenant_queries_enabled: true`).
- **Loki has no authentication of its own.** The tenant header is not a credential: any pod that can reach `loki.loki.svc:3100` can read any tenant by setting the header. So `loki-ingress` limits Loki to `loki`, `fluent-bit`, `monitoring` and `10.1.5.123` (section 4), and the tenant namespaces have a default-deny baseline of their own (`tenant-network.md`). Tenants read logs only through Grafana: each tenant organization has a read-only `Loki` data source that sends its own `X-Scope-OrgID` (`tenant-observability.md`).
- **The PVC survives deletion.** `whenDeleted: Retain`, `whenScaled: Retain`, auto-delete off; the Longhorn class is also `Retain`. Removing the app by mistake does not remove the logs.
- **Pinned to 7 days** because the volume is budgeted at 10 GiB (`storage-longhorn.md`). Raise `retention_period` and the volume together (`persistence.size`, then expand the PVC; Longhorn allows it).

### Why single binary on the filesystem, and when to change

| Question | Answer for k8s-1 |
|---|---|
| Would Garage use less storage? | No. Garage is a single node on a Longhorn volume (2 replicas), so the raw cost is the same. Loki chunks are already compressed, so Garage's compression gains almost nothing |
| Is Garage a good place for chunks? | Not yet. It adds a dependency (Loki is down when Garage is down), and Garage's 30 Gi is shared with Thanos |
| Would scalable mode help? | No. It needs object storage (Garage becomes a hard dependency), several pods plus caches, and the single-node Garage would remain the single point of failure. The chart says single binary suits up to "a few tens of GB/day" |
| Why not a multi-node Garage? | 3 nodes with Longhorn replicas is 6 copies of every byte, and 3 x 30 Gi would take almost the whole 205 GiB pool. Same Proxmox failure domain anyway (`storage-garage.md`) |
| Resource limits | The platform has little spare memory; one pod with a 1 Gi limit is the cheapest option that works |

**Downsides accepted:** one pod is a single point of failure (a gap in logs while it restarts or the volume re-attaches; Fluent Bit buffers and retries); only vertical scaling; heavy queries compete with ingestion; no chunk or result cache.

**Move to object storage and/or scalable mode when** (check in Grafana):

- the pod is `OOMKilled` even after raising the limit to 2 to 4 Gi;
- ingest is sustained at tens of GB/day, or queries are slow while ingesting;
- a real requirement appears that logs stay up during node maintenance;
- a multi-node object store (multi-node Garage, TrueNAS S3 or cloud) exists.

Cheaper steps first: raise memory and the volume, drop noisy namespaces (`K8S-Logging.Exclude`), shorten retention.

**How to move later:** add a new `schema_config` period with `object_store: s3` and a new `from:` date (never edit an old period), then change `deploymentMode`. Old data stays readable until retention removes it. On AKS with Blob storage the answer differs: start with single binary on Blob and move to SimpleScalable only when the signals above appear (check the Loki release notes first).

## 3. Dependencies

**Loki needs (must exist first)**

| Dependency | Why | Check |
|---|---|---|
| Longhorn with class `longhorn` | its volume | `kubectl get sc longhorn`; `./tests/storage-longhorn.sh` |
| Argo CD with the `platform` AppProject | deploys it; `https://grafana.github.io/helm-charts` in `sourceRepos` | `kubectl apply -f bootstrap/platform-project.yaml` |

It needs nothing else: no Secret, no DNS, no route, no Capsule. **Waiting for it:** Fluent Bit (pushes) and Grafana (data source).

**If something is missing**

- No `longhorn` class: the PVC stays `Pending` and the pod waits; it starts once the class exists.
- Loki down: Fluent Bit stops reading (`Mem_Buf_Limit`) and retries. Files stay on the nodes and are read from the saved offset when Loki returns, as long as the node has not rotated them away.

## 4. Access from the central Grafana on docker-2

The Grafana on docker-2 (`grafana.jodywan.com`, `10.1.5.123`) reads this Loki, with the same pattern as the Thanos Querier (`lan-access-metallb.md`).

| Item | Value |
|---|---|
| Address | `10.1.5.173` (MetalLB, LAN only), Service `loki-lan` in `loki`, port 80 to Loki's 3100 |
| Who can connect | `10.1.5.123` (HTTP only) and the pods of the namespaces `loki`, `fluent-bit` and `monitoring`; everything else is refused (NetworkPolicy `loki-ingress`) |
| Files | `extraObjects` in `overlays/k8s-1/loki/values.yaml` (cluster addresses: not in `base/`) |
| Data source (docker-2 Grafana) | name `Loki K8s-1`, type Loki, URL `http://10.1.5.173`, HTTP header `X-Scope-OrgID` = `platform\|zeedlogic\|jodywan` (all tenants at once) |

- **The policy is the only control.** Loki has no authentication and the tenant header is not a credential. Anyone who can use docker-2's address can read every tenant's logs, which is acceptable for the platform team and is the reason this address is not published through HAProxy or Traefik.
- **Do not break log shipping.** Fluent Bit (namespace `fluent-bit`) pushes to Loki on 3100; the policy allows it. Whenever the policy changes, run `./tests/fluent-bit.sh`: it must still show the marker lines in Loki.
- **New tenant:** add its name to the `X-Scope-OrgID` value of the data source (docker-2 Grafana, and this cluster's Grafana in `overlays/k8s-1/grafana/values.yaml`).
- The data source `Loki K8s-1` was created through the Grafana API on docker-2; like the Thanos one it lives only in that Grafana's volume (not in Git).
- **Verified:** docker-2 gets HTTP 200 on `/ready`; control-plane-1 and a pod in `default` time out; Fluent Bit still ships (`./tests/fluent-bit.sh`, 0 output errors, 0 retries or dropped records). `./tests/loki.sh` checks the address, the traffic policy, the policy object, and that the host it runs on is refused.

## 5. Deploy

1. Commit and push.
2. `kubectl apply -f bootstrap/platform-project.yaml` (adds the Grafana and Fluent chart repos).
3. Sync `platform-gitops` (creates the `loki` ApplicationSet), then sync `loki`.
4. Run `./tests/loki.sh`.

## 6. Test: `tests/loki.sh`

1. The StatefulSet is ready, the PVC is Bound on `longhorn`, the Service exists.
2. `/ready` is 200; a request without `X-Scope-OrgID` is refused (401); a pushed line is returned to its own tenant, not to another one; a query across two tenants (`a|b`) works.
3. Retention is configured (compactor on, 168 h); no container restarts.
4. The LAN address and the traffic policy (section 4).

It leaves one line in the throwaway tenant `loki-test`, which ages out with retention. Run it from a host that is **not** docker-2 (`tests/tests-guide.md`).

## 7. Risks and open items

- **Memory:** 1Gi limit. If `RESTARTS` shows `OOMKilled`, raise the limit; heavy queries are the usual cause.
- **Disk fills:** watch the volume in Longhorn and in Grafana; retention is the first lever.
- **Single point of failure:** one pod; the volume re-attaches on another worker after a node loss, with a gap in logs (Fluent Bit buffers and retries).
- **Metrics and alerts:** the ServiceMonitor is on. `monitoring.rules` (Loki alerts) and `monitoring.dashboards` are still off; Alertmanager has a mail receiver (`alerting.md`), so Loki alert rules can be added to `platform-alerts` when wanted.
- **Chart defaults** such as `useTestSchema` and `minio` are explicitly off. Review `targetRevision` bumps: Loki 3.x chart majors have changed value names before (this file was checked against 7.3.0).
- **Memberlist warnings at startup** (`Failed to resolve loki-memberlist`): the Service has no endpoint until the pod is ready. They stop by themselves and are harmless in single binary.
