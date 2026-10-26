# Grafana (own app)

- Layer 1, Argo CD app `grafana`, namespace `grafana`. Step 8c2 in `fresh-install-order.md`.
- Chart `grafana-community/grafana` 13.5.0 (Grafana 13.2.3). URL: `https://grafana-k8s.jodywan.com/`.
- Auto-sync (`prune: false`, no self-heal). It was the grafana subchart of kube-prometheus-stack; it is its own app so it restarts, upgrades and rolls back on its own.
- Login: Authentik OIDC (only the group `cluster-admin` is a Grafana admin), with the local `admin` as break-glass.
- Test: `tests/kube-prometheus-stack.sh` (it includes the Grafana checks) and `tests/tenant-observability.sh`.

## 1. What is where

| Piece | Lives in |
|---|---|
| Grafana Deployment, Service, route, volume, config (`grafana.ini`, OIDC, org mapping), data sources | this app: `appsets/grafana.yaml`, `base/grafana/values.yaml` (generic settings), `overlays/k8s-1/grafana/values.yaml` (hostname, Authentik URLs, org mapping, tenant data sources and file providers) |
| The 28 chart dashboards (folder Kubernetes) | rendered by **kube-prometheus-stack** (`grafana.enabled: false` plus `forceDeployDashboards: true`); Grafana's sidecar finds them by label in any namespace |
| Our dashboards (folder Platform) | `dashboards/platform/` (a source of the kube-prometheus-stack app, `kube-prometheus-stack.md` section 6) |
| Tenant starter dashboard | ConfigMap `tenant-dashboards` from `grafana/` (a kustomize source of this app; JSON in `grafana/dashboards/overview.json`), mounted into Grafana |
| Secrets `grafana-admin`, `grafana-oidc` | created by External Secrets from the GitLab variables `grafana_admin` and `grafana_oidc` (`external-secrets/grafana.yaml`) |
| Network | `refuse-tenant-ingress` for the namespace in `tenant-baseline/platform-ingress.yaml`; `grafana` is allowed in `thanos-query-ingress`, `loki-ingress` and `jaeger-ingress` (their values files) |
| Backup | the Longhorn volume must carry `recurring-job-group.longhorn.io/backup=enabled` (by hand, `storage-longhorn.md`); the alert rule in `platform-alerts` names PVC `grafana` |

Names: namespace `grafana`, every object called `grafana` (release name `grafana`), a 2 GiB Longhorn PVC `grafana`. The namespace carries `gateway-access=platform` and Pod Security `baseline`.

## 2. Settings

| Item | Value |
|---|---|
| Replicas and volume | 1 replica, 2 GiB volume, `Recreate` strategy (the volume is ReadWriteOnce) |
| Memory limit | 768Mi (384Mi was OOMKilled 5 times: plugins, dashboards, OIDC) |
| Route | `grafana-k8s.jodywan.com` through `traefik-gateway` |
| Login | Authentik OIDC; the local `admin` form stays as break-glass |
| Role mapping | `role_attribute_path` gives `GrafanaAdmin` to the group `cluster-admin` and `None` to anyone else (`role_attribute_strict: true`), so a changed Authentik binding cannot silently grant access. The `groups` claim carries the raw Authentik group name (no `oidc:` prefix) |
| Tenants | the Authentik groups in the token choose the organization and the role: a tenant user lands only in the organization of their tenant, as Editor (`tenant-observability.md`) |

**Data sources** (a file in the Grafana ConfigMap, `datasources:` in the overlay; same UIDs and headers on every restart):

| Name | UID | What |
|---|---|---|
| `Prometheus` (default) | `prometheus` | **through the Thanos Querier**: Prometheus only knows the last 12 hours, everything older is served by the Store Gateway through the Querier |
| `Thanos` | `thanos` | the same Querier under a visible name |
| `Loki` | `loki` | header `X-Scope-OrgID: platform\|zeedlogic\|jodywan` |
| `Jaeger` | `jaeger` | the query API of the Jaeger in namespace `jaeger` |
| `Alertmanager` | `alertmanager` | health check shows an error, cosmetic |
| per tenant organization | | `Prometheus` and `Loki` fixed to the tenant (`tenant-observability.md`) |

## 3. Login with Authentik

The values are in `base/grafana/values.yaml` and the overlay (`envFromSecrets: grafana-oidc` and `auth.generic_oauth`).

**What exists in Authentik** (names are new; other apps are untouched; the Garage UI provider is only read):

| Object | Value |
|---|---|
| Provider | `grafana-k8s-oauth2-provider`: confidential; flows, signing key, sub mode and scope mappings (`openid`, `email`, `profile`) copied from `garage-ui-oauth2-provider`; redirect URI `strict https://grafana-k8s.jodywan.com/login/generic_oauth` |
| Application | `grafana-k8s-oauth-app` ("Grafana k8s", group Observability) |
| Access | policy binding: only the group `cluster-admin` may open it |
| Issuer | `https://authentik.jodywan.com/application/o/grafana-k8s-oauth-app/` |

The other Grafana on this Authentik (`grafana-docker-2-oauth2-provider`, "Centralised Grafana") is not touched. To undo: delete the application `grafana-k8s-oauth-app`, then the provider `grafana-k8s-oauth2-provider`, and the GitLab variable `grafana_oidc`.

**To create them** (on a machine with the SSH key for `10.1.5.123`; the client secret stays in a shell variable and is never printed):

