#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

RULE='Bash(subagent-log.sh:*)'

# Sandbox HOME (offer_tkt_path would otherwise touch the real ~/.zshrc/.bashrc) and put
# canon's tools on PATH so offer_tkt_path's own prompt never fires — each interactive
# registration below must produce exactly one prompt (ours) to consume the simulated "y".
tmp_home="$(mktemp -d)"
export HOME="$tmp_home"
export PATH="$PATH:$TOOLS_DIR"
trap 'rm -rf "$tmp_home"' EXIT

run_with_tty() {
  # $1: command string, $2: answer to feed on the simulated tty.
  # forkpty (not openpty+Popen) gives the child a real controlling terminal —
  # offer_subagent_log_permission/offer_remove_subagent_log_permission open /dev/tty
  # directly, which requires an actual controlling tty, not just piped stdin/stdout fds.
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

# --- non-interactive (test harness has no tty): no write, no hang ---

project="$(make_project)"
trap 'rm -rf "$tmp_home" "$project"' EXIT
"$SKILLS" add sprint "$project" >/dev/null
[ ! -f "$project/.claude/settings.json" ] || assert_count 0 "$RULE" "$project/.claude/settings.json"

# Re-add stays a no-op the same way.
"$SKILLS" add sprint "$project" >/dev/null
[ ! -f "$project/.claude/settings.json" ] || assert_count 0 "$RULE" "$project/.claude/settings.json"

# --- scope isolation: an unrelated skill never triggers this offer ---

project_scope="$(make_project)"
trap 'rm -rf "$tmp_home" "$project" "$project_scope"' EXIT
printf '# Agents\n' > "$project_scope/AGENTS.md"
"$SKILLS" add efficiency "$project_scope" >/dev/null
[ ! -f "$project_scope/.claude/settings.json" ] || assert_count 0 "$RULE" "$project_scope/.claude/settings.json"

# --- real interactive round-trip: add ---

project2="$(make_project)"
trap 'rm -rf "$tmp_home" "$project" "$project_scope" "$project2"' EXIT

run_with_tty "'$SKILLS' add sprint '$project2'" "y"
assert_file_exists "$project2/.claude/settings.json"
assert_count 1 "$RULE" "$project2/.claude/settings.json"

# Re-running interactively when already present must not duplicate or re-prompt/hang.
run_with_tty "'$SKILLS' add sprint '$project2'" "y"
assert_count 1 "$RULE" "$project2/.claude/settings.json"

# --- real interactive round-trip: remove ---

run_with_tty "'$SKILLS' remove sprint '$project2'" "y"
[ ! -f "$project2/.claude/settings.json" ] || assert_count 0 "$RULE" "$project2/.claude/settings.json"

# --- pre-existing unrelated content survives byte-identical apart from the new rule ---

project3="$(make_project)"
trap 'rm -rf "$tmp_home" "$project" "$project_scope" "$project2" "$project3"' EXIT
mkdir -p "$project3/.claude"
cat > "$project3/.claude/settings.json" <<'JSON'
{
  "model": "opus",
  "permissions": {
    "defaultMode": "auto",
    "allow": [
      "Bash(git status:*)"
    ]
  }
}
JSON

run_with_tty "'$SKILLS' add sprint '$project3'" "y"
assert_grep '"model": "opus"' "$project3/.claude/settings.json"
assert_grep '"defaultMode": "auto"' "$project3/.claude/settings.json"
assert_grep 'Bash\(git status:\*\)' "$project3/.claude/settings.json"
assert_count 1 "$RULE" "$project3/.claude/settings.json"

run_with_tty "'$SKILLS' remove sprint '$project3'" "y"
assert_grep '"model": "opus"' "$project3/.claude/settings.json"
assert_grep '"defaultMode": "auto"' "$project3/.claude/settings.json"
assert_grep 'Bash\(git status:\*\)' "$project3/.claude/settings.json"
assert_count 0 "$RULE" "$project3/.claude/settings.json"

# --- malformed JSON aborts the write, file left untouched ---

project4="$(make_project)"
trap 'rm -rf "$tmp_home" "$project" "$project_scope" "$project2" "$project3" "$project4"' EXIT
mkdir -p "$project4/.claude"
printf '{ not valid json' > "$project4/.claude/settings.json"
before="$(cat "$project4/.claude/settings.json")"

run_with_tty "'$SKILLS' add sprint '$project4'" "y"
after="$(cat "$project4/.claude/settings.json")"
assert_eq "$before" "$after"

printf 'skills-subagent-log-permission: ok\n'
