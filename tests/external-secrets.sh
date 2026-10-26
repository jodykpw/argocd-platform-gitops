#!/usr/bin/env bash
# External Secrets pass check: operator, cert controller and webhook run, the CRDs and the webhook CA are in place,
# a store (fake provider, no GitLab needed) fills a Secret and a changed value is picked up, tenants can create a
# GitLab SecretStore and an ExternalSecret in their own namespace and nothing else (other providers, other URLs,
# ClusterSecretStore, ClusterExternalSecret, PushSecret, generators, the other tenant), and Prometheus holds the
# operator's metrics. A real GitLab round trip needs a project and a token: docs/external-secrets.md ("Check GitLab").
#
#   ./tests/external-secrets.sh
#   NS=external-secrets ./tests/external-secrets.sh
#
# Creates and removes the namespace `eso-test`; tenant checks use server side dry runs and create nothing.
set -uo pipefail
NS="${NS:-external-secrets}"
T=eso-test
PASS=0; FAIL=0
ok()   { printf '  PASS  %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n' "$*"; FAIL=$((FAIL+1)); }
step() { printf '\n== %s\n' "$*"; }
PF=""
cleanup() { [ -n "$PF" ] && kill "$PF" 2>/dev/null; kubectl delete ns "$T" --ignore-not-found --wait=false >/dev/null 2>&1; }
trap cleanup EXIT

step "1. components"
for d in external-secrets external-secrets-cert-controller external-secrets-webhook; do
  R=$(kubectl -n "$NS" get deploy "$d" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  [ "${R:-0}" -ge 1 ] && ok "deployment $d ready" || bad "deployment $d not ready"
done
RT=$(kubectl -n "$NS" get pods -o json | python3 -I -c 'import json,sys
n=0
for p in json.load(sys.stdin)["items"]:
    for c in p["status"].get("containerStatuses",[]): n+=c["restartCount"]
print(n)')
[ "${RT:-1}" -eq 0 ] && ok "no container restarts" || bad "containers restarted $RT times"
for c in externalsecrets secretstores clustersecretstores; do
  kubectl get crd "$c.external-secrets.io" >/dev/null 2>&1 && ok "CRD $c installed" || bad "CRD $c missing"
done
CA=$(kubectl get validatingwebhookconfiguration secretstore-validate -o jsonpath='{.webhooks[0].clientConfig.caBundle}' 2>/dev/null)
[ -n "$CA" ] && ok "webhook configuration has its CA bundle (cert controller works)" || bad "webhook CA bundle is empty"
L=$(kubectl get ns "$NS" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}')
[ "$L" = baseline ] && ok "namespace $NS enforces Pod Security baseline" || bad "namespace $NS Pod Security is '$L'"
ARGS=$(kubectl -n "$NS" get deploy external-secrets -o jsonpath='{.spec.template.spec.containers[0].args}')
case "$ARGS" in *enable-cluster-external-secret-reconciler=false*) ok "ClusterExternalSecret processing is off";; *) bad "ClusterExternalSecret processing is on";; esac
case "$ARGS" in *enable-push-secret-reconciler=false*) ok "PushSecret processing is off";; *) bad "PushSecret processing is on";; esac

step "2. a store fills a Secret and follows a change (fake provider)"
kubectl create ns "$T" >/dev/null 2>&1
cat <<YAML | kubectl -n "$T" apply -f - >/dev/null
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata: {name: fake}
spec:
  provider:
    fake:
      data:
        - {key: /test/password, value: first-value}
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata: {name: test}
spec:
  refreshInterval: 10s
  secretStoreRef: {name: fake, kind: SecretStore}
  target: {name: test-secret}
  data:
    - {secretKey: password, remoteRef: {key: /test/password}}
