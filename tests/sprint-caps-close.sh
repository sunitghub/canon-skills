#!/usr/bin/env bash
# sprint-caps-close (t-c990) — the close-time cap check: `sprint check-evidence` (before the evaluator) and `sprint complete` refuse when a
# tools/caps.tsv file this branch changed is over its cap, and only warn for one it did not change or with no origin/main to compare with.
# Protects the sprint close gate (_gate_caps) and the budget.exceeded / gate.rejected events it writes.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
export SPRINT_CHECK_NO_BROWSER=1
unset CANON_TICKETS_DIR   # a stamp clone sets it to the real project's .tickets; these scratch projects use their own
work="$(mktemp -d)"
trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT
use_fresh_board "$work/bin"
mkdir "$work/tmp"; export TMPDIR="$work/tmp"   # make_project's folders and their origins go with $work

# HANDOFF.md is a caps.tsv row: 80 lines between its markers
handoff() { { echo '<!-- canon:handoff:BEGIN -->'; for ((i = 0; i < $1; i++)); do echo "line $i"; done; echo '<!-- canon:handoff:END -->'; } > HANDOFF.md; }
# a project whose origin/main holds HANDOFF.md at <base lines>, on a branch
project() {
  local p; p="$(make_project)"
  git init -q --bare "$p.origin"
  (cd "$p" && git config user.email t@t && git config user.name t && handoff "$1" && git add HANDOFF.md && git commit -qm base \
    && git branch -M main && git remote add origin "$p.origin" && git push -q origin main && git checkout -qb feat)
  printf '%s\n' "$p"
}
check() { rc=0; out="$("$SPRINT" check-evidence "$id" 2>&1)" || rc=$?; }
caps_events() { cat "$CANON_HOME"/events/*.jsonl 2>/dev/null | grep -F "\"ticket\":\"$id\"" | grep -cF "$1" || true; }

# 1. the branch pushes a capped file over: refused before the evaluator, with both events
cd "$(project 70)"
id="$("$SPRINT" start "Caps close" | awk '/Sprint started:/ { print $3 }')"
handoff 82; git commit -qam over
check
assert_eq 1 "$rc"
assert_contains "$out" "HANDOFF.md: 82 of 80 lines, over by 2: this branch changed it"
assert_contains "$out" "Sprint $id cannot close: a capped file this branch changed is over its cap"
assert_contains "$(event_line budget.exceeded "$id")" '"cap":"handoff","limit":"80","stage":"close"'
assert_contains "$(event_line gate.rejected "$id")" '"reason":"cap_exceeded"'
# ... and sprint complete stops on it too, before any other gate
rc=0; out="$("$SPRINT" complete 2>&1)" || rc=$?
assert_eq 1 "$rc"; assert_contains "$out" "this branch changed it"
[[ "${out##*$'\n'}" == "Sprint $id cannot close: a capped file this branch changed is over its cap (tools/caps.tsv)." ]] \
  || fail "sprint complete went past the cap check: $out"   # the cap refusal is the last word, no later gate ran

# 2. an uncommitted or untracked change counts as the branch's
git reset -q --hard HEAD~1; handoff 81
check; assert_eq 1 "$rc"; assert_contains "$out" "over by 1: this branch changed it"
git checkout -q HANDOFF.md; git rm -q --cached HANDOFF.md; git commit -qm untrack; handoff 83
check; assert_eq 1 "$rc"; assert_contains "$out" "over by 3: this branch changed it"

# 3. over on origin/main already, not touched here: a warning and the event, never a refusal
cd "$(project 85)"
id="$("$SPRINT" start "Old handoff" | awk '/Sprint started:/ { print $3 }')"
echo x > other.txt; git add other.txt; git commit -qm other
check
assert_eq 0 "$rc"; assert_contains "$out" "HANDOFF.md: 85 of 80 lines, over by 5: not changed by this branch, so the close goes on"
assert_eq 1 "$(caps_events budget.exceeded)"
assert_eq 0 "$(caps_events gate.rejected)"

# 4. no origin/main to compare with: a warning, never a refusal
git remote remove origin; handoff 90
check
assert_eq 0 "$rc"; assert_contains "$out" "not changed by this branch (no origin/main to compare with)"

# 5. within the cap: nothing printed, no event
cd "$(project 60)"
id="$("$SPRINT" start "Roomy" | awk '/Sprint started:/ { print $3 }')"
handoff 79; git commit -qam more
check
assert_eq 0 "$rc"; [[ "$out" != *HANDOFF* ]] || fail "a file within its cap was reported: $out"
assert_eq 0 "$(caps_events budget.exceeded)"

# 6. an older board (no `caps` in --help) is never asked, and refuses nothing
printf '#!/usr/bin/env bash\n[[ "$1" == --help ]] && { echo "usage: sprint-check [port]"; exit 0; }\ntouch "%s/called"; sleep 30\n' "$work" > "$work/old"; chmod +x "$work/old"
handoff 95; git commit -qam over
rc=0; out="$(SPRINT_CHECK_BIN="$work/old" "$SPRINT" check-evidence "$id" 2>&1)" || rc=$?
assert_eq 0 "$rc"; [[ ! -e "$work/called" ]] || fail "an older board was called with caps"

# 7. a capped file the meter cannot measure is reported, not read as within
printf 'no markers\n' > HANDOFF.md; git commit -qam broken
check
assert_eq 0 "$rc"; assert_contains "$out" "HANDOFF.md: cap not measured: caps: handoff: no <!-- canon:handoff:BEGIN -->"

# 8. a linked worktree is measured itself, not the main checkout it shares .tickets/ with (the t-c990 review's probe)
cd "$(project 70)"
id="$("$SPRINT" start "In a worktree" | awk '/Sprint started:/ { print $3 }')"
git worktree add -q "$work/tmp/wt" -b wt-branch
(cd "$work/tmp/wt" && handoff 90 && git commit -qam over)
rc=0; out="$(cd "$work/tmp/wt" && "$SPRINT" check-evidence "$id" 2>&1)" || rc=$?
assert_eq 1 "$rc"; assert_contains "$out" "HANDOFF.md: 90 of 80 lines, over by 10: this branch changed it"

# 9. LEARNINGS.md never refuses: learnings-sweep's row is still uncommitted at the close, and it never blocks on the cap
lrows() { { echo '<!-- canon:learnings:BEGIN -->'; for ((i = 0; i < $1; i++)); do echo "| row $i |"; done; echo '<!-- canon:learnings:END -->'; } > LEARNINGS.md; }
lrows 80; git add LEARNINGS.md; git commit -qm learnings; git push -q origin HEAD:main; lrows 81
check
assert_eq 0 "$rc"; assert_contains "$out" "LEARNINGS.md: 81 of 80 lines, over by 1: learnings-sweep keeps pending rows, so this never blocks a close"

echo "sprint-caps-close: ok (refused when the branch changed the file, committed, uncommitted or untracked; warned when it did not or with no baseline; silent within; older board skipped; unmeasurable reported; a worktree measured itself; LEARNINGS.md never refuses)"
