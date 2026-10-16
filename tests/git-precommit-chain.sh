#!/usr/bin/env bash
# t-2194: skills.sh add chains an existing foreign pre-commit hook (moved to pre-commit.local) instead of
# refusing. Scratch repos only — never touches a real .git/hooks.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

tmp_home="$(mktemp -d)"
export HOME="$tmp_home"
export PATH="$TOOLS_DIR:$PATH"   # first, so an installed canon on PATH never runs instead of this tree
trap 'rm -rf "$tmp_home" "${projects[@]:-}"' EXIT
projects=()

# run_with_tty <command> <answer> — as tests/skills-subagent-log-permission.sh: a real controlling tty.
run_with_tty() {
  python3 - "$1" "$2" <<'PYEOF'
import os, pty, sys, time
cmd, answer = sys.argv[1], sys.argv[2]
pid, master = pty.fork()
if pid == 0:
    os.environ.pop("SKILLS_SH_NO_TTY", None)
    os.execvp("/bin/bash", ["/bin/bash", "-c", cmd])
else:
    time.sleep(0.5)
    for _ in range(6):
        os.write(master, (answer + "\n").encode())  # one per prompt: add also asks about permission/deny rules
    chunks = []
    try:
        while True:
            chunk = os.read(master, 4096)
            if not chunk:
                break
            chunks.append(chunk)
    except OSError:
        pass
    os.waitpid(pid, 0)
    sys.stdout.buffer.write(b"".join(chunks))
PYEOF
}

# new_project — scratch repo with a foreign pre-commit hook; $FOREIGN_RC is its exit code (file-driven).
new_project() {
  local dir
  dir="$(make_project)"
  projects+=("$dir")
  mkdir -p "$dir/.git/hooks"
  printf '#!/bin/sh\necho "foreign ran: $* pwd=$(pwd)" >> "$(git rev-parse --git-dir)/foreign.log"\nexit "$(cat "$(git rev-parse --git-dir)/foreign.rc" 2>/dev/null || echo 0)"\n' > "$dir/.git/hooks/pre-commit"
  chmod 755 "$dir/.git/hooks/pre-commit"
  printf '%s\n' "$dir"
}

try_commit() {  # <project> — stage a new file and commit; echoes nothing, returns git's status
  ( cd "$1" && echo x >> f.txt && git add f.txt && git -c user.email=t@t.com -c user.name=t commit -q -m c >/dev/null 2>&1 )
}

# ── no terminal: refuse, byte-identical, printed command works ───────────────
p="$(new_project)"
orig="$(cksum < "$p/.git/hooks/pre-commit")"
set +e
out="$("$SKILLS" add sprint "$p" 2>&1)"
set -e
assert_contains "$out" "already exists and is not canon-managed"
assert_eq "$orig" "$(cksum < "$p/.git/hooks/pre-commit")"
[[ ! -e "$p/.git/hooks/pre-commit.local" ]] || fail "no-tty refusal must not create pre-commit.local"
# The refusal is a failure status (add itself swallows it, so ask the function).
set +e
SKILLS_SH_NO_TTY=1 bash -c 'SKILLS_ROOT="$1"; source "$1/tools/skills/prompts.sh"; source "$1/tools/hooks-lib.sh"; _init_git_precommit "$2"' _ "$ROOT" "$p" >/dev/null 2>&1
rc=$?
set -e
assert_eq "1" "$rc"
cmd="$(printf '%s\n' "$out" | grep -E '^ +mv .* && skills\.sh refresh ' | sed -E 's/^ +//')"
[[ -n "$cmd" ]] || fail "refusal must print the mv && skills.sh refresh command; got: $out"

# Run exactly the printed command (no prompt): canon's hook installed, foreign hook chained.
bash -c "$cmd" >/dev/null 2>&1 || fail "printed command failed: $cmd"
assert_grep "canon-managed-pre-commit-hook" "$p/.git/hooks/pre-commit"
assert_eq "$orig" "$(cksum < "$p/.git/hooks/pre-commit.local")"
[[ -x "$p/.git/hooks/pre-commit" ]] || fail "canon hook must be executable"
echo 0 > "$p/.git/foreign.rc"
try_commit "$p" || fail "passing foreign hook must let the commit through"
assert_grep "foreign ran:" "$p/.git/foreign.log"
assert_grep "pwd=$(cd "$p" && pwd -P)" "$p/.git/foreign.log"

