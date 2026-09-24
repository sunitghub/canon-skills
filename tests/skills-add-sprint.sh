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

printf '# Claude\n' > "$project/CLAUDE.md"
printf '# Agents\n' > "$project/AGENTS.md"

"$SKILLS" add sprint "$project" >/dev/null

assert_dir_exists "$project/.tickets"
assert_file_exists "$project/CLAUDE.md"
assert_file_exists "$project/AGENTS.md"

# No @-imports written into project files
assert_count 0 "@$ROOT" "$project/CLAUDE.md"
assert_count 0 "@$ROOT" "$project/AGENTS.md"

# AI-SKILLS table written
assert_count 1 "| sprint | dev | $ROOT/skills/sprint/SKILL.md |" "$project/AGENTS.md"

# Symlinks created
[[ -L "$project/.claude/skills" ]] || fail "expected .claude/skills symlink after add"
[[ "$(readlink "$project/.claude/skills")" == "$ROOT/skills" ]] || fail ".claude/skills should point to $ROOT/skills"
[[ -L "$project/.agents/skills" ]] || fail "expected .agents/skills symlink after add"
[[ "$(readlink "$project/.agents/skills")" == "$ROOT/skills" ]] || fail ".agents/skills should point to $ROOT/skills"

# Re-add is idempotent
"$SKILLS" add sprint "$project" >/dev/null
assert_count 0 "@$ROOT" "$project/CLAUDE.md"
assert_count 1 "| sprint | dev | $ROOT/skills/sprint/SKILL.md |" "$project/AGENTS.md"
[[ -L "$project/.claude/skills" ]] || fail "expected .claude/skills symlink after re-add"
[[ "$(readlink "$project/.claude/skills")" == "$ROOT/skills" ]] || fail ".claude/skills stale after re-add"

status_output="$("$SKILLS" status "$project")"
assert_contains "$status_output" "sprint                    [ok]"

"$SKILLS" add context-check "$project" >/dev/null
assert_count 1 "| context-check | agent-ops | $ROOT/skills/context-check/SKILL.md |" "$project/AGENTS.md"
"$SKILLS" remove context-check "$project" >/dev/null
assert_count 0 "| context-check | agent-ops | $ROOT/skills/context-check/SKILL.md |" "$project/AGENTS.md"
assert_count 1 "| sprint | dev | $ROOT/skills/sprint/SKILL.md |" "$project/AGENTS.md"
[[ -L "$project/.claude/skills" ]] || fail "expected shared .claude/skills symlink to remain while sprint is registered"
[[ -L "$project/.agents/skills" ]] || fail "expected shared .agents/skills symlink to remain while sprint is registered"

set +e
addall_output="$("$SKILLS" addall "$project" 2>&1)"
addall_rc=$?
set -e
[[ "$addall_rc" -ne 0 ]] || fail "expected addall to fail"
assert_contains "$addall_output" "Usage: skills.sh <command> [skill] [project-dir]"

# Project registered in registry
projects_file="$tmp_home/.config/canon/projects"
assert_file_exists "$projects_file"
assert_count 1 "$project" "$projects_file"

# Re-add must not duplicate the registry entry
"$SKILLS" add sprint "$project" >/dev/null
assert_count 1 "$project" "$projects_file"

second_project="$(make_project)"
printf '# Claude\n' > "$second_project/CLAUDE.md"
printf '# Agents\n' > "$second_project/AGENTS.md"

"$SKILLS" add sprint "$second_project" >/dev/null
assert_count 1 "$project" "$projects_file"
assert_count 1 "$second_project" "$projects_file"
[[ -L "$second_project/.claude/skills" ]] || fail "expected .claude/skills symlink in second_project"
[[ -L "$second_project/.agents/skills" ]] || fail "expected .agents/skills symlink in second_project"

"$SKILLS" remove sprint "$project" >/dev/null
assert_count 0 "$project" "$projects_file"
assert_count 1 "$second_project" "$projects_file"
[[ ! -L "$project/.claude/skills" ]] || fail "expected .claude/skills symlink removed after deregister"
[[ ! -L "$project/.agents/skills" ]] || fail "expected .agents/skills symlink removed after deregister"
[[ -L "$second_project/.claude/skills" ]] || fail "second_project .claude/skills should remain"

