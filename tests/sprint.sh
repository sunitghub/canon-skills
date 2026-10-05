#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# t-b2a9: every message about a missing or unverifiable gate report says a fresh subagent writes it and the file is never hand-made.
assert_gate_notice() { # <output> <file> <evaluator|reviewer>
  assert_contains "$1" "Never create or edit $2 yourself"
  assert_contains "$1" "subagent_type \"canon-$3\""
  # t-0231: the step number is part of the notice (3 = evaluator, 2 = reviewer), so a wrong pointer is a test failure
  assert_contains "$1" "complete.md step $([[ "$3" == reviewer ]] && echo 2 || echo 3))"
}
# ...and the skill says it once up front, where a model that never opens complete.md still reads it.
grep -q 'Gate reports are never hand-written' "$ROOT/skills/sprint/SKILL.md" || fail "skills/sprint/SKILL.md must say gate reports are never hand-written"

project="$(make_project)"
trap 'rm -rf "$project"' EXIT
cd "$project"

start_output="$("$SPRINT" start "Add workflow tests")"
assert_contains "$start_output" "Sprint started:"
id="$(printf '%s\n' "$start_output" | awk '/Sprint started:/ { print $3 }')"

assert_file_exists ".tickets/$id/ticket.md"
assert_file_exists "DECISIONS.md"
assert_file_exists "HANDOFF.md"
assert_eq "$id" "$(tr -d '[:space:]' < .tickets/ACTIVE)"

# sprint start now scaffolds both docs with required headings
assert_file_exists ".tickets/$id/acceptance.md"
assert_file_exists ".tickets/$id/plan.md"
assert_grep "## Sign-off" ".tickets/$id/plan.md"
assert_grep "## Approach" ".tickets/$id/plan.md"
assert_grep "## Criteria" ".tickets/$id/acceptance.md"
assert_grep "## Test Plan" ".tickets/$id/acceptance.md"

second_start_output="$(run_fail "$SPRINT" start "Another sprint")"
assert_contains "$second_start_output" "Active sprint already exists:"

# t-577e: sprint continue resumes an in_progress ticket read-only; start refuses it.
before_continue="$(cat ".tickets/$id/ticket.md" ".tickets/$id/plan.md" ".tickets/ACTIVE")"
continue_output="$("$SPRINT" continue "$id")"
assert_contains "$continue_output" "Continuing sprint: $id"
assert_contains "$continue_output" "Status: in_progress"
assert_contains "$continue_output" "Agent next steps:"
assert_contains "$continue_output" "HANDOFF.md"
assert_eq "$before_continue" "$(cat ".tickets/$id/ticket.md" ".tickets/$id/plan.md" ".tickets/ACTIVE")"
assert_contains "$(run_fail "$SPRINT" continue t-nope)" "No ticket"
open_id="$("$TKT" create "Not started yet" -t task -p 2)"
assert_contains "$(run_fail "$SPRINT" continue "$open_id")" "sprint start $open_id"
# a closed or archived ticket is not resumable either
done_id="$("$TKT" create "Already closed" -t task -p 2)"
"$TKT" close "$done_id" --no-sprint >/dev/null
assert_contains "$(run_fail "$SPRINT" continue "$done_id")" "closed"
archived_id="$("$TKT" create "Shelved" -t task -p 2)"
"$TKT" archive "$archived_id" >/dev/null
assert_contains "$(run_fail "$SPRINT" continue "$archived_id")" "archived"
assert_contains "$(run_fail "$SPRINT" continue)" "Usage: sprint continue"

# summary.md gate — must block before any other check
missing_summary_output="$(run_fail "$SPRINT" complete)"
assert_contains "$missing_summary_output" "Missing required sprint file"
assert_contains "$missing_summary_output" "summary.md"

cat > ".tickets/$id/summary.md" <<'EOF'
# Summary
| Item | Status |
|---|---|
| done | delivered |
EOF

# Overwrite with content missing required sections — section-aware gate should block
cat > ".tickets/$id/acceptance.md" <<'EOF'
# Acceptance

- [ ] Item with no section headers.
EOF
cat > ".tickets/$id/plan.md" <<'EOF'
# Plan
EOF

missing_sections_output="$(run_fail "$SPRINT" complete)"
assert_contains "$missing_sections_output" "acceptance.md ## Criteria has no checklist items"
assert_contains "$missing_sections_output" "acceptance.md ## Test Plan has no checklist items"

# Bare checked placeholders do not count as meaningful checklist items
cat > ".tickets/$id/acceptance.md" <<'EOF'
# Acceptance

## Criteria
- [x]

## Test Plan
- [x]
EOF

bare_placeholder_output="$(run_fail "$SPRINT" complete)"
assert_contains "$bare_placeholder_output" "acceptance.md ## Criteria has no checklist items"
assert_contains "$bare_placeholder_output" "acceptance.md ## Test Plan has no checklist items"

# Acceptance has proper sections but items are unchecked — existing unchecked gate
cat > ".tickets/$id/acceptance.md" <<'EOF'
# Acceptance

## Criteria
- [ ] Required item remains.
  - [ ] Indented item remains.
* [ ] Asterisk item remains.

## Test Plan
- [ ] npm test

## Wrapup Gates
| Gate | Status | Reason |
|------|--------|--------|
| code-reviewer | ran | reviewed gate logic |
| code-simplifier | skipped | test-only change |
EOF

unchecked_output="$(run_fail "$SPRINT" complete)"
assert_contains "$unchecked_output" "Unchecked acceptance/test items remain:"
assert_contains "$unchecked_output" "- [ ] Required item remains."
assert_contains "$unchecked_output" "  - [ ] Indented item remains."
assert_contains "$unchecked_output" "* [ ] Asterisk item remains."

# All items checked but no Wrapup Gates section — new gate should block
cat > ".tickets/$id/acceptance.md" <<'EOF'
# Acceptance

## Criteria
- [x] Required item remains.

## Test Plan
- [x] npm test
EOF

missing_wrapup_output="$(run_fail "$SPRINT" complete)"
assert_contains "$missing_wrapup_output" "missing ## Wrapup Gates section"

# Wrapup Gates section exists but table has no data rows (header/separator only)
cat > ".tickets/$id/acceptance.md" <<'EOF'
# Acceptance

## Criteria
- [x] Required item remains.

## Test Plan
- [x] npm test

## Wrapup Gates
| Gate | Status | Reason |
|------|--------|--------|
EOF

empty_table_output="$(run_fail "$SPRINT" complete)"
assert_contains "$empty_table_output" "no data rows"

# Wrapup Gates table has a row with empty reason
cat > ".tickets/$id/acceptance.md" <<'EOF'
# Acceptance

## Criteria
- [x] Required item remains.

## Test Plan
- [x] npm test

## Wrapup Gates
| Gate | Status | Reason |
|------|--------|--------|
| code-reviewer | ran |  |
EOF

empty_reason_output="$(run_fail "$SPRINT" complete)"
assert_contains "$empty_reason_output" "empty or placeholder reason"

# Wrapup Gates table has em-dash placeholder reason
cat > ".tickets/$id/acceptance.md" <<'EOF'
# Acceptance

## Criteria
- [x] Required item remains.

## Test Plan
- [x] npm test

## Wrapup Gates
| Gate | Status | Reason |
|------|--------|--------|
| code-reviewer | ran | — |
EOF

emdash_reason_output="$(run_fail "$SPRINT" complete)"
assert_contains "$emdash_reason_output" "empty or placeholder reason"

# Wrapup Gates table has all-skipped rows (no ran) — t-7a9a
cat > ".tickets/$id/acceptance.md" <<'EOF'
# Acceptance

## Criteria
- [x] Required item remains.

## Test Plan
- [x] npm test

## Wrapup Gates
| Gate | Status | Reason |
|------|--------|--------|
| code-simplifier | skipped | docs-only change |
| security-review | skipped | no auth patterns |
EOF

all_skipped_output="$(run_fail "$SPRINT" complete)"
assert_contains "$all_skipped_output" "no 'ran' rows"

# Plan content gate — placeholder Approach should block even when acceptance is satisfied
cat > ".tickets/$id/acceptance.md" <<'EOF'
# Acceptance

## Criteria
- [x] Required item remains.

## Test Plan
- [x] npm test

## Wrapup Gates
| Gate | Status | Reason |
|------|--------|--------|
| code-reviewer | ran | reviewed tools/sprint gate logic |
| code-simplifier | skipped | no code touched |
EOF

# plan.md still has no Approach content from earlier override
placeholder_plan_output="$(run_fail "$SPRINT" complete)"
assert_contains "$placeholder_plan_output" "plan.md ## Approach has no content"

# Add real Approach content without Sign-off — sign-off gate should block
cat > ".tickets/$id/plan.md" <<'EOF'
# Plan

## Approach
Add _gate_plan_signoff to tools/sprint.

## Files
- tools/sprint
EOF

missing_signoff_output="$(run_fail "$SPRINT" complete)"
assert_contains "$missing_signoff_output" "plan.md is missing ## Sign-off section"

# Sign-off section present but unchecked — gate should block
cat > ".tickets/$id/plan.md" <<'EOF'
# Plan

## Sign-off

- [ ] Plan approved — proceed to implementation

## Approach
Add _gate_plan_signoff to tools/sprint.

## Files
- tools/sprint
EOF

unchecked_signoff_output="$(run_fail "$SPRINT" complete)"
assert_contains "$unchecked_signoff_output" "## Sign-off has unchecked items"

# "tier: trivial" mentioned in ## Approach prose (not ## Sign-off) must not
# trigger the trivial-tier skip — regression for a bug where the gate
# grepped the whole plan.md instead of scoping to ## Sign-off.
cat > ".tickets/$id/plan.md" <<'EOF'
# Plan

## Sign-off

- [ ] Plan approved — proceed to implementation

## Approach
We considered tier: trivial but rejected it — this touches multiple files
with coordinated intent.

## Files
- tools/sprint
EOF

stray_trivial_output="$(run_fail "$SPRINT" complete)"
assert_contains "$stray_trivial_output" "## Sign-off has unchecked items"

