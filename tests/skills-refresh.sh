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

"$SKILLS" add sprint "$project" >/dev/null

stale_std="@/stale/canon/standards/efficiency.md"
stale_sprint="@/stale/canon/skills/sprint.md"

for f in "$project/CLAUDE.md" "$project/AGENTS.md"; do
  tmp="$(mktemp)"
  awk -v stale_std="$stale_std" -v stale_sprint="$stale_sprint" '
    /\/standards\/efficiency\.md$/ { print stale_std; next }
    /\/skills\/sprint\.md$/ { print stale_sprint; next }
    { print }
  ' "$f" > "$tmp" && mv "$tmp" "$f"
done

"$SKILLS" refresh "$project" >/dev/null

assert_count 0 "$stale_std" "$project/CLAUDE.md"
assert_count 0 "$stale_sprint" "$project/CLAUDE.md"
assert_count 0 "$stale_std" "$project/AGENTS.md"
assert_count 0 "$stale_sprint" "$project/AGENTS.md"

assert_count 1 "@$ROOT/standards/efficiency.md" "$project/CLAUDE.md"
assert_count 1 "@$ROOT/skills/sprint.md" "$project/CLAUDE.md"
assert_count 1 "@$ROOT/standards/efficiency.md" "$project/AGENTS.md"
assert_count 1 "@$ROOT/skills/sprint.md" "$project/AGENTS.md"

status_output="$("$SKILLS" status "$project")"
assert_contains "$status_output" "sprint                    [ok]"
