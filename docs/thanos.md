# thanos: long-term metrics in Garage

- Layer 1, managed by Argo CD. Step 8d in `fresh-install-order.md`.
- Prometheus keeps only 12 hours locally. The Thanos sidecar uploads every 2 h block to the Garage bucket `thanos`, where **7 days** are kept.
- Grafana reads recent and old data through the Thanos Querier.
- Test: `tests/thanos.sh` (20 checks).

## 1. At a glance

| Item | Value |
|---|---|
| Chart | `thanos` 1.24.1 (app 0.42.4), repo `https://stevehipwell.github.io/helm-charts/` (the Bitnami chart is older: 0.39) |
| Namespace | `monitoring` (same as kube-prometheus-stack) |
| Sidecar | runs in the Prometheus pod; configured in `base/kube-prometheus-stack/values.yaml` (`prometheusSpec.thanos`) |
| Querier | `thanos-query` (Deployment), gRPC and HTTP on 10901 and 10902, memory limit 512Mi |
| Store Gateway | `thanos-store-gateway` (StatefulSet), 3 GiB volume on `longhorn`, index cache 256MB, memory limit 768Mi |
| Compactor | `thanos-compact` (StatefulSet), 8 GiB work volume on `longhorn`, memory limit 768Mi |
| Bucket | `thanos` in Garage (`garage.garage.svc.cluster.local:3900`, region `garage`, path style, plain HTTP), key `thanos-key`, **quota 15 GiB** |
| Secret | `monitoring/thanos-objstore`, key `objstore.yml` (S3 settings and key), created by External Secrets from the GitLab variable `thanos_objstore`; used by the sidecar and all three components |
| Retention | raw **7 days**; downsampling **off**; `--delete-delay=12h`; Prometheus local **12 h** |
| External label | `cluster=k8s-1` (added to every series Thanos serves) |
| Argo CD | ApplicationSet `thanos`, auto-sync (`prune: false`, no self-heal) |
| Files | `appsets/thanos.yaml`, `base/thanos/values.yaml`, `overlays/k8s-1/thanos/values.yaml` |

**Where the data is.** The Thanos components store nothing themselves. Metric blocks live in the Garage bucket `thanos`, on Garage's 30 Gi data volume (Longhorn, 2 replicas). The Store Gateway and Compactor volumes are only caches and work areas (rebuildable). Prometheus keeps 12 h on its own 4 GiB volume.

## 2. Sizing (dev)

