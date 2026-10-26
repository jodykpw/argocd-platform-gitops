#!/usr/bin/env bash
# Tenant GitOps check: the deployer accounts, the AppProjects and the Argo CD impersonation setting.
#
#   ./tests/tenant-gitops.sh            # sections A to C (read-only, uses impersonation and dry runs)
#   E2E=1 ./tests/tenant-gitops.sh      # also D: real syncs in temporary projects (needs the fixture pushed to main)
#
# A. each deployer deploys workloads in ITS tenant only and can never create Roles or RoleBindings (owners do that
#    with kubectl or helm, never through Argo CD)
# B. AppProject lint: no cluster-scoped kinds, destinations and sources only the tenant's, roles reference only their
#    own project
# C. Argo CD impersonation is on and not enforced (platform apps keep using the controller)
# D. a ConfigMap is deployed from Git as the deployer; a Role in Git is refused; an application that targets the
#    OTHER tenant is refused by Kubernetes even though its AppProject allows it (the safety net)
set -uo pipefail
PASS=0; FAIL=0
ok()   { printf '  PASS  %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n' "$*"; FAIL=$((FAIL+1)); }
step() { printf '\n== %s\n' "$*"; }
REPO="https://gitlab.jodywan.com/servers/pcls.jodywan.com/k8s-1.jodywan.com/platform-gitops.git"
cleanup() { kubectl -n argocd delete application zz-e2e-ok zz-e2e-rbac zz-e2e-cross --ignore-not-found --wait=false >/dev/null 2>&1
            # the applications carry a finalizer that needs their project: wait for them to go BEFORE the projects are removed
            kubectl -n argocd wait --for=delete application/zz-e2e-ok application/zz-e2e-rbac application/zz-e2e-cross --timeout=90s >/dev/null 2>&1
            kubectl -n argocd delete appproject zz-e2e-ok zz-e2e-wide --ignore-not-found >/dev/null 2>&1; }
trap cleanup EXIT

step "A. deployer accounts (impersonation)"
for t in zeedlogic jodywan; do
  other=$([ "$t" = zeedlogic ] && echo jodywan || echo zeedlogic)
  A="--as=system:serviceaccount:argocd:argocd-deployer-$t"
  chk() { want="$1"; shift; got=$(kubectl auth can-i "$@" $A 2>/dev/null | head -1); [ "$got" = "$want" ] && ok "$t deployer: $* -> $want" || bad "$t deployer: $* -> got '$got', wanted $want"; }
  for e in dev stg prod; do
    chk yes create deployments -n "$t-$e"
    chk yes create configmaps -n "$t-$e"
    chk no  create roles -n "$t-$e"            # RBAC is the owners' job (kubectl), not Argo CD's
    chk no  create rolebindings -n "$t-$e"
  done
  chk no create deployments -n "$other-dev"
  chk no create rolebindings -n "$other-dev"
  chk no create deployments -n argocd
  chk no create rolebindings -n kube-system
  chk no create clusterroles
  chk no create clusterrolebindings
  # Capsule's namespace-provisioner role gives every Capsule user (owners and these accounts alike) `create namespaces`;
  # the Capsule webhook is the limit: the tenant prefix is forced and the tenant has a namespace quota, and the
  # AppProject has no Namespace kind. So the check is the refusal, not the RBAC answer.
  for nsname in "$other-escape" "kube-escape" "escape-$t"; do
    out=$(kubectl create namespace "$nsname" $A --dry-run=server 2>&1)
    echo "$out" | grep -qi "forbidden\|denied" && ok "$t deployer cannot create namespace $nsname (Capsule refuses)" || bad "$t deployer could create namespace $nsname: $out"
  done
  out=$(kubectl create rolebinding e2e-rb --clusterrole=view --user=nobody -n "$t-dev" $A --dry-run=server 2>&1)
  echo "$out" | grep -qi "forbidden" && ok "$t deployer cannot create a RoleBinding at all" || bad "$t deployer could create a RoleBinding: $out"
done

step "B. AppProjects"
for t in zeedlogic jodywan; do
  other=$([ "$t" = zeedlogic ] && echo jodywan || echo zeedlogic)
  for env in nonprod prod; do
    P="$t-$env"
    if ! kubectl -n argocd get appproject "$P" >/dev/null 2>&1; then bad "AppProject $P missing"; continue; fi
    kubectl -n argocd get appproject "$P" -o json | python3 -I -c '
