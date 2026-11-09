#!/usr/bin/env bash
# t-1219: protects `canon-go promoted-report` as shipped: the dispatch from the built binary, the text report, --json, the usage error (exit 2),
# an unreadable .tickets/ (exit 1, never an empty report), and that the command writes nothing (the scratch tree hashes the same after).
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

work="$(mktemp -d)"; trap 'chmod -R u+rwx "$work" 2>/dev/null || true; rm -rf "$work"' EXIT
export SPRINT_CHECK_NO_BROWSER=1 HOME="$work/home" CANON_HOME="$work/canon" TMPDIR="$work/tmp" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
mkdir -p "$HOME" "$CANON_HOME" "$TMPDIR"
board="$(build_board "$work/board")"
proj="$work/proj"; mkdir -p "$proj/standards" "$proj/.tickets/t-0001"
tree_hash() { (cd "$proj" && find . -path ./.git -prune -o -type f -print | LC_ALL=C sort | xargs cat | { sha256sum 2>/dev/null || shasum -a 256; }); }

printf -- '- a rule (t-aaaa; class: slug-one)\n' > "$proj/standards/efficiency-notes.md"
printf -- '---\nid: t-0001\ncreated: 2026-10-05T10:00:00Z\n---\n' > "$proj/.tickets/t-0001/ticket.md"
printf 'slug-one came back\n' > "$proj/.tickets/t-0001/review-notes.md"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t GIT_AUTHOR_DATE=2026-10-01T12:00:00Z GIT_COMMITTER_DATE=2026-10-01T12:00:00Z
git -C "$proj" init -q && git -C "$proj" add standards && git -C "$proj" commit -q -m one

cd "$proj"
before="$(tree_hash)"
out="$("$board" promoted-report)"
assert_contains "$out" "1 lines, 1 tickets read"
assert_contains "$out" "Mentioned once class 1"
assert_contains "$out" "slug-one (t-aaaa, 2026-10-01)  standards/efficiency-notes.md"
js="$("$board" promoted-report --json)"
assert_contains "$js" '"tickets_read":1'
assert_eq "$before" "$(tree_hash)"

set +e; "$board" promoted-report --nope >/dev/null 2>"$work/err"; code=$?; set -e
assert_eq "2" "$code"
assert_contains "$(cat "$work/err")" "usage: canon-go promoted-report [--json]"

if [[ "$(id -u)" != 0 ]]; then
  chmod 000 "$proj/.tickets"
  set +e; out="$("$board" promoted-report 2>&1)"; code=$?; set -e
  chmod 755 "$proj/.tickets"
  assert_eq "1" "$code"
  assert_contains "$out" "cannot be read"
fi
echo "promoted-report: ok"