# "tier: trivial" mentioned in ## Sign-off's own free-text Risk field (not
# the Tier: field's value) must not trigger the skip either — regression for
# a narrower bug where the fix above only scoped to the section, but the
# regex still matched anywhere within it instead of the Tier: field itself.
cat > ".tickets/$id/plan.md" <<'EOF'
# Plan

## Sign-off

Tier: normal | Risk: this is not tier: trivial since it touches multiple files

- [ ] Plan approved — proceed to implementation

## Approach
Add _gate_plan_signoff to tools/sprint.

## Files
- tools/sprint
EOF

risk_field_trivial_output="$(run_fail "$SPRINT" complete)"
assert_contains "$risk_field_trivial_output" "## Sign-off has unchecked items"

# Sign-off checked — gate passes, eval gate fires next
cat > ".tickets/$id/plan.md" <<'EOF'
# Plan

## Sign-off

- [x] Plan approved — proceed to implementation

## Approach
Add _gate_plan_signoff to tools/sprint and tests.

## Files
- tools/sprint
- tests/sprint.sh
EOF

# Visual-embed gate — a bare/backticked visual filename with no real image
# embed anywhere in plan.md must block close, naming the offending path —
# regression for t-f149 (rendered as plain text on the board, not caught
# until a real workshop-prep ticket shipped it).
cat >> ".tickets/$id/plan.md" <<'EOF'

## Decisions
- Option A (`visuals/option-a.png`): some text, no real embed anywhere.
EOF

bad_visual_output="$(run_fail "$SPRINT" complete)"
assert_contains "$bad_visual_output" "has a broken visual reference"
assert_contains "$bad_visual_output" "option-a.png"
assert_contains "$bad_visual_output" "never embedded as a real image"

# t-215f — a bare filename mention with no "visuals/" prefix at all (reported live
# from a Windows workshop: a manually-created ticket referenced two visuals by bare
# filename, and the original visuals/-prefix-only regex never caught it).
sed -i.bak 's/`visuals\/option-a\.png`/`Mockup-1.jpg`/' ".tickets/$id/plan.md" && rm -f ".tickets/$id/plan.md.bak"
bare_visual_output="$(run_fail "$SPRINT" complete)"
assert_contains "$bare_visual_output" "has a broken visual reference"
assert_contains "$bare_visual_output" "Mockup-1.jpg"
assert_contains "$bare_visual_output" "never embedded as a real image"

# Add a real embed for the bare mention, but do NOT create the file on disk —
# t-215f's second gap: a syntactically-correct embed whose target was never actually
# copied to visuals/ must also block, with a distinct message, not silently pass.
cat >> ".tickets/$id/plan.md" <<'EOF'

![Mockup 1](visuals/Mockup-1.jpg)
EOF
missing_file_output="$(run_fail "$SPRINT" complete)"
assert_contains "$missing_file_output" "has a broken visual reference"
assert_contains "$missing_file_output" "doesn't exist on disk"

# Actually copy the file to visuals/ — gate passes, eval gate fires next
mkdir -p ".tickets/$id/visuals"
printf '\x89PNG\r\n\x1a\n' > ".tickets/$id/visuals/Mockup-1.jpg"

# All gates satisfied — sprint complete should succeed
cat > ".tickets/$id/acceptance.md" <<'EOF'
# Acceptance

## Criteria
- [x] Required item remains.
  - [x] Indented item remains.
* [x] Asterisk item remains.

## Test Plan
- [x] npm test

## Wrapup Gates
| Gate | Status | Reason |
|------|--------|--------|
| code-reviewer | ran | reviewed tools/sprint gate logic |
| code-simplifier | skipped | test-only change |
EOF

# eval-report.md gate — missing report should block
missing_eval_output="$(run_fail "$SPRINT" complete)"
assert_contains "$missing_eval_output" "eval-report.md is missing"
assert_gate_notice "$missing_eval_output" eval-report.md evaluator
assert_contains "$missing_eval_output" "Tier: trivial"
assert_contains "$missing_eval_output" "four not-trivial triggers"

# eval-report.md with non-pass verdict should block — give it a matching
# jsonl entry first so this test exercises the verdict check, not the
# (now-mandatory) jsonl-authenticity check exercised separately below.
mkdir -p .claude
cat > ".claude/subagent-runs.jsonl" <<'EOF'
{"ts":"2001-09-09T01:46:40Z","session_id":"s1","agent_id":"agent-prelim","agent_type":"general-purpose","transcript_path":"/tmp/prelim.jsonl"}
EOF
cat > ".tickets/$id/eval-report.md" <<'EOF'
# Eval Report
evaluator-run-id: 1000000000-12345
## Verdict
fail: criterion 1 not met
EOF
fail_eval_output="$(run_fail "$SPRINT" complete)"
assert_contains "$fail_eval_output" "eval-report.md verdict is not pass"
assert_gate_notice "$fail_eval_output" eval-report.md evaluator   # t-0231: the message that invites flipping fail: to pass: by hand

# eval-report.md missing evaluator-run-id should block
cat > ".tickets/$id/eval-report.md" <<'EOF'
# Eval Report
## Verdict
pass: all criteria met
EOF
missing_runid_output="$(run_fail "$SPRINT" complete)"
assert_contains "$missing_runid_output" "missing evaluator-run-id"
assert_gate_notice "$missing_runid_output" eval-report.md evaluator

# JSONL present, no matching entry within ±60 min → should block
# run-id epoch = 1000000000 (2001-09-09T01:46:40Z); entry is 2h before = out of window
mkdir -p .claude
cat > ".claude/subagent-runs.jsonl" <<'EOF'
{"ts":"2001-09-08T23:46:40Z","session_id":"s1","agent_id":"agent-old","agent_type":"general-purpose","transcript_path":"/tmp/old.jsonl"}
EOF
cat > ".tickets/$id/eval-report.md" <<'EOF'
# Eval Report
evaluator-run-id: 1000000000-99999
Model: test-model
## Criteria
| Criterion | Status | Evidence |
|---|---|---|
| Required item remains | pass | acceptance.md:4 |
## Verdict
pass: all criteria met
EOF
jsonl_nomatch_output="$(run_fail "$SPRINT" complete)"
assert_contains "$jsonl_nomatch_output" "no matching subagent entry"
assert_gate_notice "$jsonl_nomatch_output" eval-report.md evaluator
# t-c94f: a well-formed but out-of-window entry gets the plain message — no malformed-entry hint.
[[ "$jsonl_nomatch_output" == *"no ISO"* ]] && fail "out-of-window ISO entry must not trigger the malformed hint: $jsonl_nomatch_output"

# t-b2a9: a run-id without a timestamp prefix is the other message a model could "fix" by editing the report.
cat > ".tickets/$id/eval-report.md" <<'EOF'
# Eval Report
evaluator-run-id: abc-1
Model: test-model
## Verdict
pass: all criteria met
EOF
badprefix_output="$(run_fail "$SPRINT" complete)"
assert_contains "$badprefix_output" "no valid timestamp prefix"
assert_gate_notice "$badprefix_output" eval-report.md evaluator
cat > ".tickets/$id/eval-report.md" <<'EOF'
# Eval Report
evaluator-run-id: 1000000000-99999
Model: test-model
## Criteria
| Criterion | Status | Evidence |
|---|---|---|
| Required item remains | pass | acceptance.md:4 |
## Verdict
pass: all criteria met
EOF

# t-c94f: an entry with an integer "timestamp" and no ISO "ts" is still rejected (a hand-written
# record must not satisfy the audit trail) — but the message now names why and how to fix it.
cat > ".claude/subagent-runs.jsonl" <<'EOF'
{"timestamp":1000000100,"agent_id":"hand-written","agent_type":"evaluator"}
EOF
int_ts_output="$(run_fail "$SPRINT" complete)"
assert_contains "$int_ts_output" "no matching subagent entry"
assert_contains "$int_ts_output" "1 entry in .claude/subagent-runs.jsonl has no ISO"
# t-0231: this line used to read "Log the evaluator with: subagent-log.sh --agent-id <the report's run-id>", which on its own invites
# logging a fake run to satisfy the window match. It now says the log records a run that happened, and no longer hands over a ready-made command.
assert_contains "$int_ts_output" "it records a run that happened"
[[ "$int_ts_output" != *"Log the evaluator with"* ]] || fail "the malformed-entry note must not hand over a ready-made subagent-log.sh command"
[[ "$int_ts_output" != *"--agent-id 1000000000-99999"* ]] || fail "the malformed-entry note must not echo the report's run-id into a subagent-log.sh command"
assert_contains "$int_ts_output" "do not hand-edit"

# t-c94f: untrusted log input never crashes or matches — empty, garbage, CRLF, a 100 KB line, and a
# "ts" holding an injected newline all fail cleanly (plural wording covers >1 malformed line).
printf '' > ".claude/subagent-runs.jsonl"
empty_log_output="$(run_fail "$SPRINT" complete)"
assert_contains "$empty_log_output" "no matching subagent entry"
[[ "$empty_log_output" == *"no ISO"* ]] && fail "an empty log has nothing malformed to report: $empty_log_output"
{
  printf 'not json at all\n'
  printf '{"ts":"2001-09-09T01:46:40Z\\n","agent_id":"nl"}\r\n'
  printf '{"timestamp":1000000100,"pad":"%s"}\n' "$(head -c 100000 /dev/zero | tr '\0' 'x')"
} > ".claude/subagent-runs.jsonl"
garbage_output="$(run_fail "$SPRINT" complete)"
assert_contains "$garbage_output" "no matching subagent entry"
assert_contains "$garbage_output" "3 entries in .claude/subagent-runs.jsonl have no ISO"

# JSONL present, matching entry within ±60 min → should pass
# entry ts 30 min after run epoch (2001-09-09T02:16:40Z) = within window. A malformed line ahead of it
# (t-c94f) must not stop the valid one from matching — the accept decision is unchanged.
cat > ".claude/subagent-runs.jsonl" <<'EOF'
{"timestamp":1000000100,"agent_id":"hand-written","agent_type":"evaluator"}
{"ts":"2001-09-09T02:16:40Z","session_id":"s1","agent_id":"agent-real","agent_type":"general-purpose","transcript_path":"/tmp/eval.jsonl"}
EOF
match_output="$("$SPRINT" complete 2>&1 || true)"
[[ "$match_output" == *"no matching subagent entry"* ]] && fail "matching JSONL entry should not block close: $match_output"
# Sprint closed — start a fresh one to test the JSONL-absent fail-closed path

