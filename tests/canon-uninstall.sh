#!/usr/bin/env bash
# canon-uninstall (t-3897): `canon uninstall` on throwaway HOMEs and fake installs. Destructive code, so every refusal, the safety rule and the
# dry-run are proven to change nothing (a before/after tree digest), and the real skills.sh uninstall is run once end to end. The Windows branch
# runs against stub uname/cygpath/powershell.exe; the PowerShell script itself is verified on a Windows VM (and unit-tested with pwsh if present).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

WORK="$(cd "$(mktemp -d)" && pwd -P)"   # physical: ps shows the path as launched, the script compares physical paths
bgpids=()
cleanup() { local p; for p in ${bgpids[@]+"${bgpids[@]}"}; do kill "$p" 2>/dev/null || true; done; rm -rf "$WORK"; }
trap cleanup EXIT
ident=(-c user.email=t@example.com -c user.name=test)
n=0

refute_contains() { [[ "$1" != *"$2"* ]] || fail "expected output NOT to contain '$2'; got: $1"; }
digest() {  # names and contents of everything under a folder (not .git: git status refreshes its index)
  ( cd "$1" && { find . -path ./.git -prune -o \( -type f -o -type l -o -type d \) -print | LC_ALL=C sort
                 find . -path ./.git -prune -o -type f -exec cksum {} + | LC_ALL=C sort; } | cksum )
}

# A fake install: the real canon CLI, the uninstaller and its libs, a stub skills.sh that logs and mimics what skills.sh uninstall removes.
mk_install() { # <dir> [clone]
  local d="$1"
  mkdir -p "$d/tools"
  cp "$ROOT/tools/canon" "$ROOT/tools/canon-uninstall.sh" "$ROOT/tools/canon-uninstall.ps1" "$ROOT/tools/cockpit-launch-lib.sh" "$ROOT/tools/platform-lib.sh" "$d/tools/"
  echo "0.0.0" > "$d/VERSION"
  cat > "$d/tools/skills.sh" <<'SH'
#!/usr/bin/env bash
echo "skills.sh $*" >> "$STUB_LOG"
if [ "$1" = uninstall ]; then
  [ ! -f "$HOME/.config/canon/projects" ] || while IFS= read -r p; do [ -z "$p" ] || echo "cleaned $p" >> "$STUB_LOG"; done < "$HOME/.config/canon/projects"
  rm -f "$HOME/.config/canon/projects" "$HOME/.config/canon/install_path"; rmdir "$HOME/.config/canon" 2>/dev/null || true
fi
exit 0
SH
  chmod +x "$d/tools/skills.sh" "$d/tools/canon" "$d/tools/canon-uninstall.sh"
  if [[ "${2:-}" == clone ]]; then
    n=$((n + 1)); git init -q --bare -b main "$WORK/origin$n.git"
    git -C "$d" init -q -b main; git -C "$d" "${ident[@]}" add -A; git -C "$d" "${ident[@]}" commit -qm seed
    git -C "$d" remote add origin "$WORK/origin$n.git"; git -C "$d" push -q -u origin main 2>/dev/null
  fi
}
# A HOME with the registrations a real install leaves.
mk_home() { # <dir> <install dir>
  local h="$1"; mkdir -p "$h/.config/canon"
  printf '%s\n' "$2" > "$h/.config/canon/install_path"
}
mk_project() { mkdir -p "$1/.claude" "$1/.agents" "$1/.tickets"; echo "$1" >> "$2/.config/canon/projects"; }

# Run `canon uninstall` for a fixture; stdout+stderr in $out, exit code in $rc. Port 1 keeps it away from any real board on this machine.
STUBS="$WORK/stubs"; mkdir -p "$STUBS"
run() { # <home> <install> args...
  local h="$1" inst="$2"; shift 2
  set +e
  out="$(HOME="$h" STUB_LOG="$WORK/stub.log" CANON_COCKPIT_PORT=1 CANON_HOME= "$inst/tools/canon" uninstall "$@" </dev/null 2>&1)"; rc=$?
  set -e
}
: > "$WORK/stub.log"

