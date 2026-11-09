#!/usr/bin/env bash
# t-a05d: protects `canon-go gate-corpus` as shipped: the dispatch from the built binary, the text report, --json, the usage error (exit 2),
# an unreadable .tickets/ (exit 1, never an empty report), and that the command writes nothing (the scratch tree hashes the same after).
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

work="$(mktemp -d)"; trap 'chmod -R u+rwx "$work" 2>/dev/null || true; rm -rf "$work"' EXIT
export HOME="$work/home" CANON_HOME="$work/canon" TMPDIR="$work/tmp"; mkdir -p "$HOME" "$CANON_HOME" "$TMPDIR"
board="$(build_board "$work/board")"
proj="$work/proj"; mkdir -p "$proj/.tickets/t-aaaa" "$proj/.tickets/t-bbbb"
tree_hash() { (cd "$proj" && find . -type f | LC_ALL=C sort | xargs cat | { sha256sum 2>/dev/null || shasum -a 256; }); }

printf 'Model: claude-opus-4\nReviewed: 2026-10-02\n\n## Findings\n\nnone\n\n## Triage\n\nAct On: a.go:1 — x\nNoted: b.go:2 — y\n\n## Verdict\n\nYES\n' > "$proj/.tickets/t-aaaa/review-notes.md"
printf 'Evaluated: 2026-10-03\n\n| 1 | Safe | pass |\n| 2 | Other | fail |\n\n## Verdict: pass\n' > "$proj/.tickets/t-bbbb/eval-report.md"

cd "$proj"
before="$(tree_hash)"
out="$("$board" gate-corpus)"
assert_contains "$out" "2 tickets, 1 review-notes.md, 1 eval-report.md"
assert_contains "$out" "reviewer: YES 1, NO 0, other 0"
assert_contains "$out" "bucket lines (not none): Act On 1, Consider 0, Noted 1, Dismissed 0"
assert_contains "$out" "opus"
js="$("$board" gate-corpus --json)"
assert_contains "$js" '"tickets":2'
assert_eq "$before" "$(tree_hash)"

set +e; "$board" gate-corpus --nope >/dev/null 2>"$work/err"; code=$?; set -e
assert_eq "2" "$code"
assert_contains "$(cat "$work/err")" "usage: canon-go gate-corpus [--json]"

if [[ "$(id -u)" != 0 ]]; then
  chmod 000 "$proj/.tickets"
  set +e; out="$("$board" gate-corpus 2>&1)"; code=$?; set -e
  chmod 755 "$proj/.tickets"
  assert_eq "1" "$code"
  assert_contains "$out" "cannot be read"
fi
echo "gate-corpus: ok"