fresh_start_output="$("$SPRINT" start "JSONL absent path test")"
fresh_id="$(printf '%s\n' "$fresh_start_output" | awk '/Sprint started:/ { print $3 }')"
cat > ".tickets/$fresh_id/summary.md" <<'EOF'
# Summary
| Item | Status |
|---|---|
| done | delivered |
EOF
cat > ".tickets/$fresh_id/acceptance.md" <<'EOF'
# Acceptance
## Criteria
- [x] item
## Test Plan
- [x] npm test
## Wrapup Gates
| Gate | Status | Reason |
|------|--------|--------|
| eval | ran | pass |
EOF
cat > ".tickets/$fresh_id/plan.md" <<'EOF'
# Plan
## Sign-off
- [x] Plan approved
## Approach
test
EOF
cat > ".tickets/$fresh_id/eval-report.md" <<'EOF'
evaluator-run-id: 1000000000-absent-test
Model: test-model
## Verdict
pass: all criteria met
EOF
# JSONL absent entirely → must fail closed, not silently skip verification
rm -f .claude/subagent-runs.jsonl
jsonl_absent_output="$(run_fail "$SPRINT" complete)"
assert_contains "$jsonl_absent_output" "subagent-runs.jsonl not found"
assert_gate_notice "$jsonl_absent_output" eval-report.md evaluator

# Provide a matching entry — now it can close
# entry ts 30 min after run epoch (2001-09-09T02:16:40Z) = within window. A malformed line ahead of it
# (t-c94f) must not stop the valid one from matching — the accept decision is unchanged.
cat > ".claude/subagent-runs.jsonl" <<'EOF'
{"timestamp":1000000100,"agent_id":"hand-written","agent_type":"evaluator"}
{"ts":"2001-09-09T02:16:40Z","session_id":"s1","agent_id":"agent-real2","agent_type":"general-purpose","transcript_path":"/tmp/eval2.jsonl"}
EOF
complete_output="$("$SPRINT" complete)"
assert_contains "$complete_output" "Sprint completed: $fresh_id"
assert_grep "^status: closed$" ".tickets/$fresh_id/ticket.md"
assert_grep "^status: closed$" ".tickets/$id/ticket.md"
[[ ! -f .tickets/ACTIVE ]] || fail "expected ACTIVE to be cleared after sprint complete"

# t-bdfb: a MILLISECOND run-id (13-digit, JS Date.now() style) must normalize to
# seconds (÷1000) and still match a real subagent entry within the ±60 min
# window — some evaluators emit Date.now() instead of `date +%s`.
ms_start_output="$("$SPRINT" start "millisecond run-id tolerance test")"
ms_id="$(printf '%s\n' "$ms_start_output" | awk '/Sprint started:/ { print $3 }')"
cat > ".tickets/$ms_id/summary.md" <<'EOF'
# Summary
| Item | Status |
|---|---|
| done | delivered |
EOF
cat > ".tickets/$ms_id/acceptance.md" <<'EOF'
# Acceptance
## Criteria
- [x] item
## Test Plan
- [x] npm test
## Wrapup Gates
| Gate | Status | Reason |
|------|--------|--------|
| eval | ran | pass |
EOF
cat > ".tickets/$ms_id/plan.md" <<'EOF'
# Plan
## Sign-off
- [x] Plan approved
## Approach
test
EOF
# 1000000000000 ms ÷ 1000 = 1000000000 s (2001-09-09T01:46:40Z)
cat > ".tickets/$ms_id/eval-report.md" <<'EOF'
evaluator-run-id: 1000000000000-mstest
Model: test-model
## Verdict
pass: all criteria met
EOF
# matching seconds entry 30 min after the normalized epoch (within ±60 min)
cat > ".claude/subagent-runs.jsonl" <<'EOF'
{"ts":"2001-09-09T02:16:40Z","session_id":"s1","agent_id":"agent-ms","agent_type":"general-purpose","transcript_path":"/tmp/evalms.jsonl"}
EOF
ms_complete_output="$("$SPRINT" complete 2>&1 || true)"
[[ "$ms_complete_output" == *"no matching subagent entry"* ]] && fail "millisecond run-id should normalize to seconds and match: $ms_complete_output"
assert_contains "$ms_complete_output" "Sprint completed: $ms_id"

# ── t-072d: HARD RULE — the report-body `Model:` line is mandatory ───────────
model_start_output="$("$SPRINT" start "Model line HARD RULE test")"
model_id="$(printf '%s\n' "$model_start_output" | awk '/Sprint started:/ { print $3 }')"
cat > ".tickets/$model_id/plan.md" <<'EOF'
# Plan
## Sign-off
- [x] Plan approved
## Approach
test
EOF
cat > ".tickets/$model_id/acceptance.md" <<'EOF'
# Acceptance
## Criteria
- [x] item
## Test Plan
- [x] npm test
## Wrapup Gates
| Gate | Status | Reason |
|------|--------|--------|
| eval | ran | pass |
EOF
cat > ".tickets/$model_id/summary.md" <<'EOF'
# Summary
| Item | Status |
|---|---|
| done | delivered |
EOF
cat > ".claude/subagent-runs.jsonl" <<'EOF'
{"ts":"2001-09-09T02:16:40Z","session_id":"s1","agent_id":"agent-model","agent_type":"general-purpose","transcript_path":"/tmp/model.jsonl"}
EOF
# eval-report has run-id + matching jsonl + pass verdict, but NO Model line → blocked
cat > ".tickets/$model_id/eval-report.md" <<'EOF'
# Eval Report
evaluator-run-id: 1000000000-modeltest
## Verdict
pass: all criteria met
EOF
model_missing_output="$(run_fail "$SPRINT" complete)"
assert_contains "$model_missing_output" "eval-report.md is missing the 'Model:' line"
assert_gate_notice "$model_missing_output" eval-report.md evaluator

# add the Model line → eval-report gate satisfied (no review-notes.md yet → its gate is a no-op)
cat > ".tickets/$model_id/eval-report.md" <<'EOF'
# Eval Report
evaluator-run-id: 1000000000-modeltest
Model: test-model
## Verdict
pass: all criteria met
EOF
# a review-notes.md that EXISTS but has no Model line must also block
cat > ".tickets/$model_id/review-notes.md" <<'EOF'
# Review Notes
## Verdict
YES
EOF
review_missing_output="$(run_fail "$SPRINT" complete)"
assert_contains "$review_missing_output" "review-notes.md is missing the 'Model:' line"
assert_gate_notice "$review_missing_output" review-notes.md reviewer

# t-de16: the reviewer's passes must be SHOWN. A bare "No findings. / YES" report — the
# t-294b live defect, two runs with the same 111 bytes, one over an empty diff — is rejected.
cat > ".tickets/$model_id/review-notes.md" <<'EOF'
# Review Notes
Model: test-model
## Findings
No findings.
## Verdict
YES
EOF
bare_output="$(run_fail "$SPRINT" complete)"
assert_contains "$bare_output" "does not show the reviewer's passes"
assert_gate_notice "$bare_output" review-notes.md reviewer
assert_contains "$bare_output" 'no `Changed files:` line'
assert_contains "$bare_output" 'no line for the "Scope creep" concern'

good_review() {
  # $1 = Changed files value, $2 = Scope creep line value (the rest are well-formed)
  cat > ".tickets/$model_id/review-notes.md" <<EOF
# Review Notes
Model: test-model
Changed files: $1
## Findings
Scope creep: $2
Visual regression: none — checked no UI files changed, tools/sprint:1
Dead code: none — checked no code orphaned by the gate, tools/sprint:470
Unnecessary complexity: none — checked one function, tools/sprint:463
Standards violations: none — checked efficiency.md, tools/sprint:470
## Verdict
YES
EOF
}
# an empty diff lists no path
good_review "none (empty diff)" "none — checked plan.md Files vs diff, plan.md:20"
empty_output="$(run_fail "$SPRINT" complete)"
assert_contains "$empty_output" 'lists no path'
# a `none` with no what-was-checked / file:line
good_review "tools/sprint, tests/sprint.sh" "none"
uncited_output="$(run_fail "$SPRINT" complete)"
assert_contains "$uncited_output" 'the "Scope creep" `none` line must say what was checked'
# each half of the `none` requirement is enforced alone: a citation with no `checked`, and `checked` with no citation
good_review "tools/sprint, tests/sprint.sh" "none, tools/sprint:12"
nocheck_output="$(run_fail "$SPRINT" complete)"
assert_contains "$nocheck_output" 'the "Scope creep" `none` line must say what was checked'
good_review "tools/sprint, tests/sprint.sh" "none — checked plan.md Files vs diff"
nocite_output="$(run_fail "$SPRINT" complete)"
assert_contains "$nocite_output" 'the "Scope creep" `none` line must say what was checked'
# a missing concern line names the concern
good_review "tools/sprint, tests/sprint.sh" "none — checked plan.md Files vs diff, plan.md:20"
grep -v '^Dead code:' ".tickets/$model_id/review-notes.md" > ".tickets/$model_id/rn.tmp" && mv ".tickets/$model_id/rn.tmp" ".tickets/$model_id/review-notes.md"
missing_output="$(run_fail "$SPRINT" complete)"
assert_contains "$missing_output" 'no line for the "Dead code" concern'

# a fully-formed report — one real finding, the rest checked-none — satisfies both gates → closes.
# The paths merely START with n/na/empty (native/, empty-state.js) and the finding starts with
# "none" as a prefix (nonexistent…): neither may be read as an empty diff or an uncited none.
good_review "native/foo.c, empty-state.js" "nonexistent helper referenced, tools/sprint:12 [severity: low · confidence: med]"
model_complete_output="$("$SPRINT" complete)"
assert_contains "$model_complete_output" "Sprint completed: $model_id"
assert_grep "^status: closed$" ".tickets/$model_id/ticket.md"


