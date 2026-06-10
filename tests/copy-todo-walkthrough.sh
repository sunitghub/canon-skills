#!/usr/bin/env bash
# copy-todo-walkthrough — script behavior tests

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

SCRIPT="$ROOT/scripts/copy-todo-walkthrough.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

target="$tmp/canon-todo-walkthrough"

output="$(bash "$SCRIPT" "$target")"
assert_dir_exists "$target"
assert_file_exists "$target/README.md"
assert_file_exists "$target/steps/02-sprint-start.md"
assert_dir_exists "$target/assets"
assert_contains "$output" "Copied Todo walkthrough to:"
assert_contains "$output" "$target"
assert_contains "$output" "skills.sh add sprint"

mkdir -p "$target/.tickets"
touch "$target/CLAUDE.md" "$target/AGENTS.md" "$target/HANDOFF.md" "$target/DECISIONS.md"

failed="$(run_fail bash "$SCRIPT" "$target")"
assert_contains "$failed" "Target already exists"
assert_dir_exists "$target/.tickets"
assert_file_exists "$target/CLAUDE.md"

bash "$SCRIPT" --force "$target" >/dev/null
assert_file_exists "$target/README.md"
[[ ! -e "$target/.tickets" ]] || fail "expected copied target to omit .tickets"
[[ ! -e "$target/CLAUDE.md" ]] || fail "expected copied target to omit CLAUDE.md"
[[ ! -e "$target/AGENTS.md" ]] || fail "expected copied target to omit AGENTS.md"
[[ ! -e "$target/HANDOFF.md" ]] || fail "expected copied target to omit HANDOFF.md"
[[ ! -e "$target/DECISIONS.md" ]] || fail "expected copied target to omit DECISIONS.md"

help="$(bash "$SCRIPT" --help)"
assert_contains "$help" "Usage:"

unsafe="$(run_fail bash "$SCRIPT" --force "$ROOT")"
assert_contains "$unsafe" "Refusing unsafe target"

printf 'copy-todo-walkthrough: ok\n'