"$SKILLS" remove sprint "$second_project" >/dev/null
[[ ! -f "$projects_file" ]] || fail "expected project registry to be removed after last project deregisters"
[[ ! -L "$second_project/.claude/skills" ]] || fail "expected .claude/skills symlink removed from second_project"
[[ ! -L "$second_project/.agents/skills" ]] || fail "expected .agents/skills symlink removed from second_project"

"$SKILLS" remove sprint "$second_project" >/dev/null
[[ ! -f "$projects_file" ]] || fail "expected missing project registry to remain absent"

# --- CLAUDE.md <-> AGENTS.md bridge (ensure_claude_bridge) ---

# Fresh project, no CLAUDE.md at all: add creates it with @AGENTS.md.
bridge_project="$(make_project)"
trap 'rm -rf "$project" "$tmp_home" "$second_project" "$bridge_project"' EXIT
"$SKILLS" add sprint "$bridge_project" >/dev/null
assert_file_exists "$bridge_project/CLAUDE.md"
assert_eq "@AGENTS.md" "$(cat "$bridge_project/CLAUDE.md")"

# Re-add is idempotent — no duplicate import, file unchanged.
"$SKILLS" add sprint "$bridge_project" >/dev/null
assert_count 1 "@AGENTS.md" "$bridge_project/CLAUDE.md"

# Existing CLAUDE.md that already has @AGENTS.md: byte-identical after add.
bridge_project2="$(make_project)"
trap 'rm -rf "$project" "$tmp_home" "$second_project" "$bridge_project" "$bridge_project2"' EXIT
printf '@AGENTS.md\n' > "$bridge_project2/CLAUDE.md"
before_hash="$(md5sum "$bridge_project2/CLAUDE.md" | cut -d' ' -f1)"
"$SKILLS" add sprint "$bridge_project2" >/dev/null
after_hash="$(md5sum "$bridge_project2/CLAUDE.md" | cut -d' ' -f1)"
assert_eq "$before_hash" "$after_hash"

# Non-interactive (test harness has no tty): existing CLAUDE.md without
# @AGENTS.md must be left untouched, no hang.
bridge_project3="$(make_project)"
trap 'rm -rf "$project" "$tmp_home" "$second_project" "$bridge_project" "$bridge_project2" "$bridge_project3"' EXIT
printf '# Custom instructions\n' > "$bridge_project3/CLAUDE.md"
"$SKILLS" add sprint "$bridge_project3" >/dev/null
assert_eq "$(printf '# Custom instructions\n')" "$(cat "$bridge_project3/CLAUDE.md")"

# Real interactive add (simulated tty via python3's pty.fork): answering y appends the import.
run_with_tty() {
  python3 - "$1" "$2" <<'PYEOF'
import os, pty, sys, time

cmd, answer = sys.argv[1], sys.argv[2]
pid, master = pty.fork()
if pid == 0:
    os.execvp("/bin/bash", ["/bin/bash", "-c", cmd])
else:
    time.sleep(0.5)
    os.write(master, (answer + "\n").encode())
    try:
        while True:
            if not os.read(master, 4096):
                break
    except OSError:
        pass
    os.waitpid(pid, 0)
PYEOF
}

bridge_project4="$(make_project)"
trap 'rm -rf "$project" "$tmp_home" "$second_project" "$bridge_project" "$bridge_project2" "$bridge_project3" "$bridge_project4"' EXIT
printf '# Custom instructions\n' > "$bridge_project4/CLAUDE.md"
run_with_tty "'$SKILLS' add sprint '$bridge_project4'" "y"
assert_count 1 "@AGENTS.md" "$bridge_project4/CLAUDE.md"
assert_contains "$(cat "$bridge_project4/CLAUDE.md")" "# Custom instructions"

# --- PROMOTED.md seeding (t-f65c) ---

promo="$(make_project)"
trap 'rm -rf "$project" "$tmp_home" "$second_project" "$bridge_project" "$bridge_project2" "$bridge_project3" "$bridge_project4" "$promo"' EXIT
printf "# Agents\n" > "$promo/AGENTS.md"
"$SKILLS" add sprint "$promo" >/dev/null
assert_file_exists "$promo/PROMOTED.md"
assert_count 1 "<!-- canon:promoted:BEGIN -->" "$promo/PROMOTED.md"
assert_count 1 "<!-- canon:promoted:END -->" "$promo/PROMOTED.md"
[ "$(grep -cxF "@PROMOTED.md" "$promo/AGENTS.md")" -eq 1 ] || fail "expected exactly one @PROMOTED.md line"
[[ ! -e "$promo/LEARNINGS.md" ]] || fail "add sprint must not seed LEARNINGS.md"

