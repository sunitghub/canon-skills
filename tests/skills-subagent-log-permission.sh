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
use_fresh_board "$tmp_home/board"   # t-b62a: the settings rules are written by the board binary's helper

run_with_tty() {
  # $1: command string, $2: answer to feed on the simulated tty.
  # forkpty (not openpty+Popen) gives the child a real controlling terminal —
  # offer_subagent_log_permission/offer_remove_subagent_log_permission open /dev/tty
  # directly, which requires an actual controlling tty, not just piped stdin/stdout fds.
  # Echoes the child's captured tty output on our own stdout so callers can assert on it
  # (e.g. the "[fail]" message) via $(run_with_tty ...) — not just on file side effects.
  python3 - "$1" "$2" <<'PYEOF'
import os, pty, sys, time

cmd, answer = sys.argv[1], sys.argv[2]
pid, master = pty.fork()
if pid == 0:
    os.environ.pop("SKILLS_SH_NO_TTY", None)  # t-2d74: this child has a real (pseudo) terminal
    os.execvp("/bin/bash", ["/bin/bash", "-c", cmd])
else:
    # Answer every [y/N] prompt as it appears (t-5d4e: `skills.sh add sprint` asks up to three; a prompt left unanswered
    # waits out its 15 s auto-skip). The same answer for each: the assertions below read only the file each case names.
    chunks, seen = [], 0
    try:
        while True:
            chunk = os.read(master, 4096)
            if not chunk:
                break
            chunks.append(chunk)
            n = b"".join(chunks).count(b"[y/N]")
            while seen < n:
                os.write(master, (answer + "\n").encode()); seen += 1
    except OSError:
        pass
    os.waitpid(pid, 0)
    sys.stdout.buffer.write(b"".join(chunks))
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

output="$(run_with_tty "'$SKILLS' add sprint '$project4'" "y")"
after="$(cat "$project4/.claude/settings.json")"
assert_eq "$before" "$after"
assert_contains "$output" "[fail]"
assert_contains "$output" "not valid JSON"

# --- a Windows console ends the answer with \r: "y\r" must still mean yes ---

project5="$(make_project)"
trap 'rm -rf "$tmp_home" "$project" "$project_scope" "$project2" "$project3" "$project4" "$project5"' EXIT
run_with_tty "stty -icrnl; '$SKILLS' add sprint '$project5'" $'y\r'
assert_file_exists "$project5/.claude/settings.json"
assert_count 1 "$RULE" "$project5/.claude/settings.json"

# --- t-1ed8 (was t-5d4e's opt-in offer): add never asks about canon's skills folder or writes it; remove still cleans it up ---
# Prod path: `skills.sh add sprint` (a terminal, and the board's Project tab, which runs it with SKILLS_SH_ASSUME_YES=1 and whose
# launch terminal showed the question and waited 15 s) and `skills.sh remove sprint` for a project that accepted it on 0.36.0-0.36.2.
CANON_SKILLS_DIR="$(cd -P "$ROOT/skills" && pwd -P)"
LOCAL=".claude/settings.local.json"
p6="$(make_project)"; p7="$(make_project)"
trap 'rm -rf "$tmp_home" "$project" "$project_scope" "$project2" "$project3" "$project4" "$project5" "$p6" "$p7"' EXIT
no_grant() {   # no_grant <project> <output>: nothing written, nothing asked or printed about the folder
  [ ! -f "$1/$LOCAL" ] || ! grep -qF "$CANON_SKILLS_DIR" "$1/$LOCAL" || fail "add wrote canon's skills folder to $1/$LOCAL"
  case "$2" in *"canon's skills folder"*|*additionalDirectories*) fail "add still offers the skills-folder entry: $2";; esac
}
out="$("$SKILLS" add sprint "$p6" 2>&1)"; no_grant "$p6" "$out"                         # no terminal
out="$(SKILLS_SH_ASSUME_YES=1 "$SKILLS" add sprint "$p6" 2>&1)"; no_grant "$p6" "$out"   # the board's way
out="$(run_with_tty "'$SKILLS' add sprint '$p7'" "y")"; no_grant "$p7" "$out"            # a terminal answering yes to everything
# a project that accepted the entry on 0.36.x: remove asks first, no keeps it, yes takes only that entry
mkdir -p "$p7/.claude"
printf '{"permissions": {"allow": ["Bash(x:*)"], "additionalDirectories": ["%s"]}}\n' "$CANON_SKILLS_DIR" > "$p7/$LOCAL"
out="$(run_with_tty "'$SKILLS' remove sprint '$p7'" "n")"
assert_count 1 "$CANON_SKILLS_DIR" "$p7/$LOCAL"; assert_contains "$out" "Remove canon's skills folder"
run_with_tty "'$SKILLS' add sprint '$p7'" "n" >/dev/null
run_with_tty "'$SKILLS' remove sprint '$p7'" "y" >/dev/null
! grep -qF "$CANON_SKILLS_DIR" "$p7/$LOCAL" || fail "remove left the folder in $p7/$LOCAL"
assert_count 1 'Bash(x:*)' "$p7/$LOCAL"
printf '{"permissions": {"allow": ["Bash(x:*)"]}}\n' > "$p6/$LOCAL"     # a settings file without the entry
before="$(cat "$p6/$LOCAL")"
out="$(run_with_tty "'$SKILLS' remove sprint '$p6'" "y")"          # no question, nothing changed
case "$out" in *"Remove canon's skills folder"*) fail "remove asked about an entry the project does not have";; esac
assert_eq "$before" "$(cat "$p6/$LOCAL")"

printf 'skills-subagent-log-permission: ok\n'
