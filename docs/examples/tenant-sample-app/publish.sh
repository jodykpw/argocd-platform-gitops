#!/usr/bin/env bash
# Publish the sample app to its GitLab repo. Asks for a GitLab token with a silent prompt (never on the command line,
# never in shell history). The token needs `write_repository` (role Developer or higher).
#
#   ./publish.sh                                   # default repo below
#   REPO=https://gitlab.jodywan.com/zeedlogic/gitops/sample-app.git ./publish.sh
#
# Copies configmap.yaml, deployment.yaml, service.yaml and README.md to the repo root and pushes to `main`. If `main`
# is protected and refuses the push, it pushes the branch `add-sample-app` instead (open a merge request in GitLab).
set -euo pipefail
REPO="${REPO:-https://gitlab.jodywan.com/zeedlogic/gitops/sample-app.git}"
SRC="$(cd "$(dirname "$0")" && pwd)"
FILES="configmap.yaml deployment.yaml service.yaml README.md"
for f in $FILES; do [ -f "$SRC/$f" ] || { echo "missing $SRC/$f"; exit 1; }; done

read -r -s -p "GitLab token (write_repository): " GIT_TOKEN; echo
[ -n "$GIT_TOKEN" ] || { echo "empty token"; exit 1; }
export GIT_TOKEN
ASK="$(mktemp)"; W="$(mktemp -d)"
trap 'rm -rf "$ASK" "$W"; unset GIT_TOKEN' EXIT
# git asks this helper for the user name and the password; the token is read from the environment, not from argv
printf '#!/bin/sh\ncase "$1" in Username*) echo oauth2 ;; *) echo "$GIT_TOKEN" ;; esac\n' > "$ASK"
chmod 700 "$ASK"
export GIT_ASKPASS="$ASK" GIT_TERMINAL_PROMPT=0

git clone -q "$REPO" "$W/repo" 2>&1 | sed 's/^/  /' || true
[ -d "$W/repo/.git" ] || { echo "clone failed: check the URL and that the token can read the repo"; exit 1; }
cd "$W/repo"
git checkout -q -B main 2>/dev/null || true
for f in $FILES; do cp "$SRC/$f" .; done
git add -A
if git diff --cached --quiet; then echo "nothing to commit: the repo already has these files"; exit 0; fi
NAME="$(git config --global user.name || true)"; MAIL="$(git config --global user.email || true)"
git -c user.name="${NAME:-platform-admin}" -c user.email="${MAIL:-platform-admin@jodywan.com}" \
    commit -q -m "Sample app for the first Argo CD test"
OUT="$(git push -q origin main 2>&1)" && { echo "pushed to main: $REPO"; exit 0; }
case "$OUT" in
  *403*|*"not allowed"*)
    echo "push refused (403): this token can read the repo but not write to it."
    echo "  It needs the scope write_repository and the role Developer or higher in the group."
    echo "  (a token with only read_repository, such as the Argo CD one, can never push.)"
    exit 1 ;;
  *protected*|*"pre-receive"*|*"not allowed to push"*)
    echo "main is protected and refused the push. Pushing the branch add-sample-app instead."
    git push -q origin HEAD:add-sample-app && echo "pushed branch add-sample-app: open a merge request in GitLab" ;;
  *)
    echo "push failed:"; echo "$OUT" | sed 's/^/  /'; exit 1 ;;
esac