import json,sys
p=json.load(sys.stdin); s=p["spec"]; t,env=sys.argv[1],sys.argv[2]; name=p["metadata"]["name"]; other=sys.argv[3]
errs=[]
if s.get("clusterResourceWhitelist"): errs.append("clusterResourceWhitelist is not empty")
for d in s["destinations"]:
    if not d["namespace"].startswith(t+"-") or d["namespace"].endswith("*"): errs.append("destination "+d["namespace"])
want={"nonprod":{t+"-dev",t+"-stg"},"prod":{t+"-prod"}}[env]
if {d["namespace"] for d in s["destinations"]}!=want: errs.append("destinations differ from "+str(sorted(want)))
for r in s["sourceRepos"]:
    if not r.startswith("https://gitlab.jodywan.com/"+t+"/") and r != "harbor.jodywan.com/"+t:
        errs.append("sourceRepo "+r)
    if "pcls.jodywan.com" in r or "platform-gitops" in r or r in ("*","https://*"): errs.append("platform or open sourceRepo "+r)
kinds={(k["group"],k["kind"]) for k in s["namespaceResourceWhitelist"]}
for need in [("apps","Deployment"),("","ConfigMap"),("","Service"),("argoproj.io","Rollout"),("external-secrets.io","SecretStore"),("external-secrets.io","ExternalSecret")]:
    if need not in kinds: errs.append("missing "+str(need))
for bad_k in [("rbac.authorization.k8s.io","Role"),("rbac.authorization.k8s.io","RoleBinding"),("rbac.authorization.k8s.io","ClusterRole"),("rbac.authorization.k8s.io","ClusterRoleBinding"),("","Namespace"),("networking.k8s.io","NetworkPolicy"),("external-secrets.io","ClusterSecretStore"),("external-secrets.io","ClusterExternalSecret"),("external-secrets.io","PushSecret"),("*","*")]:
    if bad_k in kinds: errs.append("allowed kind "+str(bad_k))
dsa=s.get("destinationServiceAccounts",[])
if [x["defaultServiceAccount"] for x in dsa]!=["argocd:argocd-deployer-"+t]: errs.append("destinationServiceAccounts "+str(dsa))
for role in s["roles"]:
    for g in role.get("groups",[]):
        if not g.startswith(t+"-"): errs.append("group "+g)
    for pol in role.get("policies",[]):
        parts=[x.strip() for x in pol.split(",")]
        if parts[1]!="proj:"+name+":"+role["name"]: errs.append("policy subject "+pol)
        if parts[2] in ("clusters","projects","accounts","certificates","gpgkeys","applicationsets") and not (parts[2]=="projects" and parts[3]=="get" and parts[4]==name): errs.append("global resource "+pol)
        if parts[2] in ("applications","repositories","logs","exec") and not parts[4].startswith(name+"/"): errs.append("object outside the project "+pol)
        if other in pol: errs.append("mentions the other tenant "+pol)
print("\n".join(errs) if errs else "OK")' "$t" "$env" "$other" > /tmp/tg.$$ 2>&1
    R=$(cat /tmp/tg.$$); rm -f /tmp/tg.$$
    [ "$R" = "OK" ] && ok "AppProject $P is tenant-bound (no cluster kinds, own namespaces, own group, own roles)" || bad "AppProject $P: $R"
  done
done
# prod: developers deploy like owners, viewers only read
for t in zeedlogic jodywan; do
kubectl -n argocd get appproject $t-prod -o json | python3 -I -c '
import json,sys
p=json.load(sys.stdin)
roles={r["name"]:r["policies"] for r in p["spec"]["roles"]}
dev=" ".join(roles["developer"]); view=" ".join(roles["viewer"])
errs=[]
for a in ("applications, create","applications, update","applications, delete","applications, sync"):
    if a not in dev: errs.append("developer lacks "+a)
    if a in view: errs.append("viewer has "+a)
if "exec," in view: errs.append("viewer has exec")
print("OK" if not errs else errs)' | grep -q "^OK$" && ok "$t-prod: developers create and sync like owners, viewers only read" || bad "$t-prod: role mismatch"
done

step "C. Argo CD settings"
E=$(kubectl -n argocd get cm argocd-cm -o jsonpath='{.data.application\.sync\.impersonation\.enabled}')
F=$(kubectl -n argocd get cm argocd-cm -o jsonpath='{.data.application\.sync\.impersonation\.enforced}')
[ "$E" = true ] && ok "application.sync.impersonation.enabled is true" || bad "impersonation not enabled ('$E')"
[ "$F" = false ] && ok "enforced is false (the platform project keeps using the controller)" || bad "enforced is '$F' (must be false or platform apps stop syncing)"
kubectl -n argocd get app --no-headers | awk '{print $2,$3}' | sort | uniq -c | grep -v "Synced Healthy" | grep -q . && bad "an Argo CD application is not Synced and Healthy" || ok "all existing applications are Synced and Healthy"

