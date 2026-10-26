#!/usr/bin/env bash
# Template guard: base/ holds only what is generic. Fails when a base values file has, outside a comment line, a domain
# of this site, an address of its network, a tenant name, a mail or identity provider, or sizing and placement
# (resources, replicas, storage class, volume size, retention, priority class). Those belong in
# overlays/<cluster>/ (docs/repo-layout.md). Read-only, no cluster needed.
#
#   ./tests/overlay-split.sh
#   PATTERN='jodywan\.com|10\.1\.5\.|zeedlogic' ./tests/overlay-split.sh
set -uo pipefail
cd "$(dirname "$0")/.."
PATTERN="${PATTERN:-k8s-1|/var/log|/var/lib/fluent|jodywan\\.com|10\\.1\\.5\\.|zeedlogic|jodywan[^.]|smtp|gmail|authentik|[a-z0-9]@[a-z]|storageClass(Name)?:|retention_period|retention:|retentionSize|retention\\.resolution|priorityClassName|^\\s*resources:\\s*(\\{|$)|^\\s*size:|replicas: [1-9]|replicaCount}"
FAIL=0
while IFS= read -r f; do
  hits=$(grep -n -E "$PATTERN" "$f" | grep -v -E '^[0-9]+:\s*#' || true)
  if [ -n "$hits" ]; then FAIL=$((FAIL+1)); printf '  FAIL  %s\n%s\n' "$f" "$(echo "$hits" | sed 's/^/        /')"; else printf '  PASS  %s\n' "$f"; fi
done < <(find base -name '*.yaml' | sort)
printf '\nfiles with cluster data in base/: %d\n' "$FAIL"
[ "$FAIL" -eq 0 ]
