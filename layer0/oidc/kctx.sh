#!/usr/bin/env zsh
# kctx — kubectl context switcher for k8s-1
# Source this file or copy the function into ~/.zshrc
#
# Usage:
#   kctx              show numbered menu, pick a context
#   kctx adminjody    switch directly by name
#   kswtich / kswitch aliases for kctx
#
# What it does:
#   1. Clears the cached OIDC token for the chosen context
#   2. Switches kubectl to that context
#   3. Copies the context name (= Authentik username) to the clipboard
#   4. Opens Chrome incognito with a fresh profile (no Authentik session)
#   5. Waits for login to complete, then prints auth whoami

kctx() {
  local ctx="$1"
  if [[ -z "$ctx" ]]; then
    local -a contexts
    contexts=($(kubectl config get-contexts -o name 2>/dev/null))
    echo "Select a context:"
    local i=1
    for c in $contexts; do
      echo "  $i) $c"
      (( i++ ))
    done
    printf "#? "
    read num
    ctx="${contexts[$num]}"
    if [[ -z "$ctx" ]]; then
      echo "Invalid selection"
      return 1
    fi
  fi
  rm -rf ~/.kube/cache/oidc-login-users/"$ctx"
  kubectl config use-context "$ctx"
  echo "Switched to $ctx — starting login..."

  # Run kubectl in background, capture output to temp file
  local tmpout
  tmpout=$(mktemp)
  kubectl auth whoami >"$tmpout" 2>&1 &
  local kpid=$!

  # Wait for kubelogin to print the localhost URL (it prints while waiting for browser)
  local url="" waited=0
  while [[ $waited -lt 30 && -z "$url" ]]; do
    sleep 0.3
    url=$(grep -o 'http://localhost[^ ]*' "$tmpout" 2>/dev/null | head -1)
    (( waited++ ))
  done

  if [[ -n "$url" ]]; then
    # Copy context name (= Authentik username) to clipboard — paste into Authentik login form
    echo -n "$ctx" | pbcopy
    echo "📋 Copied to clipboard: $ctx"
    # Open Chrome incognito with a fresh temp profile — no existing Authentik session
    echo "Opening Chrome incognito for $ctx..."
    open -na "Google Chrome" --args \
      --user-data-dir="/tmp/chrome-kctx-$$" \
      --incognito "$url"
    echo "Paste the username from clipboard, log in, then wait..."
    wait $kpid
    echo ""
    cat "$tmpout"
  else
    echo "Could not get login URL — run: kubectl auth whoami"
    echo "Open the URL it prints in a Chrome incognito window"
    wait $kpid 2>/dev/null
    cat "$tmpout"
  fi
  rm -f "$tmpout"
}

alias kswitch=kctx
alias kswtich=kctx