YAML
V=""
for i in $(seq 1 30); do V=$(kubectl -n "$T" get secret test-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d); [ -n "$V" ] && break; sleep 2; done
[ "$V" = first-value ] && ok "Secret test-secret created with the stored value" || bad "Secret value is '$V'"
ST=$(kubectl -n "$T" get externalsecret test -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
[ "$ST" = True ] && ok "ExternalSecret is Ready" || bad "ExternalSecret Ready is '$ST'"
kubectl -n "$T" patch secretstore fake --type=merge -p '{"spec":{"provider":{"fake":{"data":[{"key":"/test/password","value":"second-value"}]}}}}' >/dev/null
for i in $(seq 1 30); do V=$(kubectl -n "$T" get secret test-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d); [ "$V" = second-value ] && break; sleep 2; done
[ "$V" = second-value ] && ok "a changed value reaches the Secret within the refresh interval" || bad "Secret still '$V' after the store changed"
kubectl -n "$T" delete externalsecret test >/dev/null 2>&1
for i in $(seq 1 15); do kubectl -n "$T" get secret test-secret >/dev/null 2>&1 || break; sleep 2; done
kubectl -n "$T" get secret test-secret >/dev/null 2>&1 && bad "Secret remained after its ExternalSecret was deleted" || ok "the Secret is removed with its ExternalSecret"

step "3. tenants: own namespace, GitLab only"
# as <user> <group> <namespace> <yaml>: server side dry run create as that user; prints OK or the refusal
as() {
  printf '%s\n' "$4" | kubectl create --dry-run=server -n "$3" -f - --as="$1" --as-group="oidc:$2" --as-group=system:authenticated 2>&1
}
GOOD=$'apiVersion: external-secrets.io/v1\nkind: SecretStore\nmetadata: {name: gl}\nspec:\n  provider:\n    gitlab:\n      url: https://gitlab.jodywan.com\n      projectID: "1"\n      auth:\n        SecretRef:\n          accessToken: {name: gitlab-token, key: token}'
R=$(as dev@zeedlogic.com zeedlogic-developers zeedlogic-dev "$GOOD")
case "$R" in *"(server dry run)"*) ok "developer can create a GitLab SecretStore in zeedlogic-dev";; *) bad "GitLab SecretStore refused: $R";; esac
R=$(as dev@zeedlogic.com zeedlogic-developers jodywan-dev "$GOOD")
case "$R" in *Forbidden*|*forbidden*) ok "developer cannot create it in the other tenant's namespace";; *) bad "created in jodywan-dev: $R";; esac
BADURL="${GOOD/https:\/\/gitlab.jodywan.com/http://10.1.5.170}"
R=$(as dev@zeedlogic.com zeedlogic-developers zeedlogic-dev "$BADURL")
case "$R" in *"must be https://gitlab.jodywan.com"*) ok "another gitlab url is refused";; *) bad "other url not refused: $R";; esac
KUBE=$'apiVersion: external-secrets.io/v1\nkind: SecretStore\nmetadata: {name: k}\nspec:\n  provider:\n    kubernetes:\n      remoteNamespace: kube-system\n      server: {url: https://kubernetes.default.svc}\n      auth: {serviceAccount: {name: default}}'
R=$(as dev@zeedlogic.com zeedlogic-developers zeedlogic-dev "$KUBE")
case "$R" in *"gitlab provider and no other"*) ok "the kubernetes provider is refused";; *) bad "kubernetes provider not refused: $R";; esac
FAKE=$'apiVersion: external-secrets.io/v1\nkind: SecretStore\nmetadata: {name: f}\nspec:\n  provider:\n    fake:\n      data: [{key: a, value: b}]'
R=$(as dev@zeedlogic.com zeedlogic-developers zeedlogic-dev "$FAKE")
case "$R" in *"gitlab provider and no other"*) ok "other providers are refused";; *) bad "fake provider not refused: $R";; esac
NSTOK="${GOOD/accessToken: \{name: gitlab-token, key: token\}/accessToken: {name: gitlab-token, key: token, namespace: external-secrets}}"
R=$(as dev@zeedlogic.com zeedlogic-developers zeedlogic-dev "$NSTOK")
case "$R" in *"no namespace field"*) ok "a token Secret from another namespace is refused";; *) bad "token namespace not refused: $R";; esac
ES=$'apiVersion: external-secrets.io/v1\nkind: ExternalSecret\nmetadata: {name: e}\nspec:\n  secretStoreRef: {name: gl, kind: SecretStore}\n  target: {name: x}\n  data: [{secretKey: a, remoteRef: {key: A}}]'
R=$(as dev@zeedlogic.com zeedlogic-developers zeedlogic-dev "$ES")
case "$R" in *"(server dry run)"*) ok "developer can create an ExternalSecret that uses a SecretStore";; *) bad "ExternalSecret refused: $R";; esac
CES="${ES/kind: SecretStore/kind: ClusterSecretStore}"
R=$(as dev@zeedlogic.com zeedlogic-developers zeedlogic-dev "$CES")
case "$R" in *"SecretStore of its own namespace"*) ok "an ExternalSecret that names a ClusterSecretStore is refused";; *) bad "ClusterSecretStore reference not refused: $R";; esac
OWN=(--as=owner@zeedlogic.com --as-group=oidc:zeedlogic-owners --as-group=system:authenticated)
# cluster-scoped kinds: no -n (with -n the RBAC authorizer answers from the namespace's RoleBindings and says yes wrongly)
for kind in clustersecretstores clusterexternalsecrets clusterpushsecrets clustergenerators; do
  C=$(kubectl auth can-i create "$kind" "${OWN[@]}" 2>/dev/null | tail -1)
  [ "$C" = no ] && ok "even the tenant owner cannot create $kind" || bad "owner can create $kind"
