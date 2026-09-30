#!/usr/bin/env bash
# canon-update — `canon update` and `canon completion` (t-e3d2). update runs in a throwaway
# canon clone (a copy of tools/canon and what it sources, with a stub skills.sh that logs
# each refresh): it refuses — changing nothing — on uncommitted changes, a non-main branch,
# or a pull that can't fast-forward; otherwise it fast-forwards and refreshes every project
# in a temp Cockpit registry (Windows-escaped path, missing folder, a failing refresh).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
g() { git -C "$1" "${@:2}" >/dev/null 2>&1; }
ident=(-c user.email=t@example.com -c user.name=test)

# A bare "origin", an install cloned from it (on main), and a second clone that publishes updates.
git init -q --bare -b main "$WORK/origin.git"
git clone -q "$WORK/origin.git" "$WORK/seed" 2>/dev/null
mkdir -p "$WORK/seed/tools"
cp "$ROOT/tools/canon" "$ROOT/tools/cockpit-launch-lib.sh" "$ROOT/tools/platform-lib.sh" "$WORK/seed/tools/"
cat > "$WORK/seed/tools/skills.sh" <<'SH'
#!/usr/bin/env bash
# stub: log each refresh; a project folder named "bad" fails
echo "$*" >> "$REFRESH_LOG"
echo "prompts off: ${SKILLS_SH_NO_TTY:-unset}" >> "$REFRESH_LOG"
# A project whose refresh leaves a background process holding stdout/stderr (as a daemon would).
if [[ "$(basename "$2")" == spawner ]]; then (sleep 4 &); fi
if [[ "$(basename "$2")" == slow ]]; then sleep 2.5; fi
if [[ "$(basename "$2")" == empty ]]; then echo "No canon skills registered in: $2"; exit 1; fi
[[ "$(basename "$2")" != bad ]] || { echo "boom: bad project"; exit 1; }
SH
chmod +x "$WORK/seed/tools/skills.sh"
git -C "$WORK/seed" "${ident[@]}" add -A && git -C "$WORK/seed" "${ident[@]}" commit -qm seed && git -C "$WORK/seed" push -q origin main 2>/dev/null
git clone -q "$WORK/origin.git" "$WORK/install" 2>/dev/null
INSTALL="$WORK/install"; CANON="$INSTALL/tools/canon"
export REFRESH_LOG="$WORK/refresh.log"; : > "$REFRESH_LOG"

# A Cockpit registry: two real projects, one Windows-escaped path, one missing folder.
export CANON_HOME="$WORK/home"; mkdir -p "$CANON_HOME/cockpit" "$WORK/p1" "$WORK/p2"
cat > "$CANON_HOME/cockpit/projects.json" <<JSON
[
  {"id": "a", "path": "$WORK/p1", "name": "p1"},
  {"id": "b", "path": "$WORK/p2", "name": "p2"},
  {"id": "c", "path": "C:\\\\Users\\\\me\\\\Proj", "name": "win"},
  {"id": "d", "path": "$WORK/gone", "name": "gone"}
]
JSON

head_of() { git -C "$INSTALL" rev-parse --short HEAD; }
refused() {   # refused <label> <expected message part>
  local before; before="$(head_of)"; : > "$REFRESH_LOG"
  set +e; out="$("$CANON" update 2>&1)"; code=$?; set -e
  assert_eq "1" "$code"
  assert_contains "$out" "$2"
  assert_contains "$out" "Nothing was changed."
  assert_eq "$before" "$(head_of)"
  assert_eq "" "$(cat "$REFRESH_LOG")"
  echo "canon-update: refused when $1"
}

# Already up to date: projects are still refreshed; the escaped path is unescaped; missing noted.
out="$("$CANON" update)"
assert_contains "$out" "canon is up to date ($(head_of))."
assert_contains "$out" "refreshed: $WORK/p1"
assert_contains "$out" "refreshed: $WORK/p2"
assert_contains "$out" 'skipped (folder missing): C:\Users\me\Proj'
assert_contains "$out" "skipped (folder missing): $WORK/gone"
assert_eq "refresh $WORK/p1"$'\n'"prompts off: 1"$'\n'"refresh $WORK/p2"$'\n'"prompts off: 1" "$(cat "$REFRESH_LOG")"

