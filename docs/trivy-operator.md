# Trivy Operator

- Continuous security scanning. Layer 1, Argo CD app `trivy-operator`, namespace `trivy-system`. Step 8l in `fresh-install-order.md`.
- Chart `aqua/trivy-operator` 0.37.0 (Operator 0.35.0, Trivy 0.75.0). Auto-sync (`prune: false`).
- Test: `tests/trivy-operator.sh` (19 checks).
- It detects only; it blocks nothing (blocking is Gatekeeper, `gatekeeper.md`).

## 1. What it adds

The operator watches every workload in every namespace and writes report objects next to it:

| Report | Content | Scanner |
|---|---|---|
| `VulnerabilityReport` | CVEs in each container image | Trivy (database held by the in-cluster server) |
| `ConfigAuditReport` | misconfigurations of workloads, Services, NetworkPolicies, Roles, ... | Trivy checks |
| `ExposedSecretReport` | secrets baked into image layers | Trivy |
| `RbacAssessmentReport` | risky Roles and ClusterRoles | Trivy checks |
| `ClusterComplianceReport` | NSA and Pod Security baseline/restricted specs, every 6 hours | derived from the reports above |

Findings are also exported as Prometheus metrics (`trivy_image_vulnerabilities`, `trivy_resource_configaudits`, ...).

| Part | Role |
|---|---|
| `trivy-operator` (Deployment) | watches workloads, starts scan Jobs, writes reports |
| `trivy-server` (StatefulSet, 5 GiB Longhorn) | holds the vulnerability database; scan Jobs are clients, so none downloads it |
| scan Jobs | short-lived, in `trivy-system`, removed after 5 minutes |

## 2. Decisions

| Setting | Value | Why |
|---|---|---|
| Namespace Pod Security | `baseline` | like the other platform apps |
| `infraAssessmentScannerEnabled` | **false** | node-collector Jobs mount `/etc/kubernetes`, `/var/lib/etcd`, ... by hostPath, which `baseline` forbids. See "Turning on node checks" |
| `compliance.specs` | NSA, PSS baseline, PSS restricted | the CIS spec needs the node checks |
| `sbomGenerationEnabled` | false | SBOM reports are large etcd objects and nothing reads them |
| `accessGlobalSecretsAndServiceAccount` | **false** | otherwise the operator reads Secrets in every namespace to pull from private registries. Tenants may use any registry, so a cluster-wide Secret reader is not accepted by default |
| `scanJobsInSameNamespace` | false | scan Jobs run in `trivy-system`, never in a tenant namespace (no quota use, nothing a tenant can touch) |
| Concurrency | 5 scans, finished Jobs removed after 30 s, Job timeout 10 min | finished Jobs count against the limit until deleted: with 3 and a 5 minute TTL the first scan of the cluster ran at about one workload a minute |
| Report TTL | 24 h | every workload is rescanned daily, which also picks up new CVEs |

## 3. Tenants

The chart aggregates **read** access to `vulnerabilityreports`, `configauditreports` and `exposedsecretreports` into
`view`, `edit` and `admin`. Tenant users read the reports of their own namespaces (Capsule Proxy shows only those) and
cannot change or delete them. `RbacAssessmentReport` and `ClusterComplianceReport` stay platform only. The test checks
both directions.

Report objects live in etcd: one per workload container, tens of KiB each. At the size of this cluster that is
negligible; with many tenant workloads watch `etcd_db_total_size_in_bytes`.

## 4. Limits

- Images in **private registries** are not scanned (`accessGlobalSecretsAndServiceAccount: false`). To scan a tenant's
  private image, add `operator.privateRegistryScanSecretsNames` for that namespace with a pull Secret the platform
  holds, instead of switching the global access on.
- Nothing blocks a deployment on findings. This is detection. Blocking belongs in an admission policy (Gatekeeper,
  `gatekeeper.md`).
- Scan Jobs need egress to the image registries and to `mirror.gcr.io` (Trivy images, database, checks bundle). The
  platform namespaces have no egress policy.

## 5. Turning on node checks (CIS)

1. Label the namespace `pod-security.kubernetes.io/enforce: privileged` (in `managedNamespaceMetadata` of
   `appsets/trivy-operator.yaml`). Tenants cannot create anything in `trivy-system`.
