# Object storage for tenants

- Layer 1, Argo CD app `tenant-storage`. Step 8t in `fresh-install-order.md`. Needs `storage-garage` (`storage-garage.md`).
- Files: `overlays/k8s-1/tenant-storage/network-policies.yaml`, `appsets/tenant-storage.yaml`.
- Test: `tests/tenant-storage.sh` (10 checks).
- Status: tested on k8s-1 on 2026-10-18, 10/10. End to end through the application as well: ZeedLogic's `POST /_files/_upload`, `GET /_files/_download` and `POST /_files/_delete_object`, called through the public Studio host, stored a file in `jodywan-dev-zeedlogic-files`, returned identical bytes and removed it. The two network policies were first applied by hand (under Argo CD's field-manager name) to run the test before the merge; after the merge Argo CD adopted them with no conflict (`tenant-storage` Synced and Healthy), and the test passed again on the merged state.

## 1. The idea

A tenant namespace cannot reach a platform service on its own: egress there is default-deny, and the `garage` namespace refuses
tenant sources (`refuse-tenant-ingress`, `tenant-network.md`). A tenant that needs object storage is therefore a platform decision,
with a rule on **both** sides, the same pattern as the databases namespace (`databases.md`). The platform's one Garage is shared; each
tenant gets its own buckets and its own key.

## 2. What exists for `jodywan-dev`

| Object | Where | Purpose |
|---|---|---|
| bucket `jodywan-dev-zeedlogic-files` | Garage | ZeedLogic's files; **5 GiB quota** |
| bucket `jodywan-dev-zeedlogic-audit` | Garage | ZeedLogic's cold audit archives; **1 GiB quota** |
| key `jodywan-dev-zeedlogic` | Garage | read and write on those two buckets only |
| Secret `zeedlogic-s3` (keys `accessKey`, `secretKey`) | namespace `jodywan-dev` | the key; **created by hand, never in Git** |
| NetworkPolicy `allow-jodywan-dev-s3` | `garage` | lets `jodywan-dev` reach Garage pods on **3900 (the S3 API) only** |
| NetworkPolicy `allow-egress-to-s3` | `jodywan-dev` | lets that namespace leave for Garage pods on 3900 |

Garage's data volume is **shared by every bucket**, so each bucket has a size quota; check the sum against the volume (`storage-garage.md`).
The buckets, the quotas and the key live inside Garage, not in Git: they were created with the Garage CLI, as `storage-garage.md` section 6 describes.

## 3. How an application connects

| Setting | Value |
|---|---|
| Endpoint | `http://garage.garage.svc.cluster.local:3900` |
| **Region** | **`garage`**. This store's region is not `us-east-1`; a client with the wrong region fails with a signature error |
| Addressing | path-style |
| Keys | from the Secret `zeedlogic-s3` |

For the zeedlogic chart that is `global.objectStorage` (`endpoint`, `bucket`, `auditArchiveBucket`, `region: garage`, `existingSecret: {name: zeedlogic-s3}`).

**No public S3 host is needed for Studio.** Studio uploads and downloads files through fastapi (`/_files/_upload`, `/_files/_download`), which uses the internal endpoint above; the browser never contacts Garage. A browser-reachable S3 address and CORS on the bucket matter only for an API client that uses the older presigned-URL endpoints (`_upload_intent`, `_download_url`), which Studio no longer calls. This Garage has no public S3 hostname (only the UI is published), and that is fine for Studio.

## 4. Network flows

| From | To | Allowed by |
|---|---|---|
| `jodywan-dev` pods | Garage pods, 3900 | `allow-egress-to-s3` (source side) and `allow-jodywan-dev-s3` (destination side); both are needed |
| `jodywan-dev` pods | Garage admin 3903, RPC 3901, web 3902 | refused |
| any other tenant namespace | Garage | refused twice |

The key limits what a caller can do inside the S3 API: it can reach only its own two buckets (the test checks that it is refused on `thanos`).

## 5. Adding another tenant namespace or app

1. In Garage: `bucket create`, `bucket set-quotas --max-size ...`, `key create`, `bucket allow --read --write ... --key ...`.
2. Put the key in a Secret in the tenant namespace. Do not print it; do not commit it.
3. Add an `allow-<namespace>-s3` policy in `garage` and an `allow-egress-to-s3` policy in the tenant namespace to `network-policies.yaml`. Do not widen the existing ones.
4. Run `tests/tenant-storage.sh` with the new names (`TENANT_NS`, `FILES`, `AUDIT`, `KEY`).

### 5a. `zeedlogic-dev` (the same steps, written down)

Policies `allow-zeedlogic-dev-s3` (in `garage`) and `allow-egress-to-s3` (in `zeedlogic-dev`) are in Git. The Garage side is not, so by hand with the Garage CLI (`storage-garage.md` section 6): buckets `zeedlogic-dev-zeedlogic-files` (5 GiB) and `zeedlogic-dev-zeedlogic-audit` (1 GiB), key `zeedlogic-dev-zeedlogic`, allowed read and write on those two only; then Secret `zeedlogic-s3` (keys `accessKey`, `secretKey`) in `zeedlogic-dev`. Check the quota total against the volume first. Test: `TENANT_NS=zeedlogic-dev FILES=zeedlogic-dev-zeedlogic-files AUDIT=zeedlogic-dev-zeedlogic-audit KEY=zeedlogic-dev-zeedlogic OTHERS="jodywan-stg zeedlogic-stg" ./tests/tenant-storage.sh`.

### 5b. Removing an environment's buckets and key

When an environment is reset or retired (`reset.sh` in zeedlogic-microservices does this): `garage bucket delete --yes <bucket>` for each bucket (the bucket is emptied by deleting its objects first if it holds any) and `garage key delete --yes <key>`, through `kubectl -n garage exec garage-0 -c garage -- /garage ...`, then delete the Secret `zeedlogic-s3` in the tenant namespace. The network policies stay in Git; they only open the port.

## 6. Risks

| Risk | Detail |
|---|---|
| One shared volume | quotas are the only fence between apps; unused quota is not reserved |
| Key in a Secret in the tenant namespace | tenant developers (`edit`) can read it. It reaches only that tenant's buckets |
| No browser-reachable endpoint | harmless for Studio (it goes through fastapi); only a client using the legacy presigned endpoints would need one |
| S3 API on a cluster-internal Service | the S3 port is plain HTTP inside the cluster |
