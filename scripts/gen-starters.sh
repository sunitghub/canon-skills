#!/usr/bin/env bash
# gen-starters.sh — sync flat-copy files from their source into starters/
# To add a new sync pair: append a "src:dst" entry to SYNC_PAIRS below.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# source:destination pairs (paths relative to REPO_ROOT)
SYNC_PAIRS=(
  "standards/efficiency.md:starters/standards/efficiency.md"
)

for pair in "${SYNC_PAIRS[@]}"; do
  src="${pair%%:*}"
  dst="${pair##*:}"
  cp "$REPO_ROOT/$src" "$REPO_ROOT/$dst"
  echo "starters: $dst synced from $src"
done
