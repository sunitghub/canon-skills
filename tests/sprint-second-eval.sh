#!/usr/bin/env bash
# sprint-second-eval — t-864c: the optional second evaluator. Protects the close's `sprint second-eval` (whether it runs and on which
# model: Admin's Second eval pick, Off by default; high-risk or `Second eval: on`; never the Gate model), `sprint eval-compare` (the two
# reports row by row, `Disagreements: <n>`, the eval.compared event) and sprint complete's check of the second-eval Wrapup Gates row, and
# that the binding evaluator's checks never read eval-report-2.md.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"
use_fresh_board "$(mktemp -d)"

# its own Admin registry: the full run shares one CANON_HOME across parallel suites, and sprint-gate-model writes model-tiers.json too
CANON_HOME="$(mktemp -d)"; export CANON_HOME
project="$(make_project)"
trap 'rm -rf "$project" "$CANON_HOME"' EXIT
cd "$project"
id="$("$SPRINT" start "Second opinion" | awk '/Sprint started:/ { print $3 }')"
t=".tickets/$id"
signoff() { printf '# Plan\n\n## Sign-off\n%s\n\n- [x] Plan approved\n\n## Approach\nx\n' "$1" > "$t/plan.md"; }
reg() { mkdir -p "$CANON_HOME/cockpit"; printf '%s' "$1" > "$CANON_HOME/cockpit/model-tiers.json"; }
second() { COCKPIT_AGENT="${2:-claude}" "$SPRINT" second-eval "$id" 2>&1 || echo "EXIT $?"; }   # a skip or a model always exits 0

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
signoff "**Tier:** normal | Risk: x | **Second eval:** ON"
assert_eq "opus" "$(second)"                                   # bold markdown and capitals parse like _signoff_tier
signoff "Tier: high-risk | Risk: x | Second eval: yes"
out="$(second)"; assert_contains "$out" "ignoring 'Second eval: yes'"; assert_contains "$out" "opus"   # an unknown value is said, then ignored
signoff "Tier: high-risk | Risk: x | Gate model: opus"
assert_eq "skip: the ticket's Gate model already put the binding evaluator on opus" "$(second)"

# 2. sprint eval-compare: rows matched by their first cell; a different status, and a row only one side has, are disagreements
report() {   # report <model> <file> <criterion 1 status> <criterion 2 status> [extra criterion row] [test plan status]
  printf 'evaluator-run-id: 1-1\ngraded-head: abc\n\n# Eval Report\n\nModel: %s\n\n## Criteria\n\n| Criterion | Status | Evidence |\n|---|---|---|\n| One works | %s | a.sh:1 |\n| Two works | %s | b.sh:2 |\n%s\n## Test Plan\n\n| Item | Status | Notes |\n|---|---|---|\n| run the test | %s | ok |\n\n## Verdict\n\npass: fine\n' "$1" "$3" "$4" "${5:-}" "${6:-pass}" > "$t/$2"
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
# a first cell holding an escaped pipe or a pipe in backticks, and a bold status, still parse (reviewer t-864c: about 100 real rows)
report "sonnet (claude-sonnet-5-5)" eval-report.md pass pass '| `a | b` and x \\| y | **pass** | q |'
report "opus (claude-opus-5-5)" eval-report-2.md pass pass '| `a | b` and x \\| y | fail | q |'
out="$("$SPRINT" eval-compare "$id")"
assert_contains "$out" 'Criteria: `a | b` and x'; assert_contains "$out" ': binding pass, second fail'   # one cell, not split at either pipe
assert_contains "$out" "Disagreements: 1"
report "sonnet (claude-sonnet-5-5)" eval-report.md pass pass   # back to the plain binding report for the sections below
# the Test Plan table is compared too, and a row only the binding report has is a difference as well
report "sonnet (claude-sonnet-5-5)" eval-report.md pass pass "| Old criterion | pass | x |"
report "opus (claude-opus-5-5)" eval-report-2.md pass pass "" not-run
out="$("$SPRINT" eval-compare "$id")"
assert_contains "$out" "Test Plan: run the test: binding pass, second not-run"
assert_contains "$out" "Criteria: Old criterion: only in eval-report.md (pass)"
assert_contains "$out" "Disagreements: 2"
report "sonnet (claude-sonnet-5-5)" eval-report.md pass pass
printf '# nothing here\n' > "$t/eval-report-2.md"
rc=0; out="$("$SPRINT" eval-compare "$id" 2>&1)" || rc=$?
assert_eq 1 "$rc"; assert_contains "$out" "eval-report-2.md has no Criteria or Test Plan rows"
# the binding report missing or empty is said the same way, never compared as zero rows
cp "$t/eval-report.md" "$t/binding.bak"; report "opus (claude-opus-5-5)" eval-report-2.md pass pass
rm "$t/eval-report.md"; rc=0; out="$("$SPRINT" eval-compare "$id" 2>&1)" || rc=$?
assert_eq 1 "$rc"; assert_contains "$out" "eval-report.md not found"
printf 'pass: no tables\n' > "$t/eval-report.md"; rc=0; out="$("$SPRINT" eval-compare "$id" 2>&1)" || rc=$?
assert_eq 1 "$rc"; assert_contains "$out" "eval-report.md has no Criteria or Test Plan rows"
mv "$t/binding.bak" "$t/eval-report.md"; printf '# nothing here\n' > "$t/eval-report-2.md"

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
acc "| second-eval | ran | opus; Disagreements: 12; none |"
gates >/dev/null && fail "Disagreements: 12 passed for a count of 1"
printf '# nothing here\n' > "$t/eval-report-2.md"; acc "| second-eval | ran | Disagreements: 0 |"
out="$(gates)" && fail "an unreadable eval-report-2.md was accepted at close"
assert_contains "$out" "cannot read the reports"
rm "$t/eval-report-2.md"; acc ""
gates >/dev/null || fail "a close without a second evaluator now needs a second-eval row"

# 4. the binding evaluator's report checks never read eval-report-2.md: a failing or malformed one changes nothing there
# every function tools/sprint defines, with the libraries it sources (reviewer t-864c: one function alone ran with undefined helpers, so
# both runs printed "command not found" and matched; the check below fails if any helper is missing)
binding() { ( export SCRIPT_DIR="$ROOT/tools"; source "$ROOT/tools/ticket-root.sh"; source "$ROOT/tools/platform-lib.sh"
  eval "$(awk '/^[A-Za-z_][A-Za-z0-9_]*\(\) \{/,/^}/' "$SPRINT")"; _gate_eval_report "$id" "$t" 2>&1; echo "rc=$?" ) }
printf 'evaluator-run-id: 1-1\n' > "$t/eval-report.md"
before="$(binding)"
[[ "$before" != *"command not found"* && "$before" == *"rc="* ]] || fail "the binding check did not run for real: $before"
[[ "$before" == *"eval-report.md"* ]] || fail "the binding check said nothing about eval-report.md: $before"   # it refuses this short report
printf 'fail: everything is wrong\n' > "$t/eval-report-2.md"
assert_eq "$before" "$(binding)"

# 5. complete-checklist.md stays inside its word cap (it gained the second-eval step)
words="$(wc -w < "$ROOT/skills/sprint/reference/complete-checklist.md" | tr -d ' ')"
(( words <= 900 )) || fail "complete-checklist.md is $words words (cap 900)"

echo "sprint-second-eval: ok"
