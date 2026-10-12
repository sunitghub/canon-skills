#!/usr/bin/env bash
# prefix-keys-parity — t-a198: the keyboard prefix handler is copied into three pages that share no module system
# (the shell, the board, and the terminal page embedded in the daemon). The copies must stay byte-identical.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

# t-c58e: the board's copy lives in whichever of its scripts holds it, so check the board's sources as one text.
# t-565f: so does the shell's (cockpit.html or the static/cockpit-*.js module that holds it).
board="$(mktemp)"; shell="$(mktemp)"
trap 'rm -f "$board" "$shell"' EXIT
board_sources "$ROOT" > "$board"
shell_sources "$ROOT" > "$shell"

files=(
  "$shell"
  "$board"
  "$ROOT/tools/cockpit-daemon/web/cockpit.html"
)
ref=""
for f in "${files[@]}"; do
  [ "$(grep -c 'canon:prefix-keys:begin' "$f")" -eq 1 ] || fail "$f: expected exactly one canon:prefix-keys:begin marker"
  [ "$(grep -c 'canon:prefix-keys:end' "$f")" -eq 1 ] || fail "$f: expected exactly one canon:prefix-keys:end marker"
  sum="$(sed -n '/canon:prefix-keys:begin/,/canon:prefix-keys:end/p' "$f" | cksum)"
  [ -n "$ref" ] || ref="$sum"
  [ "$sum" = "$ref" ] || fail "prefix-keys snippet in $f differs from the one in ${files[0]}"
done
echo "prefix-keys-parity: ok (3 identical copies)"
