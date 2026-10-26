# Repository layout: what goes where

This repository is meant to become a **template**. A fork for another cluster changes only the files that describe that
cluster; everything else comes from the template unchanged. This page explains where each kind of setting lives.

## The rule in one line

- **`base/`** holds only what is true on **every** cluster.
- **`overlays/<cluster>/`** holds everything that exists because of **this** cluster.

## Where does a setting go?

| Kind of setting | Goes in | Examples |
|---|---|---|
| What the app is, true on any cluster | `base/<app>/values.yaml` | `enabled` switches, `ServiceMonitor` on, Secret names, security context, chart structure |
| Specific to this cluster | `overlays/<cluster>/<app>/values.yaml` | hostnames, IPs and CIDRs, issuer URLs, tenant names, GitLab endpoint, mail and identity provider, resources, replicas, storage class, volume sizes, retention, priority class, backup target, probe targets |
| Which chart, which version, which namespace, sync options | `appsets/<app>.yaml` | same in every fork |
| Plain manifests that are generic | their own folder | `gateway-api-crds/`, `tenant-baseline/` |
| Plain manifests that are cluster data | `overlays/<cluster>/<name>/` | `metallb-config/` (the address pool), `tenants/` (Tenants, RoleBindings, namespace Job) |
| Argo CD itself and the OIDC flags | `layer0/` | see `how-layer0-works.md` |

## How the files are combined

- Each Helm ApplicationSet loads two files, in this order: `base/<app>/values.yaml`, then `overlays/<cluster>/<app>/values.yaml`.
- A base file on its own is **not** a complete configuration, by design.
- **Helm merges maps but replaces lists.** So:
  - a **map key** (a hostname inside `route.main`, `kubeEtcd.endpoints`) moves to the overlay alone;
  - a **list** that holds cluster data (Probe objects, Services with an IP, NetworkPolicies with a CIDR, Grafana data sources,
    backup locations, `extraArgs`) moves to the overlay as a **whole**.

## The guard

`./tests/overlay-split.sh` fails when a file in `base/` contains a domain of this site, an address of its network, a tenant
name, or sizing (resources, replicas, storage class, volume size, retention, priority class) outside a comment.
Run it after editing any base file. The `validate` job in GitLab CI runs it on every merge request.

## Moving a setting from `base/` to the overlay

1. Render before: `helm template` with the current files, saved to a file.
2. Move the setting.
3. Render after, and compare with `cmp`. The two must be **byte-identical**, so no live object changes.
4. Run the app's own test (`tests/<app>.sh`).

## What is still cluster-specific outside the Helm values

These plain-manifest folders still name this cluster's hostnames, addresses or tenants. Moving them into
`overlays/<cluster>/` is mechanical but changes the source path of live apps, so it is done one app at a time with the same
before and after comparison (Argo CD diff must be empty).

| Where | What is specific |
|---|---|
| `appsets/*.yaml` | the GitLab repo URL (`repoURL`) in every ApplicationSet. Plan: one `cluster/cluster.yaml` read by a Git file generator, so `appsets/` is identical in every fork |
| `tenant-baseline/` | platform hostnames, the GitLab URL, node and tunnel addresses |
| `tenant-gitops/`, `tenant-observability/` | tenant names, GitLab group paths, Authentik group names |
| `external-secrets/` | the ClusterSecretStore with the GitLab group ID, the ExternalSecrets |
| `gatekeeper-policies/` | the registry allowlist in the Constraint parameters |

## Adding a second cluster

1. Create `overlays/<new>/<app>/values.yaml` for every app (copy `k8s-1`, change the cluster data).
2. Add one list element (`cluster`, `server`) to each ApplicationSet, or use the `cluster.yaml` generator once it exists.
3. Copy `overlays/<new>/metallb-config/` and `overlays/<new>/tenants/`, and adjust them.
4. Handle the folders in the table above until they are moved.