# Existing PROMOTED.md content is never overwritten; re-add and refresh stay idempotent.
printf -- '- keep me (t-0000)\n' >> "$promo/PROMOTED.md"
before_hash="$(md5sum "$promo/PROMOTED.md" | cut -d' ' -f1)"
"$SKILLS" add sprint "$promo" >/dev/null
"$SKILLS" refresh "$promo" >/dev/null 2>&1
assert_eq "$before_hash" "$(md5sum "$promo/PROMOTED.md" | cut -d' ' -f1)"
[ "$(grep -cxF "@PROMOTED.md" "$promo/AGENTS.md")" -eq 1 ] || fail "re-add/refresh duplicated @PROMOTED.md"

# A project that added sprint before t-f65c (no PROMOTED.md, no import) is upgraded by refresh.
rm "$promo/PROMOTED.md"
grep -vxF "@PROMOTED.md" "$promo/AGENTS.md" > "$promo/AGENTS.tmp" && mv "$promo/AGENTS.tmp" "$promo/AGENTS.md"
"$SKILLS" refresh "$promo" >/dev/null 2>&1
assert_file_exists "$promo/PROMOTED.md"
[ "$(grep -cxF "@PROMOTED.md" "$promo/AGENTS.md")" -eq 1 ] || fail "refresh did not add @PROMOTED.md"

# canon itself (project_dir == SKILLS_ROOT) is never seeded.
fake_canon="$(make_project)"
trap 'rm -rf "$project" "$tmp_home" "$second_project" "$bridge_project" "$bridge_project2" "$bridge_project3" "$bridge_project4" "$promo" "$fake_canon"' EXIT
printf '# Agents\n' > "$fake_canon/AGENTS.md"
SKILLS_ROOT="$fake_canon" bash -c 'source "$1"; ensure_promoted_learnings "$2"' _ "$ROOT/tools/skills/prompts.sh" "$fake_canon"
[[ ! -e "$fake_canon/PROMOTED.md" ]] || fail "canon's own root must not get PROMOTED.md"
[ "$(grep -cxF "@PROMOTED.md" "$fake_canon/AGENTS.md")" -eq 0 ] || fail "canon's own AGENTS.md must not import PROMOTED.md"

# AGENTS.md without a trailing newline: the import still lands on its own line. Called directly —
# via `add`, skills_table_upsert rewrites AGENTS.md first, so this shape never reaches the hook.
no_nl="$(make_project)"
trap 'rm -rf "$project" "$tmp_home" "$second_project" "$bridge_project" "$bridge_project2" "$bridge_project3" "$bridge_project4" "$promo" "$fake_canon" "$no_nl"' EXIT
printf '# Agents' > "$no_nl/AGENTS.md"
SKILLS_ROOT="$ROOT" bash -c 'source "$1"; ensure_promoted_learnings "$2"' _ "$ROOT/tools/skills/prompts.sh" "$no_nl" >/dev/null
[ "$(grep -cxF "# Agents" "$no_nl/AGENTS.md")" -eq 1 ] || fail "@PROMOTED.md glued onto AGENTS.md's last line"
[ "$(grep -cxF "@PROMOTED.md" "$no_nl/AGENTS.md")" -eq 1 ] || fail "expected @PROMOTED.md on its own line"

# A dangling PROMOTED.md symlink is never written through (would create a file outside the project).
dangle="$(make_project)"
trap 'rm -rf "$project" "$tmp_home" "$second_project" "$bridge_project" "$bridge_project2" "$bridge_project3" "$bridge_project4" "$promo" "$fake_canon" "$no_nl" "$dangle"' EXIT
printf '# Agents\n' > "$dangle/AGENTS.md"
ln -s "$dangle/outside/target.md" "$dangle/PROMOTED.md"
mkdir -p "$dangle/outside"
SKILLS_ROOT="$ROOT" bash -c 'source "$1"; ensure_promoted_learnings "$2"' _ "$ROOT/tools/skills/prompts.sh" "$dangle" >/dev/null
[[ ! -e "$dangle/outside/target.md" ]] || fail "wrote through a dangling PROMOTED.md symlink"

printf 'skills-add-sprint: ok\n'
