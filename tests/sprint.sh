#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

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
| reviewer | ran | reviewed gate logic |
| simplifier | skipped | test-only change |
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
| reviewer | ran |  |
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
| reviewer | ran | — |
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
| simplifier | skipped | docs-only change |
| security | skipped | no auth patterns |
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
| reviewer | ran | reviewed tools/sprint gate logic |
| simplifier | skipped | no code touched |
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

# Mockup-embed gate — a bare/backticked mockup filename with no real image
# embed anywhere in plan.md must block close, naming the offending path —
# regression for t-f149 (rendered as plain text on the board, not caught
# until a real workshop-prep ticket shipped it).
cat >> ".tickets/$id/plan.md" <<'EOF'

## Decisions
- Option A (`mockups/option-a.png`): some text, no real embed anywhere.
EOF

bad_mockup_output="$(run_fail "$SPRINT" complete)"
assert_contains "$bad_mockup_output" "has a broken mockup reference"
assert_contains "$bad_mockup_output" "option-a.png"
assert_contains "$bad_mockup_output" "never embedded as a real image"

# t-215f — a bare filename mention with no "mockups/" prefix at all (reported live
# from a Windows workshop: a manually-created ticket referenced two mockups by bare
# filename, and the original mockups/-prefix-only regex never caught it).
sed -i.bak 's/`mockups\/option-a\.png`/`Mockup-1.jpg`/' ".tickets/$id/plan.md" && rm -f ".tickets/$id/plan.md.bak"
bare_mockup_output="$(run_fail "$SPRINT" complete)"
assert_contains "$bare_mockup_output" "has a broken mockup reference"
assert_contains "$bare_mockup_output" "Mockup-1.jpg"
assert_contains "$bare_mockup_output" "never embedded as a real image"

# Add a real embed for the bare mention, but do NOT create the file on disk —
# t-215f's second gap: a syntactically-correct embed whose target was never actually
# copied to mockups/ must also block, with a distinct message, not silently pass.
cat >> ".tickets/$id/plan.md" <<'EOF'

![Mockup 1](mockups/Mockup-1.jpg)
EOF
missing_file_output="$(run_fail "$SPRINT" complete)"
assert_contains "$missing_file_output" "has a broken mockup reference"
assert_contains "$missing_file_output" "doesn't exist on disk"

# Actually copy the file to mockups/ — gate passes, eval gate fires next
mkdir -p ".tickets/$id/mockups"
printf '\x89PNG\r\n\x1a\n' > ".tickets/$id/mockups/Mockup-1.jpg"

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
| reviewer | ran | reviewed tools/sprint gate logic |
| simplifier | skipped | test-only change |
EOF

# eval-report.md gate — missing report should block
missing_eval_output="$(run_fail "$SPRINT" complete)"
assert_contains "$missing_eval_output" "eval-report.md is missing"

# eval-report.md with non-pass verdict should block
cat > ".tickets/$id/eval-report.md" <<'EOF'
# Eval Report
evaluator-run-id: 1000000000-12345
## Verdict
fail: criterion 1 not met
EOF
fail_eval_output="$(run_fail "$SPRINT" complete)"
assert_contains "$fail_eval_output" "eval-report.md verdict is not pass"

# eval-report.md missing evaluator-run-id should block
cat > ".tickets/$id/eval-report.md" <<'EOF'
# Eval Report
## Verdict
pass: all criteria met
EOF
missing_runid_output="$(run_fail "$SPRINT" complete)"
assert_contains "$missing_runid_output" "missing evaluator-run-id"

# JSONL present, no matching entry within ±60 min → should block
# run-id epoch = 1000000000 (2001-09-09T01:46:40Z); entry is 2h before = out of window
mkdir -p .claude
cat > ".claude/subagent-runs.jsonl" <<'EOF'
{"ts":"2001-09-08T23:46:40Z","session_id":"s1","agent_id":"agent-old","agent_type":"general-purpose","transcript_path":"/tmp/old.jsonl"}
EOF
cat > ".tickets/$id/eval-report.md" <<'EOF'
# Eval Report
evaluator-run-id: 1000000000-99999
## Criteria
| Criterion | Status | Evidence |
|---|---|---|
| Required item remains | pass | acceptance.md:4 |
## Verdict
pass: all criteria met
EOF
jsonl_nomatch_output="$(run_fail "$SPRINT" complete)"
assert_contains "$jsonl_nomatch_output" "no matching subagent entry"

# JSONL present, matching entry within ±60 min → should pass
# entry ts 30 min after run epoch (2001-09-09T02:16:40Z) = within window
cat > ".claude/subagent-runs.jsonl" <<'EOF'
{"ts":"2001-09-09T02:16:40Z","session_id":"s1","agent_id":"agent-real","agent_type":"general-purpose","transcript_path":"/tmp/eval.jsonl"}
EOF
match_output="$("$SPRINT" complete 2>&1 || true)"
[[ "$match_output" == *"no matching subagent entry"* ]] && fail "matching JSONL entry should not block close: $match_output"
# Sprint closed — start a fresh one to test JSONL-absent success path

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
## Verdict
pass: all criteria met
EOF
rm -f .claude/subagent-runs.jsonl
complete_output="$("$SPRINT" complete)"
assert_contains "$complete_output" "Sprint completed: $fresh_id"
assert_grep "^status: closed$" ".tickets/$fresh_id/ticket.md"
assert_grep "^status: closed$" ".tickets/$id/ticket.md"
[[ ! -f .tickets/ACTIVE ]] || fail "expected ACTIVE to be cleared after sprint complete"

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