# A new upstream commit: fast-forward.
echo change > "$WORK/seed/NEWS"; git -C "$WORK/seed" "${ident[@]}" add NEWS && git -C "$WORK/seed" "${ident[@]}" commit -qm news && git -C "$WORK/seed" push -q origin main 2>/dev/null
before="$(head_of)"
out="$("$CANON" update)"
assert_contains "$out" "canon updated $before..$(git -C "$WORK/seed" rev-parse --short HEAD)."
assert_eq "$(git -C "$WORK/seed" rev-parse HEAD)" "$(git -C "$INSTALL" rev-parse HEAD)"

# Refusals: each leaves HEAD and every project untouched.
echo wip > "$INSTALL/scratch.txt"
refused "the install has uncommitted changes" "has uncommitted changes"
rm "$INSTALL/scratch.txt"
g "$INSTALL" checkout -q -b feature
refused "the install is on another branch" "is on 'feature', not main"
g "$INSTALL" checkout -q main
echo local > "$INSTALL/LOCAL"; git -C "$INSTALL" "${ident[@]}" add LOCAL && git -C "$INSTALL" "${ident[@]}" commit -qm local
echo again > "$WORK/seed/NEWS"; git -C "$WORK/seed" "${ident[@]}" commit -qam news2 && git -C "$WORK/seed" push -q origin main 2>/dev/null
refused "the pull can't fast-forward" "can't fast-forward"
g "$INSTALL" reset -q --hard origin/main~1

# A failing refresh makes update exit 1 and names the project.
mkdir -p "$WORK/bad"
sed -i.bak "s|\"$WORK/gone\"|\"$WORK/bad\"|" "$CANON_HOME/cockpit/projects.json"
set +e; out="$("$CANON" update 2>&1)"; code=$?; set -e
assert_eq "1" "$code"
assert_contains "$out" "refresh FAILED: $WORK/bad"
assert_contains "$out" "boom: bad project"   # the failing refresh's own message is shown, not swallowed

# A project with no skills installed is skipped, not a failure.
mkdir -p "$WORK/empty"
sed -i.bak "s|\"$WORK/bad\"|\"$WORK/empty\"|" "$CANON_HOME/cockpit/projects.json"
set +e; out="$("$CANON" update 2>&1)"; code=$?; set -e
assert_eq "0" "$code"
assert_contains "$out" "skipped (no skills installed): $WORK/empty"
echo "canon-update: fast-forward, up to date, registry parsing, failed refresh ok"

# A non-git install (zip): on macOS/Linux it is refused with the reinstall command and changes nothing;
# --refresh-only refreshes the registered projects without pulling.
cp -R "$INSTALL" "$WORK/zipinstall" && rm -rf "$WORK/zipinstall/.git"
: > "$REFRESH_LOG"
set +e; out="$("$WORK/zipinstall/tools/canon" update 2>&1)"; code=$?; set -e
assert_eq "1" "$code"
assert_contains "$out" "isn't a git clone"
assert_contains "$out" "install.sh | bash"
assert_eq "" "$(cat "$REFRESH_LOG")"
sed -i.bak "s|\"$WORK/bad\"|\"$WORK/gone\"|" "$CANON_HOME/cockpit/projects.json"
before="$(head_of)"
out="$("$CANON" update --refresh-only)"
assert_contains "$out" "refreshed: $WORK/p1"
assert_eq "$before" "$(head_of)"
set +e; "$CANON" update --bogus >/dev/null 2>&1; code=$?; set -e
assert_eq "2" "$code"
# Windows hands over to the installer by exec (never overwrites the running script) and then refreshes.
grep -q 'exec powershell.exe .*-Command' "$ROOT/tools/canon" || fail "canon-update: the Windows non-git path no longer execs PowerShell"
grep -A2 'exec powershell.exe' "$ROOT/tools/canon" | grep -q '</dev/null' || fail "canon-update: the PowerShell handover inherits stdin (hangs the nested refresh on Windows)"
grep -q 'url="https://raw.githubusercontent.com/sunitghub/canon-skills/main/install.ps1"' "$ROOT/tools/canon" || fail "canon-update: no installer URL"
echo "canon-update: non-git install refused off Windows; --refresh-only ok"

