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


# --- t-6541: a project copied from elsewhere: its AGENTS.md row names a copy that is gone, .claude/skills is a real folder without
# sprint and .agents/skills is missing. status names every problem (never one tag over another) and the cause; --json is what
# the board's Projects card reads; refresh fixes all of it. Prod path: skills.sh status / status --json / refresh (the card's Refresh).
cp_proj="$(make_project)"
trap 'rm -rf "$project" "$tmp_home" "$inj" "$cp_proj"' EXIT
"$SKILLS" add sprint "$cp_proj" >/dev/null 2>&1
sed -i.bak 's#| skills/sprint/SKILL.md |#| /gone/canon/skills/sprint/SKILL.md |#' "$cp_proj/AGENTS.md" && rm -f "$cp_proj/AGENTS.md.bak"
grep -qF '/gone/canon/skills/sprint/SKILL.md' "$cp_proj/AGENTS.md" || fail "the test could not plant the stale row: $(grep -F sprint "$cp_proj/AGENTS.md")"
rm -rf "${cp_proj:?}/.claude/skills" "${cp_proj:?}/.agents/skills"; mkdir -p "$cp_proj/.claude/skills/other"
out="$("$SKILLS" status "$cp_proj")"
assert_contains "$out" "sprint                    [broken ref, stale path, missing link .claude/skills, missing link .agents/skills]"
assert_contains "$out" "this project was moved or copied, or canon was installed again"
assert_eq '{"skills":[{"name":"sprint","problems":["broken ref","stale path","missing link .claude/skills","missing link .agents/skills"]}],"issues":4}' "$("$SKILLS" status --json "$cp_proj")"
"$SKILLS" refresh "$cp_proj" >/dev/null 2>&1
assert_eq '{"skills":[{"name":"sprint","problems":[]}],"issues":0}' "$("$SKILLS" status --json "$cp_proj")"
assert_contains "$("$SKILLS" status "$cp_proj")" "sprint                    [ok]"
# review: a registered row that is not a skill folder (efficiency's standards/efficiency.md) has no links to check: it never shows
# a problem Refresh cannot clear
"$SKILLS" add efficiency "$cp_proj" >/dev/null 2>&1
grep -qF 'efficiency' "$cp_proj/AGENTS.md" || fail "the test could not register efficiency"
assert_eq "0" "$("$SKILLS" status --json "$cp_proj" | sed -E 's/.*"issues":([0-9]+).*/\1/')"
assert_contains "$("$SKILLS" status --json "$cp_proj")" '{"name":"efficiency","problems":[]}'
case "$("$SKILLS" status "$cp_proj")" in *"moved or copied"*) fail "a healthy project with efficiency printed the cause line";; esac

# --- t-38ab: a real folder where canon's link belongs (empty, or the copies Windows `ln` makes) is replaced by the link when it
# holds only what canon proved is its own; a project-local entry is never touched; refresh and status agree. Prod path: skills.sh
# refresh / add (what `canon update` runs on every registered project, and the Projects card's Refresh).
RF_DIRS=(/nonexistent-t38ab)
rf_proj() {   # rf_proj: sets RF_NEW to a registered project with sprint linked, then its skills and agents links removed for the case to rebuild
  RF_NEW="$(make_project)"; RF_DIRS+=("$RF_NEW")
  "$SKILLS" add sprint "$RF_NEW" >/dev/null 2>&1
  rm -rf "${RF_NEW:?}/.claude/skills" "${RF_NEW:?}/.agents/skills" "${RF_NEW:?}/.claude/agents"
}
trap 'rm -rf "$project" "$tmp_home" "$inj" "$cp_proj" "${RF_DIRS[@]}"' EXIT
is_link_to() { [[ -L "$1" && "$(readlink "$1")" == "$2" ]]; }
status_ok() { assert_eq '{"skills":[{"name":"sprint","problems":[]}],"issues":0}' "$("$SKILLS" status --json "$1")"; }

# 1. empty real folders become links; a second refresh changes nothing and says so
rf_proj; e1="$RF_NEW"; mkdir -p "$e1/.claude/skills" "$e1/.agents/skills"
"$SKILLS" refresh "$e1" >/dev/null 2>&1
is_link_to "$e1/.claude/skills" "$ROOT/skills" || fail "t-38ab: an empty .claude/skills was not replaced by a link"
is_link_to "$e1/.agents/skills" "$ROOT/skills" || fail "t-38ab: an empty .agents/skills was not replaced by a link"
status_ok "$e1"
"$SKILLS" refresh "$e1" >/dev/null 2>&1
export SKILLS_SH_ASSUME_YES=1   # the install-deny-rules offer is declined without a TTY, and its "[skip] ... not added" line counts as a refresh change
"$SKILLS" refresh "$e1" >/dev/null 2>&1   # settles every one-time change
assert_contains "$("$SKILLS" refresh "$e1" 2>&1)" "All up to date."

