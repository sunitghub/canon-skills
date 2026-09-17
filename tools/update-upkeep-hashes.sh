#!/usr/bin/env bash
# update-upkeep-hashes.sh — regenerate tools/upkeep-skill-hashes.json from the
# current on-disk SKILL.md of each built-in Upkeep skill.
#
# Run this after an intentional edit to one of the four skills' SKILL.md, in
# the same commit as that edit — tools/upkeep-run refuses to headlessly
# dispatch a skill whose current hash doesn't match this manifest, and
# tests/upkeep-skill-hash-parity.sh fails the same way at test time. This is
# what keeps that refusal meaningful: the manifest is the "known good"
# reference a post-clone tamper is checked against, not just a cache of
# whatever happens to be on disk.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST="$ROOT/tools/upkeep-skill-hashes.json"

# Fixed list — mirrors server.py/main.go's own UPKEEP_SKILLS constant and
# tools/upkeep-run's case statement. Adding a fifth built-in skill means
# updating all of these together, not just this one.
SKILLS=(context-check context-doctor dead-code-cleanup promote-learnings)

# Portable sha256 hex of a file — same idiom as gate-cache.sh's
# _gate_cache_sha (sourced there for cache keys; duplicated here as a
# standalone one-liner rather than sourcing an unrelated caching library).
_sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    echo "update-upkeep-hashes: no sha256sum or shasum found" >&2
    exit 1
  fi
}

{
  echo '{'
  last=$((${#SKILLS[@]} - 1))
  for i in "${!SKILLS[@]}"; do
    skill="${SKILLS[$i]}"
    file="$ROOT/skills/$skill/SKILL.md"
    [[ -f "$file" ]] || { echo "update-upkeep-hashes: missing $file" >&2; exit 1; }
    hash="$(_sha256_file "$file")"
    if [[ "$i" -eq "$last" ]]; then
      printf '  "%s": "%s"\n' "$skill" "$hash"
    else
      printf '  "%s": "%s",\n' "$skill" "$hash"
    fi
  done
  echo '}'
} > "$MANIFEST"

echo "Wrote $MANIFEST"