# A refresh that leaves a background process behind must not hang the update (a $(...) capture waits for it).
mkdir -p "$WORK/spawner"
sed -i.bak "s|\"$WORK/empty\"|\"$WORK/spawner\"|" "$CANON_HOME/cockpit/projects.json"
SECONDS=0
out="$("$CANON" update --refresh-only)"
[[ $SECONDS -lt 3 ]] || fail "canon-update: refresh waited ${SECONDS}s for a background process"
assert_contains "$out" "refreshed: $WORK/spawner"
echo "canon-update: refresh does not wait on background processes"

# On a terminal each project first prints "refreshing <project> (please wait)..." (no background animation:
# a forking loop deadlocked Git Bash on Windows); off a terminal (every run above) it prints nothing extra.
mkdir -p "$WORK/slow"
sed -i.bak "s|\"$WORK/spawner\"|\"$WORK/slow\"|" "$CANON_HOME/cockpit/projects.json"
tty_out="$(python3 - "$CANON" <<'PYEOF'
import os, pty, sys
pid, master = pty.fork()
if pid == 0:
    os.execvp("/bin/bash", ["/bin/bash", sys.argv[1], "update", "--refresh-only"])
chunks = []
try:
    while True:
        chunk = os.read(master, 4096)
        if not chunk: break
        chunks.append(chunk)
except OSError:
    pass
os.waitpid(pid, 0)
sys.stdout.write(b"".join(chunks).decode(errors="replace"))
PYEOF
)"
assert_contains "$tty_out" "refreshing $WORK/slow (please wait)..."
assert_contains "$tty_out" "refreshed: $WORK/slow"
if grep -q '( while' "$ROOT/tools/canon"; then fail "canon-update: a background loop crept back into the refresh (deadlocked Git Bash)"; fi
echo "canon-update: a please-wait line is shown on a terminal"

# The cockpit's ? help tells people how to update (a section of its own, naming the command).
help_update="$(awk '/<div class="help-sect">Update<\/div>/{f=1} f&&/<div class="help-sect">Theme/{exit} f' "$ROOT/tools/sprint-check-app/cockpit.html")"
assert_contains "$help_update" "canon update"
assert_contains "$help_update" "Stop Daemon"
assert_contains "$help_update" "canon update</code> again"   # after stopping the daemon, update again (not just start canon)
echo "canon-update: the cockpit help has an Update section"

# Completion.
bash_out="$(bash -c 'eval "$("$1" completion bash)"
  COMP_WORDS=(canon st); COMP_CWORD=1; _canon; echo "${COMPREPLY[*]}"
  COMP_WORDS=(canon wait t-ab12 --until n); COMP_CWORD=4; _canon; echo "${COMPREPLY[*]}"
  COMP_WORDS=(canon stop ""); COMP_CWORD=2; _canon; echo "${COMPREPLY[*]}"
  COMP_WORDS=(canon completion p); COMP_CWORD=2; _canon; echo "${COMPREPLY[*]}"' _ "$CANON")"
assert_eq "status stop"$'\n'"needs-you"$'\n'"--force"$'\n'"powershell" "$bash_out"
if command -v zsh >/dev/null 2>&1; then
  "$CANON" completion zsh > "$WORK/comp.zsh"
  zsh -n "$WORK/comp.zsh" || fail "canon-update: zsh completion has a syntax error"
  assert_eq "registered" "$(zsh -fc 'autoload -U compinit && compinit -u -d "$1/.zcompdump"; source "$2"; (( $+_comps[canon] )) && echo registered' _ "$WORK" "$WORK/comp.zsh")"
fi
ps="$("$CANON" completion powershell)"
for w in Register-ArgumentCompleter status sessions stop restart wait update completion version help needs-you working done idle exited --json --force --until --timeout --project; do
  assert_contains "$ps" "$w"
done
set +e; "$CANON" completion fish >/dev/null 2>&1; code=$?; set -e
assert_eq "2" "$code"
echo "canon-update: ok (update guards + fast-forward + project refresh; bash/zsh completion work, PowerShell script complete, unknown shell refused)"
