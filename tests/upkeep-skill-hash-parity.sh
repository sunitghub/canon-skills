#!/usr/bin/env bash
# upkeep-skill-hash-parity — pins tools/upkeep-skill-hashes.json against the
# actual current content of each built-in Upkeep skill's SKILL.md (t-92f4).
#
# tools/upkeep-run refuses to headlessly dispatch a skill whose SKILL.md
# doesn't match this manifest — that refusal is only meaningful if the
# manifest itself tracks intentional edits. This test is the "did you forget
# to regenerate it" catch: it fails at PR/test time instead of upkeep-run
# silently refusing to run for everyone after a legitimate skill edit ships.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$ROOT/tools/upkeep-skill-hashes.json"
SKILLS=(context-check context-doctor dead-code-cleanup promote-learnings)

_sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    echo "upkeep-skill-hash-parity: no sha256sum or shasum found — skipped"
    exit 0
  fi
}

[[ -f "$MANIFEST" ]] || { printf 'FAIL: %s not found\n' "$MANIFEST"; exit 1; }

fails=0
for skill in "${SKILLS[@]}"; do
  file="$ROOT/skills/$skill/SKILL.md"
  if [[ ! -f "$file" ]]; then
    printf '  FAIL %s: %s not found\n' "$skill" "$file"
    fails=$((fails + 1))
    continue
  fi
  pinned="$(grep -o "\"$skill\"[[:space:]]*:[[:space:]]*\"[a-f0-9]*\"" "$MANIFEST" | grep -o '[a-f0-9]\{64\}')"
  if [[ -z "$pinned" ]]; then
    printf '  FAIL %s: no entry in %s\n' "$skill" "$MANIFEST"
    fails=$((fails + 1))
    continue
  fi
  actual="$(_sha256_file "$file")"
  if [[ "$actual" != "$pinned" ]]; then
    printf '  FAIL %s: manifest has %s, SKILL.md hashes to %s\n' "$skill" "$pinned" "$actual"
    printf '       run tools/update-upkeep-hashes.sh and commit the updated manifest\n'
    fails=$((fails + 1))
  fi
done

if [[ "$fails" -eq 0 ]]; then
  printf 'upkeep-skill-hash-parity: ok (%d skills)\n' "${#SKILLS[@]}"
else
  printf '\nupkeep-skill-hash-parity: FAIL (%d)\n' "$fails"
  exit 1
fi
