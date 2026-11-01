#!/usr/bin/env bash
# caps (t-19bb) — the board's cap meter (`canon-go caps`) end to end: tools/caps.tsv holds every cap the gates enforce, the CLI prints
# "<name>: <used> of <limit> <unit>, <N> left" or "over by <M>" with exit 0 / 1 / 2, --json, --list and "not capped", and the word count
# equals a byte-wise count of ASCII-whitespace fields on the real checklists (t-35a7: never `wc -w`, which differs between GNU and BSD). Protects the shipped helper the close-gate tests (sprint-checklists, release-zip-slim) and the
# plan-time headroom line (t-cc88) read their caps through.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export SPRINT_CHECK_NO_BROWSER=1   # an older board would take `caps` for a port and start (t-269d)
BOARD="$(build_board "$T")"
CAPS="$ROOT/tools/caps.tsv"

# the table's rows and numbers: a cap is lowered or the file fixed, never raised to hide a miss
rows="$(grep -v '^#' "$CAPS" | grep . | cut -f1,3,4 | tr '\t' ' ')"
assert_eq "start-checklist 900 words
complete-checklist 900 words
handoff 80 block-lines
learnings 80 block-lines
release-zip 4096 kb
release-zip-files 300 files" "$rows"

# --help names the helper: a bash caller checks for it, as canon_event checks for `event <kind>` (an older board takes a word for a port)
[[ "$("$BOARD" --help 2>&1)" == *"caps [--json]"* ]] || fail "caps: --help does not list caps"

# t-35a7: the word count equals the cap's own rule, fields of bytes other than ASCII whitespace, counted byte-wise in the C locale. Not
# `wc -w`: GNU (Linux, the Claude cloud) and BSD (macOS) disagree on a standalone non-ASCII token such as " — ", so a wc oracle failed the
# pre-commit hook on every cloud commit. Prod path: the 900-word cap on the always-read checklists, and the hook that runs this suite.
ascii_words() { LC_ALL=C tr -s ' \t\n\r\v\f' '\n' < "$1" | LC_ALL=C grep -c .; }
for phase in start complete; do
  f="$ROOT/skills/sprint/reference/$phase-checklist.md"
  json="$("$BOARD" caps --json --table "$CAPS" "$phase-checklist" "$f")"
  assert_eq "$(ascii_words "$f")" "$(sed -n 's/.*"used":\([0-9]*\).*/\1/p' <<< "$json")"
done
# a standalone non-ASCII token is a word, and an NBSP joins its neighbours: "a — b c\u00a0d" is 4 words for the cap and for the oracle
printf 'a \xe2\x80\x94 b c\xc2\xa0d\n' > "$T/tokens.md"
json="$("$BOARD" caps --json --table "$CAPS" "start-checklist" "$T/tokens.md")"
assert_eq "4" "$(sed -n 's/.*"used":\([0-9]*\).*/\1/p' <<< "$json")"
assert_eq "4" "$(ascii_words "$T/tokens.md")"

# the line, the exit codes, --json, --list, not capped, by path
printf '%s\n' "x	f.md	3	words	-" > "$T/t.tsv"
printf 'a b c' > "$T/f.md"
assert_eq "x: 3 of 3 words, 0 left" "$("$BOARD" caps --table "$T/t.tsv" x "$T/f.md")"
printf 'a b c d' > "$T/f.md"
rc=0; out="$("$BOARD" caps --table "$T/t.tsv" x "$T/f.md")" || rc=$?
assert_eq 1 "$rc"; assert_eq "x: 4 of 3 words, over by 1" "$out"
assert_eq '{"name":"x","used":4,"limit":3,"unit":"words","left":-1,"over":true}' "$("$BOARD" caps --json --table "$T/t.tsv" x "$T/f.md" || true)"
assert_eq "other.md: not capped" "$("$BOARD" caps --table "$T/t.tsv" other.md)"
assert_eq "x: 4 of 3 words, over by 1" "$(cd "$T" && "$BOARD" caps --table "$T/t.tsv" f.md || true)"   # a row found by its path
rc=0; "$BOARD" caps --table "$T/missing.tsv" x >/dev/null 2>&1 || rc=$?; assert_eq 2 "$rc"
rc=0; "$BOARD" caps --table "$T/t.tsv" >/dev/null 2>&1 || rc=$?; assert_eq 2 "$rc"
list="$(cd "$ROOT" && "$BOARD" caps --list --table "$CAPS")"
[[ "$list" == *"complete-checklist: "*" of 900 words, "* && "$list" == *"release-zip: 4096 KB (the caller gives the path)"* ]] || fail "caps: --list is wrong: $list"

# cap_check (tests/helpers.sh) fails on a missing row instead of reading it as no cap
mkdir -p "$T/root/tools"; grep -v '^start-checklist' "$CAPS" > "$T/root/tools/caps.tsv"
rc=0; (ROOT="$T/root"; cap_check "$BOARD" start-checklist "$ROOT/skills/sprint/reference/start-checklist.md") >/dev/null 2>&1 || rc=$?
[[ $rc -ne 0 ]] || fail "caps: cap_check passed a file whose row is missing"
# ... on a file over its cap and on one it cannot measure, and passes one within it; the default table is the install's tools/caps.tsv
mkdir -p "$T/root2/tools"; printf '%s\n' "x	f.md	3	words	-" > "$T/root2/tools/caps.tsv"
rc=0; (ROOT="$T/root2"; cap_check "$BOARD" x "$T/f.md") >/dev/null 2>&1 || rc=$?; [[ $rc -ne 0 ]] || fail "caps: cap_check passed a file over its cap"
rc=0; (ROOT="$T/root2"; cap_check "$BOARD" x "$T") >/dev/null 2>&1 || rc=$?; [[ $rc -ne 0 ]] || fail "caps: cap_check passed a file it could not measure"
printf 'a b' > "$T/f.md"; (ROOT="$T/root2"; cap_check "$BOARD" x "$T/f.md") || fail "caps: cap_check refused a file within its cap"
[[ "$(cd "$ROOT" && "$BOARD" caps start-checklist)" == "start-checklist: "*" of 900 words, "*" left" ]] || fail "caps: without --table it does not read the install's tools/caps.tsv"

echo "caps: ok (table pinned, --help lists it, words equal the ASCII-field count (a standalone non-ASCII token included), line, exit codes, --json, --list, not capped, a missing row fails)"