# ── dry-run changes nothing; no terminal and no --yes changes nothing and exits 2 ────────────────────────────────────────────────────────────
inst="$WORK/i1"; h="$WORK/h1"; mk_install "$inst"; mk_home "$h" "$inst"; mk_project "$WORK/p1" "$h"; mkdir -p "$h/.canon/cockpit/changes/aa/t-x"; echo s > "$h/.canon/cockpit/changes/aa/t-x/f"; echo '{}' > "$h/.canon/cockpit/projects.json"
before="$(digest "$WORK"; digest "$h")"
run "$h" "$inst" --dry-run
[[ "$rc" == 0 ]] || fail "dry-run must exit 0: $out"
assert_contains "$out" "Install folder: $inst"; assert_contains "$out" "-> DELETE"; assert_contains "$out" "clean   $WORK/p1"; assert_contains "$out" "[canon 0.0.0, uninstall rev $(sed -n 's/^UNINSTALL_REV=//p' "$ROOT/tools/canon-uninstall.sh")]"
assert_contains "$out" "1 restore snapshot(s) of projects without git (these cannot be recreated)"; assert_contains "$out" "Left on purpose:"; assert_contains "$out" "Dry run: nothing was changed."
assert_eq "$before" "$(digest "$WORK"; digest "$h")"
run "$h" "$inst"; assert_eq 2 "$rc"; assert_contains "$out" "Not a terminal and no --yes: nothing was changed"
assert_eq "$before" "$(digest "$WORK"; digest "$h")"
run "$h" "$inst" --bogus; assert_eq 2 "$rc"; assert_contains "$out" "unknown option"
run "$h" "$inst" --help; assert_eq 0 "$rc"; assert_contains "$out" "canon uninstall — remove canon from this machine"

# ── a zip-style install, --yes: projects cleaned (both registries), empty .claude/.agents folders removed, data and install gone ─────────────
inst="$WORK/i2"; h="$WORK/h2"; mk_install "$inst"; mk_home "$h" "$inst"; mk_project "$WORK/p2a" "$h"; echo f > "$WORK/p2a/.claude/keep.txt"
mkdir -p "$WORK/p2b/.claude" "$WORK/p2b/.agents"   # known only to the Cockpit registry
mkdir -p "$h/.canon/cockpit"; printf '{"projects":[{"path":"%s"},{"path":"%s"}]}\n' "$WORK/p2b" "$WORK/missing-folder" > "$h/.canon/cockpit/projects.json"
: > "$WORK/stub.log"; run "$h" "$inst" --yes
[[ "$rc" == 0 ]] || fail "zip-style uninstall failed ($rc): $out"
assert_contains "$out" "canon uninstall: done."; assert_contains "$out" "skip    $WORK/missing-folder (folder missing)"
assert_contains "$out" "[1/5] Cockpit daemon: not running, nothing to stop."; assert_contains "$out" "Working..."; assert_contains "$out" "[2/5] Cleaning 3 project(s)"; assert_contains "$out" "[3/5] Removing Cockpit data"; assert_contains "$out" "[4/5] Install folder"
[[ "${out%%Working...*}" != "$out" && "${out%%\[2/5\]*}" == *"Working..."* ]] || fail "Working... must be printed before the first step"
log="$(cat "$WORK/stub.log")"; assert_contains "$log" "cleaned $WORK/p2a"; assert_contains "$log" "cleaned $WORK/p2b"   # the Cockpit-only project was cleaned too
[[ ! -e "$inst" ]] || fail "the install folder should be gone"
[[ ! -e "$h/.canon/cockpit" ]] || fail "the Cockpit data should be gone"
[[ -d "$WORK/p2a/.claude" && -f "$WORK/p2a/.claude/keep.txt" ]] || fail "a non-empty .claude folder must stay"
[[ ! -d "$WORK/p2a/.agents" ]] || fail "an empty .agents folder should be removed"
[[ ! -d "$WORK/p2b/.claude" && ! -d "$WORK/p2b/.agents" ]] || fail "empty .claude/.agents folders should be removed"
[[ -d "$WORK/p2a/.tickets" ]] || fail ".tickets/ must be left alone"

