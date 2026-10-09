#!/usr/bin/env bash
# canon-update — `canon update` and `canon completion` (t-e3d2). update runs in a throwaway
# canon clone (a copy of tools/canon and what it sources, with a stub skills.sh that logs
# each refresh): it refuses — changing nothing — on uncommitted changes, a non-main branch,
# or a pull that can't fast-forward; otherwise it fast-forwards and refreshes every project
# in a temp Cockpit registry (Windows-escaped path, missing folder, a failing refresh).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
refute_contains() { [[ "$1" != *"$2"* ]] || fail "expected output NOT to contain '$2'; got: $1"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# The sections before t-9383's assume a non-Windows host: there `canon update` does not insist on the Windows exes. On a real Windows
# run (Git Bash) that assumption fails at the first update, so the platform is pinned here; t-9383's section fakes Windows per call
# with its own stub, which comes first in PATH and still wins.
REAL_UNAME="$(command -v uname)"; LSTUB="$WORK/linuxstub"; mkdir -p "$LSTUB"
printf '#!/bin/sh\ncase "$1" in -s) echo Linux ;; *) exec "%s" "$@" ;; esac\n' "$REAL_UNAME" > "$LSTUB/uname"; chmod +x "$LSTUB/uname"; export PATH="$LSTUB:$PATH"
g() { git -C "$1" "${@:2}" >/dev/null 2>&1; }
ident=(-c user.email=t@example.com -c user.name=test)
# t-65c9: a plain update follows the latest verified release unless the install chose main. The sections before t-65c9's test the main track (what every
# install did before), so those installs say so; t-65c9's own section starts from installs with no marker.
maintrack() { printf 'main\n' > "$1/.canon-track"; echo '/.canon-track' >> "$1/.git/info/exclude"; }

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
INSTALL="$WORK/install"; CANON="$INSTALL/tools/canon"; maintrack "$INSTALL"
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
assert_contains "$out" "?? scratch.txt"
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
if command -v python3 >/dev/null 2>&1 && python3 -c "import pty" 2>/dev/null; then   # pty is Unix-only: Windows (Git Bash) has none, so the check cannot run there
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
  echo "canon-update: a please-wait line is shown on a terminal"
else
  echo "canon-update: SKIPPED the please-wait-on-a-terminal check (no python3 with pty on this machine)"
fi
if grep -q '( while' "$ROOT/tools/canon"; then fail "canon-update: a background loop crept back into the refresh (deadlocked Git Bash)"; fi

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
# t-0d25: a depth-1 install (what install.sh now makes) updates with canon update, stays shallow and gains only the new commits
git clone -q --depth 1 "file://$WORK/origin.git" "$WORK/shallow" 2>/dev/null; maintrack "$WORK/shallow"
assert_eq true "$(git -C "$WORK/shallow" rev-parse --is-shallow-repository)"
echo shallow-news > "$WORK/seed/NEWS"; git -C "$WORK/seed" "${ident[@]}" commit -qam shallow-news && git -C "$WORK/seed" push -q origin main 2>/dev/null
: > "$REFRESH_LOG"
set +e; out="$("$WORK/shallow/tools/canon" update 2>&1)"; code=$?; set -e
assert_eq "0" "$code"; assert_contains "$out" "canon updated"
assert_eq true "$(git -C "$WORK/shallow" rev-parse --is-shallow-repository)"
assert_eq "$(git -C "$WORK/origin.git" rev-parse --short HEAD)" "$(git -C "$WORK/shallow" rev-parse --short HEAD)"
assert_eq 2 "$(git -C "$WORK/shallow" rev-list --count HEAD)"
# t-97b1: on a default install CANON_HOME is the clone, so the Cockpit data dir cockpit/ sits inside it. The repo's own .gitignore must ignore it,
# or canon update refuses on every install that has run the Cockpit; a real stray file next to it must still be refused.
git -C "$ROOT" check-ignore -q cockpit/projects.json || fail "the repo .gitignore must ignore /cockpit/ (the Cockpit data dir inside a default install)"
cp "$ROOT/.gitignore" "$WORK/seed/.gitignore"; git -C "$WORK/seed" "${ident[@]}" add .gitignore && git -C "$WORK/seed" "${ident[@]}" commit -qm "real gitignore" && git -C "$WORK/seed" push -q origin main 2>/dev/null
git clone -q "$WORK/origin.git" "$WORK/inst2" 2>/dev/null; maintrack "$WORK/inst2"
mkdir -p "$WORK/inst2/cockpit"; echo '{}' > "$WORK/inst2/cockpit/projects.json"
assert_eq "" "$(git -C "$WORK/inst2" status --porcelain)"
echo cockpit-news > "$WORK/seed/NEWS"; git -C "$WORK/seed" "${ident[@]}" commit -qam cockpit-news && git -C "$WORK/seed" push -q origin main 2>/dev/null
: > "$REFRESH_LOG"
set +e; out="$(CANON_HOME="$WORK/inst2" "$WORK/inst2/tools/canon" update 2>&1)"; code=$?; set -e
assert_eq "0" "$code"; assert_contains "$out" "canon updated"
assert_eq "$(git -C "$WORK/origin.git" rev-parse --short HEAD)" "$(git -C "$WORK/inst2" rev-parse --short HEAD)"
echo stray > "$WORK/inst2/stray.txt"
echo more > "$WORK/seed/NEWS"; git -C "$WORK/seed" "${ident[@]}" commit -qam more-news && git -C "$WORK/seed" push -q origin main 2>/dev/null
set +e; out="$(CANON_HOME="$WORK/inst2" "$WORK/inst2/tools/canon" update 2>&1)"; code=$?; set -e
assert_eq "1" "$code"; assert_contains "$out" "has uncommitted changes"; assert_contains "$out" "Nothing was changed."
rm -f "$WORK/inst2/stray.txt"
# ── t-9383: the Windows exes are not committed any more. A git install on Windows keeps its old exes until the fetch has put
# verified ones back, so a failed fetch never leaves it without a board or daemon. (Windows is faked with a stub `uname`; the
# fetcher is a stub the test controls: STUB_FETCH=ok writes new exes, fail writes nothing and exits 1.)
WSTUB="$WORK/winstub"; mkdir -p "$WSTUB"; printf '#!/bin/sh\ncase "$1" in -s) echo MINGW64_NT-10.0 ;; *) echo MINGW64_NT-10.0 ;; esac\n' > "$WSTUB/uname"; chmod +x "$WSTUB/uname"
cat > "$WORK/seed/tools/fetch-daemon.sh" <<'SH'
#!/usr/bin/env bash
echo "fetch $*" >> "$REFRESH_LOG.fetch"
[ "${STUB_FETCH:-ok}" = ok ] || { echo "fetch-daemon: download failed (stub)" >&2; exit 1; }
d="$(cd "$(dirname "$0")" && pwd)"
for n in cockpit-daemon sprint-check sprint-headless-json; do echo "new-$n" > "$d/$n-win.exe"; done
SH
chmod +x "$WORK/seed/tools/fetch-daemon.sh"
for n in cockpit-daemon sprint-check sprint-headless-json; do echo "old-$n" > "$WORK/seed/tools/$n-win.exe"; done
git -C "$WORK/seed" "${ident[@]}" add -A -f && git -C "$WORK/seed" "${ident[@]}" commit -qm "tracked exes (the old way; -f: the real .gitignore now ignores them)" && git -C "$WORK/seed" push -q origin main 2>/dev/null
out="$(STUB_FETCH=fail "$CANON" update 2>&1)" || fail "update to the tracked-exes commit failed: $out"   # the install now tracks the three exes
[[ "$(cat "$INSTALL/tools/sprint-check-win.exe" 2>&1)" == old-sprint-check ]] || fail "the fixture install lacks the tracked exe: $out"
# upstream drops them from git (the seed already carries the real .gitignore, which ignores them)
git -C "$WORK/seed" "${ident[@]}" rm -q --cached tools/cockpit-daemon-win.exe tools/sprint-check-win.exe tools/sprint-headless-json-win.exe
git -C "$WORK/seed" "${ident[@]}" commit -qm "exes are release assets now" && git -C "$WORK/seed" push -q origin main 2>/dev/null
rm -f "$REFRESH_LOG.fetch"
# the pull deletes the tracked exes; the fetch fails: the previous ones come back, and the user is told
set +e; out="$(STUB_FETCH=fail PATH="$WSTUB:$PATH" "$CANON" update 2>&1)"; code=$?; set -e
for n in cockpit-daemon sprint-check sprint-headless-json; do assert_eq "old-$n" "$(cat "$INSTALL/tools/$n-win.exe")"; done
assert_contains "$out" "kept your previous sprint-check-win.exe"; assert_contains "$out" "download failed (stub)"
assert_eq "fetch --quiet" "$(cat "$REFRESH_LOG.fetch")"; assert_eq "" "$(git -C "$INSTALL" status --porcelain)"
# the next update with a working fetch replaces them (the fetcher writes new bytes over the kept ones)
echo again > "$WORK/seed/NEWS2"; git -C "$WORK/seed" "${ident[@]}" add NEWS2; git -C "$WORK/seed" "${ident[@]}" commit -qm news3 && git -C "$WORK/seed" push -q origin main 2>/dev/null
out="$(STUB_FETCH=ok PATH="$WSTUB:$PATH" "$CANON" update 2>&1)"
for n in cockpit-daemon sprint-check sprint-headless-json; do assert_eq "new-$n" "$(cat "$INSTALL/tools/$n-win.exe")"; done
refute_contains "$out" "kept your previous"
# a pull that cannot fast-forward leaves no backup folder behind and changes nothing
echo local > "$INSTALL/LOCAL2"; git -C "$INSTALL" "${ident[@]}" add LOCAL2; git -C "$INSTALL" "${ident[@]}" commit -qm local2
echo more3 > "$WORK/seed/NEWS3"; git -C "$WORK/seed" "${ident[@]}" add NEWS3; git -C "$WORK/seed" "${ident[@]}" commit -qm news4 && git -C "$WORK/seed" push -q origin main 2>/dev/null
export TMPDIR="$WORK/updtmp"; mkdir -p "$TMPDIR"   # the backup folder is made under TMPDIR: count it there
set +e; out="$(PATH="$WSTUB:$PATH" "$CANON" update 2>&1)"; code=$?; set -e
assert_eq "1" "$code"; assert_contains "$out" "can't fast-forward"
assert_eq 0 "$(find "$TMPDIR" -maxdepth 1 -name 'canon-update-bak.*' | wc -l | tr -d ' ')"; unset TMPDIR
for n in cockpit-daemon sprint-check sprint-headless-json; do assert_eq "new-$n" "$(cat "$INSTALL/tools/$n-win.exe")"; done
g "$INSTALL" reset -q --hard origin/main~0 2>/dev/null || true; git -C "$INSTALL" reset -q --hard origin/main
# a fetch that fails with nothing to restore (the exes were never there) is a failed update: exit 1 and say which programs are missing
rm -f "$INSTALL"/tools/*-win.exe; echo more4 > "$WORK/seed/NEWS4"; git -C "$WORK/seed" "${ident[@]}" add NEWS4; git -C "$WORK/seed" "${ident[@]}" commit -qm news5 && git -C "$WORK/seed" push -q origin main 2>/dev/null
set +e; out="$(STUB_FETCH=fail PATH="$WSTUB:$PATH" "$CANON" update 2>&1)"; code=$?; set -e
assert_eq "1" "$code"; assert_contains "$out" "cockpit-daemon-win.exe sprint-check-win.exe"; assert_contains "$out" "could not be fetched"
assert_contains "$out" "download failed (stub)"; assert_eq "" "$(git -C "$INSTALL" status --porcelain)"
# the same state on macOS/Linux is NOT an error (no Windows exes exist there)
echo more5 > "$WORK/seed/NEWS5"; git -C "$WORK/seed" "${ident[@]}" add NEWS5; git -C "$WORK/seed" "${ident[@]}" commit -qm news6 && git -C "$WORK/seed" push -q origin main 2>/dev/null
set +e; out="$(STUB_FETCH=fail "$CANON" update 2>&1)"; code=$?; set -e
assert_eq "0" "$code"; refute_contains "$out" "could not be fetched"
# macOS/Linux never touch exes: no backup, no restore message
out="$("$CANON" update 2>&1)"; refute_contains "$out" "kept your previous"

# ── t-30fc: `canon update --to <ref>` pins an install to a release tag (or returns it to main). The install is a depth-1 clone, so
# the tag is not there until it is fetched. Fixture: tags v0.3.0 and v0.3.1, then an untagged commit on main.
O3="$WORK/o3.git"; git init -q --bare -b main "$O3"
git clone -q "$O3" "$WORK/seed3" 2>/dev/null
mkdir -p "$WORK/seed3/tools"
cp "$ROOT/tools/canon" "$ROOT/tools/cockpit-launch-lib.sh" "$ROOT/tools/platform-lib.sh" "$WORK/seed3/tools/"
cp "$WORK/seed/tools/skills.sh" "$WORK/seed/tools/fetch-daemon.sh" "$ROOT/tools/release-manifest.sh" "$WORK/seed3/tools/"
printf "tools/*-win.exe\n/.canon-track\n" > "$WORK/seed3/.gitignore"   # as the real .gitignore: the fetch stub writes these
echo 0.3.0 > "$WORK/seed3/VERSION"; git -C "$WORK/seed3" "${ident[@]}" add -A -f; git -C "$WORK/seed3" "${ident[@]}" commit -qm "release 0.3.0"
git -C "$WORK/seed3" "${ident[@]}" tag -a v0.3.0 -m "v0.3.0"
echo 0.3.1 > "$WORK/seed3/VERSION"; git -C "$WORK/seed3" "${ident[@]}" commit -qam "release 0.3.1"
git -C "$WORK/seed3" "${ident[@]}" tag -a v0.3.1 -m "v0.3.1"
echo next > "$WORK/seed3/UNRELEASED"; git -C "$WORK/seed3" "${ident[@]}" add UNRELEASED; git -C "$WORK/seed3" "${ident[@]}" commit -qm "after the release"
git -C "$WORK/seed3" push -q origin main --tags 2>/dev/null
git clone -q --depth 1 "file://$O3" "$WORK/inst3" 2>/dev/null
I3="$WORK/inst3"; C3="$I3/tools/canon"
tip3="$(git -C "$WORK/seed3" rev-parse HEAD)"
sha3() { git -C "$WORK/seed3" rev-list -n1 "$1"; }
assert_eq "" "$(git -C "$I3" tag)"   # the shallow clone has no tags until one is asked for
h3() { git -C "$I3" rev-parse HEAD; }
# t-34f1: a release installs only if the published manifest lists it with the tag's own commit. The manifest here is a file (the zip sha
# is a stand-in: the git path checks the commit); v0.3.2 is listed but was never pushed to origin.
Z3="$(printf 'e%.0s' $(seq 1 64))"; M3="$WORK/manifest3.txt"
good3() { printf '# canon releases\nv0.3.2 %s %s\nv0.3.1 %s %s\nv0.3.0 %s %s\n' "$Z3" "$tip3" "$Z3" "$(sha3 v0.3.1)" "$Z3" "$(sha3 v0.3.0)" > "$M3"; }
if command -v cygpath >/dev/null 2>&1; then M3URL="file:///$(cygpath -m "$M3")"; else M3URL="file://$M3"; fi   # Git for Windows' curl is native: it needs C:/..., not /tmp/...
good3; export CANON_MANIFEST_URL="$M3URL"

# Invalid refs exit 2 before any git call: a git stub that records every call proves none was made.
GSTUB="$WORK/gitstub"; mkdir -p "$GSTUB"; printf '#!/bin/sh\necho "$*" >> "%s/git.calls"\nexit 99\n' "$WORK" > "$GSTUB/git"; chmod +x "$GSTUB/git"
rm -f "$WORK/git.calls"
for bad in -x ../x v1 v1.2 release main2 v1.2.3.4 'v1.2.3;x' 'v1.2.3 ' V1.2.3 ''; do
  set +e; out="$(PATH="$GSTUB:$PATH" "$C3" update --to "$bad" 2>&1)"; code=$?; set -e
  assert_eq "2" "$code"; assert_contains "$out" "--to takes latest, main or a release tag like v0.3.0"
done
set +e; out="$(PATH="$GSTUB:$PATH" "$C3" update --to 2>&1)"; code=$?; set -e; assert_eq "2" "$code"; assert_contains "$out" "--to takes latest, main or a release tag like v0.3.0"
set +e; out="$(PATH="$GSTUB:$PATH" "$C3" update --to v0.3.0 extra 2>&1)"; code=$?; set -e; assert_eq "2" "$code"
[[ ! -e "$WORK/git.calls" ]] || fail "canon-update: a bad --to value reached git: $(cat "$WORK/git.calls")"
assert_eq "$tip3" "$(h3)"

# A tag that does not exist, a dirty install and another branch each refuse and change nothing.
set +e; out="$("$C3" update --to v9.9.9 2>&1)"; code=$?; set -e
assert_eq "1" "$code"; assert_contains "$out" "v9.9.9"; assert_contains "$out" "Nothing was changed."; assert_eq "$tip3" "$(h3)"
# Listed in the manifest but not on origin: the fetch fails, nothing changes.
set +e; out="$("$C3" update --to v0.3.2 2>&1)"; code=$?; set -e
assert_eq "1" "$code"; assert_contains "$out" "was not found on origin"; assert_eq "$tip3" "$(h3)"
# t-34f1: each way the manifest can fail refuses with the reason, leaving HEAD, the tree and the tags exactly as they were.
nochange3() { assert_eq "$tip3" "$(h3)"; assert_eq "" "$(git -C "$I3" status --porcelain)"; assert_eq "" "$(git -C "$I3" tag)"; assert_eq "main" "$(git -C "$I3" symbolic-ref --short HEAD)"; }
refuse3() {   # refuse3 <label> <expected message part>
  set +e; out="$("$C3" update --to v0.3.0 2>&1)"; code=$?; set -e
  [[ "$code" == 1 ]] || fail "canon-update: $1 did not refuse (exit $code): $out"
  assert_contains "$out" "$2"; assert_contains "$out" "Nothing was changed."; nochange3
}
printf 'v0.3.1 %s %s\n' "$Z3" "$(sha3 v0.3.1)" > "$M3";                                       refuse3 "a manifest without the tag" "not in the release manifest"
printf 'v0.3.0 %s %s\n' "$Z3" "$(sha3 v0.3.1)" > "$M3";                                       refuse3 "a manifest naming another commit" "published manifest says"
printf 'v0.3.0 %s %s\n' "${Z3%?}" "$(sha3 v0.3.0)" > "$M3";                                   refuse3 "a short sha256" "malformed"
printf 'v0.3.0 %s %s\nv0.3.0 %s %s\n' "$Z3" "$(sha3 v0.3.0)" "$Z3" "$(sha3 v0.3.1)" > "$M3";  refuse3 "two different lines for the tag" "twice with different values"
: > "$M3";                                                                                     refuse3 "an empty manifest" "not in the release manifest"
rm -f "$M3";                                                                                   refuse3 "no manifest at all" "cannot read the release manifest"
# A tag that is already here is not trusted either: it must match the manifest too. (It is the user's tag, so it is left alone.)
good3; git -C "$I3" tag -f v0.3.0 HEAD >/dev/null 2>&1
set +e; out="$("$C3" update --to v0.3.0 2>&1)"; code=$?; set -e
[[ "$code" == 1 ]] || fail "canon-update: a local tag at the wrong commit was trusted (exit $code): $out"
assert_contains "$out" "published manifest says"; assert_eq "$tip3" "$(h3)"; assert_eq "v0.3.0" "$(git -C "$I3" tag)"
git -C "$I3" tag -d v0.3.0 >/dev/null
# main and a plain update need no manifest (--to main from main is an ordinary update).
out="$("$C3" update --to main 2>&1)"; assert_contains "$out" "canon is up to date"; assert_contains "$out" "not checksum-verified"
out="$("$C3" update 2>&1)"; assert_contains "$out" "canon is up to date"; assert_eq "$tip3" "$(h3)"; assert_eq "" "$(git -C "$I3" status --porcelain)"
# (an ordinary pull may bring tags along; a local tag is still checked against the manifest below before it is used)
good3
echo wip > "$I3/scratch.txt"
set +e; out="$("$C3" update --to v0.3.0 2>&1)"; code=$?; set -e
assert_eq "1" "$code"; assert_contains "$out" "has uncommitted changes"; assert_eq "$tip3" "$(h3)"; rm "$I3/scratch.txt"
g "$I3" checkout -q -b feature
set +e; out="$("$C3" update --to v0.3.0 2>&1)"; code=$?; set -e
assert_eq "1" "$code"; assert_contains "$out" "is on 'feature', not main"; assert_eq "$tip3" "$(h3)"
g "$I3" checkout -q main

# Pin to v0.3.0: HEAD is the tag's commit, detached; the daemon fetch and the project refresh still run.
: > "$REFRESH_LOG"; rm -f "$REFRESH_LOG.fetch"
out="$("$C3" update --to v0.3.0 2>&1)"
assert_eq "$(sha3 v0.3.0)" "$(h3)"; assert_eq "0.3.0" "$(cat "$I3/VERSION")"
assert_contains "$out" "canon is now on v0.3.0"; assert_contains "$out" "verified against the published manifest"; refute_contains "$out" "not checksum-verified"
assert_contains "$out" "refreshed: $WORK/p1"
assert_eq "fetch --quiet" "$(cat "$REFRESH_LOG.fetch")"
[[ -z "$(git -C "$I3" symbolic-ref -q HEAD || true)" ]] || fail "canon-update: --to a tag left a branch checked out"
# t-65c9: a plain update on a release install moves to the latest release in the manifest (not sticky: nothing remembers the older pin).
printf '# canon releases\nv0.3.1 %s %s\nv0.3.0 %s %s\n' "$Z3" "$(sha3 v0.3.1)" "$Z3" "$(sha3 v0.3.0)" > "$M3"
: > "$REFRESH_LOG"
out="$("$C3" update 2>&1)"
assert_eq "$(sha3 v0.3.1)" "$(h3)"; assert_contains "$out" "canon is now on v0.3.1"; assert_contains "$out" "verified against the published manifest"; refute_contains "$out" "not checksum-verified"
assert_contains "$out" "refreshed: $WORK/p1"
out="$("$C3" update 2>&1)"; assert_contains "$out" "canon is up to date (v0.3.1, verified"; assert_eq "$(sha3 v0.3.1)" "$(h3)"
good3
# Pinned to another tag, then back to main: a normal fast-forward from there.
out="$("$C3" update --to v0.3.1 2>&1)"; assert_eq "$(sha3 v0.3.1)" "$(h3)"; assert_eq "0.3.1" "$(cat "$I3/VERSION")"
out="$("$C3" update --to main 2>&1)"
assert_eq "$tip3" "$(h3)"; assert_eq "main" "$(git -C "$I3" symbolic-ref --short HEAD)"; assert_eq "" "$(git -C "$I3" status --porcelain)"
refute_contains "$out" "pinned"
# Plain update works again, and `--to main` on main is the ordinary update.
out="$("$C3" update 2>&1)"; assert_contains "$out" "canon is up to date"
out="$("$C3" update --to main 2>&1)"; assert_contains "$out" "canon is up to date"
# --to is meaningless without a git clone off Windows: refused like a plain update there.
cp -R "$I3" "$WORK/zip3" && rm -rf "$WORK/zip3/.git"
set +e; out="$("$WORK/zip3/tools/canon" update --to v0.3.0 2>&1)"; code=$?; set -e
assert_eq "1" "$code"; assert_contains "$out" "isn't a git clone"
# Windows zip install: the installer is re-run with the ref in CANON_REF (PowerShell cannot run here), and install.ps1 reads it.
grep -q 'CANON_REF' "$ROOT/tools/canon" || fail "canon-update: the Windows non-git path does not pass CANON_REF to the installer"
grep -q 'CANON_REF' "$ROOT/install.ps1" || fail "canon-update: install.ps1 ignores CANON_REF"
grep -q 'releases/download/' "$ROOT/install.ps1" || fail "canon-update: install.ps1 cannot fetch a release's zip"
grep -q 'Get-FileHash' "$ROOT/install.ps1" && grep -q 'Get-CanonReleaseSha256' "$ROOT/install.ps1" || fail "canon-update: install.ps1 does not verify a release zip against the manifest (t-34f1; its behavior is checked on the Windows VM)"
echo "canon-update: --to installs a release tag or main, bad refs never reach git (t-30fc)"

# ── t-65c9: a plain `canon update` follows the latest verified release. An install with no marker (made before this, or by install.sh) is on branch
# main; it moves to the latest release once, with a message; `--to main` is the remembered opt-in; `--to vX.Y.Z` is not sticky. The manifest here
# lists v0.3.1 as the latest (v0.3.2 above was never pushed). Every refusal leaves HEAD and the tree untouched.
m31() { printf '# canon releases\nv0.3.1 %s %s\nv0.3.0 %s %s\n' "$Z3" "$(sha3 v0.3.1)" "$Z3" "$(sha3 v0.3.0)" > "$M3"; }
leg() { git clone -q --depth 1 "file://$O3" "$WORK/$1" 2>/dev/null; printf '%s' "$WORK/$1"; }   # an install with no marker
m31
A="$(leg legA)"; CA="$A/tools/canon"; ha() { git -C "$A" rev-parse HEAD; }
assert_eq "main" "$(git -C "$A" symbolic-ref --short HEAD)"; [[ ! -e "$A/.canon-track" ]] || fail "canon-update: a fresh install has a track marker"
out="$("$CA" update 2>&1)"
assert_eq "$(sha3 v0.3.1)" "$(ha)"; [[ -z "$(git -C "$A" symbolic-ref -q HEAD || true)" ]] || fail "canon-update: the migration left a branch checked out"
assert_contains "$out" "canon is now on v0.3.1"; assert_contains "$out" "verified against the published manifest"
assert_contains "$out" "This install was following main"; assert_contains "$out" "canon update --to main"; refute_contains "$out" "not checksum-verified"
assert_eq "" "$(git -C "$A" status --porcelain)"; [[ ! -e "$A/.canon-track" ]] || fail "canon-update: the release track wrote a marker"
out="$("$CA" update 2>&1)"; assert_contains "$out" "canon is up to date (v0.3.1, verified"; refute_contains "$out" "was following main"; refute_contains "$out" "not checksum-verified"
assert_eq "canon 0.3.1" "$("$CA" version)"
# --to main is the opt-in: remembered (an ignored file), followed by a plain update, and the only place the unverified note appears
out="$("$CA" update --to main 2>&1)"
assert_eq "$tip3" "$(ha)"; assert_eq "main" "$(git -C "$A" symbolic-ref --short HEAD)"; assert_eq "main" "$(tr -d '[:space:]' < "$A/.canon-track")"; assert_eq "" "$(git -C "$A" status --porcelain)"
assert_contains "$out" "following main"; assert_contains "$out" "not checksum-verified"; assert_contains "$out" "canon update --to latest"
assert_contains "$("$CA" version)" "Following main"
echo extra-main > "$WORK/seed3/NEWS3"; git -C "$WORK/seed3" "${ident[@]}" add NEWS3; git -C "$WORK/seed3" "${ident[@]}" commit -qm "more main"; git -C "$WORK/seed3" push -q origin main 2>/dev/null
out="$("$CA" update 2>&1)"; assert_eq "$(git -C "$WORK/seed3" rev-parse HEAD)" "$(ha)"; assert_contains "$out" "canon updated"; assert_contains "$out" "not checksum-verified"
# --to latest returns to the verified releases and forgets the marker; the version command says nothing about main again
out="$("$CA" update --to latest 2>&1)"
assert_eq "$(sha3 v0.3.1)" "$(ha)"; [[ ! -e "$A/.canon-track" ]] || fail "canon-update: --to latest kept the marker"; refute_contains "$out" "not checksum-verified"; refute_contains "$("$CA" version)" "Following main"
# a rollback is not sticky: --to v0.3.0 installs it, the next plain update goes forward again
out="$("$CA" update --to v0.3.0 2>&1)"; assert_eq "$(sha3 v0.3.0)" "$(ha)"; assert_contains "$out" "canon is now on v0.3.0"
out="$("$CA" update 2>&1)"; assert_eq "$(sha3 v0.3.1)" "$(ha)"; assert_contains "$out" "canon is now on v0.3.1"; refute_contains "$out" "was following main"
# the manifest cannot say what the latest release is: a plain update refuses, changing nothing, and names the way that needs no manifest
B="$(leg legB)"; CB="$B/tools/canon"; hb() { git -C "$B" rev-parse HEAD; }; beforeb="$(hb)"
nolatest() {   # nolatest <label> (a manifest file is already in $M3)
  set +e; out="$("$CB" update 2>&1)"; code=$?; set -e
  [[ "$code" == 1 ]] || fail "canon-update: $1: a plain update was not refused (exit $code): $out"
  assert_contains "$out" "Nothing was changed."; assert_contains "$out" "canon update --to main"
  assert_eq "$beforeb" "$(hb)"; assert_eq "main" "$(git -C "$B" symbolic-ref --short HEAD)"; assert_eq "" "$(git -C "$B" status --porcelain)"; [[ ! -e "$B/.canon-track" ]] || fail "canon-update: $1: a refusal wrote a marker"
}
rm -f "$M3"; nolatest "manifest unreachable"
printf '# canon releases\n' > "$M3"; nolatest "manifest lists no release"
printf 'v0.3.1 %s %s\nv0.3.1 %s %s\n' "$Z3" "$(sha3 v0.3.1)" "$Z3" "$tip3" > "$M3"; nolatest "latest release listed twice with different values"
printf 'v0.3.1 short %s\n' "$tip3" > "$M3"; nolatest "only a malformed line"
printf 'v0.3.9 %s %s\n' "$Z3" "$(printf 'f%.0s' $(seq 1 40))" > "$M3"; nolatest "latest release the manifest names but the origin does not have"
m31
# local commits, uncommitted changes and another branch each refuse a plain update, changing nothing (a release would leave the commits behind)
C2="$(leg legC)"; hc() { git -C "$C2" rev-parse HEAD; }
echo mine > "$C2/mine.txt"; git -C "$C2" add mine.txt; git -C "$C2" "${ident[@]}" commit -qm "local work"; beforec="$(hc)"
set +e; out="$("$C2/tools/canon" update 2>&1)"; code=$?; set -e
assert_eq "1" "$code"; assert_contains "$out" "local commit(s) on main"; assert_contains "$out" "canon update --to main"; assert_contains "$out" "Nothing was changed."; assert_eq "$beforec" "$(hc)"
echo wip > "$C2/scratch.txt"
set +e; out="$("$C2/tools/canon" update 2>&1)"; code=$?; set -e
assert_eq "1" "$code"; assert_contains "$out" "has uncommitted changes"; assert_eq "$beforec" "$(hc)"; rm "$C2/scratch.txt"
g "$C2" checkout -q -b feature
set +e; out="$("$C2/tools/canon" update 2>&1)"; code=$?; set -e
assert_eq "1" "$code"; assert_contains "$out" "is on 'feature', not main"
# a bad value after --to latest never reaches git
rm -f "$WORK/git.calls"; set +e; out="$(PATH="$GSTUB:$PATH" "$CA" update --to latest extra 2>&1)"; code=$?; set -e
assert_eq "2" "$code"; [[ ! -e "$WORK/git.calls" ]] || fail "canon-update: a bad --to latest reached git: $(cat "$WORK/git.calls")"
# the installers read the same rules (PowerShell cannot run here; the Windows VM checks it)
grep -q '\.canon-track' "$ROOT/install.ps1" || fail "canon-update: install.ps1 does not read the track marker"
grep -q 'Get-CanonLatestRelease' "$ROOT/install.ps1" || fail "canon-update: install.ps1 cannot resolve the latest release"
echo "canon-update: plain update follows the latest verified release; --to main is the remembered opt-in; a rollback is not sticky; every refusal changes nothing (t-65c9)"

ps="$("$CANON" completion powershell)"
for w in Register-ArgumentCompleter status sessions stop restart wait update uninstall --dry-run --keep-data --yes completion version help needs-you working done idle exited --json --force --until --timeout --project; do
  assert_contains "$ps" "$w"
done
set +e; "$CANON" completion fish >/dev/null 2>&1; code=$?; set -e
assert_eq "2" "$code"
echo "canon-update: ok (Windows exes kept across a failed fetch (t-9383); update guards + fast-forward + project refresh; bash/zsh completion work, PowerShell script complete, unknown shell refused)"
