# blackbox-exporter

- Probes endpoints from inside the cluster and reports `probe_success` and certificate expiry to Prometheus.
- Layer 1, Argo CD app `blackbox-exporter`, namespace `monitoring`, auto-sync (`prune: false`). Step 8j in `fresh-install-order.md`.
- Test: `tests/blackbox-exporter.sh` (16 checks).

## 1. Why

Prometheus only knows what pods say about themselves. These failures were invisible: HAProxy or DNS down while the
Grafana pod is fine, the backup Garage or TrueNAS NFS not answering until the next backup run, Authentik or GitLab
down (every login or every Argo CD sync fails), a public certificate about to expire.

## 2. What is probed (every 60 s)

| Probe (`Probe` object) | Module | Targets |
|---|---|---|
| `public-ui` | `http_2xx` | `https://grafana-k8s.jodywan.com/api/health`, `https://headlamp.jodywan.com/`, `https://garage-k8s.jodywan.com/`, `https://argocd.jodywan.com/` |
| `dependencies` | `http_2xx` | the Authentik issuer (`.well-known/openid-configuration` of the Grafana application), `https://gitlab.jodywan.com/users/sign_in` |
| `tcp-ports` | `tcp_connect` | `10.1.5.123:3910` (backup Garage), `10.1.5.202:2049` (TrueNAS NFS), `10.1.5.171:9001` (Capsule Proxy), `10.1.5.170:80` (Traefik) |

`http_2xx` follows redirects, requires TLS (`fail_if_not_ssl`) and times out after 10 s. 10 targets in all. Targets
are plain lists in `overlays/k8s-1/blackbox-exporter/values.yaml` (`extraManifests`): add a URL or `host:port` and push.
No ICMP (it would need `NET_RAW`).

## 3. Alerts (`platform-alerts`, group `platform-probes`)

| Alert | Fires when | Severity |
|---|---|---|
| `ProbeFailed` | `probe_success == 0` for 5 min | warning |
| `ProbeCertificateExpiresSoon` | an HTTPS certificate expires in under 14 days (for 1 h) | warning |
| `ProbeCertificateExpiresVerySoon` | under 3 days (for 10 min) | critical |

Mail goes through the receiver in `alerting.md`.

## 4. Dashboard: `Probes (k8s-1)`

Folder Platform, `dashboards/platform/probes.json` (UID `platform-probes`), variable `Group` (public-ui,
dependencies, tcp-ports). 12 panels:

| Panel | Shows |
|---|---|
| Targets up, Targets down, Targets total | counts from `probe_success` |
| Shortest certificate (days) | red under 3, orange under 14, yellow under 30 |
| Slowest probe | `max(probe_duration_seconds)` |
| Probes failing over 24 h | targets that failed at least once in a day |
| Targets (table) | per target: status, HTTP code, duration, certificate days |
| Up and down over time | state timeline per target, green UP and red DOWN |
| Probe duration, Certificate days left, HTTP status code | time series per target |
| Exporter's own health | `up{job="blackbox-exporter"}` |

All queries were run against Prometheus when it was written. The failure counters show 0 when nothing fails.
TCP targets have no HTTP code or certificate (those cells stay empty in the table).

## 5. Design notes

- **Not a metrics gap filler:** it tests the path a pod would use (cluster DNS, node egress, pfSense and HAProxy for
  the public names). Problems that only affect a laptop on another network are not seen.
- **NetworkPolicy:** only pods in `monitoring` may reach port 9115 (`networkPolicy.allowMonitoringNamespace`). The
  exporter fetches any URL it is asked to, so tenant pods must not be able to use it to reach internal addresses.
- **Targets that need a login are probed only up to the login page.** A 200 from Headlamp or Argo CD shows the
  route, HAProxy and the pod are alive, not that SSO works. The Authentik probe covers the issuer separately.
- **Resources:** 10m CPU, 24Mi memory (limit 96Mi).
- The chart's own `prometheusRule` is off; alert rules live next to the others in the stack's values.

## 6. Install

1. `kube-prometheus-stack` running (Probe CRD, Prometheus accepts probes with any labels: `probeSelectorNilUsesHelmValues: false`).
2. Push, let `platform-gitops` create the ApplicationSet, sync `blackbox-exporter`.
3. `./tests/blackbox-exporter.sh` (10 targets up, closed port detected, policy holds).
4. Auto-sync is on in `appsets/blackbox-exporter.yaml`.

## 7. Check by hand

```bash
kubectl -n monitoring port-forward svc/blackbox-exporter 9115:9115 &
curl -s 'localhost:9115/probe?target=https://headlamp.jodywan.com/&module=http_2xx' | grep -E 'probe_success|probe_http_status_code|probe_ssl_earliest'
```
In Grafana (Explore, Prometheus): `probe_success`, `probe_duration_seconds`.