# ── eval_override (t-c0e6, t-7cd5): human-hand-edit-only, deliberately coarse
# tkt create seeds every new ticket with "eval_override: false" (t-7cd5) so the
# field is discoverable — but no tkt/sprint command ever WRITES "true"; flipping
# it to true still requires a human hand-editing ticket.md directly. The CLI
# check is intentionally coarse (flag + at least one dated waiver present) —
# per-item waiver correctness is verified by a human at complete.md's steps
# 4-5, not re-derived mechanically here. A mechanical per-item check
# (text-matching, then position-based correlation) was built and abandoned as
# fundamentally unsound across five rounds of adversarial review (see
# DECISIONS.md) — every version shipped failed open.

# Freshly created ticket seeds eval_override: false (t-7cd5)
override_start_output="$("$SPRINT" start "eval_override coverage")"
override_id="$(printf '%s\n' "$override_start_output" | awk '/Sprint started:/ { print $3 }')"
assert_grep "^eval_override: false$" ".tickets/$override_id/ticket.md"

# eval_override: false (the seeded default) → unchanged fail-closed behavior
cat > ".tickets/$override_id/plan.md" <<'EOF'
# Plan
## Sign-off
- [x] Plan approved
## Approach
test
EOF
cat > ".tickets/$override_id/acceptance.md" <<'EOF'
# Acceptance
## Criteria
- [x] Some criterion. **Waived (partial):** live-API-only claim, user-approved waiver, 2026-07-11: cannot re-verify without real cost per run.
## Test Plan
- [x] npm test
## Wrapup Gates
| Gate | Status | Reason |
|------|--------|--------|
| eval | ran | verdict: fail |
EOF
cat > ".tickets/$override_id/summary.md" <<'EOF'
# Summary
| Item | Status |
|---|---|
| done | delivered |
EOF
mkdir -p .claude
cat > ".claude/subagent-runs.jsonl" <<'EOF'
{"ts":"2001-09-09T02:16:40Z","session_id":"s1","agent_id":"agent-override","agent_type":"general-purpose","transcript_path":"/tmp/override.jsonl"}
EOF
cat > ".tickets/$override_id/eval-report.md" <<'EOF'
# Eval Report
evaluator-run-id: 1000000000-override1
Model: test-model
## Verdict
fail: one criterion partial
EOF
no_override_output="$(run_fail "$SPRINT" complete)"
assert_contains "$no_override_output" "eval-report.md verdict is not pass"
assert_gate_notice "$no_override_output" eval-report.md evaluator

# eval_override: true, acceptance.md has a dated waiver → allowed (coarse check)
# ticket.md already has "eval_override: false" seeded by tkt create — replace it,
# don't insert a second line (a duplicate would let the first-match reader see
# "false" and silently defeat this test).
sed -i.bak 's/^eval_override: false$/eval_override: true/' ".tickets/$override_id/ticket.md"
rm -f ".tickets/$override_id/ticket.md.bak"
override_pass_output="$("$SPRINT" complete)"
assert_contains "$override_pass_output" "Sprint completed: $override_id"
assert_grep "^status: closed$" ".tickets/$override_id/ticket.md"

# eval_override: true, but acceptance.md has NO waiver at all → still blocked
unwaived_start_output="$("$SPRINT" start "eval_override no waiver")"
unwaived_id="$(printf '%s\n' "$unwaived_start_output" | awk '/Sprint started:/ { print $3 }')"
sed -i.bak 's/^eval_override: false$/eval_override: true/' ".tickets/$unwaived_id/ticket.md"
rm -f ".tickets/$unwaived_id/ticket.md.bak"
cat > ".tickets/$unwaived_id/plan.md" <<'EOF'
# Plan
## Sign-off
- [x] Plan approved
## Approach
test
EOF
cat > ".tickets/$unwaived_id/acceptance.md" <<'EOF'
# Acceptance
## Criteria
- [x] Some criterion with no waiver annotation at all.
## Test Plan
- [x] npm test
## Wrapup Gates
| Gate | Status | Reason |
|------|--------|--------|
| eval | ran | verdict: fail |
EOF
cat > ".tickets/$unwaived_id/summary.md" <<'EOF'
# Summary
| Item | Status |
|---|---|
| done | delivered |
EOF
cat > ".tickets/$unwaived_id/eval-report.md" <<'EOF'
# Eval Report
evaluator-run-id: 1000000000-unwaived1
## Verdict
fail: one criterion not met, no waiver
EOF
cat > ".claude/subagent-runs.jsonl" <<'EOF'
{"ts":"2001-09-09T02:16:40Z","session_id":"s1","agent_id":"agent-unwaived","agent_type":"general-purpose","transcript_path":"/tmp/unwaived.jsonl"}
EOF
unwaived_output="$(run_fail "$SPRINT" complete)"
assert_contains "$unwaived_output" "no dated waiver on record"
[[ -f .tickets/ACTIVE ]] && "$TKT" close "$unwaived_id" --no-sprint >/dev/null

# eval_override: true, acceptance.md mentions "waiver" but never "waived" → still blocked
wrongword_start_output="$("$SPRINT" start "eval_override wrong word")"
wrongword_id="$(printf '%s\n' "$wrongword_start_output" | awk '/Sprint started:/ { print $3 }')"
sed -i.bak 's/^eval_override: false$/eval_override: true/' ".tickets/$wrongword_id/ticket.md"
rm -f ".tickets/$wrongword_id/ticket.md.bak"
cat > ".tickets/$wrongword_id/plan.md" <<'EOF'
# Plan
## Sign-off
- [x] Plan approved
## Approach
test
EOF
cat > ".tickets/$wrongword_id/acceptance.md" <<'EOF'
# Acceptance
## Criteria
- [x] Some criterion mentions a waiver process but records no waiver decision, dated 2026-07-11.
## Test Plan
- [x] npm test
## Wrapup Gates
| Gate | Status | Reason |
|------|--------|--------|
| eval | ran | verdict: fail |
EOF
cat > ".tickets/$wrongword_id/summary.md" <<'EOF'
# Summary
| Item | Status |
|---|---|
| done | delivered |
EOF
cat > ".tickets/$wrongword_id/eval-report.md" <<'EOF'
# Eval Report
evaluator-run-id: 1000000000-wrongword1
## Verdict
fail: one criterion not met
EOF
cat > ".claude/subagent-runs.jsonl" <<'EOF'
{"ts":"2001-09-09T02:16:40Z","session_id":"s1","agent_id":"agent-wrongword","agent_type":"general-purpose","transcript_path":"/tmp/wrongword.jsonl"}
EOF
wrongword_output="$(run_fail "$SPRINT" complete)"
assert_contains "$wrongword_output" "no dated waiver on record"
[[ -f .tickets/ACTIVE ]] && "$TKT" close "$wrongword_id" --no-sprint >/dev/null

# tools/tkt may only ever seed eval_override as the fixed "false" scaffolding
# string — it must never contain a code path that writes "true" (t-7cd5).
grep -qE 'eval_override' "$TKT" || fail "tools/tkt should seed eval_override: false on ticket creation, but the string is missing entirely"
grep -E 'eval_override' "$TKT" | grep -qi 'true' && fail "tools/tkt must never write eval_override: true — that stays hand-edit-only by design"
mkdir -p nested/deeper
(
  cd nested/deeper
  nested_start_output="$("$SPRINT" start "Nested sprint")"
  nested_id="$(printf '%s\n' "$nested_start_output" | awk '/Sprint started:/ { print $3 }')"
  [[ -f "../../.tickets/$nested_id/ticket.md" ]] || fail "expected nested sprint to use project .tickets"
)
# Clean up ACTIVE left by the nested sprint (it wasn't completed in the subshell)
[[ -f .tickets/ACTIVE ]] && "$TKT" close "$(cat .tickets/ACTIVE)" --no-sprint >/dev/null

# sprint start <existing-id> works the existing ticket directly — no child created
existing_id="$("$TKT" create "pre-existing backlog ticket" -t task -p 3)"
ticket_count_before="$(find .tickets -name "ticket.md" | wc -l | tr -d ' ')"
resume_output="$("$SPRINT" start "$existing_id")"
ticket_count_after="$(find .tickets -name "ticket.md" | wc -l | tr -d ' ')"
assert_contains "$resume_output" "Sprint started: $existing_id"
assert_file_exists ".tickets/$existing_id/plan.md"
assert_file_exists ".tickets/$existing_id/acceptance.md"
[[ "$ticket_count_after" -eq "$ticket_count_before" ]] || fail "sprint start <id> must not create a new ticket (before: $ticket_count_before, after: $ticket_count_after)"
assert_grep "^status: in_progress$" ".tickets/$existing_id/ticket.md"
"$TKT" close "$existing_id" --no-sprint >/dev/null   # clear ACTIVE without needing acceptance sign-off

# partial ID resolution
partial_ticket_id="$("$TKT" create "partial id test ticket" -t task -p 3)"
partial="${partial_ticket_id#t-}"
partial="${partial:0:3}"
partial_output="$("$SPRINT" start "$partial")"
assert_contains "$partial_output" "Sprint started: $partial_ticket_id"
"$TKT" close "$partial_ticket_id" --no-sprint >/dev/null

# sprint eval-verdict: increments eval_fail_count on fail, resets on pass, warns at 3
eval_id="$("$TKT" create "eval-verdict state machine test" -t task -p 3)"
assert_grep "^eval_fail_count: 0$" ".tickets/$eval_id/ticket.md"

echo "fail: first attempt" > ".tickets/$eval_id/eval-report.md"
v1="$("$SPRINT" eval-verdict "$eval_id")"
assert_contains "$v1" "eval_fail_count=1"
assert_grep "^eval_fail_count: 1$" ".tickets/$eval_id/ticket.md"

v2="$("$SPRINT" eval-verdict "$eval_id")"
assert_contains "$v2" "eval_fail_count=2"

v3="$("$SPRINT" eval-verdict "$eval_id" 2>&1)"
assert_contains "$v3" "eval_fail_count=3"
assert_contains "$v3" "retry budget exhausted"
assert_grep "^eval_fail_count: 3$" ".tickets/$eval_id/ticket.md"

echo "pass: fixed it" > ".tickets/$eval_id/eval-report.md"
v4="$("$SPRINT" eval-verdict "$eval_id")"
assert_contains "$v4" "eval_fail_count=0"
assert_grep "^eval_fail_count: 0$" ".tickets/$eval_id/ticket.md"

