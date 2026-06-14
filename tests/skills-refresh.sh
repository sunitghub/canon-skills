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

# Simulate a pre-t-3832 project: AI-SKILLS table + legacy @-imports in CLAUDE.md/AGENTS.md
cat > "$project/CLAUDE.md" << EOF
@$ROOT/standards/efficiency.md
@$ROOT/skills/sprint/SKILL.md
User content.
EOF

cat > "$project/AGENTS.md" << EOF
@$ROOT/standards/efficiency.md
@$ROOT/skills/sprint/SKILL.md

<!-- AI-SKILLS:BEGIN -->
## Active canon skills
> Managed by \`skills.sh\` — use \`add\`/\`remove\` to change. Source: $ROOT

| Skill | Category | Source |
|-------|----------|--------|
| sprint | dev | $ROOT/skills/sprint/SKILL.md |
<!-- AI-SKILLS:END -->
User AGENTS content.
EOF

# Register the project so refresh has a registry entry
mkdir -p "$tmp_home/.config/canon"
printf '%s\n' "$project" > "$tmp_home/.config/canon/projects"

"$SKILLS" refresh "$project" >/dev/null

# Legacy @-imports pruned
assert_count 0 "@$ROOT/standards/efficiency.md" "$project/CLAUDE.md"
assert_count 0 "@$ROOT/skills/sprint/SKILL.md" "$project/CLAUDE.md"
assert_count 0 "@$ROOT/standards/efficiency.md" "$project/AGENTS.md"
assert_count 0 "@$ROOT/skills/sprint/SKILL.md" "$project/AGENTS.md"

# User content preserved
assert_count 1 "User content." "$project/CLAUDE.md"
assert_count 1 "User AGENTS content." "$project/AGENTS.md"

# AI-SKILLS table still present
assert_count 1 "| sprint | dev | $ROOT/skills/sprint/SKILL.md |" "$project/AGENTS.md"

# Symlinks created/repaired by refresh (via cmd_add)
[[ -L "$project/.claude/skills" ]] || fail "expected .claude/skills symlink after refresh"
[[ "$(readlink "$project/.claude/skills")" == "$ROOT/skills" ]] || fail ".claude/skills should point to $ROOT/skills"
[[ -L "$project/.agents/skills" ]] || fail "expected .agents/skills symlink after refresh"

status_output="$("$SKILLS" status "$project")"
assert_contains "$status_output" "sprint                    [ok]"

printf 'skills-refresh: ok\n'
