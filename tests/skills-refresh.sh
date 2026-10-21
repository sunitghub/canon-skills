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

out="$("$SKILLS" refresh "$project" 2>&1)"
assert_contains "$out" "added the platforms line"   # t-5c4b: the block had none

# Legacy @-imports pruned
assert_count 0 "@$ROOT/standards/efficiency.md" "$project/CLAUDE.md"
assert_count 0 "@$ROOT/skills/sprint/SKILL.md" "$project/CLAUDE.md"
assert_count 0 "@$ROOT/standards/efficiency.md" "$project/AGENTS.md"
assert_count 0 "@$ROOT/skills/sprint/SKILL.md" "$project/AGENTS.md"

# User content preserved
assert_count 1 "User content." "$project/CLAUDE.md"
assert_count 1 "User AGENTS content." "$project/AGENTS.md"

# AI-SKILLS table still present, its old absolute row and "Source: <path>" note made portable once (t-97e2)
assert_count 1 "| sprint | dev | skills/sprint/SKILL.md |" "$project/AGENTS.md"
assert_count 0 "Source: $ROOT" "$project/AGENTS.md"
assert_count 1 "Paths are relative to the canon install." "$project/AGENTS.md"
# t-5c4b: an existing block gains the platforms line once, under its note (the cksum check below proves a second refresh adds none)
assert_count 1 "> Platforms: on Windows canon's commands run in Git Bash" "$project/AGENTS.md"
[[ "$(grep -A1 '^> Managed by `skills.sh`' "$project/AGENTS.md" | tail -1)" == "> Platforms:"* ]] || fail "the platforms line is not under the note"
sum_before="$(cksum < "$project/AGENTS.md")"
out="$("$SKILLS" refresh "$project" 2>&1)"
assert_eq "$sum_before" "$(cksum < "$project/AGENTS.md")"
[[ "$out" != *"added the platforms line"* ]] || fail "a refresh of a block that has the line claimed to add it"
# ...and an older wording of the line is replaced, never kept beside the new one
sed -i.bak 's/^> Platforms:.*/> Platforms: old wording./' "$project/AGENTS.md" && rm -f "$project/AGENTS.md.bak"
"$SKILLS" refresh "$project" >/dev/null
assert_count 0 "old wording" "$project/AGENTS.md"
assert_count 1 "> Platforms: on Windows canon's commands run in Git Bash" "$project/AGENTS.md"
# ...but a "> Platforms:" line of the user's own, outside the block, is kept
printf '\n> Platforms: user note.\n' >> "$project/AGENTS.md"
sed -i.bak 's/^> Platforms: on Windows.*/> Platforms: old wording./' "$project/AGENTS.md" && rm -f "$project/AGENTS.md.bak"
"$SKILLS" refresh "$project" >/dev/null
assert_count 1 "> Platforms: user note." "$project/AGENTS.md"
assert_count 1 "> Platforms: on Windows canon's commands run in Git Bash" "$project/AGENTS.md"
# ...and a block whose note line is gone still gains it once, inside the block (before its end)
sed -i.bak -e '/^> Managed by `skills.sh`/d' -e '/^> Platforms: on Windows/d' "$project/AGENTS.md" && rm -f "$project/AGENTS.md.bak"
"$SKILLS" refresh "$project" >/dev/null
assert_count 1 "> Platforms: on Windows canon's commands run in Git Bash" "$project/AGENTS.md"
[[ "$(sed -n '/<!-- AI-SKILLS:BEGIN -->/,/<!-- AI-SKILLS:END -->/p' "$project/AGENTS.md")" == *"> Platforms: on Windows"* ]] || fail "the platforms line landed outside the block"

# Symlinks created/repaired by refresh (via cmd_add)
[[ -L "$project/.claude/skills" ]] || fail "expected .claude/skills symlink after refresh"
[[ "$(readlink "$project/.claude/skills")" == "$ROOT/skills" ]] || fail ".claude/skills should point to $ROOT/skills"
[[ -L "$project/.agents/skills" ]] || fail "expected .agents/skills symlink after refresh"

