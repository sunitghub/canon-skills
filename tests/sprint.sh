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

second_start_output="$(run_fail "$SPRINT" start "Another sprint")"
assert_contains "$second_start_output" "Active sprint already exists:"

missing_output="$(run_fail "$SPRINT" complete)"
assert_contains "$missing_output" "Missing required sprint file: $project/.tickets/$id/acceptance.md"
assert_contains "$missing_output" "Missing required sprint file: $project/.tickets/$id/plan.md"

cat > ".tickets/$id/acceptance.md" <<'EOF'
# Acceptance

- [ ] Required item remains.
EOF
cat > ".tickets/$id/plan.md" <<'EOF'
# Plan
EOF

unchecked_output="$(run_fail "$SPRINT" complete)"
assert_contains "$unchecked_output" "Unchecked acceptance/test items remain:"
assert_contains "$unchecked_output" "- [ ] Required item remains."

cat > ".tickets/$id/acceptance.md" <<'EOF'
# Acceptance

- [x] Required item remains.
EOF

complete_output="$("$SPRINT" complete)"
assert_contains "$complete_output" "Sprint completed: $id"
assert_grep "^status: closed$" ".tickets/$id/ticket.md"
[[ ! -f .tickets/ACTIVE ]] || fail "expected ACTIVE to be cleared after sprint complete"
