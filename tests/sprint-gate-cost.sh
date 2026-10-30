#!/usr/bin/env bash
# t-5ef3: `sprint gate-cost` groups the last N measured gate runs by gate type × tier (× model, t-3a14).
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
row() { printf '%s\n' "$out" | awk -v g="$1" -v t="$2" -v m="${3:--}" '$1 == g && $2 == t && $3 == m'; }
# gate tier model runs tok-med tok-worst min-med min-worst fail/budget
assert_eq "reviewer normal - 3 50000 60000 5.0 9.0 33%" "$(row reviewer normal | tr -s ' ')"
assert_eq "evaluator normal - 1 99000 99000 26.0 26.0 100%" "$(row evaluator normal | tr -s ' ')"
assert_eq "evaluator bugfix - 1 45000 45000 - - 0%" "$(row evaluator bugfix | tr -s ' ')"

# --last keeps only the newest N measured runs; an even count takes the mean of the middle two.
out="$("$SPRINT" gate-cost --last 4)"
assert_contains "$out" "last 4 measured run(s)"
assert_eq "reviewer normal - 2 55000 60000 7.0 9.0 50%" "$(row reviewer normal | tr -s ' ')"

assert_contains "$out" "gate       tier      model              runs    tok-med  tok-worst  min-med min-worst fail/budget"

# A row without a type or tier groups under "-".
"$SUBAGENT_LOG" --agent-id x1 --tokens 1000
out="$("$SPRINT" gate-cost --last 1)"
assert_eq "- - - 1 1000 1000 - - 0%" "$(row - - | tr -s ' ')"

# t-3a14: the model splits a gate x tier group; a row without one shows "-", never a guess; token-less rows still skip.
"$SUBAGENT_LOG" --agent-id m1 --agent-type evaluator --tokens 30000 --tier normal --model claude-sonnet-5
"$SUBAGENT_LOG" --agent-id m2 --agent-type evaluator --tokens 50000 --tier normal --model claude-sonnet-5 --outcome fail
"$SUBAGENT_LOG" --agent-id m3 --agent-type evaluator --tokens 70000 --tier normal --model claude-opus-5
"$SUBAGENT_LOG" --agent-id m4 --agent-type evaluator --tokens 20000 --tier normal
"$SUBAGENT_LOG" --agent-id m5 --agent-type evaluator --tier normal --model claude-sonnet-5
out="$("$SPRINT" gate-cost --last 4)"
assert_contains "$out" "last 4 measured run(s)"
assert_eq "evaluator normal claude-sonnet-5 2 40000 50000 - - 50%" "$(row evaluator normal claude-sonnet-5 | tr -s ' ')"
assert_eq "evaluator normal claude-opus-5 1 70000 70000 - - 0%" "$(row evaluator normal claude-opus-5 | tr -s ' ')"
assert_eq "evaluator normal - 1 20000 20000 - - 0%" "$(row evaluator normal | tr -s ' ')"

# t-63a7: rows logged under the old spellings group as high-risk.
printf '%s\n' '{"agent_type":"reviewer","tier":"high","tokens":8000}' '{"agent_type":"reviewer","tier":"highrisk","tokens":6000}' >> .claude/subagent-runs.jsonl
out="$("$SPRINT" gate-cost --last 2)"
assert_eq "reviewer high-risk - 2 7000 8000 - - 0%" "$(row reviewer high-risk | tr -s ' ')"

for bad in "--last 0" "--last x" "--last" "--bogus"; do
  set +e
  # shellcheck disable=SC2086  # split on purpose
  "$SPRINT" gate-cost $bad >/dev/null 2>&1; rc=$?
  set -e
  assert_eq 1 "$rc"
done
assert_eq "Usage: sprint gate-cost [--last N]" "$("$SPRINT" gate-cost --help)"

# t-7c89: a run in the log twice (an older log, or a hand edit) counts once, the later measured row winning.
"$SUBAGENT_LOG" --agent-id dupe --agent-type reviewer --tier dupetier
printf '{"ts":"2026-10-29T10:00:00Z","agent_id":"dupe","agent_type":"reviewer","tokens":1000,"tier":"dupetier"}\n{"ts":"2026-10-29T10:01:00Z","agent_id":"dupe","agent_type":"reviewer","tokens":3000,"tier":"dupetier"}\n{"ts":"2026-10-29T10:02:00Z","agent_id":"dupe","agent_type":"reviewer","tier":"dupetier"}\n' >> .claude/subagent-runs.jsonl
out="$("$SPRINT" gate-cost --last 50)"
assert_eq "reviewer dupetier - 1 3000 3000 - - 0%" "$(printf '%s\n' "$out" | awk '$1 == "reviewer" && $2 == "dupetier"' | tr -s ' ')"

printf 'sprint-gate-cost: ok\n'
