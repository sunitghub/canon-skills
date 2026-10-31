#!/usr/bin/env bash
# caps (t-19bb) — the board's cap meter (`canon-go caps`) end to end: tools/caps.tsv holds every cap the gates enforce, the CLI prints
# "<name>: <used> of <limit> <unit>, <N> left" or "over by <M>" with exit 0 / 1 / 2, --json, --list and "not capped", and the word count
# equals `wc -w` on the real checklists. Protects the shipped helper the close-gate tests (sprint-checklists, release-zip-slim) and the
# plan-time headroom line (t-cc88) read their caps through.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
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

# the word count equals wc -w on both checklists, in the C locale and a UTF-8 one
for phase in start complete; do
  f="$ROOT/skills/sprint/reference/$phase-checklist.md"
  json="$("$BOARD" caps --json --table "$CAPS" "$phase-checklist" "$f")"
  for loc in C en_US.UTF-8; do
    assert_eq "$(LC_ALL=$loc wc -w < "$f" | tr -d ' ')" "$(sed -n 's/.*"used":\([0-9]*\).*/\1/p' <<< "$json")"
  done
done

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

echo "caps: ok (table pinned, --help lists it, words equal wc -w in two locales, line, exit codes, --json, --list, not capped, a missing row fails)"
