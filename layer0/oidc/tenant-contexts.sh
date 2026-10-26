#!/usr/bin/env bash
# Run on the MacBook (not on the server). Creates one kubectl context per test user so you can switch:
#   kubectl config use-context zeedlogic-dev     (or: kubectl --context zeedlogic-dev get ns)
# Needs: kubectl, kubelogin (brew install kubelogin) and, in the current directory:
#   proxy-ca.crt  the public Capsule Proxy certificate, for the six tenant users:
#     kubectl get secret -n capsule-system capsule-proxy -o jsonpath='{.data.tls\.crt}' | base64 -d > proxy-ca.crt
#   k8s-ca.crt    the public cluster CA, for adminjody (the platform admin, direct to the API server)
set -euo pipefail

SERVER="https://10.1.5.171:9001"          # Capsule Proxy (tenant users)
API_SERVER="https://10.1.5.151:6443"      # API server (platform admin only)
ISSUER="https://authentik.jodywan.com/application/o/kube-apiserver-oauth-app/"
CLIENT_ID="BJf5svepOPOag0dbh48rzIvGOhg6I9UagQ0QxQjJ"
CA="$PWD/proxy-ca.crt"
API_CA="$PWD/k8s-ca.crt"
CACHE_ROOT="$HOME/.kube/cache/oidc-login-users"

[ -f "$CA" ] || { echo "proxy-ca.crt not found in $PWD"; exit 1; }
[ -f "$API_CA" ] || { echo "k8s-ca.crt not found in $PWD"; exit 1; }

kubectl config set-cluster k8s-1-proxy --server="$SERVER" --certificate-authority="$CA" --embed-certs=true

# Platform admin: Authentik group cluster-admin, straight to the API server (the proxy ignores this group anyway)
kubectl config set-cluster k8s-1 --server="$API_SERVER" --certificate-authority="$API_CA" --embed-certs=true

for user in adminjody zeedlogic-owner zeedlogic-dev zeedlogic-viewer jodywan-owner jodywan-dev jodywan-viewer; do
  # --token-cache-dir keeps every user's token separate (kubelogin otherwise shares one cache per issuer+client).
  # --skip-open-browser prints the login URL: open it in a private window, because Authentik
  # keeps the previous user's session in the normal browser window.
  kubectl config set-credentials "$user" \
    --exec-api-version=client.authentication.k8s.io/v1 \
    --exec-interactive-mode=IfAvailable \
    --exec-command=kubectl \
    --exec-arg=oidc-login --exec-arg=get-token \
    --exec-arg=--oidc-issuer-url="$ISSUER" \
    --exec-arg=--oidc-client-id="$CLIENT_ID" \
    --exec-arg=--oidc-extra-scope=profile --exec-arg=--oidc-extra-scope=email --exec-arg=--oidc-extra-scope=groups \
    --exec-arg=--token-cache-dir="$CACHE_ROOT/$user" \
    --exec-arg=--skip-open-browser
  if [ "$user" = "adminjody" ]; then cluster=k8s-1; else cluster=k8s-1-proxy; fi
  kubectl config set-context "$user" --cluster="$cluster" --user="$user"
done

kubectl config get-contexts
echo
echo "Switch:  kubectl config use-context zeedlogic-dev"
echo "Log out: rm -rf $CACHE_ROOT/<user>     (forget one user's token)"