status_output="$("$SKILLS" status "$project")"
assert_contains "$status_output" "sprint                    [ok]"

# --- registered inject skill's @-import is kept in place, not pruned and re-appended (t-bd3e) ---
inj="$(make_project)"
trap 'rm -rf "$project" "$tmp_home" "$inj"' EXIT
cat > "$inj/AGENTS.md" << AGENTSEOF
# Agents

<!-- AI-SKILLS:BEGIN -->
## Active canon skills
> Managed by \`skills.sh\` — use \`add\`/\`remove\` to change. Source: $ROOT

| Skill | Category | Source |
|-------|----------|--------|
| efficiency | agent-ops | $ROOT/standards/efficiency.md |
| sprint | dev | $ROOT/skills/sprint/SKILL.md |
<!-- AI-SKILLS:END -->
@$ROOT/standards/efficiency.md
User AGENTS content.
AGENTSEOF
line_before="$(grep -nxF "@$ROOT/standards/efficiency.md" "$inj/AGENTS.md" | cut -d: -f1)"
out="$("$SKILLS" refresh "$inj" 2>&1)"
[[ "$out" != *"legacy @-import: @$ROOT/standards/efficiency.md"* ]] || fail "registered efficiency import was pruned"
[ "$(grep -cxF "@$ROOT/standards/efficiency.md" "$inj/AGENTS.md")" -eq 1 ] || fail "efficiency import missing or duplicated"
# kept in place: still the line right after the block (t-5c4b's platforms line, added inside the block, shifts it down by one)
assert_eq "$((line_before + 1))" "$(grep -nxF "@$ROOT/standards/efficiency.md" "$inj/AGENTS.md" | cut -d: -f1)"
assert_eq "<!-- AI-SKILLS:END -->" "$(grep -B1 -xF "@$ROOT/standards/efficiency.md" "$inj/AGENTS.md" | head -1)"

# Same file with CRLF endings (Windows): the import is kept, not pruned, and neither it nor
# @PROMOTED.md is duplicated across two refreshes.
sed 's/$/\r/' "$inj/AGENTS.md" > "$inj/a.tmp" && mv "$inj/a.tmp" "$inj/AGENTS.md"
out="$("$SKILLS" refresh "$inj" 2>&1)"
[[ "$out" != *"legacy @-import: @$ROOT/standards/efficiency.md"* ]] || fail "CRLF: registered efficiency import was pruned"
"$SKILLS" refresh "$inj" >/dev/null 2>&1
[ "$(tr -d '\r' < "$inj/AGENTS.md" | grep -cxF "@$ROOT/standards/efficiency.md")" -eq 1 ] || fail "CRLF: efficiency import duplicated"
[ "$(tr -d '\r' < "$inj/AGENTS.md" | grep -cxF "@PROMOTED.md")" -eq 1 ] || fail "CRLF: @PROMOTED.md duplicated"
# t-5c4b: a CRLF block without the platforms line gains it once, CRLF-ended, and a second refresh neither changes nor claims it
sed -i.bak '/^> Platforms:/d' "$inj/AGENTS.md" && rm -f "$inj/AGENTS.md.bak"
out="$("$SKILLS" refresh "$inj" 2>&1)"
assert_contains "$out" "added the platforms line"
[ "$(grep -c $'^> Platforms: on Windows.*\r$' "$inj/AGENTS.md")" -eq 1 ] || fail "CRLF: the platforms line is missing, duplicated or not CRLF-ended"
sum_before="$(cksum < "$inj/AGENTS.md")"
out="$("$SKILLS" refresh "$inj" 2>&1)"
assert_eq "$sum_before" "$(cksum < "$inj/AGENTS.md")"
[[ "$out" != *"added the platforms line"* ]] || fail "CRLF: a refresh of a block that has the line claimed to add it"


printf 'skills-refresh: ok\n'