# backward compat: a ticket.md predating this field gets it appended, not rejected
sed -i.bak '/^eval_fail_count: /d' ".tickets/$eval_id/ticket.md" && rm -f ".tickets/$eval_id/ticket.md.bak"
grep -q '^eval_fail_count:' ".tickets/$eval_id/ticket.md" && fail "expected eval_fail_count line removed for backward-compat test"
echo "fail: legacy ticket" > ".tickets/$eval_id/eval-report.md"
v5="$("$SPRINT" eval-verdict "$eval_id")"
assert_contains "$v5" "eval_fail_count=1"
assert_grep "^eval_fail_count: 1$" ".tickets/$eval_id/ticket.md"
"$TKT" close "$eval_id" --no-sprint >/dev/null

# --- Bugfix tier (t-4b2a): eval-only — must NOT be exempt from the evaluator gate ---
# Contrast with trivial: trivial skips the eval-report gate; bugfix must not, because
# bugfix keeps the binding evaluator (only the advisory reviewer is skipped agent-side).
bugfix_id="$("$SPRINT" start "bugfix tier keeps the evaluator" | awk '/Sprint started:/ { print $3 }')"

cat > ".tickets/$bugfix_id/summary.md" <<'EOF'
# Summary
| Item | Status |
|---|---|
| fix | delivered |
EOF
cat > ".tickets/$bugfix_id/acceptance.md" <<'EOF'
# Acceptance
## Criteria
- [x] Bug fixed; independent invariant holds.
## Test Plan
- [x] npm test
## Wrapup Gates
| Gate | Status | Reason |
|------|--------|--------|
| security-review | ran | no trust boundary touched |
| repo-check | ran | single-file fix |
EOF
cat > ".tickets/$bugfix_id/plan.md" <<'EOF'
# Plan
## Sign-off
Tier: bugfix | Risk: single logic file + covering test
- [x] Plan approved — proceed to implementation
## Approach
Fix the off-by-one in the split calc; the covering test asserts the independent invariant.
EOF

# Tier: bugfix + no eval-report → must be BLOCKED (bugfix keeps the binding evaluator)
bugfix_no_eval="$(run_fail "$SPRINT" complete)"
assert_contains "$bugfix_no_eval" "eval-report.md is missing"

# Flip the identical setup to Tier: trivial → the eval gate is now skipped and it closes,
# proving the contrast: trivial skips the evaluator, bugfix does not.
sed -i.bak 's/^Tier: bugfix .*/Tier: trivial | Risk: genuinely a one-liner/' ".tickets/$bugfix_id/plan.md" && rm -f ".tickets/$bugfix_id/plan.md.bak"
trivial_close="$("$SPRINT" complete 2>&1 || true)"
assert_contains "$trivial_close" "closed"

# --- sprint suggest-tier (t-b6a3): propose-only structural bugfix-tier classifier ---
# Isolated git fixtures (make_project's shared repo has no origin/main baseline).
# Asserts run in the MAIN shell, never inside a subshell, so `fail` exits the suite;
# only the `cd` is scoped inside command substitution.
st_git_init() {  # st_git_init <dir>
  git -C "$1" init -q
  git -C "$1" config user.email t@example.com
  git -C "$1" config user.name test
}

# Case 1: one modified logic file + a covering test → bugfix; and it writes nothing.
st_d1="$(mktemp -d)"
st_git_init "$st_d1"
mkdir -p "$st_d1/src" "$st_d1/tests"
echo 'a' > "$st_d1/src/foo.js"
git -C "$st_d1" add -A >/dev/null && git -C "$st_d1" commit -qm base
git -C "$st_d1" update-ref refs/remotes/origin/main HEAD
echo 'b' >> "$st_d1/src/foo.js"
echo 'covering test' > "$st_d1/tests/foo_test.sh"
git -C "$st_d1" add -A >/dev/null && git -C "$st_d1" commit -qm fix
st_bugfix="$(cd "$st_d1" && "$SPRINT" suggest-tier)"
assert_contains "$st_bugfix" "suggested tier: bugfix"
assert_contains "$st_bugfix" "covering test"
assert_contains "$st_bugfix" "propose-only"
assert_contains "$st_bugfix" "independent invariant"
# propose-only: the run must not create/modify any file (no Tier: written anywhere)
st_clean="$(cd "$st_d1" && git status --porcelain)"
assert_eq "" "$st_clean"
rm -rf "$st_d1"

# Case 2: an added non-test logic file → normal (new file beyond the test)
st_d2="$(mktemp -d)"
st_git_init "$st_d2"
mkdir -p "$st_d2/src"
echo 'a' > "$st_d2/src/foo.js"
git -C "$st_d2" add -A >/dev/null && git -C "$st_d2" commit -qm base
git -C "$st_d2" update-ref refs/remotes/origin/main HEAD
echo 'x' > "$st_d2/src/newmod.js"
git -C "$st_d2" add -A >/dev/null && git -C "$st_d2" commit -qm add
st_newfile="$(cd "$st_d2" && "$SPRINT" suggest-tier)"
assert_contains "$st_newfile" "suggested tier: normal"
assert_contains "$st_newfile" "new file beyond the test"
rm -rf "$st_d2"

# Case 3: two modified non-test logic files → normal (coordinated multi-file intent)
st_d3="$(mktemp -d)"
st_git_init "$st_d3"
mkdir -p "$st_d3/src"
echo 'a' > "$st_d3/src/foo.js"
echo 'a' > "$st_d3/src/bar.js"
git -C "$st_d3" add -A >/dev/null && git -C "$st_d3" commit -qm base
git -C "$st_d3" update-ref refs/remotes/origin/main HEAD
echo 'b' >> "$st_d3/src/foo.js"
echo 'b' >> "$st_d3/src/bar.js"
git -C "$st_d3" add -A >/dev/null && git -C "$st_d3" commit -qm two
st_multi="$(cd "$st_d3" && "$SPRINT" suggest-tier)"
assert_contains "$st_multi" "suggested tier: normal"
assert_contains "$st_multi" "coordinated multi-file intent"
rm -rf "$st_d3"

# Case 4: a build/test-infrastructure file in the diff → normal (infrastructure wiring)
st_d4="$(mktemp -d)"
st_git_init "$st_d4"
mkdir -p "$st_d4/src"
echo 'a' > "$st_d4/src/foo.js"
git -C "$st_d4" add -A >/dev/null && git -C "$st_d4" commit -qm base
git -C "$st_d4" update-ref refs/remotes/origin/main HEAD
echo 'b' >> "$st_d4/src/foo.js"
echo '{}' > "$st_d4/package.json"
git -C "$st_d4" add -A >/dev/null && git -C "$st_d4" commit -qm infra
st_infra="$(cd "$st_d4" && "$SPRINT" suggest-tier)"
assert_contains "$st_infra" "suggested tier: normal"
assert_contains "$st_infra" "test/build-infrastructure wiring"
rm -rf "$st_d4"

# Case 5: a hook/pipeline file in the diff → normal (hook/pipeline change)
st_d5="$(mktemp -d)"
st_git_init "$st_d5"
mkdir -p "$st_d5/src" "$st_d5/.github/workflows"
echo 'a' > "$st_d5/src/foo.js"
git -C "$st_d5" add -A >/dev/null && git -C "$st_d5" commit -qm base
git -C "$st_d5" update-ref refs/remotes/origin/main HEAD
echo 'b' >> "$st_d5/src/foo.js"
echo 'ci' > "$st_d5/.github/workflows/ci.yml"
git -C "$st_d5" add -A >/dev/null && git -C "$st_d5" commit -qm ci
st_hook="$(cd "$st_d5" && "$SPRINT" suggest-tier)"
assert_contains "$st_hook" "suggested tier: normal"
assert_contains "$st_hook" "hook/pipeline/post-commit change"
rm -rf "$st_d5"

# Case 6: no origin/main baseline → normal, exit 0 (decided by merge-base exit status)
st_d6="$(mktemp -d)"
st_git_init "$st_d6"
mkdir -p "$st_d6/src"
echo 'a' > "$st_d6/src/foo.js"
git -C "$st_d6" add -A >/dev/null && git -C "$st_d6" commit -qm base
if st_nobase="$(cd "$st_d6" && "$SPRINT" suggest-tier)"; then st_rc=0; else st_rc=$?; fi
assert_eq "0" "$st_rc"
assert_contains "$st_nobase" "suggested tier: normal"
assert_contains "$st_nobase" "no git baseline"
rm -rf "$st_d6"

# ── t-eabb: not-run is a first-class, non-coercible verdict ──────────────────
# _gate_eval_report_consistency: a `pass:` verdict contradicted by the report's
# own `not-run`/`partial` status row must block close. Structural self-consistency
# check (report's verdict token vs its own status tokens), not a semantic re-derive.
consist_start_output="$("$SPRINT" start "not-run consistency gate test")"
consist_id="$(printf '%s\n' "$consist_start_output" | awk '/Sprint started:/ { print $3 }')"
cat > ".tickets/$consist_id/plan.md" <<'EOF'
# Plan
## Sign-off
- [x] Plan approved
## Approach
test
EOF
cat > ".tickets/$consist_id/acceptance.md" <<'EOF'
# Acceptance
## Criteria
- [x] item
## Test Plan
- [x] npm test
## Wrapup Gates
| Gate | Status | Reason |
|------|--------|--------|
| eval | ran | pass |
EOF
cat > ".tickets/$consist_id/summary.md" <<'EOF'
# Summary
| Item | Status |
|---|---|
| done | delivered |
EOF
cat > ".claude/subagent-runs.jsonl" <<'EOF'
{"ts":"2001-09-09T02:16:40Z","session_id":"s1","agent_id":"agent-consist","agent_type":"general-purpose","transcript_path":"/tmp/consist.jsonl"}
EOF

# T1: pass: verdict + a `not-run` status row → blocked (naming the contradiction)
cat > ".tickets/$consist_id/eval-report.md" <<'EOF'
# Eval Report
evaluator-run-id: 1000000000-consist1
Model: test-model
## Test Plan
| Item | Status | Notes |
|---|---|---|
| render the DOM and assert | not-run | no browser in eval env |
## Verdict
pass: all criteria met
EOF
notrun_verdict_output="$(run_fail "$SPRINT" complete)"
assert_contains "$notrun_verdict_output" "verdict is 'pass:' but a status row is graded 'not-run' or 'partial'"
assert_gate_notice "$notrun_verdict_output" eval-report.md evaluator   # t-0231: invites editing the rows or the verdict

