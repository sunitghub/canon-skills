#!/usr/bin/env bash
# example-paths — every examples/<name> reference in the doc/install surface
# must resolve to a directory that actually exists on disk (repo-audit
# 07-12-2026, t-2f2a). Scoped to a fixed file list, not a repo-wide grep, to
# avoid false positives from unrelated prose (ticket docs, skill examples)
# incidentally mentioning "examples".

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

SURFACE=(
  "$ROOT/README.md"
  "$ROOT/install.sh"
  "$ROOT/install.ps1"
  "$ROOT/bin/install.js"
  "$ROOT/MAP.md"
)
while IFS= read -r f; do SURFACE+=("$f"); done < <(find "$ROOT/docs" -maxdepth 1 -name "*.md" -type f 2>/dev/null)

refs="$(grep -rhoE 'examples/[a-zA-Z0-9_-]+' "${SURFACE[@]}" 2>/dev/null | sort -u)"

missing=0
while IFS= read -r ref; do
  [[ -z "$ref" ]] && continue
  if [[ ! -d "$ROOT/$ref" ]]; then
    echo "Stale reference: $ref (referenced in doc/install surface, but no such directory exists)"
    missing=1
  fi
done <<< "$refs"

[[ "$missing" -eq 1 ]] && fail "one or more examples/<name> references are stale — fix the reference or restore the directory"

echo "example-paths: ok ($(printf '%s\n' "$refs" | grep -c .) reference(s) checked, all resolve)"
