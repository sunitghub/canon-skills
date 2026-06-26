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

# eval-report.md with pass: verdict and run-id — gate should pass
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

complete_output="$("$SPRINT" complete)"
assert_contains "$complete_output" "Sprint completed: $id"
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
[[ -f .tickets/ACTIVE ]] && "$TKT" close "$(cat .tickets/ACTIVE)" >/dev/null

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
"$TKT" close "$existing_id" >/dev/null   # clear ACTIVE without needing acceptance sign-off

# partial ID resolution
partial_ticket_id="$("$TKT" create "partial id test ticket" -t task -p 3)"
partial="${partial_ticket_id#t-}"
partial="${partial:0:3}"
partial_output="$("$SPRINT" start "$partial")"
assert_contains "$partial_output" "Sprint started: $partial_ticket_id"
"$TKT" close "$partial_ticket_id" >/dev/null
