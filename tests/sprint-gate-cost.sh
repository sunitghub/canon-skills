#!/usr/bin/env bash
# t-5ef3: `sprint gate-cost` groups the last N measured gate runs by gate type × tier.
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
SUBAGENT_LOG="$ROOT/tools/subagent-log.sh"

project="$(make_project)"
trap 'rm -rf "$project"' EXIT
cd "$project"

# No log yet: says so, exit 0.
out="$("$SPRINT" gate-cost)"
assert_contains "$out" "No gate runs logged"

# Legacy rows carry no numbers: skipped, not read as zero.
"$SUBAGENT_LOG" --agent-id legacy --agent-type evaluator
out="$("$SPRINT" gate-cost)"
assert_contains "$out" "No measured gate runs yet"

"$SUBAGENT_LOG" --agent-id r1 --agent-type reviewer --tokens 40000 --minutes 3 --tool-uses 10 --tier normal --outcome pass
"$SUBAGENT_LOG" --agent-id r2 --agent-type reviewer --tokens 60000 --minutes 9 --tool-uses 12 --tier normal --outcome fail
"$SUBAGENT_LOG" --agent-id r3 --agent-type reviewer --tokens 50000 --minutes 5 --tool-uses 11 --tier normal --outcome pass
"$SUBAGENT_LOG" --agent-id e1 --agent-type evaluator --tokens 99000 --minutes 26 --tool-uses 80 --tier normal --outcome budget
"$SUBAGENT_LOG" --agent-id e2 --agent-type evaluator --tokens 45000 --tier bugfix --outcome pass

out="$("$SPRINT" gate-cost)"
assert_contains "$out" "last 5 measured run(s)"
row() { printf '%s\n' "$out" | awk -v g="$1" -v t="$2" '$1 == g && $2 == t'; }
# gate tier runs tok-med tok-worst min-med min-worst fail/budget
assert_eq "reviewer normal 3 50000 60000 5.0 9.0 33%" "$(row reviewer normal | tr -s ' ')"
assert_eq "evaluator normal 1 99000 99000 26.0 26.0 100%" "$(row evaluator normal | tr -s ' ')"
assert_eq "evaluator bugfix 1 45000 45000 - - 0%" "$(row evaluator bugfix | tr -s ' ')"

# --last keeps only the newest N measured runs; an even count takes the mean of the middle two.
out="$("$SPRINT" gate-cost --last 4)"
assert_contains "$out" "last 4 measured run(s)"
assert_eq "reviewer normal 2 55000 60000 7.0 9.0 50%" "$(row reviewer normal | tr -s ' ')"

set +e
"$SPRINT" gate-cost --last 0 2>/dev/null; rc=$?
set -e
assert_eq 1 "$rc"

printf 'sprint-gate-cost: ok\n'