# T2: pass: verdict + a `partial` status row → blocked
cat > ".tickets/$consist_id/eval-report.md" <<'EOF'
# Eval Report
evaluator-run-id: 1000000000-consist2
Model: test-model
## Criteria
| Criterion | Status | Evidence |
|---|---|---|
| feature works end to end | partial | only the happy path is wired |
## Verdict
pass: all criteria met
EOF
partial_verdict_output="$(run_fail "$SPRINT" complete)"
assert_contains "$partial_verdict_output" "verdict is 'pass:' but a status row is graded 'not-run' or 'partial'"
assert_gate_notice "$partial_verdict_output" eval-report.md evaluator

# T7: CRLF eval-report (Windows Git Bash) with pass: + not-run → still blocked
printf '# Eval Report\r\nevaluator-run-id: 1000000000-consist3\r\nModel: test-model\r\n## Test Plan\r\n| Item | Status | Notes |\r\n|---|---|---|\r\n| run the suite | not-run | interpreter missing |\r\n## Verdict\r\npass: all criteria met\r\n' > ".tickets/$consist_id/eval-report.md"
crlf_verdict_output="$(run_fail "$SPRINT" complete)"
assert_contains "$crlf_verdict_output" "verdict is 'pass:' but a status row is graded 'not-run' or 'partial'"

# Final close: a `pass:` report whose status tables contain ONLY real tokens
# closes — and a `pass / fail / partial` TEMPLATE placeholder row must NOT trip the
# gate (only a bare whitespace-bounded token counts). This one successful close
# proves both T3 (a pass report with status tables closes) and the false-positive guard.
cat > ".tickets/$consist_id/eval-report.md" <<'EOF'
# Eval Report
evaluator-run-id: 1000000000-consist5
Model: test-model
## Criteria
| Criterion | Status | Evidence |
|---|---|---|
| example row | pass / fail / partial | placeholder text, must not trip |
| real row | pass | acceptance.md:3 |
## Test Plan
| Item | Status | Notes |
|---|---|---|
| npm test | pass | ran green |
## Verdict
pass: all criteria met
EOF
consist_complete_output="$("$SPRINT" complete)"
assert_contains "$consist_complete_output" "Sprint completed: $consist_id"
[[ "$consist_complete_output" == *"status row is graded"* ]] && fail "template placeholder 'pass / fail / partial' must not trip the not-run consistency gate: $consist_complete_output"
assert_grep "^status: closed$" ".tickets/$consist_id/ticket.md"

# T4: a fail: verdict WITH a not-run row is unchanged — _gate_eval_report_verdict
# blocks it first (no pass:), and the consistency gate is a no-op on the non-pass path.
consist2_start_output="$("$SPRINT" start "not-run fail-path unchanged test")"
consist2_id="$(printf '%s\n' "$consist2_start_output" | awk '/Sprint started:/ { print $3 }')"
cat > ".tickets/$consist2_id/plan.md" <<'EOF'
# Plan
## Sign-off
- [x] Plan approved
## Approach
test
EOF
cat > ".tickets/$consist2_id/acceptance.md" <<'EOF'
# Acceptance
## Criteria
- [x] item
## Test Plan
- [x] npm test
## Wrapup Gates
| Gate | Status | Reason |
|------|--------|--------|
| eval | ran | fail |
EOF
cat > ".tickets/$consist2_id/summary.md" <<'EOF'
# Summary
| Item | Status |
|---|---|
| done | delivered |
EOF
cat > ".tickets/$consist2_id/eval-report.md" <<'EOF'
# Eval Report
evaluator-run-id: 1000000000-consist6
Model: test-model
## Test Plan
| Item | Status | Notes |
|---|---|---|
| render check | not-run | no browser |
## Verdict
fail: one item could not run
EOF
consist2_output="$(run_fail "$SPRINT" complete)"
assert_contains "$consist2_output" "eval-report.md verdict is not pass"
[[ -f .tickets/ACTIVE ]] && "$TKT" close "$consist2_id" --no-sprint >/dev/null

# ── t-01a4: sprint start's gate is per-worktree, not repo-wide ─────────────

sp_project="$(make_project)"
(cd "$sp_project" && git commit -q --allow-empty -m init)

(
  cd "$sp_project"
  main_out="$("$SPRINT" start "Main checkout ticket")"
  main_id="$(printf '%s\n' "$main_out" | awk '/Sprint started:/ { print $3 }')"

  # cmd_start writes .cockpit-cwd on a fresh start, matching worktree_root().
  assert_file_exists ".tickets/$main_id/.cockpit-cwd"
  assert_eq "$(pwd -P)" "$(cat ".tickets/$main_id/.cockpit-cwd")"

  # Same worktree (main checkout): a second sprint start is still blocked —
  # unchanged behavior for the dominant, common case.
  same_wt_blocked="$(run_fail "$SPRINT" start "Second in main checkout")"
  assert_contains "$same_wt_blocked" "Active sprint already exists:"

  # A different worktree: NOT blocked — the actual point of this ticket.
  sp_wt="$sp_project-worktrees/feat-x"
  mkdir -p "$(dirname "$sp_wt")"
  git worktree add -q -b sprint/feat-x "$sp_wt"
  wt_out="$(cd "$sp_wt" && "$SPRINT" start "Worktree ticket")"
  assert_contains "$wt_out" "Sprint started:"
  wt_id="$(printf '%s\n' "$wt_out" | awk '/Sprint started:/ { print $3 }')"
  assert_eq "$(cd "$sp_wt" && pwd -P)" "$(cat ".tickets/$wt_id/.cockpit-cwd")"

  # tkt current from EACH worktree resolves independently — the CLI-facing
  # proof that current_id()'s worktree-awareness and cmd_start's own binding
  # write interoperate correctly end to end.
  assert_contains "$("$TKT" current)" "$main_id"
  assert_contains "$(cd "$sp_wt" && "$TKT" current)" "$wt_id"

  git worktree remove -f "$sp_wt" >/dev/null 2>&1 || true
  "$TKT" close "$main_id" --no-sprint >/dev/null
  "$TKT" close "$wt_id" --no-sprint >/dev/null
)

rm -rf "$sp_project" "$sp_project-worktrees"

