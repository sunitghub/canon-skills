#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

project="$(make_project)"
trap 'rm -rf "$project"' EXIT
cd "$project"

id="$("$TKT" create "Write tests" -t task -p 1 -d "Cover the ticket lifecycle")"

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

close_output="$("$TKT" close "$second_id")"
assert_contains "$close_output" "$second_id: closed"
[[ ! -f .tickets/ACTIVE ]] || fail "expected ACTIVE to be cleared after closing active ticket"
assert_grep "^status: closed$" ".tickets/$second_id/ticket.md"

missing_output="$(run_fail "$TKT" show does-not-exist)"
assert_contains "$missing_output" "Error: no ticket matching 'does-not-exist'"