done
C=$(kubectl auth can-i create pushsecrets.external-secrets.io -n zeedlogic-dev "${OWN[@]}" 2>/dev/null)
[ "$C" = no ] && ok "even the tenant owner cannot create pushsecrets" || bad "owner can create pushsecrets"
for g in passwords webhooks vaultdynamicsecrets gitlabdeploytokens; do
  C=$(kubectl auth can-i create "$g.generators.external-secrets.io" -n zeedlogic-dev "${OWN[@]}" 2>/dev/null)
  [ "$C" = no ] && ok "tenant owner has no rights on the $g generator" || bad "owner can create $g generators"
done
C=$(kubectl auth can-i create secretstores.external-secrets.io -n zeedlogic-dev --as=viewer@zeedlogic.com --as-group=oidc:zeedlogic-viewers --as-group=system:authenticated 2>/dev/null)
[ "$C" = no ] && ok "a viewer cannot create SecretStores" || bad "viewer can create SecretStores"
C=$(kubectl auth can-i list externalsecrets.external-secrets.io -n zeedlogic-dev --as=viewer@zeedlogic.com --as-group=oidc:zeedlogic-viewers --as-group=system:authenticated 2>/dev/null)
[ "$C" = yes ] && ok "a viewer can read ExternalSecrets" || bad "viewer cannot read ExternalSecrets"

step "4. metrics"
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 19097:9090 >/dev/null 2>&1 & PF=$!
sleep 3
N=0
for i in $(seq 1 12); do
  N=$(curl -s -m 15 -G "http://127.0.0.1:19097/api/v1/query" --data-urlencode 'query=count({__name__=~"externalsecret_.*",namespace="'"$NS"'"}) or count({__name__=~"externalsecret_.*"})' | python3 -I -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else 0)' 2>/dev/null)
  [ "${N:-0}" != 0 ] && break; sleep 10
done
[ "${N:-0}" != 0 ] && ok "Prometheus has externalsecret_* metrics ($N series)" || bad "no externalsecret_* series (ServiceMonitor, scrape interval)"

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] && echo "EXTERNAL SECRETS CHECK: OK"
exit "$FAIL"