if [ -n "${E2E:-}" ]; then
step "D. end to end (temporary projects zz-e2e-*, fixture tests/fixtures/tenant-app from main)"
mk_project() { # name destination-namespace sa-namespace-pattern
kubectl apply -f - >/dev/null <<YAML
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata: {name: $1, namespace: argocd}
spec:
  sourceRepos: ["$REPO"]
  destinations: [{server: https://kubernetes.default.svc, namespace: "$2"}]
  clusterResourceWhitelist: []
  namespaceResourceWhitelist:
    - {group: "", kind: ConfigMap}
  destinationServiceAccounts:
    - {server: https://kubernetes.default.svc, namespace: "$2", defaultServiceAccount: "argocd:argocd-deployer-zeedlogic"}
YAML
}
mk_app() { # app project dest-namespace [path]
kubectl apply -f - >/dev/null <<YAML
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: $1, namespace: argocd, finalizers: [resources-finalizer.argocd.argoproj.io]}
spec:
  project: $2
  source: {repoURL: "$REPO", targetRevision: main, path: ${4:-tests/fixtures/tenant-app}}
  destination: {server: https://kubernetes.default.svc, namespace: $3}
  syncPolicy: {syncOptions: [ServerSideApply=true]}
YAML
}
sync() { kubectl -n argocd patch application "$1" --type merge -p '{"operation":{"sync":{}}}' >/dev/null 2>&1
  for i in $(seq 1 40); do ph=$(kubectl -n argocd get application "$1" -o jsonpath='{.status.operationState.phase}' 2>/dev/null); case "$ph" in Succeeded|Failed|Error) break;; esac; sleep 3; done; echo "$ph"; }
mk_project zz-e2e-ok zeedlogic-dev; mk_app zz-e2e-ok zz-e2e-ok zeedlogic-dev
R=$(sync zz-e2e-ok)
[ "$R" = Succeeded ] && ok "application in a nonprod-style project synced as the deployer" || bad "sync of the in-tenant application: $R ($(kubectl -n argocd get application zz-e2e-ok -o jsonpath='{.status.operationState.message}' | cut -c1-160))"
kubectl -n zeedlogic-dev get configmap e2e-probe >/dev/null 2>&1 && ok "ConfigMap created in zeedlogic-dev from Git" || bad "ConfigMap not created"
# a Role in Git is not deployable through Argo CD
mk_app zz-e2e-rbac zz-e2e-ok zeedlogic-dev tests/fixtures/tenant-app-rbac
R=$(sync zz-e2e-rbac)
MSG=$(kubectl -n argocd get application zz-e2e-rbac -o jsonpath='{.status.operationState.message}{" "}{.status.conditions[*].message}' | cut -c1-300)
if [ "$R" != Succeeded ] && echo "$MSG" | grep -qi -E "not permitted|not allowed|whitelist|forbidden"; then ok "a Role in Git is refused by Argo CD (owners manage RBAC with kubectl)"
else bad "a Role from Git was not refused (phase '$R'): $MSG"; fi
kubectl -n zeedlogic-dev get role e2e-from-git >/dev/null 2>&1 && bad "the Role was created in zeedlogic-dev" || ok "no Role was created in zeedlogic-dev"
# the project says it may go anywhere, the account of zeedlogic must still be refused in jodywan-dev
mk_project zz-e2e-wide "jodywan-*"; mk_app zz-e2e-cross zz-e2e-wide jodywan-dev
R=$(sync zz-e2e-cross)
if [ "$R" = Failed ] || [ "$R" = Error ]; then
  MSG=$(kubectl -n argocd get application zz-e2e-cross -o jsonpath='{.status.operationState.message}{" "}{.status.operationState.syncResult.resources[*].message}' | cut -c1-300)
  echo "$MSG" | grep -q -i -E "forbidden|cannot|denied" && ok "zeedlogic deployer refused in jodywan-dev by Kubernetes/Capsule even though the project allowed it" || bad "failed for another reason: $MSG"
else bad "the cross-tenant application did not fail (phase '$R'): the safety net is not working"; fi
kubectl -n jodywan-dev get configmap e2e-probe >/dev/null 2>&1 && bad "an object was created in jodywan-dev" || ok "nothing was created in jodywan-dev"
fi

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] && echo "TENANT GITOPS CHECK: OK"
exit "$FAIL"
