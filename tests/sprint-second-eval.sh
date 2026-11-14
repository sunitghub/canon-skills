#!/usr/bin/env bash
# sprint-second-eval — t-864c: the optional second evaluator. Protects the close's `sprint second-eval` (whether it runs and on which
# model: Admin's Second eval pick, Off by default; high-risk or `Second eval: on`; never the Gate model), `sprint eval-compare` (the two
# reports row by row, `Disagreements: <n>`, the eval.compared event) and sprint complete's check of the second-eval Wrapup Gates row, and
# that the binding evaluator's checks never read eval-report-2.md.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
use_fresh_board "$(mktemp -d)"

project="$(make_project)"
trap 'rm -rf "$project"' EXIT
cd "$project"
id="$("$SPRINT" start "Second opinion" | awk '/Sprint started:/ { print $3 }')"
t=".tickets/$id"
signoff() { printf '# Plan\n\n## Sign-off\n%s\n\n- [x] Plan approved\n\n## Approach\nx\n' "$1" > "$t/plan.md"; }
reg() { mkdir -p "$CANON_HOME/cockpit"; printf '%s' "$1" > "$CANON_HOME/cockpit/model-tiers.json"; }
second() { COCKPIT_AGENT="${2:-claude}" "$SPRINT" second-eval "$id" 2>&1; }

# 1. sprint second-eval: Off by default (the seed has no pick), so it never runs until a model is picked
signoff "Tier: high-risk | Risk: x"
reg '{"defaults":{"evaluator":{"claude":"claude-sonnet-5-5"}},"models":{"anthropic":[{"id":"claude-sonnet-5-5"},{"id":"claude-opus-5-5","alias":"opus"}]}}'
assert_eq "skip: no Second eval model in Admin for claude" "$(second)"
reg '{"defaults":{"evaluator":{"claude":"claude-sonnet-5-5"},"evaluator2":{"claude":"claude-opus-5-5","copilot":"gpt-6-luna"}},"models":{"anthropic":[{"id":"claude-sonnet-5-5"},{"id":"claude-opus-5-5","alias":"opus"}]}}'
assert_eq "opus" "$(second)"                                   # high-risk: runs, on the pick's alias
assert_eq "gpt-6-luna" "$(second x copilot)"                   # Copilot CLI: its own pick
assert_eq "skip: pi has no Second eval step" "$(second x pi)"
signoff "Tier: high-risk | Risk: x | Second eval: OFF"
assert_eq "skip: Second eval: off on this ticket" "$(second)"
signoff "Tier: normal | Risk: x"
assert_eq "skip: not high-risk (add | Second eval: on to run it)" "$(second)"
signoff "Tier: normal | Risk: x | second eval: on | Gate model: haiku"
assert_eq "opus" "$(second)"                                   # on runs it on any tier; the Gate model never sets it

# 2. sprint eval-compare: rows matched by their first cell; a different status, and a row only one side has, are disagreements
report() {   # report <file> <criterion 1 status> <criterion 2 status> [extra criterion row]
  printf 'evaluator-run-id: 1-1\ngraded-head: abc\n\n# Eval Report\n\nModel: %s\n\n## Criteria\n\n| Criterion | Status | Evidence |\n|---|---|---|\n| One works | %s | a.sh:1 |\n| Two works | %s | b.sh:2 |\n%s\n## Test Plan\n\n| Item | Status | Notes |\n|---|---|---|\n| run the test | pass | ok |\n\n## Verdict\n\npass: fine\n' "$1" "$3" "$4" "${5:-}" > "$t/$2"
}
report "sonnet (claude-sonnet-5-5)" eval-report.md pass pass
rc=0; out="$("$SPRINT" eval-compare "$id" 2>&1)" || rc=$?
assert_eq 1 "$rc"; assert_contains "$out" "eval-report-2.md not found"
report "opus (claude-opus-5-5)" eval-report-2.md pass pass
out="$("$SPRINT" eval-compare "$id")"
assert_eq "Disagreements: 0" "$out"
report "opus (claude-opus-5-5)" eval-report-2.md pass "fail" "| Three is new | pass | c.sh:3 |"
out="$("$SPRINT" eval-compare "$id")"
assert_contains "$out" "Criteria: Two works: binding pass, second fail"
assert_contains "$out" "Criteria: Three is new: only in eval-report-2.md (pass)"
assert_contains "$out" "Disagreements: 2"
assert_contains "$(event_line eval.compared "$id")" '"disagreements":"2"'
assert_contains "$(event_line eval.compared "$id")" '"model":"opus (claude-opus-5-5)"'
printf '# nothing here\n' > "$t/eval-report-2.md"
rc=0; out="$("$SPRINT" eval-compare "$id" 2>&1)" || rc=$?
assert_eq 1 "$rc"; assert_contains "$out" "eval-report-2.md has no Criteria or Test Plan rows"

# 3. sprint complete's Wrapup Gates check: with eval-report-2.md, the second-eval row must carry the count; without it, nothing changes
gates() { ( eval "$(sed -n '/^_acceptance_section()/,/^}/p;/^_eval_rows()/,/^}/p;/^_eval_compare()/,/^}/p;/^_gate_wrapup_gates()/,/^}/p' "$SPRINT")"; _gate_wrapup_gates "$id" "$t/acceptance.md" 2>&1 ); }
acc() { printf '# Acceptance\n\n## Wrapup Gates\n| Gate | Status | Reason |\n|------|--------|--------|\n| reviewer | ran | fine |\n%s\n' "$1" > "$t/acceptance.md"; }
report "opus (claude-opus-5-5)" eval-report-2.md pass "fail"
acc ""
out="$(gates)" && fail "a second evaluator with no second-eval row was accepted"
assert_contains "$out" "needs the row | second-eval | ran | … Disagreements: 1"
acc "| second-eval | ran | opus; Disagreements: 0; none |"
gates >/dev/null && fail "a second-eval row with the wrong count was accepted"
acc "| second-eval | ran | opus; Disagreements: 1; criterion 2: the user kept the binding pass |"
gates >/dev/null || fail "the right second-eval row was refused"
rm "$t/eval-report-2.md"; acc ""
gates >/dev/null || fail "a close without a second evaluator now needs a second-eval row"

# 4. the binding evaluator's report checks never read eval-report-2.md: a failing or malformed one changes nothing there
binding() { ( eval "$(sed -n '/^_gate_eval_report()/,/^}/p' "$SPRINT")"; _gate_eval_report "$id" "$t" 2>&1 ); }
printf 'evaluator-run-id: 1-1\n' > "$t/eval-report.md"
before="$(binding || true)"
printf 'fail: everything is wrong\n' > "$t/eval-report-2.md"
assert_eq "$before" "$(binding || true)"

# 5. complete-checklist.md stays inside its word cap (it gained the second-eval step)
words="$(wc -w < "$ROOT/skills/sprint/reference/complete-checklist.md" | tr -d ' ')"
(( words <= 900 )) || fail "complete-checklist.md is $words words (cap 900)"

echo "sprint-second-eval: ok"
