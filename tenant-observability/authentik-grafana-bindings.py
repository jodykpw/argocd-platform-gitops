# Let the tenant groups open the Authentik application "Grafana k8s" (slug grafana-k8s-oauth-app).
# Idempotent. Adds one policy binding per group on that ONE application and changes nothing else in Authentik.
# Run it AFTER the Grafana org_mapping is live (base/kube-prometheus-stack/values.yaml), so a tenant user never reaches
# a Grafana that would put them in the platform organization:
#
#   scp tenant-observability/authentik-grafana-bindings.py adminjody@10.1.5.123:/tmp/
#   ssh adminjody@10.1.5.123 'sudo docker exec -i authentik-server-1 ak shell < /tmp/authentik-grafana-bindings.py'
#
# Dry run: set APPLY = False below. Rollback: delete these bindings in the Authentik admin UI (application
# "Grafana k8s", tab Policy / Group / User Bindings), or run this file with REMOVE = True.
APPLY = True
REMOVE = False
GROUPS = ["zeedlogic-owners", "zeedlogic-developers", "zeedlogic-viewers",
          "jodywan-owners", "jodywan-developers", "jodywan-viewers"]

from authentik.core.models import Application, Group
from authentik.policies.models import PolicyBinding

app = Application.objects.get(slug="grafana-k8s-oauth-app")
print("application:", app.name, "| engine:", app.policy_engine_mode)
order = 10
for name in GROUPS:
    g = Group.objects.get(name=name)
    b = PolicyBinding.objects.filter(target=app, group=g).first()
    if REMOVE:
        if b and APPLY:
            b.delete()
        print("remove", name, "->", "deleted" if (b and APPLY) else "nothing/dry-run")
        continue
    if b:
        print("exists ", name)
    else:
        print("add    ", name, "(dry run)" if not APPLY else "")
        if APPLY:
            PolicyBinding.objects.create(target=app, group=g, order=order, enabled=True, negate=False, timeout=30)
    order += 10
print("bindings now:", sorted((x.order, (x.group.name if x.group else str(x.policy))) for x in PolicyBinding.objects.filter(target=app)))
