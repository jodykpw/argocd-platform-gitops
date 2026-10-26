#!/usr/bin/env bash
# Give Argo CD the read-only token for one GitLab repo, scoped to one Argo CD project. Silent prompt: the token is never
# on a command line or in shell history.
#
#   ./argocd-repo-credential.sh                                             # zeedlogic sample app (defaults)
#   REPO=https://gitlab.jodywan.com/jodywan/gitops/sample-app.git PROJECT=jodywan-nonprod NAME=repo-jodywan-sample-app ./argocd-repo-credential.sh
set -euo pipefail
REPO="${REPO:-https://gitlab.jodywan.com/zeedlogic/gitops/sample-app.git}"
PROJECT="${PROJECT:-zeedlogic-nonprod}"
NAME="${NAME:-repo-zeedlogic-sample-app}"
read -r -s -p "argocd-read token (read_repository): " T; echo
[ -n "$T" ] || { echo "empty token"; exit 1; }
# heredoc and printf are shell builtins: the token does not appear in any process argument list
kubectl apply -f - <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: $NAME
  namespace: argocd
  labels: {argocd.argoproj.io/secret-type: repository}
type: Opaque
stringData:
  type: git
  url: $REPO
  username: argocd-read
  password: "$T"
  project: $PROJECT
YAML
unset T
echo "repository registered for project $PROJECT: $REPO"
