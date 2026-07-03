#!/usr/bin/env bash

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

project="$(make_project)"
tmp_home="$(mktemp -d)"
trap 'rm -rf "$project" "$tmp_home"' EXIT

export HOME="$tmp_home"

printf '# Agents\n' > "$project/AGENTS.md"

# Non-interactive (test harness has no tty): prompt must be skipped, no write.
"$SKILLS" add efficiency "$project" >/dev/null
assert_count 0 "MODEL-TIERS:BEGIN" "$project/AGENTS.md"

# Re-add stays a no-op the same way.
"$SKILLS" add efficiency "$project" >/dev/null
assert_count 0 "MODEL-TIERS:BEGIN" "$project/AGENTS.md"

# If the note is already present (e.g. from a prior interactive Y), re-add
# must not duplicate it and must not prompt/hang.
cat "$ROOT/AGENTS.md" | awk '/<!-- MODEL-TIERS:BEGIN -->/{flag=1} flag; /<!-- MODEL-TIERS:END -->/{flag=0}' >> "$project/AGENTS.md"
assert_count 1 "MODEL-TIERS:BEGIN" "$project/AGENTS.md"

"$SKILLS" add efficiency "$project" >/dev/null
assert_count 1 "MODEL-TIERS:BEGIN" "$project/AGENTS.md"

# --- removal path ---

# Non-interactive remove (test harness has no tty): block stays untouched.
"$SKILLS" remove efficiency "$project" >/dev/null
assert_count 1 "MODEL-TIERS:BEGIN" "$project/AGENTS.md"

# Removing a different (also inject-type) skill never touches the block.
"$SKILLS" add agent-design "$project" >/dev/null
"$SKILLS" remove agent-design "$project" >/dev/null
assert_count 1 "MODEL-TIERS:BEGIN" "$project/AGENTS.md"

# Removing efficiency when the block is absent doesn't error.
project2="$(make_project)"
trap 'rm -rf "$project" "$tmp_home" "$project2"' EXIT
printf '# Agents\n' > "$project2/AGENTS.md"
"$SKILLS" add efficiency "$project2" >/dev/null
assert_count 0 "MODEL-TIERS:BEGIN" "$project2/AGENTS.md"
"$SKILLS" remove efficiency "$project2" >/dev/null
assert_count 0 "MODEL-TIERS:BEGIN" "$project2/AGENTS.md"

# --- real interactive round-trip (simulated tty via python3's pty, answering y) ---

run_with_tty() {
  # $1: command string, $2: answer to feed on the simulated tty.
  # Uses forkpty (not openpty+Popen) so the child gets a real controlling
  # terminal — offer_model_tiers_note/offer_remove_model_tiers_note open
  # /dev/tty directly, which requires an actual controlling tty, not just
  # piped stdin/stdout fds.
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

project3="$(make_project)"
trap 'rm -rf "$project" "$tmp_home" "$project2" "$project3"' EXIT
printf '# Agents\n' > "$project3/AGENTS.md"

# Real interactive add: answering y writes the block.
run_with_tty "'$SKILLS' add efficiency '$project3'" "y"
assert_count 1 "MODEL-TIERS:BEGIN" "$project3/AGENTS.md"

# Real interactive remove: answering y strips the block and leaves no orphaned blank line —
# the file must round-trip back to exactly its pre-add state.
run_with_tty "'$SKILLS' remove efficiency '$project3'" "y"
assert_count 0 "MODEL-TIERS:BEGIN" "$project3/AGENTS.md"
assert_eq "$(printf '# Agents\n')" "$(cat "$project3/AGENTS.md")"

printf 'skills-model-tiers-note: ok\n'