# ── t-0231: eval-report.md must be backed by a real canon-evaluator transcript ──────────────────────────────
# Claude Code keeps every subagent's transcript (agent-<id>.jsonl) and meta (agent-<id>.meta.json) under
# <config>/projects/<slug>/<session>/subagents/. An agent cannot write those, so a hand-written report, however well formed
# and however it was logged, has nothing behind it. Fixture config root; CLAUDECODE=1 turns the check on.
tx_project="$(make_project)"
tx_cfg="$(mktemp -d)"
(
  cd "$tx_project"
  mkdir -p .claude
  export CLAUDECODE=1 CLAUDE_CONFIG_DIR="$tx_cfg"
  now="$(date +%s)"
  stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  gate_ticket() { # starts a sprint with every doc valid except the report; sets gid
    local out; out="$("$SPRINT" start "transcript gate $1")"
    gid="$(printf '%s\n' "$out" | awk '/Sprint started:/ { print $3 }')"
    printf '# Plan\n## Sign-off\n- [x] Plan approved\n## Approach\ntest\n' > ".tickets/$gid/plan.md"
    printf '# Acceptance\n## Criteria\n- [x] item\n## Test Plan\n- [x] npm test\n## Wrapup Gates\n| Gate | Status | Reason |\n|------|--------|--------|\n| eval | ran | pass |\n' > ".tickets/$gid/acceptance.md"
    printf '# Summary\n| Item | Status |\n|---|---|\n| done | delivered |\n' > ".tickets/$gid/summary.md"
    printf '{"ts":"%s","session_id":"s1","agent_id":"x","agent_type":"evaluator","transcript_path":""}\n' "$stamp" > .claude/subagent-runs.jsonl
  }
  stamp_for() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
  touch_at() { touch -t "$(date -r "$2" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$2" +%Y%m%d%H%M.%S)" "$1"; }
  report() { # <run-id> <verdict line>
    printf '# Eval Report\nevaluator-run-id: %s\nModel: test-model\n## Verdict\n%s\n' "$1" "$2" > ".tickets/$gid/eval-report.md"
  }
  transcript() { # <name> <agentType> <text...>: a harness transcript + meta
    local d="$tx_cfg/projects/-proj/sess1/subagents"; mkdir -p "$d"
    printf '{"agentType": "%s", "description": "t"}\n' "$2" > "$d/agent-$1.meta.json"
    printf '%s\n' "${@:3}" > "$d/agent-$1.jsonl"
  }
  rid="$now-4242"

  gate_ticket blocked
  # (a) Claude Code is recognised (a subagents dir exists) and a genuine transcript exists, but the report's run-id was made up.
  transcript real canon-evaluator "evaluator-run-id: $now-9999" "$gid" "pass: all criteria met"
  report "$rid" "pass: all criteria met"
  out="$(run_fail "$SPRINT" complete)"
  assert_contains "$out" "no canon-evaluator transcript"
  assert_contains "$out" "$rid"
  assert_gate_notice "$out" eval-report.md evaluator
  # (b) the run-id is real but belongs to another ticket's run: the ticket id is not in the transcript.
  transcript real canon-evaluator "evaluator-run-id: $rid" "t-zzzz" "pass: all criteria met"
  out="$(run_fail "$SPRINT" complete)"; assert_contains "$out" "no canon-evaluator transcript"
  # (c) the right text, but the dispatch was not a canon-evaluator.
  transcript real canon-reviewer "evaluator-run-id: $rid" "$gid" "pass: all criteria met"
  out="$(run_fail "$SPRINT" complete)"; assert_contains "$out" "no canon-evaluator transcript"
  transcript real general-purpose "evaluator-run-id: $rid" "$gid" "pass: all criteria met"
  out="$(run_fail "$SPRINT" complete)"; assert_contains "$out" "no canon-evaluator transcript"
  # (d) a genuine run said fail:, and the report was hand-flipped to pass:.
  transcript real canon-evaluator "evaluator-run-id: $rid" "$gid" "fail: criterion 2 not met"
  out="$(run_fail "$SPRINT" complete)"; assert_contains "$out" "no canon-evaluator transcript"
  # (e) the transcript is too old for the run-id (3 hours before it).
  transcript real canon-evaluator "evaluator-run-id: $rid" "$gid" "pass: all criteria met"
  touch -t "$(date -v-3H +%Y%m%d%H%M.%S 2>/dev/null || date -d '3 hours ago' +%Y%m%d%H%M.%S)" "$tx_cfg/projects/-proj/sess1/subagents/agent-real.jsonl"
  out="$(run_fail "$SPRINT" complete)"; assert_contains "$out" "no canon-evaluator transcript"
  # (f) Claude Code is recognised but no evaluator transcript exists at all.
  rm -f "$tx_cfg"/projects/-proj/sess1/subagents/agent-*
  out="$(run_fail "$SPRINT" complete)"; assert_contains "$out" "no canon-evaluator transcript"

  # (g) a genuine dispatch: the transcript carries the run-id, the ticket id and the verdict -> the close goes through
  transcript real canon-evaluator "evaluator-run-id: $rid" "cd .tickets/$gid" "pass: all criteria met"
  assert_contains "$("$SPRINT" complete 2>&1)" "Sprint completed"
  # ...even in a later session: transcripts of every session in the window count
  gate_ticket resumed
  rid2="$now-5151"; report "$rid2" "pass: all criteria met"
  mkdir -p "$tx_cfg/projects/-other/sess9/subagents"
  printf '{"agentType": "canon-evaluator"}\n' > "$tx_cfg/projects/-other/sess9/subagents/agent-old.meta.json"
  printf 'evaluator-run-id: %s\n%s\npass: all criteria met\n' "$rid2" "$gid" > "$tx_cfg/projects/-other/sess9/subagents/agent-old.jsonl"
  assert_contains "$("$SPRINT" complete 2>&1)" "Sprint completed"

  # (i) the documented fallback dispatches the evaluator as `Plan` when canon's agent files are not installed (complete.md step 3):
  # it counts only when its transcript shows the evaluator protocol; a Plan agent doing something else, or a reviewer, does not.
  gate_ticket planfallback; rid3="$now-3333"; report "$rid3" "pass: all criteria met"
  transcript real Plan "evaluator-run-id: $rid3" "$gid" "pass: all criteria met"
  out="$(run_fail "$SPRINT" complete)"; assert_contains "$out" "no canon-evaluator transcript"
  transcript real Plan "Read skills/sprint/reference/eval.md" "evaluator-run-id: $rid3" "$gid" "pass: all criteria met"
  assert_contains "$("$SPRINT" complete 2>&1)" "Sprint completed"
  # (j) a symlinked projects dir is searched as well as recognised
  gate_ticket symlinked; rid4="$now-4444"; report "$rid4" "pass: all criteria met"
  sym_real="$(mktemp -d)"; sym_cfg="$(mktemp -d)"; ln -s "$sym_real" "$sym_cfg/projects"
  mkdir -p "$sym_real/-p/s1/subagents"
  printf '{"agentType": "canon-evaluator"}\n' > "$sym_real/-p/s1/subagents/agent-x.meta.json"
  printf 'evaluator-run-id: %s\n%s\npass: all criteria met\n' "$rid4" "$gid" > "$sym_real/-p/s1/subagents/agent-x.jsonl"
  assert_contains "$(CLAUDE_CONFIG_DIR="$sym_cfg" "$SPRINT" complete 2>&1)" "Sprint completed"
  rm -rf "$sym_real" "$sym_cfg"
  # (k) a verdict line too short to verify: bare `pass:` is a substring of every evaluator transcript
  gate_ticket shortverdict; rid5="$now-5555"; report "$rid5" "pass:"
  transcript real canon-evaluator "evaluator-run-id: $rid5" "$gid" "pass: all criteria met"
  out="$(run_fail "$SPRINT" complete)"
  assert_contains "$out" "too short to verify"
  assert_gate_notice "$out" eval-report.md evaluator
  "$TKT" close "$gid" --no-sprint >/dev/null   # a blocked scenario leaves its sprint active; the next one starts a new sprint
  # (l) the window's END edge: a transcript written more than an hour after the run-id does not count; one 5 minutes after does
  gate_ticket lateedge; old=$((now - 7200)); rid6="$old-6666"; report "$rid6" "pass: all criteria met"
  printf '{"ts":"%s","session_id":"s1","agent_id":"x","agent_type":"evaluator","transcript_path":""}\n' "$(stamp_for "$old")" > .claude/subagent-runs.jsonl
  transcript real canon-evaluator "evaluator-run-id: $rid6" "$gid" "pass: all criteria met"
  out="$(run_fail "$SPRINT" complete)"; assert_contains "$out" "no canon-evaluator transcript"   # its mtime is now: 2 hours after the run-id
  touch_at "$tx_cfg/projects/-proj/sess1/subagents/agent-real.jsonl" $((old + 300))
  assert_contains "$("$SPRINT" complete 2>&1)" "Sprint completed"
  # (m) a millisecond run-id (13 digits, eval.md says never, but t-bdfb tolerates it) is normalised for the window too
  gate_ticket millis; rid7="${now}000-7777"; report "$rid7" "pass: all criteria met"
  transcript real canon-evaluator "evaluator-run-id: $rid7" "$gid" "pass: all criteria met"
  assert_contains "$("$SPRINT" complete 2>&1)" "Sprint completed"

  # (n) EVERY verdict line must be backed: the verdict gate accepts any `^pass:` line, so a `pass:` appended under a genuine `fail:`
  # must not ride on the transcript's `fail:` (the check once looked only at the first verdict line).
  gate_ticket appended; rid8="$now-8888"
  printf '# Eval Report\nevaluator-run-id: %s\nModel: test-model\n## Verdict\nfail: criterion 2 not met\npass: all criteria met\n' "$rid8" > ".tickets/$gid/eval-report.md"
  transcript real canon-evaluator "evaluator-run-id: $rid8" "$gid" "fail: criterion 2 not met"
  out="$(run_fail "$SPRINT" complete)"; assert_contains "$out" "no canon-evaluator transcript"
  "$TKT" close "$gid" --no-sprint >/dev/null
  # (o) a terse but real verdict (eval.md asks for a sentence, real evaluators have written `pass: true`) still verifies; only a
  # line too short to be distinctive (bare `pass:`, case (k)) is refused
  gate_ticket terse; rid9="$now-9999"; report "$rid9" "pass: true"
  transcript real canon-evaluator "evaluator-run-id: $rid9" "$gid" "pass: true"
  assert_contains "$("$SPRINT" complete 2>&1)" "Sprint completed"

  # (p) a short `fail:` line cannot pass the verdict gate on its own, so the length rule skips it instead of blocking: a real evaluator
  # that wrote a terse `fail: x` next to a verified `pass:` line is not refused for the short one.
  gate_ticket shortfail; rid10="$now-1010"
  printf '# Eval Report\nevaluator-run-id: %s\nModel: test-model\n## Verdict\npass: all criteria met\nfail: x\n' "$rid10" > ".tickets/$gid/eval-report.md"
  transcript real canon-evaluator "evaluator-run-id: $rid10" "$gid" "pass: all criteria met"
  assert_contains "$("$SPRINT" complete 2>&1)" "Sprint completed"

  # (h) fail open: not Claude Code (no CLAUDECODE), or Claude Code with a layout never seen (no subagents dir anywhere).
  gate_ticket noclaude; report "$now-1111" "pass: all criteria met"
  assert_contains "$(env -u CLAUDECODE "$SPRINT" complete 2>&1)" "transcript check skipped"
  gate_ticket nolayout; report "$now-2222" "pass: all criteria met"
  empty_cfg="$(mktemp -d)"
  assert_contains "$(CLAUDE_CONFIG_DIR="$empty_cfg" "$SPRINT" complete 2>&1)" "transcript check skipped"
  rm -rf "$empty_cfg"
)
rm -rf "$tx_project" "$tx_cfg"

