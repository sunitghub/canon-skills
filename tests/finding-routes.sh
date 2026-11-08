#!/usr/bin/env bash
# finding-routes (t-b360) — `sprint start` offers /promote-learnings in one line when the project's root LEARNINGS.md has 5 or more UNPROMOTED
# rows, and prints nothing with fewer, no file, or other statuses. Protects `sprint start`, which every sprint runs, in a project that is not
# canon (a scratch project: no canon-only path). The `sprint complete` line and `tkt learn`'s list have their cases in tests/sprint.sh and
# tests/tkt.sh.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
use_fresh_board "$(mktemp -d)"   # sprint start's event goes through the board binary

project="$(make_project)"
trap 'rm -rf "$project"' EXIT
cd "$project"

rows() { # <unpromoted> <promoted> [crlf]: a LEARNINGS.md table
  local eol=$'\n'; [[ "${3:-}" == crlf ]] && eol=$'\r\n'
  { printf '# Learnings%s%s' "$eol" "$eol"; printf '| Date | Ticket | Finding | Status |%s|---|---|---|---|%s' "$eol" "$eol"
    local i; for ((i = 1; i <= $1; i++)); do printf '| 2026-11-0%s | [t-a%03d](x) | a lesson | UNPROMOTED |%s' "$((i % 9 + 1))" "$i" "$eol"; done
    for ((i = 1; i <= $2; i++)); do printf '| 2026-10-0%s | [t-b%03d](y) | kept | PROMOTED |%s' "$((i % 9 + 1))" "$i" "$eol"; done
  } > LEARNINGS.md
}
start() { # <title>: sprint start's output; the ticket is closed again so the next call may start
  local o; o="$("$SPRINT" start "$1" 2>&1)"; printf '%s\n' "$o"
  "$TKT" close "$(awk '/Sprint started:/ { print $3 }' <<<"$o")" --no-sprint >/dev/null 2>&1 || true
}

out="$(start "no file")"
[[ "$out" != *"UNPROMOTED learnings"* ]] || fail "a project with no LEARNINGS.md was told to promote"
rm -f LEARNINGS.md
rows 4 0
out="$(start "four rows")"; [[ "$out" != *"UNPROMOTED learnings"* ]] || fail "4 UNPROMOTED rows printed the line"
rows 3 6
out="$(start "mostly promoted")"; [[ "$out" != *"UNPROMOTED learnings"* ]] || fail "promoted rows were counted"
rows 5 0
out="$(start "five rows")"; assert_contains "$out" "5 UNPROMOTED learnings: /promote-learnings reviews them"
assert_eq 1 "$(grep -c 'UNPROMOTED learnings' <<<"$out")"
rows 7 2 crlf
out="$(start "seven rows, CRLF file")"; assert_contains "$out" "7 UNPROMOTED learnings: /promote-learnings reviews them"
assert_contains "$out" "Sprint started:"   # the line is an addition: the start itself is unchanged

# --- sprint complete: the routed counts, and nothing when there is no such section ---
close_with() { # <title> <learnings body or empty>: a trivial-tier close, the output of sprint complete
  local o id; o="$("$SPRINT" start "$1" 2>&1)"; id="$(awk '/Sprint started:/ { print $3 }' <<<"$o")"
  [[ "$id" =~ ^t-[0-9a-f]{4}$ ]] || fail "sprint start gave no ticket id for $1: $o"
  printf '# Summary\n| Item | Status |\n|---|---|\n| x | delivered |\n' > ".tickets/$id/summary.md"
  printf '# Acceptance\n## Criteria\n- [x] Done.\n## Test Plan\n- [x] npm test\n## Wrapup Gates\n| Gate | Status | Reason |\n|------|--------|--------|\n| security-review | ran | no trust boundary touched |\n' > ".tickets/$id/acceptance.md"
  printf '# Plan\n## Sign-off\nTier: trivial | Risk: one-liner\n- [x] Plan approved \xe2\x80\x94 proceed to implementation\n## Approach\nNone needed.\n' > ".tickets/$id/plan.md"
  [[ -z "$2" ]] || printf '%s\n' "$2" > ".tickets/$id/learnings.md"
  git -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m fixture
  "$SPRINT" complete 2>&1 || true
}
out="$(close_with "routed close" "$(printf '# L\n\n## Noticed and not checked\n\n- [ ] one (review-notes.md)\n- [ ] two (review-notes.md)\n- [t-abcd] three (eval-report.md)\n* [dismissed: a duplicate] four (summary.md)\n- plain text, not a route\n\n## Candidate lessons\n- [ ] (other)\n')")"
assert_contains "$out" "Findings: 4 noticed (1 routed to a ticket, 1 dismissed, 2 left as lessons)"
out="$(close_with "no section" "$(printf '# L\n\n## Evaluator findings\n\n- [ ] not in the noticed list\n')")"
[[ "$out" != *"Findings:"* ]] || fail "a candidate with no noticed section printed a Findings line: $out"
out="$(close_with "no file" "")"
[[ "$out" == *"closed"* && "$out" != *"Findings:"* ]] || fail "a close with no learnings.md printed a Findings line, or did not close: $out"
git update-ref -d "$(git symbolic-ref HEAD)"

echo "finding-routes: ok (sprint start's promote line: none, 4, promoted rows, 5, CRLF; sprint complete's routed counts; in a non-canon project)"
