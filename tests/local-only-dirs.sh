#!/usr/bin/env bash
# local-only-dirs (t-fc00) — examples/, .tickets/ and .kiro/ are local-only folders:
# never tracked, never promised by the doc/install surface. They had crept into the
# public tree (two `git add -f` style commits and a worked-examples folder whose
# third-party mockups and logo had no recorded permission). A fresh clone has none of
# them, so nothing a user reads or runs may point at them.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

# 1. no path under the three folders is tracked (skipped outside a git checkout)
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  tracked="$(git -C "$ROOT" ls-files examples .tickets .kiro)"
  if [[ -n "$tracked" ]]; then
    fail "tracked local-only path(s), e.g. $(printf '%s\n' "$tracked" | head -3 | tr '\n' ' ')— git rm --cached them; they belong in .gitignore"
  fi
fi

# 2. the doc/install surface does not mention examples/
SURFACE=(
  "$ROOT/README.md"
  "$ROOT/install.sh"
  "$ROOT/install.ps1"
  "$ROOT/bin/install.js"
  "$ROOT/MAP.md"
)
while IFS= read -r f; do SURFACE+=("$f"); done < <(find "$ROOT/docs" -maxdepth 1 -name "*.md" -type f 2>/dev/null)

hits="$(grep -nH 'examples/' "${SURFACE[@]}" 2>/dev/null || true)"
if [[ -n "$hits" ]]; then
  fail "the doc/install surface points at examples/, which is not shipped: $(printf '%s\n' "$hits" | head -3 | tr '\n' ' ')"
fi

echo "local-only-dirs: ok (no tracked path under examples/, .tickets/ or .kiro/; the doc/install surface never points at examples/)"
