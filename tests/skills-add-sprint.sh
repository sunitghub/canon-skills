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

printf 'skills-add-sprint: ok\n'