# ── --keep-data: the install is cleared but the Cockpit data and the registrations stay (data inside the install, the default layout) ───────────
mkdir -p "$WORK/h3"; h="$WORK/h3"; inst="$h/.canon"; mk_install "$inst"; mk_home "$h" "$inst"; mk_project "$WORK/p3" "$h"
mkdir -p "$inst/cockpit/changes/aa/t-x"; echo s > "$inst/cockpit/changes/aa/t-x/f"; echo '{}' > "$inst/cockpit/projects.json"
run "$h" "$inst" --yes --keep-data
[[ "$rc" == 0 ]] || fail "--keep-data failed ($rc): $out"
assert_contains "$out" "[3/5] Cockpit data: kept (--keep-data)"
assert_eq "cockpit" "$(ls -A "$inst")"; [[ -f "$inst/cockpit/changes/aa/t-x/f" && -f "$inst/cockpit/projects.json" ]] || fail "--keep-data must keep the Cockpit data"
assert_contains "$(cat "$h/.config/canon/projects")" "$WORK/p3"   # registrations restored after skills.sh uninstall removed them
# data outside the install, kept
inst="$WORK/i3b"; h="$WORK/h3b"; mk_install "$inst"; mk_home "$h" "$inst"; mkdir -p "$h/.canon/cockpit"; echo '{}' > "$h/.canon/cockpit/projects.json"
run "$h" "$inst" --yes --keep-data; [[ "$rc" == 0 && ! -e "$inst" && -f "$h/.canon/cockpit/projects.json" ]] || fail "kept data outside the install must survive: $out"

# ── the safety rule: a git clone with doubtful state is never deleted, even with --yes; everything else is still cleaned ──────────────────────
check_kept() { # <name> <why substring>   (uses $inst $h; the clone was altered by the caller)
  local b a; b="$(digest "$inst")"
  run "$h" "$inst" --yes
  [[ "$rc" == 0 ]] || fail "$1: expected exit 0 with the install kept, got $rc: $out"
  assert_contains "$out" "KEEP: $2" ; assert_contains "$out" "rm -rf \"$inst\""; assert_contains "$out" "[kept]  $inst"
  [[ -d "$inst/tools" ]] || fail "$1: the install folder must still exist"
  assert_eq "$b" "$(digest "$inst")"
}
inst="$WORK/i4"; h="$WORK/h4"; mk_install "$inst" clone; mk_home "$h" "$inst"; echo x > "$inst/untracked.txt"; check_kept dirty "the git clone has uncommitted or untracked changes"
inst="$WORK/i5"; h="$WORK/h5"; mk_install "$inst" clone; mk_home "$h" "$inst"; echo y >> "$inst/VERSION"; git -C "$inst" "${ident[@]}" commit -qam local; check_kept unpushed "the git clone has 1 commit(s) not on its upstream"
inst="$WORK/i6"; h="$WORK/h6"; mk_install "$inst" clone; mk_home "$h" "$inst"; git -C "$inst" remote remove origin; check_kept noupstream "the git clone has no upstream branch"
h="$WORK/h7"; inst="$h/.canon"; mkdir -p "$h"; mk_install "$inst" clone; mk_home "$h" "$inst"; mkdir -p "$inst/cockpit"; echo '{}' > "$inst/cockpit/projects.json"   # the default layout: the Cockpit data dir inside a clean pushed clone is not "dirty"
run "$h" "$inst" --yes; [[ "$rc" == 0 && ! -e "$inst" ]] || fail "a clean pushed clone (data dir inside) should be deleted: $out"
# a safety rule rejection is not overridden by anything else
inst="$WORK/i8"; h="$WORK/h8"; mk_install "$inst"; mk_home "$h" "$inst"; echo "$WORK/some-other-install" > "$h/.config/canon/install_path"
run "$h" "$inst" --yes; assert_contains "$out" "KEEP: ~/.config/canon/install_path names a different folder"; [[ -d "$inst/tools" ]] || fail "install_path mismatch must keep the folder"
# the install folder is the home folder, or contains it
mk_install "$WORK/h9"; h="$WORK/h9"; mkdir -p "$h/.config/canon"; printf '%s\n' "$h" > "$h/.config/canon/install_path"; run "$h" "$h" --yes
assert_contains "$out" "KEEP: the install folder is your home folder"; [[ -d "$h/tools" ]] || fail "a home-folder install must never be deleted"
top="$WORK/top10"; mk_install "$top"; mkdir -p "$top/home/.config/canon"; printf '%s\n' "$top" > "$top/home/.config/canon/install_path"; run "$top/home" "$top" --yes
assert_contains "$out" "KEEP: the install folder contains your home folder"; [[ -d "$top/tools" && -d "$top/home" ]] || fail "an install that contains HOME must never be deleted"
# a symlinked HOME: physical paths on both sides, so the install_path check passes and the install is removed
inst="$WORK/real11/.canon"; mkdir -p "$WORK/real11"; ln -s "$WORK/real11" "$WORK/link11"; mk_install "$inst"; mkdir -p "$WORK/real11/.config/canon"; printf '%s\n' "$WORK/link11/.canon" > "$WORK/real11/.config/canon/install_path"
run "$WORK/link11" "$WORK/link11/.canon" --yes; [[ "$rc" == 0 && ! -e "$inst" ]] || fail "a symlinked HOME/install_path must resolve and be removed: $out"

