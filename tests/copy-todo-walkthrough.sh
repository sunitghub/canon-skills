#!/usr/bin/env bash
# copy-todo-walkthrough — script behavior tests

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

SCRIPT="$ROOT/scripts/copy-todo-walkthrough.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

target="$tmp/canon-todo-walkthrough"

# Exact non-existent path: created directly
output="$(bash "$SCRIPT" "$target")"
assert_dir_exists "$target"
assert_file_exists "$target/README.md"
assert_file_exists "$target/steps/02-sprint-start.md"
assert_dir_exists "$target/assets"
assert_contains "$output" "Copied Todo walkthrough to:"
assert_contains "$output" "$target"
assert_contains "$output" "skills.sh add sprint"

# Existing directory: copy INTO it (cp -R semantics); inner destination already exists → fail without --force
mkdir -p "$target/.tickets"
touch "$target/CLAUDE.md" "$target/AGENTS.md" "$target/HANDOFF.md" "$target/DECISIONS.md"

failed="$(run_fail bash "$SCRIPT" "$(dirname "$target")")"
assert_contains "$failed" "Target already exists"
assert_dir_exists "$target/.tickets"
assert_file_exists "$target/CLAUDE.md"

bash "$SCRIPT" --force "$(dirname "$target")" >/dev/null
assert_file_exists "$target/README.md"
[[ ! -e "$target/.tickets" ]] || fail "expected copied target to omit .tickets"
[[ ! -e "$target/CLAUDE.md" ]] || fail "expected copied target to omit CLAUDE.md"
[[ ! -e "$target/AGENTS.md" ]] || fail "expected copied target to omit AGENTS.md"
[[ ! -e "$target/HANDOFF.md" ]] || fail "expected copied target to omit HANDOFF.md"
[[ ! -e "$target/DECISIONS.md" ]] || fail "expected copied target to omit DECISIONS.md"

# Fresh parent dir: copy into it when destination doesn't yet exist
parent="$tmp/parent"
mkdir -p "$parent"
bash "$SCRIPT" "$parent" >/dev/null
assert_dir_exists "$parent/canon-todo-walkthrough"
assert_file_exists "$parent/canon-todo-walkthrough/README.md"

help="$(bash "$SCRIPT" --help)"
assert_contains "$help" "Usage:"

unsafe="$(run_fail bash "$SCRIPT" --force "$ROOT")"
assert_contains "$unsafe" "Refusing unsafe target"

printf 'copy-todo-walkthrough: ok\n'
