#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

project="$(make_project)"
trap 'rm -rf "$project"' EXIT
cd "$project"

id="$("$TKT" create "Write tests" -t task -p 1 -d "Cover the ticket lifecycle")"

[[ "$id" =~ ^t-[a-f0-9]{4}$ ]] || fail "expected ticket ID to be four hex chars, got: $id"
assert_dir_exists ".tickets/$id"
assert_file_exists ".tickets/$id/ticket.md"
assert_grep "^id: $id$" ".tickets/$id/ticket.md"
assert_grep "^status: open$" ".tickets/$id/ticket.md"
assert_grep "^type: task$" ".tickets/$id/ticket.md"
assert_grep "^priority: 1$" ".tickets/$id/ticket.md"
assert_grep "^# Write tests$" ".tickets/$id/ticket.md"

start_output="$("$TKT" start "$id")"
assert_contains "$start_output" "$id: in_progress"
assert_eq "$id" "$(tr -d '[:space:]' < .tickets/ACTIVE)"
assert_grep "^status: in_progress$" ".tickets/$id/ticket.md"

current_output="$("$TKT" current)"
assert_contains "$current_output" "$id  in_progress  Write tests"

second_id="$("$TKT" create "Second ticket")"
"$TKT" start "$second_id" >/dev/null
assert_eq "$second_id" "$(tr -d '[:space:]' < .tickets/ACTIVE)"
assert_grep "^status: in_progress$" ".tickets/$second_id/ticket.md"

no_flag_output="$(run_fail "$TKT" close "$second_id")"
assert_contains "$no_flag_output" "has no sprint docs"
assert_contains "$no_flag_output" "--no-sprint"
assert_grep "^status: in_progress$" ".tickets/$second_id/ticket.md"

close_output="$("$TKT" close "$second_id" --no-sprint)"
assert_contains "$close_output" "$second_id: closed"
[[ ! -f .tickets/ACTIVE ]] || fail "expected ACTIVE to be cleared after closing active ticket"
assert_grep "^status: closed$" ".tickets/$second_id/ticket.md"

# t-dec8: a CLI close writes a `closed:` marker (the pre-commit hook keys off a co-added
# `closed:` line to tell a legit CLI close from a hand-edited status), and reopen removes it.
assert_grep "^closed: " ".tickets/$second_id/ticket.md"
"$TKT" reopen "$second_id" >/dev/null
assert_grep "^status: open$" ".tickets/$second_id/ticket.md"
grep -qE "^closed: " ".tickets/$second_id/ticket.md" && fail "expected reopen to remove the closed: marker" || true

# A ticket with sprint docs refuses close without --no-sprint, pointing to sprint complete
sprint_id="$("$TKT" create "Ticket with sprint docs")"
mkdir -p ".tickets/$sprint_id"
: > ".tickets/$sprint_id/acceptance.md"
: > ".tickets/$sprint_id/plan.md"
sprint_docs_output="$(run_fail "$TKT" close "$sprint_id")"
assert_contains "$sprint_docs_output" "has sprint docs"
assert_contains "$sprint_docs_output" "sprint complete"
assert_grep "^status: open$" ".tickets/$sprint_id/ticket.md"

force_close_output="$("$TKT" close "$sprint_id" --no-sprint)"
assert_contains "$force_close_output" "$sprint_id: closed"
assert_grep "^status: closed$" ".tickets/$sprint_id/ticket.md"

"$TKT" start "$id" >/dev/null
assert_eq "$id" "$(tr -d '[:space:]' < .tickets/ACTIVE)"
reopen_output="$("$TKT" reopen "$id")"
assert_contains "$reopen_output" "$id: open"
[[ ! -f .tickets/ACTIVE ]] || fail "expected ACTIVE to be cleared after reopening the active ticket"
assert_grep "^status: open$" ".tickets/$id/ticket.md"

missing_output="$(run_fail "$TKT" show does-not-exist)"
assert_contains "$missing_output" "Error: no ticket matching 'does-not-exist'"

mkdir -p nested/deeper
(
  cd nested/deeper
  nested_id="$("$TKT" create "Nested ticket")"
  [[ -f "../../.tickets/$nested_id/ticket.md" ]] || fail "expected nested create to use project .tickets"
)

# ── tkt gate (t-4e57): eval sets the line, full removes it, no-arg prints, bad errors ─
gate_id="$("$TKT" create "Gate mode ticket")"
assert_contains "$("$TKT" gate "$gate_id")" "$gate_id: gate=full"
assert_contains "$("$TKT" gate "$gate_id" eval)" "$gate_id: gate=eval"
assert_grep "^gate: eval$" ".tickets/$gate_id/ticket.md"
assert_contains "$("$TKT" gate "$gate_id")" "$gate_id: gate=eval"
"$TKT" gate "$gate_id" full >/dev/null
grep -q "^gate:" ".tickets/$gate_id/ticket.md" && fail "expected 'gate:' line removed after 'gate full'" || true
assert_contains "$("$TKT" gate "$gate_id")" "$gate_id: gate=full"
bad_gate_output="$(run_fail "$TKT" gate "$gate_id" bogus)"
assert_contains "$bad_gate_output" "must be 'eval' or 'full'"

# ── tkt demo (t-dfaa): on sets demo: true, off removes it, no-arg prints, bad errors ─
demo_id="$("$TKT" create "Demo mode ticket")"
grep -q "^demo:" ".tickets/$demo_id/ticket.md" && fail "expected no 'demo:' line on a fresh ticket" || true
assert_contains "$("$TKT" demo "$demo_id")" "$demo_id: demo=false"
assert_contains "$("$TKT" demo "$demo_id" on)" "$demo_id: demo=true"
assert_grep "^demo: true$" ".tickets/$demo_id/ticket.md"
assert_contains "$("$TKT" demo "$demo_id")" "$demo_id: demo=true"
"$TKT" demo "$demo_id" off >/dev/null
grep -q "^demo:" ".tickets/$demo_id/ticket.md" && fail "expected 'demo:' line removed after 'demo off'" || true
assert_contains "$("$TKT" demo "$demo_id")" "$demo_id: demo=false"
bad_demo_output="$(run_fail "$TKT" demo "$demo_id" bogus)"
assert_contains "$bad_demo_output" "must be 'on' or 'off'"
demo_usage_output="$(run_fail "$TKT" demo)"
assert_contains "$demo_usage_output" "Usage: tkt demo <id> [on|off]"