# ── blockers change nothing: a process running from the install folder, a board that is still up ────────────────────────────────────────────────
inst="$WORK/i12"; h="$WORK/h12"; mk_install "$inst"; mk_home "$h" "$inst"; mk_project "$WORK/p12" "$h"
( exec -a "$inst/tools/fake-board" sleep 60 ) & bgpids+=("$!"); sleep 0.5
before="$(digest "$WORK/i12"; digest "$h")"
run "$h" "$inst" --yes; assert_eq 1 "$rc"; assert_contains "$out" "processes are still running from $inst"; assert_contains "$out" "fake-board"
assert_eq "$before" "$(digest "$WORK/i12"; digest "$h")"
run "$h" "$inst" --dry-run; assert_contains "$out" "BLOCKED: processes are running from the install folder"
kill "${bgpids[$((${#bgpids[@]} - 1))]}" 2>/dev/null || true; sleep 0.3
# a board answering on the port: canon stop is asked first (--force only when given), then the board itself blocks
cat > "$STUBS/curl" <<'SH'
#!/usr/bin/env bash
echo "curl $*" >> "$STUB_LOG"
case "$*" in
  *"-X POST"*) if [ "${STUB_BUSY:-0}" = 1 ] && [[ "$*" != *'"force": true'* ]]; then echo '{"busy": true, "sessions": 2}'; else echo '{"running": false}'; fi ;;
  *) [ "${STUB_BOARD:-0}" = 1 ] || exit 7 ;;   # /api/version answers only when the test wants the board up
esac
SH
chmod +x "$STUBS/curl"
inst="$WORK/i13"; h="$WORK/h13"; mk_install "$inst"; mk_home "$h" "$inst"; before="$(digest "$WORK/i13"; digest "$h")"
runb() { set +e; out="$(PATH="$STUBS:$PATH" HOME="$h" STUB_LOG="$WORK/stub.log" STUB_BOARD=1 STUB_BUSY="${BUSY:-0}" CANON_COCKPIT_PORT=1 CANON_HOME= "$inst/tools/canon" uninstall "$@" </dev/null 2>&1)"; rc=$?; set -e; }
: > "$WORK/stub.log"; BUSY=1 runb --yes; assert_eq 1 "$rc"; assert_contains "$out" "session(s) running"; assert_contains "$out" "the daemon did not stop; nothing was changed"
assert_eq "$before" "$(digest "$WORK/i13"; digest "$h")"
: > "$WORK/stub.log"; BUSY=1 runb --yes --force; assert_eq 1 "$rc"; assert_contains "$(cat "$WORK/stub.log")" '"force": true'; assert_contains "$out" "the Cockpit daemon was stopped, but the board is still running on port 1. Close its window"
assert_eq "$before" "$(digest "$WORK/i13"; digest "$h")"
runb --dry-run; assert_eq 0 "$rc"; assert_contains "$out" "BLOCKED: the Cockpit board answers on port 1"