# t-1b74: a stale evaluator report. The report records the commit it graded (graded-head:), and `sprint complete` refuses when a
# tracked file outside the late-doc/artifact allow-list differs from that commit; honest path easy, a forgotten re-grade loud.
fr_project="$(make_project)"
(
  cd "$fr_project"
  git config user.email t@example.com; git config user.name test
  mkdir -p .claude src dist tools
  echo 'a' > src/app.js; echo '# L' > LEARNINGS.md; echo 'z' > dist/a.zip; echo 'x' > tools/cockpit-daemon-win.exe
  git add -A >/dev/null && git commit -qm base
  now="$(date +%s)"; stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  fr_ticket() { # starts a sprint with every doc valid except the report; sets fid
    local out; out="$("$SPRINT" start "stale eval $1")"
    fid="$(printf '%s\n' "$out" | awk '/Sprint started:/ { print $3 }')"
    printf '# Plan\n## Sign-off\n- [x] Plan approved\n## Approach\ntest\n' > ".tickets/$fid/plan.md"
    printf '# Acceptance\n## Criteria\n- [x] item\n## Test Plan\n- [x] npm test\n## Wrapup Gates\n| Gate | Status | Reason |\n|------|--------|--------|\n| eval | ran | pass |\n' > ".tickets/$fid/acceptance.md"
    printf '# Summary\n| Item | Status |\n|---|---|\n| done | delivered |\n' > ".tickets/$fid/summary.md"
    printf '{"ts":"%s","session_id":"s1","agent_id":"x","agent_type":"evaluator","transcript_path":""}\n' "$stamp" > .claude/subagent-runs.jsonl
  }
  fr_report() { # <graded-head value>...: a passing report that records each value as a graded-head line
    { printf '# Eval Report\nevaluator-run-id: %s\n' "$now-7000"; local g; for g in "$@"; do printf 'graded-head: %s\n' "$g"; done
      printf 'Model: test-model\n## Verdict\npass: all criteria met\n'; } > ".tickets/$fid/eval-report.md"
  }
  fr_complete() { env -u CLAUDECODE "$SPRINT" complete 2>&1; }   # not Claude Code: the transcript check fails open, the rest still runs
  head0="$(git rev-parse HEAD)"

  fr_ticket missing; fr_report
  # a report without the line, two different values, and a value that is not a commit are each refused
  sed -i.bak '/^graded-head:/d' ".tickets/$fid/eval-report.md" && rm -f ".tickets/$fid/eval-report.md.bak"
  out="$(run_fail env -u CLAUDECODE "$SPRINT" complete)"; assert_contains "$out" "missing graded-head"; assert_gate_notice "$out" eval-report.md evaluator
  fr_report "$head0" "0000000000000000000000000000000000000001"
  out="$(run_fail env -u CLAUDECODE "$SPRINT" complete)"; assert_contains "$out" "more than one graded-head"; assert_gate_notice "$out" eval-report.md evaluator
  fr_report "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
  out="$(run_fail env -u CLAUDECODE "$SPRINT" complete)"; assert_contains "$out" "is not a commit"; assert_gate_notice "$out" eval-report.md evaluator

  # a code commit after grading is stale, and eval_override does not bypass it
  fr_report "$head0"
  echo 'b' >> src/app.js; git add src/app.js; git commit -qm "code after grading"
  out="$(run_fail env -u CLAUDECODE "$SPRINT" complete)"
  assert_contains "$out" "tracked files changed after the evaluator graded"; assert_contains "$out" "src/app.js"; assert_contains "$out" "re-dispatch a fresh evaluator"
  assert_gate_notice "$out" eval-report.md evaluator
  sed -i.bak 's/^eval_override: false/eval_override: true/' ".tickets/$fid/ticket.md" && rm -f ".tickets/$fid/ticket.md.bak"
  printf '\nwaived 2026-01-01 test\n' >> ".tickets/$fid/acceptance.md"
  out="$(run_fail env -u CLAUDECODE "$SPRINT" complete)"; assert_contains "$out" "tracked files changed after the evaluator graded"
  head1="$(git rev-parse HEAD)"

  # re-graded at the new HEAD: only late docs, hook-built artifacts and untracked files differ afterwards, which is allowed
  "$TKT" close "$fid" --no-sprint >/dev/null
  fr_ticket late; fr_report "$head1"
  echo '| row |' >> LEARNINGS.md; git add LEARNINGS.md; git commit -qm "learnings"
  echo 'zz' > dist/a.zip; echo 'xx' > tools/cockpit-daemon-win.exe; git add dist tools; git commit -qm "hook artifacts"
  echo 'scratch' > untracked-scratch.txt
  assert_contains "$(fr_complete)" "Sprint completed: $fid"

  # an uncommitted edit to a tracked code file is stale too
  fr_ticket dirty; fr_report "$(git rev-parse HEAD)"
  echo 'c' >> src/app.js
  out="$(run_fail env -u CLAUDECODE "$SPRINT" complete)"; assert_contains "$out" "src/app.js"
  git checkout -q src/app.js
  assert_contains "$(fr_complete)" "Sprint completed: $fid"

  # graded-head must be a full hex commit sha: an abbreviation or a ref name is refused (HEAD would hide committed changes)
  fr_ticket refs; fr_report "$(git rev-parse --short HEAD)"
  out="$(run_fail env -u CLAUDECODE "$SPRINT" complete)"; assert_contains "$out" "is not a commit"
  fr_report "HEAD"
  out="$(run_fail env -u CLAUDECODE "$SPRINT" complete)"; assert_contains "$out" "is not a commit"

  # a tracked .tickets/ (consumer projects), AGENTS.md and any CLAUDE.md are written after grading by complete.md steps 6-7: allowed
  fr_report "$(git rev-parse HEAD)"
  mkdir -p docs; echo 'c' > AGENTS.md; echo 'c' > CLAUDE.md; echo 'c' > docs/CLAUDE.md
  git add -f -A .tickets AGENTS.md CLAUDE.md docs/CLAUDE.md; git commit -qm "ticket docs and convention files"
  assert_contains "$(fr_complete)" "Sprint completed: $fid"

  # a rename counts through its old path; a non-ASCII code path is named verbatim; a long change list still gets the full message
  fr_ticket rename; fr_report "$(git rev-parse HEAD)"
  git mv src/app.js dist/app.js; git commit -qm "move code into dist"
  out="$(run_fail env -u CLAUDECODE "$SPRINT" complete)"; assert_contains "$out" "src/app.js"
  git mv dist/app.js src/app.js; git commit -qm "move it back"
  fr_report "$(git rev-parse HEAD)"; printf 'q\n' > "é.js"; git add "é.js"; git commit -qm "non-ascii code"
  out="$(run_fail env -u CLAUDECODE "$SPRINT" complete)"; assert_contains "$out" "é.js"
  fr_report "$(git rev-parse HEAD)"; mkdir -p many
  for i in $(seq 1 500); do : > "many/file-$(printf '%0150d' "$i").js"; done
  git add many; git commit -qm "many files"
  out="$(run_fail env -u CLAUDECODE "$SPRINT" complete)"; assert_contains "$out" "tracked files changed after the evaluator graded"; assert_contains "$out" "500 file(s)"
)
rm -rf "$fr_project"

# t-1b74: the allow-list names the same hook-built artifacts as scripts/install-hooks.sh (they are a second copy of ARTIFACT_PATHS)
art_line="$(grep '^ARTIFACT_PATHS=' "$ROOT/scripts/install-hooks.sh")"
art_line="${art_line#ARTIFACT_PATHS=(}"; art_line="${art_line%)*}"
for art in $art_line; do
  sed 's/\\//g' "$ROOT/tools/sprint" | grep -qF "$art" || fail "tools/sprint's late-path list is missing the hook artifact $art (scripts/install-hooks.sh ARTIFACT_PATHS)"
done

# t-1b74: shared fixture for the repository-shape cases below
fr_gate_docs() { # <ticket dir> <jsonl file> <run-id> <graded-head>
  local t="$1"
  printf '# Plan\n## Sign-off\n- [x] Plan approved\n## Approach\ntest\n' > "$t/plan.md"
  printf '# Acceptance\n## Criteria\n- [x] item\n## Test Plan\n- [x] npm test\n## Wrapup Gates\n| Gate | Status | Reason |\n|------|--------|--------|\n| eval | ran | pass |\n' > ""$t/acceptance.md""
  printf '# Summary\n| Item | Status |\n|---|---|\n| done | delivered |\n' > "$t/summary.md"
  printf '{"ts":"%s","session_id":"s1","agent_id":"x","agent_type":"evaluator","transcript_path":""}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$2"
  printf '# Eval Report\nevaluator-run-id: %s\ngraded-head: %s\nModel: test-model\n## Verdict\npass: all criteria met\n' "$3" "$4" > "$t/eval-report.md"
}

# t-1b74: a sprint run from a linked worktree is graded against the worktree's own commits, not the main checkout's working tree
wt_main="$(make_project)"; wt_dir="$(mktemp -d)/wt"
(
  cd "$wt_main"; git config user.email t@example.com; git config user.name test
  mkdir -p src .claude; echo 'a' > src/app.js; git add -A >/dev/null && git commit -qm base
  git worktree add -q -b wtb "$wt_dir"
  cd "$wt_dir"; echo 'b' >> src/app.js; git add src/app.js; git commit -qm "work done in the worktree"
  out="$("$SPRINT" start "worktree stale eval")"; wid="$(printf '%s\n' "$out" | awk '/Sprint started:/ { print $3 }')"
  fr_gate_docs "$wt_main/.tickets/$wid" "$wt_main/.claude/subagent-runs.jsonl" "$(date +%s)-7000" "$(git rev-parse HEAD)"
  assert_contains "$(env -u CLAUDECODE "$SPRINT" complete 2>&1)" "Sprint completed: $wid"
)
rm -rf "$wt_main" "$(dirname "$wt_dir")"

# t-1b74: a project that is a subdirectory of a larger repository is graded on its own subtree only
sub_top="$(make_project)"
(
  cd "$sub_top"; git config user.email t@example.com; git config user.name test
  mkdir -p proj/src other proj/.tickets proj/.claude; echo 'a' > proj/src/app.js; echo 'a' > other/x.js; git add -A >/dev/null && git commit -qm base
  cd proj
  out="$("$SPRINT" start "subtree stale eval")"; sid="$(printf '%s\n' "$out" | awk '/Sprint started:/ { print $3 }')"
  fr_gate_docs ".tickets/$sid" ".claude/subagent-runs.jsonl" "$(date +%s)-7000" "$(git rev-parse HEAD)"
  echo 'b' >> ../other/x.js; git add ../other/x.js; git commit -qm "outside the project"
  assert_contains "$(env -u CLAUDECODE "$SPRINT" complete 2>&1)" "Sprint completed: $sid"
  out="$("$SPRINT" start "subtree stale eval 2")"; sid2="$(printf '%s\n' "$out" | awk '/Sprint started:/ { print $3 }')"
  fr_gate_docs ".tickets/$sid2" ".claude/subagent-runs.jsonl" "$(date +%s)-7000" "$(git rev-parse HEAD)"
  echo 'c' >> src/app.js; git add src/app.js; git commit -qm "inside the project"
  out="$(run_fail env -u CLAUDECODE "$SPRINT" complete)"; assert_contains "$out" "tracked files changed after the evaluator graded"; assert_contains "$out" "src/app.js"
)
rm -rf "$sub_top"

# t-1b74: a folder without git has nothing to compare, so the gate is skipped and a report without graded-head closes
ng_dir="$(mktemp -d)"
(
  cd "$ng_dir"; mkdir -p .claude
  out="$("$SPRINT" start "no git stale eval")"; nid="$(printf '%s\n' "$out" | awk '/Sprint started:/ { print $3 }')"
  fr_gate_docs ".tickets/$nid" ".claude/subagent-runs.jsonl" "$(date +%s)-7000" "ignored"
  sed -i.bak '/^graded-head:/d' ".tickets/$nid/eval-report.md" && rm -f ".tickets/$nid/eval-report.md.bak"
  assert_contains "$(env -u CLAUDECODE "$SPRINT" complete 2>&1)" "Sprint completed: $nid"
)
rm -rf "$ng_dir"
