# Renovate

- Opens merge requests in `platform-gitops` when a Helm chart or container image has a new version.
- It **never merges**: you read the merge request, run the test of that app, merge, and Argo CD does the rest.
- Layer 1, Argo CD app `renovate`, namespace `renovate`. Step 8q in `fresh-install-order.md`. Chart `renovate/renovate` 46.352.2 (Renovate 44.149.2).
- Status: written. The CronJob is **suspended until you create the GitLab token** (section 4).
- Test: `tests/renovate.sh` (6 checks).

## 1. What it tracks (20 dependencies today)

The versions here are pins written by hand, not in a standard file, so `renovate.json` (repo root) has four custom
managers:

| Manager | Finds | Examples |
|---|---|---|
| Argo CD ApplicationSets | `repoURL` + `chart` + `targetRevision` (comment lines in between are fine) | longhorn, loki, thanos, kube-prometheus-stack, keda, velero, jaeger, reloader ... (14 charts) |
| Garage | the chart read from its git tag (`targetRevision: v2.4.1`) | garage |
| Images in values and manifests | `image: name:tag` | prom-label-proxy, the Velero AWS plugin |
| Helper images in `tests/*.sh` | `IMG="${IMG:-name:tag}"` and inline `image:` | busybox, curlimages/curl, amazon/aws-cli |

`tests/renovate.sh` proves, without Renovate, that every chart pin in `appsets/` is found.

## 2. Rules and why

| Rule | Why |
|---|---|
| Nothing is automerged | every bump of a platform component needs a person and its test |
| Branches are created only before 07:00 on Monday; the Dependency Dashboard issue refreshes nightly | one review slot per week, no daily noise |
| Majors need approval on the Dependency Dashboard first | CRDs, flags and values change |
| `jaeger` allowed only below 4.14.0 | 4.14 (Jaeger 2.21) removed the query API Grafana's Jaeger data source uses (`jaeger.md`) |
| `longhorn`, `kube-prometheus-stack`, `loki`, `thanos`, `velero`, `keda`: one minor at a time, minors and patches separate | the appset comments ask for this: they restart Grafana, move data or hold volumes |
| Velero and its AWS plugin in one group | they are paired; check the compatibility table |
| All test helper images in one merge request | low risk |
| At most 6 open merge requests, 4 per hour | no flood on the first run |

## 3. Not tracked (on purpose or not visible)

- **Argo CD itself** (installed by GitLab CI; `CHART_VERSION` in `layer0/argocd/deploy.sh`) and **Calico** (kubespray). MetalLB, Traefik, Capsule and Capsule Proxy are ApplicationSets in `appsets/`, so their chart versions are tracked like the other apps.
- **Kubespray and Kubernetes** (its own repo and procedure, `K8S-UPGRADE-PLAN.md`).
- **Images inside charts** (Grafana, Prometheus, Loki ...): they move with the chart version.
- **docker-2** (Authentik, the zeedlogic stack, the backup Garage): compose files outside this repo.
- Image digests are not pinned.

## 4. Turn it on (one time, you)

1. In GitLab, project `platform-gitops` → Settings → Access tokens → **Add new token**: name `renovate`, role
   **Developer**, scopes **api** (needed for merge requests and the dashboard issue; `write_repository` is included
   in `api`), expiry as you prefer (GitLab allows at most one year, then rotate it as in `rotate-argocd-gitlab-token.md`).
2. Create the Secret (the token never goes into Git):
   ```bash
   kubectl -n renovate create secret generic renovate-env --from-literal=RENOVATE_TOKEN='<the token>'
   ```
   Optional, avoids GitHub API rate limits for release notes: add `--from-literal=GITHUB_COM_TOKEN='<read-only token>'`.
3. In `base/renovate/values.yaml` set `cronjob.suspend: false` and push.
4. Check without creating anything: `DRYRUN=1 ./tests/renovate.sh` (a one-off Job with `RENOVATE_DRY_RUN=full`).
5. The first real run creates the **Dependency Dashboard** issue and, on Monday morning, the merge requests.

## 5. Working with the merge requests

| Step | What |
|---|---|
| Read | the description links release notes and says what changed; for a chart bump check the new default values and CRDs |
| Test | run the app's test after the merge (`tests/<app>.sh`, table in `tests/tests-guide.md`); Argo CD syncs automatically for auto-sync apps and waits for you for `storage-garage`, `headlamp`, `garage-ui` |
| Merge | one app per merge request, as Renovate groups them; a failure is reverted by reverting the commit |
| Skip | close the merge request; Renovate will not reopen that version. To pause a dependency add a `packageRules` entry with `"enabled": false` and a reason |

## 6. Check and operate

```bash
./tests/renovate.sh                         # config and cluster objects
DRYRUN=1 ./tests/renovate.sh                # also a real dry run (needs the Secret)
kubectl -n renovate get cronjob,job
kubectl -n renovate logs job/<job>          # what it did
```

Failure mode to know: with the CronJob active and no valid token, the nightly Job fails (`renovate-env` is optional,
so the pod starts but GitLab answers 401). The test reports a missing token on an active CronJob.