# a failing project cleanup stops the run before the data and the install folder are touched
inst="$WORK/i19"; h="$WORK/h19"; mk_install "$inst"; mk_home "$h" "$inst"; mk_project "$WORK/p19" "$h"; mkdir -p "$h/.canon/cockpit"; echo d > "$h/.canon/cockpit/f"
printf '#!/usr/bin/env bash\necho "skills.sh boom" >&2; exit 1\n' > "$inst/tools/skills.sh"
before="$(digest "$inst"; digest "$h"; digest "$WORK/p19")"
run "$h" "$inst" --yes; assert_eq 1 "$rc"; assert_contains "$out" "skills.sh uninstall failed; the Cockpit data and the install folder were left in place"
assert_eq "$before" "$(digest "$inst"; digest "$h"; digest "$WORK/p19")"

# a data root that would make the data dir <home>/cockpit is refused, never deleted
inst="$WORK/i18"; h="$WORK/h18"; mk_install "$inst"; mk_home "$h" "$inst"; mkdir -p "$h/cockpit"; echo keepme > "$h/cockpit/f"
set +e; out="$(HOME="$h" STUB_LOG="$WORK/stub.log" CANON_COCKPIT_PORT=1 CANON_HOME="$h" "$inst/tools/canon" uninstall --yes </dev/null 2>&1)"; rc=$?; set -e
assert_eq 1 "$rc"; assert_contains "$out" "[refused]  $h/cockpit is not a <data root>/cockpit folder"; [[ -f "$h/cockpit/f" ]] || fail "the data guard must not delete <home>/cockpit"

# ── shell rc lines naming the install are reported with file and line, and never edited ─────────────────────────────────────────────────────
inst="$WORK/i14"; h="$WORK/h14"; mk_install "$inst"; mk_home "$h" "$inst"
printf 'alias x=y\nexport PATH="$PATH:%s/tools"\n' "$inst" > "$h/.zshrc"; rcsum="$(cksum < "$h/.zshrc")"
run "$h" "$inst" --yes; [[ "$rc" == 0 ]] || fail "rc case failed: $out"
assert_contains "$out" "$h/.zshrc:2:export PATH"; assert_contains "$out" "NOT edited"; assert_eq "$rcsum" "$(cksum < "$h/.zshrc")"

# ── Windows branch (stub uname/cygpath/powershell): PATH entry planned, the tail handed to PowerShell, the folder left for it to delete ─────────
cat > "$STUBS/uname" <<'SH'
#!/usr/bin/env bash
[ "$1" = -s ] && echo MINGW64_NT-10.0 || /usr/bin/uname "$@"
SH
cat > "$STUBS/cygpath" <<'SH'
#!/usr/bin/env bash
# a stand-in: cygpath -w /x/y -> C:\x\y, cygpath -u C:\x\y -> /x/y (enough to see the arguments and the dedupe)
case "$1" in
  -u) printf '%s\n' "$(printf '%s' "$2" | sed 's#^[A-Za-z]:##; s#\\#/#g')" ;;
  *)  printf 'C:%s\n' "$(printf '%s' "$2" | tr '/' '\\')" ;;