```bash
OUT=$(ssh adminjody@10.1.5.123 "sudo docker exec -i authentik-server-1 ak shell" 2>/dev/null <<'PY'
from authentik.providers.oauth2.models import OAuth2Provider as P, RedirectURI, RedirectURIMatchingMode
from authentik.core.models import Application, Group
from authentik.policies.models import PolicyBinding
NAME="grafana-k8s-oauth2-provider"; SLUG="grafana-k8s-oauth-app"
URI="https://grafana-k8s.jodywan.com/login/generic_oauth"
g=P.objects.get(name="garage-ui-oauth2-provider")
p=P.objects.filter(name=NAME).first()
created=False
if p is None:
    p=P(name=NAME, client_type="confidential",
        authorization_flow=g.authorization_flow, invalidation_flow=g.invalidation_flow,
        signing_key=g.signing_key, sub_mode=g.sub_mode, issuer_mode=g.issuer_mode,
        include_claims_in_id_token=g.include_claims_in_id_token,
        access_code_validity=g.access_code_validity, access_token_validity=g.access_token_validity,
        refresh_token_validity=g.refresh_token_validity)
    p.redirect_uris=[RedirectURI(RedirectURIMatchingMode.STRICT, URI)]
    p.save(); created=True
p.property_mappings.set(list(g.property_mappings.all()))
a=Application.objects.filter(slug=SLUG).first()
if a is None:
    a=Application(name="Grafana k8s", slug=SLUG, provider=p, group="Observability"); a.save()
elif a.provider_id!=p.pk:
    a.provider=p; a.save()
grp=Group.objects.get(name="cluster-admin")
if not PolicyBinding.objects.filter(target=a, group=grp).exists():
    PolicyBinding.objects.create(target=a, group=grp, order=0, enabled=True)
print("RESULT created_provider=%s app=%s bindings=%d" % (created, a.slug, PolicyBinding.objects.filter(target=a).count()))
print("CLIENT_ID=" + p.client_id)
print("CLIENT_SECRET=" + p.client_secret)
PY
)
echo "$OUT" | grep '^RESULT'                      # expect: created_provider=True app=grafana-k8s-oauth-app bindings=1
CID=$(echo "$OUT" | sed -n 's/^CLIENT_ID=//p'); CS=$(echo "$OUT" | sed -n 's/^CLIENT_SECRET=//p'); unset OUT
echo "id length: ${#CID}, secret length: ${#CS}"   # both must be non-zero (about 40 and 128)
curl -s -o /dev/null -w 'discovery HTTP %{http_code}\n' \
  https://authentik.jodywan.com/application/o/grafana-k8s-oauth-app/.well-known/openid-configuration   # 200
```

Then put the two values into the GitLab variable `grafana_oidc` as `{"GF_AUTH_GENERIC_OAUTH_CLIENT_ID":"…","GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET":"…"}` (type Variable, **Protected**, **Hidden off**) and `unset CID CS`. External Secrets creates the Secret `grafana/grafana-oidc` (`external-secrets.md`). Create the secrets **before** Grafana syncs; without them the pod waits in `CreateContainerConfigError` and starts as soon as they exist.

The admin password: add the GitLab variable `grafana_admin` as `{"admin-user":"admin","admin-password":"…"}` (generate with `openssl rand -base64 24`). It stays as the break-glass login, and it lives only in the Secret `grafana-admin`: read it with `kubectl -n grafana get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d` and keep it in a password manager.

**Manual check:** open `https://grafana-k8s.jodywan.com/`, press **Sign in with Authentik**, and log in as a `cluster-admin` member; you land as a Grafana admin. A user outside `cluster-admin` is refused by Authentik before reaching Grafana.

## 4. Deploy

1. `kubectl apply -f bootstrap/platform-project.yaml` (adds the grafana-community chart repo).
2. The GitLab variables `grafana_admin` and `grafana_oidc` exist (section 3), and DNS and HAProxy for `grafana-k8s.jodywan.com` exist (the same as for `headlamp` and `garage-k8s`).
3. Push. `platform-gitops` creates the ApplicationSet `grafana`, and the app syncs. Grafana is down for about a minute on every values change (the volume is ReadWriteOnce).
4. Run `./tests/kube-prometheus-stack.sh` and `./tests/tenant-observability.sh`, then log in from a browser.

## 5. Changing it later

- A values change restarts Grafana for about a minute (`Recreate`).
- A chart upgrade: bump `targetRevision` in `appsets/grafana.yaml` (independent of the stack), then re-run the tests.
- A rotated `grafana-admin` or `grafana-oidc` restarts it through Reloader (`reloader.md`).
- A new data source or tenant: edit `datasources:` in `overlays/k8s-1/grafana/values.yaml` (the whole list, because Helm replaces lists). The per-tenant organizations must exist first (`tenant-observability/grafana-orgs.sh`).
- Dashboards: `kube-prometheus-stack.md` section 6.

## 6. Risks and open items

- **Dashboards made by hand in the UI** live only in the 2 GiB volume. The volume is in the nightly Longhorn backup only if the Longhorn Volume object carries the backup label (`storage-longhorn.md`, section 8).
- **When an app moves** (namespace or name), Argo CD can sync the *old* spec against the *new* values for a few minutes and run two copies. Apply the new ApplicationSet by hand before pushing, or scale the old workload to 0 after the push settles.
- **The volume cannot change namespace.** A move means a fresh volume and a copy of `/var/lib/grafana`, with the old volume left untouched until the new Grafana is verified.