# 2. a real folder of byte-identical canon copies (the Windows `ln` copies) becomes a link
rf_proj; e2="$RF_NEW"; mkdir -p "$e2/.claude/skills" "$e2/.agents/skills"
cp -R "$ROOT/skills/sprint" "$e2/.claude/skills/sprint"; cp -R "$ROOT/skills/sprint" "$e2/.agents/skills/sprint"
"$SKILLS" refresh "$e2" >/dev/null 2>&1
is_link_to "$e2/.claude/skills" "$ROOT/skills" || fail "t-38ab: a folder of identical canon copies was not replaced by a link"
status_ok "$e2"

# 3. a project-local skill keeps the folder real and byte-identical; canon's skill in it serves reference/ too
rf_proj; e3="$RF_NEW"; mkdir -p "$e3/.claude/skills/mine"; printf 'MINE\n' > "$e3/.claude/skills/mine/SKILL.md"
"$SKILLS" refresh "$e3" >/dev/null 2>&1
[[ ! -L "$e3/.claude/skills" && -d "$e3/.claude/skills" ]] || fail "t-38ab: a folder with a project-local skill must stay a real folder"
assert_eq "MINE" "$(cat "$e3/.claude/skills/mine/SKILL.md")"
[[ -f "$e3/.claude/skills/sprint/reference/start-checklist.md" ]] || fail "t-38ab: sprint's reference/ is not served in the per-skill layout"
status_ok "$e3"

# 4. a stale copy that differs from canon's SKILL.md is left, named, and refresh does not claim all is well
rf_proj; e4="$RF_NEW"; mkdir -p "$e4/.claude/skills/mine" "$e4/.claude/skills/sprint"
printf 'MINE\n' > "$e4/.claude/skills/mine/SKILL.md"; printf 'OLD COPY\n' > "$e4/.claude/skills/sprint/SKILL.md"
"$SKILLS" refresh "$e4" >/dev/null 2>&1   # settles the one-time changes, so the next run is only about the folder
out4="$("$SKILLS" refresh "$e4" 2>&1)"
assert_eq "OLD COPY" "$(cat "$e4/.claude/skills/sprint/SKILL.md")"
assert_contains "$out4" "[needs attention]"
assert_contains "$out4" "stale link .claude/skills"
case "$out4" in *"All up to date."*) fail "t-38ab: refresh said All up to date while status reports a problem";; esac
assert_contains "$("$SKILLS" status "$e4")" "stale link .claude/skills"
assert_contains "$("$SKILLS" status "$e4")" "remove .claude/skills"

# 5. agents: empty or canon-only real folder -> link; a folder with a user's own file keeps it
rf_proj; e5="$RF_NEW"; mkdir -p "$e5/.claude/agents"
"$SKILLS" refresh "$e5" >/dev/null 2>&1
is_link_to "$e5/.claude/agents" "$ROOT/agents" || fail "t-38ab: an empty .claude/agents was not replaced by a link"
rf_proj; e6="$RF_NEW"; mkdir -p "$e6/.claude/agents"; cp "$ROOT"/agents/canon-*.md "$e6/.claude/agents/"
"$SKILLS" refresh "$e6" >/dev/null 2>&1
is_link_to "$e6/.claude/agents" "$ROOT/agents" || fail "t-38ab: a .claude/agents of canon-marked files was not replaced by a link"
rf_proj; e7="$RF_NEW"; mkdir -p "$e7/.claude/agents"; printf 'my own agent\n' > "$e7/.claude/agents/mine.md"
"$SKILLS" refresh "$e7" >/dev/null 2>&1
[[ ! -L "$e7/.claude/agents" && "$(cat "$e7/.claude/agents/mine.md")" == "my own agent" ]] || fail "t-38ab: a user's own agent file or its folder was touched"

# 6. nothing is removed or replaced through a planted link (t-f5e4's rule): .claude is a link to an outside folder holding an empty skills/
rf_proj; e8="$RF_NEW"; out8="$(mktemp -d)"; RF_DIRS+=("$out8"); rm -rf "$e8/.claude"; mkdir -p "$out8/skills"; ln -s "$out8" "$e8/.claude"
"$SKILLS" refresh "$e8" >/dev/null 2>&1 || true
[[ -d "$out8/skills" && ! -L "$out8/skills" ]] || fail "t-38ab: an empty skills/ behind a planted .claude link was replaced or removed"
[[ ! -e "$out8/agents" ]] || fail "t-38ab: a link was made behind a planted .claude link"

printf 'skills-refresh: ok\n'
