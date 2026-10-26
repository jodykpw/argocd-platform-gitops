#!/usr/bin/env bash
set -euo pipefail

CHART_VERSION="10.10.1"
NAMESPACE="argocd"

cd "$(dirname "$(readlink -f "$0")")"

# Usage:
#   ./deploy.sh            install or upgrade Argo CD
#   ./deploy.sh platform   apply the platform AppProject (after Argo CD is running)
# The AppProject lives in the platform-gitops repo (it lists every chart and Git repo the apps may use). The old
# The old argocd/platform-project.yaml was removed because applying it would have removed those.
if [ "${1:-}" = "platform" ]; then
  PROJECT="../../bootstrap/platform-project.yaml"
  [ -f "$PROJECT" ] || { echo "missing $PROJECT"; exit 1; }
  kubectl apply -f "$PROJECT"
  kubectl get appprojects -n "$NAMESPACE"
  exit 0
fi

# The Authentik client secret is not in values.yaml. Copy the file you already have next to this script:
#   Create patch-secret.yaml here (stringData: dex.authentik.clientSecret)
# It is added to argocd-secret after the install (and again on every run), and is git-ignored.
# In GitLab CI the secret comes from the masked, protected variable ARGOCD_AUTHENTIK_CLIENT_SECRET instead of a file;
# the file is written for this run only and removed on exit (.gitlab-ci.yml, job deploy-argocd).
if [ ! -f patch-secret.yaml ] && [ -n "${ARGOCD_AUTHENTIK_CLIENT_SECRET:-}" ]; then
  umask 077
  printf 'stringData:\n  dex.authentik.clientSecret: "%s"\n' "$ARGOCD_AUTHENTIK_CLIENT_SECRET" > patch-secret.yaml
  trap 'rm -f patch-secret.yaml' EXIT
fi
[ -f patch-secret.yaml ] || { echo "patch-secret.yaml missing (see the comment above)"; exit 1; }

helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo update argo

if helm status argocd -n "$NAMESPACE" >/dev/null 2>&1; then
  helm get values argocd -n "$NAMESPACE" -o yaml > "backup-values-$(date +%F).yaml"
fi

# Prerequisites of values.yaml (httproute.enabled): the chart renders an HTTPRoute, so the Gateway API CRDs must exist, and the
# namespace must carry gateway-access=platform or the Traefik listener refuses the route. On a fresh cluster neither
# exists yet (the gateway-api-crds app comes after Argo CD). Both steps are no-ops on a cluster that has them: the CRDs
# are only applied when missing, so the field ownership of the Argo CD app is not disturbed.
if ! kubectl get crd httproutes.gateway.networking.k8s.io >/dev/null 2>&1; then
  echo "Gateway API CRDs missing: applying ../../gateway-api-crds/ (server-side, the file is over 256 KiB)"
  kubectl apply --server-side -f ../../gateway-api-crds/
  kubectl wait --for=condition=Established crd/httproutes.gateway.networking.k8s.io crd/gateways.gateway.networking.k8s.io --timeout=60s
fi
kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$NAMESPACE"
kubectl label namespace "$NAMESPACE" gateway-access=platform --overwrite

helm upgrade --install argocd argo/argo-cd \
  --version "$CHART_VERSION" \
  --namespace "$NAMESPACE" --create-namespace \
  -f values.yaml \
  --atomic --wait --timeout 10m

# Add the Authentik client secret to argocd-secret, then restart Dex so it reads it
kubectl -n "$NAMESPACE" patch secret argocd-secret --patch-file patch-secret.yaml
kubectl -n "$NAMESPACE" rollout restart deployment argocd-dex-server
kubectl -n "$NAMESPACE" rollout status deployment argocd-dex-server --timeout=120s

kubectl get pods -n "$NAMESPACE"
kubectl get httproute -n "$NAMESPACE"

# CI only: wire Argo CD to this repo (AppProject, OCI repositories, the top-level Application).
# By hand these are applied as before (./deploy.sh platform, kubectl apply -f ../../bootstrap/...).
if [ "${CI:-}" = "true" ]; then
  kubectl apply -f ../../bootstrap/platform-project.yaml -f ../../bootstrap/oci-repos.yaml
  kubectl apply -f ../../bootstrap/platform-gitops.yaml
fi