- About 6,350 samples/s and about 181,000 active series, about 550 million samples a day; at 1.3 to 2 bytes per sample that is **about 0.7 to 1.1 GiB a day**. Measure again with `garage bucket info thanos`.
- 7 days is about 7 GiB, plus up to 12 h of deleted blocks waiting for removal. The quota (15 GiB) leaves room to grow to about 14 days. Garage's data volume (29.4 GiB) is shared with every other bucket.
- **Downsampling is off** on purpose: it saves no disk (it only speeds up queries over long ranges) and costs compactor memory. With it off, `--retention.resolution-5m` and `-1h` are set to 7d but unused.
- Raw cost on Longhorn: store 3 GiB + compactor 8 GiB, times 2 replicas = 22 GiB (the bucket itself is in Garage's existing volume).

## 3. Design choices

- **Dev retention is short.** History beyond a week is not needed on a dev cluster. To change it, edit `--retention.resolution-raw` in `overlays/k8s-1/thanos/values.yaml`, raise the bucket quota (`garage bucket set-quotas --max-size <size> thanos`), and grow Garage's data volume if the total no longer fits (`storage-garage.md`).
- **The quota protects the other users of Garage.** If metrics fill 15 GiB, uploads fail and the compactor stops rather than filling the shared volume (Velero and Loki chunks may use it later).
- **12 h local retention** survives a sidecar or Garage outage of about 10 h (a block is uploaded every 2 h). Shorter than about 6 h risks losing data after one failed upload.
- **One replica of everything.** A restart of any component is a short gap in long-range queries only; recent data keeps flowing through the sidecar.
- **The Querier de-duplicates on `prometheus_replica`**, so adding a second Prometheus replica later needs no query change.
- **Grafana reads through the Querier** (section 6).

## 4. Dependencies

**Needs (must exist first)**

| Dependency | Why | Check |
|---|---|---|
| kube-prometheus-stack | Prometheus, the sidecar, the namespace, the ServiceMonitor CRD | `./tests/kube-prometheus-stack.sh` |
| Garage with the bucket `thanos`, key `thanos-key` and the quota | block storage | `kubectl -n garage exec garage-0 -c garage -- /garage bucket info thanos` |
| Secret `monitoring/thanos-objstore` | S3 settings for the sidecar and components | `kubectl -n monitoring get secret thanos-objstore` |
| Longhorn | the Store Gateway and Compactor volumes | `./tests/storage-longhorn.sh` |
| The `stevehipwell` chart repo in the `platform` AppProject | deploys it | `kubectl apply -f bootstrap/platform-project.yaml` |

**Waiting for it:** the Grafana `Prometheus` data source, long-range dashboards, and later alerting rules that need history.

**If something is missing**

| Symptom | Cause and fix |
|---|---|
| the Prometheus pod cannot start | the stack synced before the Secret `thanos-objstore` existed (the sidecar mounts it). Order: bucket and key, variable, push, sync |
| uploads fail and retry; errors in the sidecar log | Garage is down; Prometheus keeps 12 h locally |
| `AccessDenied` in the sidecar and compactor logs | wrong key or bucket policy: run `garage bucket allow` again |

## 5. Create the bucket, key and variable (once)

The key is shown once and is never printed or saved by this script; it goes straight into the file for the GitLab variable.

```bash
G="kubectl -n garage exec garage-0 -c garage -- /garage"
$G bucket create thanos
OUT=$($G key create thanos-key 2>&1 | grep -v INFO)
KID=$(echo "$OUT" | sed -n 's/^Key ID: *//p' | head -1); KSEC=$(echo "$OUT" | sed -n 's/^Secret key: *//p' | head -1); unset OUT
$G bucket allow --read --write --owner thanos --key thanos-key
$G bucket set-quotas --max-size 15GiB thanos
cat <<EOT        # the value of the GitLab variable thanos_objstore: paste it in the GitLab UI, then unset KID KSEC
type: S3
config:
  bucket: thanos
  endpoint: garage.garage.svc.cluster.local:3900
  region: garage
  insecure: true
  bucket_lookup_type: path
  access_key: $KID
  secret_key: $KSEC
EOT
```

- Garage serves path-style requests only (`bucket_lookup_type: path`), without TLS inside the cluster (`insecure: true`).
- Add the text as the GitLab group variable `thanos_objstore` (type Variable, **Protected**, **Hidden off**). External Secrets creates `monitoring/thanos-objstore` from it (`external-secrets.md`; the namespace `monitoring` exists once kube-prometheus-stack synced).

## 6. Deploy

1. The bucket, key, quota and variable exist (section 5). **This must come before the push**: the stack change adds the sidecar, and the Prometheus pod waits for the Secret.
2. Commit and push. The stack (auto-sync) restarts Prometheus with the sidecar (WAL replay, a short gap).
3. `kubectl apply -f bootstrap/platform-project.yaml` (adds the stevehipwell repo), then sync `platform-gitops` and `thanos`.
4. Run `./tests/thanos.sh`. Blocks appear in the bucket about 2 hours after Prometheus (re)starts.

**The Grafana data source.** `datasources:` in `overlays/k8s-1/grafana/values.yaml` points both `Prometheus` (default, UID `prometheus`) and `Thanos` (UID `thanos`) at the Querier, `http://thanos-query.monitoring.svc.cluster.local:10902`. The default dashboards then query the Querier, which merges the sidecar (the last 12 h) and the Store Gateway (older). The entry called `Prometheus` is kept because the dashboards reference its UID; `Thanos` was added so the Querier is easy to find. There is no data source that talks to Prometheus directly; to query Prometheus alone (for example to debug the sidecar), use `kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090`.

## 7. Test: `tests/thanos.sh`

1. The Querier, Store Gateway and Compactor are ready, their volumes Bound, the Secret exists, no restarts.
2. The `thanos-sidecar` container is ready in the Prometheus pod, and local retention is 12h.
3. The Querier lists the sidecar and the Store Gateway, returns data with `cluster=k8s-1`, and is ready.
4. The compactor is not halted (`thanos_compact_halted 0`) and logs no errors.
5. The bucket exists with a quota and holds objects once the first block was uploaded (a NOTE, not a failure, during the first 3 hours).
6. The LAN address (section 8): reachable from the allowed host, refused from the host the script runs on.

Run it from a host that is **not** docker-2 (`tests/tests-guide.md`).

## 8. Access from the central Grafana on docker-2

The Grafana on docker-2 (`grafana.jodywan.com`, `10.1.5.123`) reads the same Querier. How the LAN address works, step by step, with a recipe for other apps: `lan-access-metallb.md`.

| Item | Value |
|---|---|
| Name | `thanos-query-k8s.jodywan.com` |
| Address | `10.1.5.172` (MetalLB, LAN only), Service `thanos-query-lan` in `monitoring`, port 80 to the Querier's 10902 |
| Data source URL | `http://thanos-query-k8s.jodywan.com` (type Prometheus; set "Prometheus type" to Thanos) |
| Who can connect | pods of the `monitoring` namespace, and `10.1.5.123` on the HTTP port only (NetworkPolicy `thanos-query-ingress`, enforced by Calico; `externalTrafficPolicy: Local` keeps the source IP) |
| Not used | HAProxy, Traefik and the internet: the Querier has no authentication and exposes every metric |
| Files | `extraManifests` in `overlays/k8s-1/kube-prometheus-stack/values.yaml` (the Thanos chart cannot set `externalTrafficPolicy`) |

- **The name:** create an A record `thanos-query-k8s.jodywan.com` -> `10.1.5.172`, DNS only (Cloudflare, like the other `-k8s` names but with the private address), or a host override in pfSense (Unbound) if you prefer not to publish a private address. Docker-2 must resolve it.
- **In the docker-2 Grafana:** Connections > Data sources > Add > Prometheus; URL `http://10.1.5.172` (works without DNS; use the name once it resolves); Prometheus type `Thanos`; Save and test. Its dashboards that use a `cluster` variable then show `k8s-1` (the external label).
- The data source `Prometheus K8s-1` exists there (UID `cg0tex758kni8a`; URL `http://10.1.5.172`, type Prometheus, Prometheus type Thanos, POST, 30 s). It was created through the API, so it lives only in that Grafana's volume (`grafana_data`): it is **not** in Git, and the CI/CD-managed Compose project (`/home/docker-cicd/cicd-deploy/grafana-docker-compose`) was not changed. Recreate it from this table if that volume is ever lost.
- **Check:** `./tests/thanos.sh` from a control plane (must be refused), and `curl -s http://thanos-query-k8s.jodywan.com/-/ready` from docker-2 (must answer `Thanos Query is Ready.`).

## 9. Risks and open items

- **Single Garage node.** No metrics are uploaded while Garage restarts, and the Store Gateway cannot serve old data; recent data is unaffected. An off-cluster backup of the bucket is not set up (the Garage volumes are in the nightly Longhorn backup, `storage-longhorn.md`).
- **Compactor halt.** Thanos stops compacting on overlapping or corrupt blocks (`thanos_compact_halted 1`). Alert on it (`alerting.md`).
- **Quota full:** uploads fail. Raise the quota and Garage's volume, or shorten raw retention.
- **Shared Garage volume (29.4 GiB):** check `garage bucket info` for every bucket before adding Velero or Loki chunks.
- **No authentication on the Querier itself.** Tenant pods are blocked by `thanos-query-ingress` and the tenant network baseline; tenants read metrics only through a per-tenant `prom-label-proxy` that fixes `namespace` to their own namespaces (`tenant-observability.md`).
- **Flag names:** the compactor flag is `--downsampling.disable` (not `.disabled`); the wrong name makes the pod crash-loop with `unknown long flag`. Check flags against `thanos compact --help` of the pinned image when bumping the chart.

## 10. Secret rotation (Reloader)

`compact.podAnnotations` and `storeGateway.podAnnotations` make Reloader restart the compactor and the store gateway when `thanos-objstore` changes. The Prometheus sidecar reads the same Secret, but its StatefulSet belongs to the operator: after rotating the Secret run `kubectl -n monitoring rollout restart statefulset prometheus-kube-prometheus-stack-prometheus`. See `reloader.md`.
