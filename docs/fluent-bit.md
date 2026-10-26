# fluent-bit: log shipper

- Layer 1, managed by Argo CD. Step 8b in `fresh-install-order.md`.
- Reads container logs on every node and pushes them to Loki (`loki.md`).
- The Loki tenant is taken from the Capsule tenant label of the pod's namespace.
- Test: `tests/fluent-bit.sh` (11 checks).

## 1. At a glance

| Item | Value |
|---|---|
| Chart | `fluent-bit` 0.58.3 (app 5.1.3), repo `https://fluent.github.io/helm-charts` |
| Kind | DaemonSet, every node (control-plane taint tolerated), `priorityClassName: addons-critical` |
| Namespace | `fluent-bit` (Pod Security **`privileged`**: hostPath volumes are not allowed by `baseline`) |
| Reads | `/var/log/containers/*.log` (containerd, `cri` multiline parser); its own logs are excluded |
| Offsets | `/var/lib/fluent-bit/tail.db` on the node (hostPath), so restarts neither re-send nor skip |
| Discovery | new log files are found every 5 s (`Refresh_Interval`), so a short-lived pod's lines are not lost |
| Writes | `loki.loki.svc.cluster.local:3100`, tenant from the record key `tenant_id` |
| Labels | `job`, `cluster`, `namespace`, `pod`, `container`, `stream` |
| Resources | request 25m / 64Mi, limit 192Mi memory |
| Argo CD | ApplicationSet `fluent-bit`, auto-sync (`prune: false`, no self-heal) |
| Files | `appsets/fluent-bit.yaml`; `base/fluent-bit/values.yaml` (service section, parsers, switches); `overlays/k8s-1/fluent-bit/values.yaml` (inputs, filters, outputs, the Lua tenant script, host paths, sizing: the pipeline is cluster specific) |

## 2. How the tenant is chosen

1. The `kubernetes` filter adds pod metadata and, with `Namespace_Labels On`, the namespace's labels under the record key `kubernetes_namespace`.
2. A Lua filter (`luaScripts.tenant.lua`) sets `tenant_id` to the namespace label `capsule.clastix.io/tenant`, or `platform` if there is none (kube-system, argocd, longhorn-system, ...). It always overwrites `tenant_id`, so a pod that logs `{"tenant_id":"platform"}` cannot pick its tenant. `Merge_Log_Key log_processed` also keeps parsed JSON out of the top level.
3. The `loki` output uses `tenant_id_key tenant_id` as `X-Scope-OrgID` and removes the helper keys from the line. Capsule stops tenant owners changing the tenant label on their namespaces.

- Namespace labels are cached for 900 s (`kube_meta_namespace_cache_ttl`): a new tenant namespace is routed correctly from its first pod, but a label change takes up to 15 minutes to show.
- The layout of `kubernetes_namespace` is not in the Fluent Bit docs, so the Lua script accepts a `labels` map inside it or the labels directly. Verified: tenant lines land in the right tenant. If lines ever show under `platform` after a Fluent Bit upgrade, look at the real record (a temporary `stdout` output) and fix the script.

## 3. Dependencies

**Fluent Bit needs (must exist first)**

| Dependency | Why | Check |
|---|---|---|
| Loki running | the output | `./tests/loki.sh` |
| Containerd logs in `/var/log/containers` | the input | true on all nodes |
| Argo CD `platform` AppProject with `https://fluent.github.io/helm-charts` | deploys it | `kubectl apply -f bootstrap/platform-project.yaml` |

**Waiting for it:** the Grafana Loki data sources (a data source with no data is not an error, but it is useless).
**Does not need:** Longhorn directly, Secrets, DNS, or Capsule (only the label on the namespaces).

## 4. Deploy

1. Loki is synced and `./tests/loki.sh` passes.
2. Commit, push, sync `platform-gitops`, then sync `fluent-bit`.
3. Run `./tests/fluent-bit.sh`.

## 5. Test: `tests/fluent-bit.sh`

1. The DaemonSet is ready on every node (6 pods), with no restarts and no error lines towards Loki.
2. It creates a pod in `zeedlogic-dev` and one in `default`, each printing a unique marker.
3. After up to 90 s: the tenant marker is in Loki tenant `zeedlogic` only (not `jodywan`, not `platform`), and the platform marker is in `platform` only. Both pods are deleted at the end.

Test pods need unique names, and discovery takes time: the `kubernetes` filter caches pod metadata by pod name (a reused name arrived without `namespace`, `pod` and `container` labels), and the `tail` input finds new log files only every `Refresh_Interval` (60 s by default; 5 s in the values). The script therefore uses a fresh pod name per run and polls up to 90 s.

Not yet checked: a `jodywan` namespace, and behaviour after a node reboot.

## 6. Risks and open items

- **Privileged namespace.** Only Fluent Bit lives there; the pod mounts `/var/log` read-only. Keep other workloads out of `fluent-bit`.
- **Volume of logs:** everything is shipped, including `debug` noise from apps. Loki limits and retention are the guard; add `K8S-Logging.Exclude` annotations or a `grep` filter if one pod floods.
- **The journal (kubelet, containerd) is not shipped.** Add a `systemd` input tagged `host.*` and a second output for the `platform` tenant when node logs are wanted.
- **Cardinality:** `pod` is a stream label (normal for Loki; short-lived pods create streams). Do not add request IDs or user names as labels.
- **Tenant users cannot read Loki directly**: `loki-ingress` and the tenant network baseline block them. They read their own logs through their Grafana organization (data source `Loki` with a fixed tenant header, `tenant-observability.md`).