esac
SH
cat > "$STUBS/powershell.exe" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *Get-Process* ]]; then [ -z "${STUB_PROCS:-}" ] || printf '%s\n' "$STUB_PROCS"; exit 0; fi
if [[ "$*" == *GetEnvironmentVariable* ]]; then printf 'C:\\Windows;%s;C:\\Users\\x\\Documents\\canon-skills\\tools;C:\\Other\r\n' "$STUB_WINPATH"; exit 0; fi
printf '%s\n' "$*" > "$STUB_PSARGS"
SH
chmod +x "$STUBS/uname" "$STUBS/cygpath" "$STUBS/powershell.exe"
inst="$WORK/i15"; h="$WORK/h15"; mk_install "$inst"; mk_home "$h" "$inst"; mk_project "$WORK/p15" "$h"
winentry="C:$(printf '%s' "$inst" | tr '/' '\\')\\tools"
runw() { set +e; out="$(PATH="$STUBS:$PATH" HOME="$h" STUB_LOG="$WORK/stub.log" STUB_WINPATH="$winentry" STUB_PROCS="${PROCS:-}" STUB_PSARGS="$WORK/psargs" CANON_UNINSTALL_POWERSHELL="$STUBS/powershell.exe" CANON_COCKPIT_PORT=1 CANON_HOME= "$inst/tools/canon" uninstall "$@" </dev/null 2>&1)"; rc=$?; set -e; }
# the same project registered in both spellings (skills.sh: /c/..., the Cockpit: C:\\... JSON-escaped) is one project, listed and cleaned once
mkdir -p "$h/.canon/cockpit"; winp="C:$(printf '%s' "$WORK/p15" | tr '/' '\\')"
winpu="$(printf '%s' "$winp" | tr 'a-z' 'A-Z')"   # Windows paths ignore case: C:\USERS\... is the same folder
printf '{"projects":[{"path":"%s"},{"path":"%s"}]}\n' "$(printf '%s' "$winp" | sed 's/\\/\\\\/g')" "$(printf '%s' "$winpu" | sed 's/\\/\\\\/g')" > "$h/.canon/cockpit/projects.json"
runw --dry-run; assert_eq 0 "$rc"; assert_contains "$out" "Windows user PATH entry: $winentry"; assert_contains "$out" "-> REMOVE"
assert_contains "$out" "Projects to clean (1,"; refute_contains "$out" "clean   C:"
assert_contains "$out" "Other PATH entries that mention canon"; assert_contains "$out" "C:\\Users\\x\\Documents\\canon-skills\\tools"
# a process whose executable is in the install folder (asked of PowerShell on Windows) blocks the run and is listed
PROCS="4242 C:\\fake\\cockpit-daemon-win.exe" runw --dry-run; assert_contains "$out" "BLOCKED: processes are running from the install folder"; assert_contains "$out" "4242 C:\\fake\\cockpit-daemon-win.exe"
before="$(digest "$inst"; digest "$h")"; PROCS="4242 C:\\fake\\cockpit-daemon-win.exe" runw --yes; assert_eq 1 "$rc"; assert_contains "$out" "processes are still running from $inst"; assert_eq "$before" "$(digest "$inst"; digest "$h")"
runw --yes; [[ "$rc" == 0 ]] || fail "windows branch failed ($rc): $out"
ps="$(cat "$WORK/psargs")"; assert_contains "$ps" "-File"; assert_contains "$ps" "-InstallDir C:$(printf '%s' "$inst" | tr '/' '\\')"; assert_contains "$ps" "-ToolsEntry $winentry"; assert_contains "$ps" "-KeepCockpit 0"; assert_contains "$ps" "-LogFile"
[[ -d "$inst/tools" ]] || fail "on Windows bash must leave the install folder for the PowerShell helper"
assert_eq 1 "$(grep -c "cleaned $WORK/p15" "$WORK/stub.log")"; refute_contains "$(cat "$WORK/stub.log")" "cleaned C:"   # the portable steps ran first, once per project

# ── the PowerShell tail: structure always, the PATH logic when pwsh exists ──────────────────────────────────────────────────────────────────
ps1="$ROOT/tools/canon-uninstall.ps1"
grep -q 'function Remove-PathEntry' "$ps1" && grep -q "Test-CanonInstall" "$ps1" && grep -q "User PATH before:" "$ps1" || fail "canon-uninstall.ps1 lost a load-bearing piece"
if command -v pwsh >/dev/null 2>&1; then
  r="$(pwsh -NoProfile -Command ". '$ps1' -InstallDir x -ToolsEntry x -LogFile x; (Remove-PathEntry 'C:\\A;C:\\canon\\tools\\;C:\\B;c:\\CANON\\TOOLS' 'C:\\canon\\tools')")"
  assert_eq 'C:\A;C:\B' "$r"
  echo "canon-uninstall: PowerShell Remove-PathEntry verified with pwsh"
else
  echo "canon-uninstall: pwsh not installed here; the PowerShell script is verified on the Windows VM"
fi