2. `operator.infraAssessmentScannerEnabled: true`, add `k8s-cis-1.23` to `compliance.specs`.
3. node-collector runs on the three control planes and the workers one node at a time
   (`scanNodeCollectorLimit: 1`); the control planes carry the `node-role.kubernetes.io/control-plane` taint, so add
   `nodeCollector.tolerations`.

## 6. Install

1. `kubectl apply -f bootstrap/platform-project.yaml` (adds the aquasecurity chart repo).
2. Push, let `platform-gitops` create the ApplicationSet, sync `trivy-operator`.
3. `./tests/trivy-operator.sh` (about 3 to 8 minutes).

## 7. Dashboard

`Trivy (k8s-1)` in Grafana folder Platform (main organization, platform team only), from
`dashboards/platform/trivy.json`. Panels: operator up, critical and high vulnerabilities, config audit critical and
high, exposed secrets, containers scanned; vulnerabilities and config audit findings over time by severity; top
namespaces and a table of the worst images and workloads; RBAC findings; compliance pass and fail per spec. A
`Namespace` variable filters the vulnerability and config audit panels. Every query was checked against live
Prometheus. Tenant organizations do not get it: their data source is limited to their own namespaces.

## 8. Using it

```
kubectl get vulnerabilityreports -A -o wide          # all reports with critical/high/medium counts
kubectl get configauditreports -A -o wide
kubectl -n my-ns describe vulnerabilityreport <name> # the CVE list
kubectl get clustercompliancereports                 # summary per spec
```

Which CVEs are behind the counts (the dashboard shows only counts; `jq` is installed on the control planes). Each
report lists the CVE, the package, the installed version, the version that fixes it and a link:

```
# the critical CVEs of one report
kubectl -n argocd get vulnerabilityreport <name> -o json \
  | jq -r '.report.vulnerabilities[] | select(.severity=="CRITICAL")
           | [.vulnerabilityID,.resource,.installedVersion,.fixedVersion,.primaryLink] | @tsv'

# every CRITICAL in the cluster, one line each: namespace, report, CVE, package, installed, fixed in
kubectl get vulnerabilityreports -A -o json | jq -r '.items[] | .metadata.namespace as $n | .metadata.name as $r
  | .report.vulnerabilities[] | select(.severity=="CRITICAL")
  | [$n,$r,.vulnerabilityID,.resource,.installedVersion,.fixedVersion] | @tsv'

# only the ones that already have a fix (fixedVersion is not empty)
kubectl get vulnerabilityreports -A -o json | jq -r '.items[] | .metadata.namespace as $n
  | .report.vulnerabilities[] | select(.severity=="CRITICAL" and (.fixedVersion // "") != "")
  | [$n,.vulnerabilityID,.resource,.installedVersion,.fixedVersion] | @tsv' | sort -u
```

The workload name of a report is in its labels (`trivy-operator.resource.name`, `.kind`, `.namespace`). The
dashboard has no CVE column on purpose: a per-CVE metric (`operator.metricsVulnIdEnabled`) creates one series per CVE
and workload, which is high cardinality.

## 9. Accepted findings

28 Critical on the first full scan, all in third-party images and all waiting for the maintainers to rebuild:
Go `stdlib` `CVE-2025-68121` (Argo CD v3.5.4 built with Go 1.25.3, fixed in Go 1.25.7; also nodelocaldns, MetalLB,
CoreDNS, the NFS provisioner), `libssl3` `CVE-2026-31789` and `grpc` `CVE-2026-33186` in kube-system images. Decision:
wait for new image versions (Renovate proposes the bumps); nothing is ignored in Trivy, so the counts fall by
themselves. Re-check with the "fixable only" command above after each upgrade.

## 10. Test: `tests/trivy-operator.sh`

Operator and server ready, volume Bound, no restarts, namespace `baseline`, node checks off; operator cannot read
Secrets in `kube-system`; a throwaway Deployment with `alpine:3.12.0` gets a VulnerabilityReport with findings and a
ConfigAuditReport, no failed scan pods; tenant developer reads reports in own namespace, not in the other tenant's, and
cannot delete or read compliance reports; ClusterComplianceReports exist; Prometheus holds
`trivy_image_vulnerabilities`.