# ── yes: moved (mode kept), chained; failing foreign hook blocks with its exit code ──
p="$(new_project)"
orig="$(cksum < "$p/.git/hooks/pre-commit")"
mode="$(stat -c %a "$p/.git/hooks/pre-commit" 2>/dev/null || stat -f %Lp "$p/.git/hooks/pre-commit")"
out="$(run_with_tty "'$SKILLS' add sprint '$p'" y)"
assert_contains "$out" "pre-commit.local"
assert_grep "canon-managed-pre-commit-hook" "$p/.git/hooks/pre-commit"
assert_eq "$orig" "$(cksum < "$p/.git/hooks/pre-commit.local")"
assert_eq "$mode" "$(stat -c %a "$p/.git/hooks/pre-commit.local" 2>/dev/null || stat -f %Lp "$p/.git/hooks/pre-commit.local")"
echo 7 > "$p/.git/foreign.rc"
set +e
( cd "$p" && echo y >> f.txt && git add f.txt && git -c user.email=t@t.com -c user.name=t commit -q -m c >/dev/null 2>&1 )
rc=$?
set -e
[[ $rc -ne 0 ]] || fail "failing foreign hook must block the commit"
# Exit code propagates: run canon's hook directly.
set +e; ( cd "$p" && .git/hooks/pre-commit >/dev/null 2>&1 ); rc=$?; set -e
assert_eq "7" "$rc"
echo 0 > "$p/.git/foreign.rc"
try_commit "$p" || fail "passing foreign hook must let canon's checks and the commit run"

# A pre-commit.local that is not executable is skipped, like git skips a non-executable hook.
chmod -x "$p/.git/hooks/pre-commit.local"
echo 9 > "$p/.git/foreign.rc"
try_commit "$p" || fail "a non-executable pre-commit.local must not run or block"
chmod +x "$p/.git/hooks/pre-commit.local"
echo 0 > "$p/.git/foreign.rc"

# Runs from the repo root even when the commit is made from a subdirectory.
mkdir -p "$p/sub"
( cd "$p/sub" && echo z >> g.txt && git add g.txt && git -c user.email=t@t.com -c user.name=t commit -q -m sub >/dev/null 2>&1 ) || fail "commit from a subdirectory failed"
assert_eq "foreign ran:  pwd=$(cd "$p" && pwd -P)" "$(tail -1 "$p/.git/foreign.log")"
# Invoked directly from a subdirectory (git itself already runs hooks from the root): canon's own cd.
( cd "$p/sub" && ../.git/hooks/pre-commit >/dev/null 2>&1 )
assert_eq "foreign ran:  pwd=$(cd "$p" && pwd -P)" "$(tail -1 "$p/.git/foreign.log")"

# Args forwarded: foreign hook sees the arguments canon's hook gets.
( cd "$p" && .git/hooks/pre-commit a1 a2 >/dev/null 2>&1 )
assert_grep "foreign ran: a1 a2" "$p/.git/foreign.log"

# ── re-run add / refresh: no double move, canon's hook never lands in .local ──
local_sum="$(cksum < "$p/.git/hooks/pre-commit.local")"
hook_sum="$(cksum < "$p/.git/hooks/pre-commit")"
"$SKILLS" add sprint "$p" >/dev/null 2>&1
"$SKILLS" refresh "$p" >/dev/null 2>&1
assert_eq "$local_sum" "$(cksum < "$p/.git/hooks/pre-commit.local")"
assert_eq "$hook_sum" "$(cksum < "$p/.git/hooks/pre-commit")"
if grep -qF "canon-managed-pre-commit-hook" "$p/.git/hooks/pre-commit.local"; then fail "canon hook moved into .local"; fi

# ── reappeared foreign hook (a tool re-installed itself): reported, both files byte-identical ──
printf '#!/bin/sh\necho reinstalled\n' > "$p/.git/hooks/pre-commit"
chmod 755 "$p/.git/hooks/pre-commit"
re_sum="$(cksum < "$p/.git/hooks/pre-commit")"
out="$(run_with_tty "'$SKILLS' refresh '$p'" y)"
assert_contains "$out" "both left as is"
assert_eq "$re_sum" "$(cksum < "$p/.git/hooks/pre-commit")"
assert_eq "$local_sum" "$(cksum < "$p/.git/hooks/pre-commit.local")"

# ── foreign hook + explicit no on a terminal: refused, byte-identical ────────
p="$(new_project)"
orig="$(cksum < "$p/.git/hooks/pre-commit")"
out="$(run_with_tty "'$SKILLS' add sprint '$p'" n)"
assert_contains "$out" "skills.sh refresh"
assert_eq "$orig" "$(cksum < "$p/.git/hooks/pre-commit")"
[[ ! -e "$p/.git/hooks/pre-commit.local" ]] || fail "'n' must not move the hook"

# ── remove: pre-commit.local restored as pre-commit ──────────────────────────
p="$(new_project)"
orig="$(cksum < "$p/.git/hooks/pre-commit")"
run_with_tty "'$SKILLS' add sprint '$p'" y >/dev/null
"$SKILLS" remove sprint "$p" >/dev/null 2>&1
assert_eq "$orig" "$(cksum < "$p/.git/hooks/pre-commit")"
[[ ! -e "$p/.git/hooks/pre-commit.local" ]] || fail "remove must restore pre-commit.local"

echo "git-precommit-chain: ok"
