#!/usr/bin/env bash
# t-1583: every agents/*.md declares the fixed template fields, so a reader (or the Integrity card) never parses prose
# for permissions. AGENTS_DIR overrides the folder (the revert checks run on a scratch copy).
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

dir="${AGENTS_DIR:-$ROOT/agents}"
fm() { awk -v k="$2" 'NR==1{next} /^---/{exit} index($0, k": ")==1 {print substr($0, length(k)+3)}' "$1"; }

shopt -s nullglob
files=("$dir"/*.md)
(( ${#files[@]} > 0 )) || { echo "FAIL: no agent files in $dir"; exit 1; }
for f in "${files[@]}"; do
  n="$(basename "$f")"
  for k in purpose model effort tools writes shell graded-by; do
    [[ -n "$(fm "$f" "$k")" ]] || { echo "FAIL: $n: missing or empty frontmatter field '$k'"; exit 1; }
  done
  case "$(fm "$f" shell)" in none|read-only|pinned-env) ;; *) echo "FAIL: $n: unknown shell value '$(fm "$f" shell)'"; exit 1 ;; esac
done
echo "ok: ${#files[@]} agent files declare the template fields"