# ── the real skills.sh uninstall end to end (minus the large binaries): hooks, symlinks, imports, empty dirs, install folder ───────────────────
inst="$WORK/i16"; h="$WORK/h16"; mkdir -p "$inst"
rsync -a --exclude '*.exe' --exclude 'cockpit-daemon' --exclude '*.zip' --exclude 'node_modules' --exclude '*.go' --exclude 'go.*' "$ROOT/tools/" "$inst/tools/" 2>/dev/null || cp -R "$ROOT/tools/." "$inst/tools/"
for d in skills standards scripts agents; do cp -R "$ROOT/$d" "$inst/$d" 2>/dev/null || true; done; cp "$ROOT/VERSION" "$ROOT/AGENTS.md" "$inst/" 2>/dev/null || true
mkdir -p "$h"; proj="$WORK/p16"; mkdir -p "$proj"; git -C "$proj" init -q; echo a > "$proj/a.txt"; git -C "$proj" "${ident[@]}" add -A; git -C "$proj" "${ident[@]}" commit -qm base
set +e
( cd "$inst" && HOME="$h" SKILLS_SH_NO_TTY=1 bash tools/skills.sh init >/dev/null 2>&1 ) ; ( cd "$proj" && HOME="$h" SKILLS_SH_NO_TTY=1 bash "$inst/tools/skills.sh" add sprint "$proj" >/dev/null 2>&1 )
set -e
if [[ -f "$proj/.git/hooks/pre-commit" ]]; then
  run "$h" "$inst" --yes
  [[ "$rc" == 0 ]] || fail "real skills.sh uninstall integration failed ($rc): $out"
  [[ ! -e "$proj/.git/hooks/pre-commit" ]] || fail "the project's pre-commit hook should be removed"
  [[ -z "$(find "$proj" -path "$proj/.git" -prune -o -type l -print)" ]] || fail "no canon symlink should remain in the project"
  [[ ! -e "$inst" && ! -e "$h/.config/canon/install_path" ]] || fail "the install folder and install_path should be gone"
  [[ -d "$proj" && -f "$proj/a.txt" && -f "$proj/AGENTS.md" ]] || fail "the project's own files must stay"
  refute_contains "$out" "You can now delete this install directory"; refute_contains "$out" "To remove canon itself"   # canon uninstall prints its own report
  echo "canon-uninstall: real skills.sh uninstall integration ok"
else
  fail "the real skills.sh add did not install a pre-commit hook in the fixture (the integration case cannot run)"
fi

# ── idempotent: with the install kept, a second run changes nothing more ────────────────────────────────────────────────────────────────────
inst="$WORK/i17"; h="$WORK/h17"; mk_install "$inst" clone; mk_home "$h" "$inst"; mk_project "$WORK/p17" "$h"; echo x > "$inst/untracked.txt"
run "$h" "$inst" --yes; assert_eq 0 "$rc"; b="$(digest "$inst"; digest "$h")"
run "$h" "$inst" --yes; assert_eq 0 "$rc"; assert_contains "$out" "(none)"; assert_eq "$b" "$(digest "$inst"; digest "$h")"

# ── docs and completions list the command; the old two-step is gone ─────────────────────────────────────────────────────────────────────────
help_out="$("$ROOT/tools/canon" --help)"; assert_contains "$help_out" "canon uninstall [--dry-run] [--yes] [--keep-data] [--force]"
assert_contains "$("$ROOT/tools/canon" completion bash)" "update uninstall completion"
assert_contains "$("$ROOT/tools/canon" completion powershell)" "'uninstall'"
for f in README.md docs/setup.md; do assert_contains "$(cat "$ROOT/$f")" "canon uninstall"; done
[[ -z "$(grep -n 'rm -rf ~/.canon' "$ROOT/README.md" "$ROOT/docs/setup.md" || true)" ]] || fail "README.md/docs/setup.md still tell people to rm -rf ~/.canon"

echo "canon-uninstall: ok (dry-run and refusals change nothing, safety rule, keep-data, both registries, blockers, rc report-only, Windows branch against stubs, real skills.sh uninstall, idempotent, docs)"
