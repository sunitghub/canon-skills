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
  echo "@/stale/canon/skills/sprint/SKILL.md"
} > "$project/CLAUDE.md"

{
  echo "@/stale/canon/standards/efficiency.md"
  echo "@/stale/canon/skills/sprint/SKILL.md"
} > "$project/AGENTS.md"

"$SKILLS" add sprint "$project" >/dev/null

assert_dir_exists "$project/.tickets"
assert_file_exists "$project/CLAUDE.md"
assert_file_exists "$project/AGENTS.md"

assert_count 0 "@/stale/canon/standards/efficiency.md" "$project/CLAUDE.md"
assert_count 0 "@/stale/canon/skills/sprint/SKILL.md" "$project/CLAUDE.md"
assert_count 0 "@/stale/canon/standards/efficiency.md" "$project/AGENTS.md"
assert_count 0 "@/stale/canon/skills/sprint/SKILL.md" "$project/AGENTS.md"
assert_count 1 "@$ROOT/standards/efficiency.md" "$project/CLAUDE.md"
assert_count 1 "@$ROOT/skills/sprint/SKILL.md" "$project/CLAUDE.md"
assert_count 1 "@$ROOT/standards/efficiency.md" "$project/AGENTS.md"
assert_count 1 "@$ROOT/skills/sprint/SKILL.md" "$project/AGENTS.md"
assert_count 1 "| sprint | dev | $ROOT/skills/sprint/SKILL.md |" "$project/AGENTS.md"

"$SKILLS" add sprint "$project" >/dev/null

assert_count 1 "@$ROOT/standards/efficiency.md" "$project/CLAUDE.md"
assert_count 1 "@$ROOT/skills/sprint/SKILL.md" "$project/CLAUDE.md"
assert_count 1 "@$ROOT/standards/efficiency.md" "$project/AGENTS.md"
assert_count 1 "@$ROOT/skills/sprint/SKILL.md" "$project/AGENTS.md"
assert_count 1 "| sprint | dev | $ROOT/skills/sprint/SKILL.md |" "$project/AGENTS.md"

status_output="$("$SKILLS" status "$project")"
assert_contains "$status_output" "sprint                    [ok]"

# Project should be registered in the project registry
projects_file="$tmp_home/.config/canon/projects"
assert_file_exists "$projects_file"
assert_count 1 "$project" "$projects_file"

# Re-add must not duplicate the entry
"$SKILLS" add sprint "$project" >/dev/null
assert_count 1 "$project" "$projects_file"

second_project="$(make_project)"
printf '# Claude\n' > "$second_project/CLAUDE.md"
printf '# Agents\n' > "$second_project/AGENTS.md"

"$SKILLS" add sprint "$second_project" >/dev/null
assert_count 1 "$project" "$projects_file"
assert_count 1 "$second_project" "$projects_file"

"$SKILLS" remove sprint "$project" >/dev/null
assert_count 0 "$project" "$projects_file"
assert_count 1 "$second_project" "$projects_file"

"$SKILLS" remove sprint "$second_project" >/dev/null
[[ ! -f "$projects_file" ]] || fail "expected project registry to be removed after last project deregisters"

"$SKILLS" remove sprint "$second_project" >/dev/null
[[ ! -f "$projects_file" ]] || fail "expected missing project registry to remain absent"

printf 'skills-add-sprint: ok
'
