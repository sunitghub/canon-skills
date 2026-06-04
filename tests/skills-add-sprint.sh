#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

project="$(make_project)"
tmp_home="$(mktemp -d)"
trap 'rm -rf "$project" "$tmp_home"' EXIT

touch "$tmp_home/.zshrc"
export HOME="$tmp_home"
export SHELL="/bin/zsh"
export PATH="$TOOLS_DIR:$PATH"

{
  echo "@/stale/canon/standards/efficiency.md"
  echo "@/stale/canon/skills/sprint.md"
} > "$project/CLAUDE.md"

{
  echo "@/stale/canon/standards/efficiency.md"
  echo "@/stale/canon/skills/sprint.md"
} > "$project/AGENTS.md"

"$SKILLS" add sprint "$project" >/dev/null

assert_dir_exists "$project/.tickets"
assert_file_exists "$project/CLAUDE.md"
assert_file_exists "$project/AGENTS.md"

assert_count 0 "@/stale/canon/standards/efficiency.md" "$project/CLAUDE.md"
assert_count 0 "@/stale/canon/skills/sprint.md" "$project/CLAUDE.md"
assert_count 0 "@/stale/canon/standards/efficiency.md" "$project/AGENTS.md"
assert_count 0 "@/stale/canon/skills/sprint.md" "$project/AGENTS.md"
assert_count 1 "@$ROOT/standards/efficiency.md" "$project/CLAUDE.md"
assert_count 1 "@$ROOT/skills/sprint.md" "$project/CLAUDE.md"
assert_count 1 "@$ROOT/standards/efficiency.md" "$project/AGENTS.md"
assert_count 1 "@$ROOT/skills/sprint.md" "$project/AGENTS.md"
assert_count 1 "| sprint | dev | $ROOT/skills/sprint.md |" "$project/AGENTS.md"

"$SKILLS" add sprint "$project" >/dev/null

assert_count 1 "@$ROOT/standards/efficiency.md" "$project/CLAUDE.md"
assert_count 1 "@$ROOT/skills/sprint.md" "$project/CLAUDE.md"
assert_count 1 "@$ROOT/standards/efficiency.md" "$project/AGENTS.md"
assert_count 1 "@$ROOT/skills/sprint.md" "$project/AGENTS.md"
assert_count 1 "| sprint | dev | $ROOT/skills/sprint.md |" "$project/AGENTS.md"

status_output="$("$SKILLS" status "$project")"
assert_contains "$status_output" "sprint                    [ok]"
