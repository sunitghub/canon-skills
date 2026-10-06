#!/usr/bin/env bash
# canon-uninstall (t-3897): `canon uninstall` on throwaway HOMEs and fake installs. Destructive code, so every refusal, the safety rule and the
# dry-run are proven to change nothing (a before/after tree digest), and the real skills.sh uninstall is run once end to end. The Windows branch
# runs against stub uname/cygpath/powershell.exe; the PowerShell script itself is verified on a Windows VM (and unit-tested with pwsh if present).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# Hermetic: this command deletes the Cockpit runtime state dir under the temp/cache folders, so a run must never see the real ones (t-70a2:
# an earlier version of this test removed the real <tmp>/canon-cockpit-board of the machine it ran on).
REAL_TMP="${TMPDIR:-/tmp}"
WORK="$(cd "$(mktemp -d)" && pwd -P)"   # physical: ps shows the path as launched, the script compares physical paths
bgpids=()
cleanup() { local p; for p in ${bgpids[@]+"${bgpids[@]}"}; do kill "$p" 2>/dev/null || true; done; rm -rf "$WORK"; }
trap cleanup EXIT
export TMPDIR="$WORK/tmp"; mkdir -p "$TMPDIR"; unset COCKPIT_STATE_DIR XDG_RUNTIME_DIR XDG_CACHE_HOME   # the code under test derives state dirs from these
real_state_sig() { { ls -A "$REAL_TMP/canon-cockpit-board" 2>/dev/null || true; } | cksum; }   # a canary: the real state dir (if any) must come out unchanged
REAL_STATE_BEFORE="$(real_state_sig)"
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
  cp "$ROOT/tools/canon" "$ROOT/tools/canon-uninstall.sh" "$ROOT/tools/canon-uninstall.ps1" "$ROOT/tools/cockpit-launch-lib.sh" "$ROOT/tools/platform-lib.sh" "$ROOT/tools/cockpit-stop-lib.sh" "$d/tools/"
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
assert_contains "$out" "[1/5] Cockpit board and daemon: not running, nothing to stop."; assert_contains "$out" "Working..."; assert_contains "$out" "[2/5] Cleaning 3 project(s)"; assert_contains "$out" "[3/5] Removing Cockpit data"; assert_contains "$out" "[4/5] Install folder"
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
# data nested one level down (CANON_HOME inside the install): the whole top-level folder that holds it is kept, not just a folder named cockpit
inst="$WORK/i3n"; h="$WORK/h3n"; mk_install "$inst"; mk_home "$h" "$inst"; mkdir -p "$inst/data/cockpit"; echo '{}' > "$inst/data/cockpit/projects.json"
out="$(HOME="$h" STUB_LOG="$WORK/stub.log" CANON_COCKPIT_PORT=1 CANON_HOME="$inst/data" bash "$inst/tools/canon-uninstall.sh" --yes --keep-data </dev/null 2>&1)" && rc=0 || rc=$?
[[ "$rc" == 0 && -f "$inst/data/cockpit/projects.json" ]] || fail "nested CANON_HOME: --keep-data deleted the data it said it kept ($rc): $out"
assert_eq "data" "$(ls -A "$inst")"
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
inst="$WORK/i4b"; h="$WORK/h4b"; mk_install "$inst" clone; mk_home "$h" "$inst"; git -C "$inst" checkout -q -b wip; echo w >> "$inst/VERSION"; git -C "$inst" "${ident[@]}" commit -qam wip; git -C "$inst" checkout -q main; check_kept localbranch "the git clone has a local branch with commits that are on no remote"
inst="$WORK/i4c"; h="$WORK/h4c"; mk_install "$inst" clone; mk_home "$h" "$inst"; echo s >> "$inst/VERSION"; git -C "$inst" "${ident[@]}" stash -q; check_kept stash "the git clone has stashed changes"
inst="$WORK/i4d"; h="$WORK/h4d"; mk_install "$inst" clone; mk_home "$h" "$inst"; git -C "$inst" worktree add -q "$WORK/wt4d" -b wt4d; git -C "$inst" push -q origin wt4d 2>/dev/null; check_kept worktree "the git clone has linked worktrees"
inst="$WORK/i4e"; h="$WORK/h4e"; mk_install "$inst" clone; mk_home "$h" "$inst"; git -C "$inst" update-index --skip-worktree VERSION; echo hidden >> "$inst/VERSION"; check_kept skipworktree "the git clone has local edits hidden with skip-worktree"
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
run "$h" "$inst" --yes; assert_eq 1 "$rc"; assert_contains "$out" "processes are running from $inst"; assert_contains "$out" "fake-board"
assert_eq "$before" "$(digest "$WORK/i12"; digest "$h")"
run "$h" "$inst" --dry-run; assert_contains "$out" "BLOCKED: processes are running from the install folder"
kill "${bgpids[$((${#bgpids[@]} - 1))]}" 2>/dev/null || true; sleep 0.3
# something answers on the port but nothing can say it is THIS install's board (the curl stub answers; no listener is visible): refuse, never guess
cat > "$STUBS/curl" <<'SH'
#!/usr/bin/env bash
echo "curl $*" >> "$STUB_LOG"
[ "${STUB_BOARD:-0}" = 1 ] || exit 7   # /api/version answers only when the test wants a board up
SH
chmod +x "$STUBS/curl"
inst="$WORK/i13"; h="$WORK/h13"; mk_install "$inst"; mk_home "$h" "$inst"; before="$(digest "$WORK/i13"; digest "$h")"
runb() { set +e; out="$(PATH="$STUBS:$PATH" HOME="$h" STUB_LOG="$WORK/stub.log" STUB_BOARD=1 CANON_COCKPIT_PORT=1 CANON_HOME= "$inst/tools/canon" uninstall "$@" </dev/null 2>&1)"; rc=$?; set -e; }
: > "$WORK/stub.log"; runb --yes; assert_eq 1 "$rc"; assert_contains "$out" "cannot be identified as this install's Cockpit board"; assert_contains "$out" "Nothing was changed."
assert_eq "$before" "$(digest "$WORK/i13"; digest "$h")"
runb --dry-run; assert_eq 0 "$rc"; assert_contains "$out" "BLOCKED: something answers on port 1"

# ── t-70a2: the command stops THIS install's Cockpit board and daemon itself, found by recorded pid / port and verified against the install ───────
# Real throwaway processes under a fake install: a daemon stub (argv0 = <install>/tools/cockpit-daemon/cockpit-daemon, writes daemon.json with its own pid,
# removes it on SIGTERM), a board stub (python listening on a free port, started as <install>/tools/sprint-check-app/server.py) under a launcher stub
# (argv0 "bash <install>/tools/canon") that exits when the board dies.
killlist=()
trap 'for p in ${killlist[@]+"${killlist[@]}"}; do kill -9 "$p" 2>/dev/null || true; done; cleanup' EXIT
free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])'; }
cat > "$WORK/dstub.sh" <<'SH'
#!/usr/bin/env bash
# dstub.sh <state dir> [ignore-term]
state="$1"; mkdir -p "$state"
if [ "${2:-}" = ignore-term ]; then trap '' TERM; else trap 'rm -f "$state/daemon.json"; exit 0' TERM; fi
printf '{"addr": "127.0.0.1:1", "token": "t", "pid": "%s"}' "$$" > "$state/daemon.json"
while :; do sleep 0.2; done
SH
cat > "$WORK/bstub.py" <<'PY'
import signal, socket, sys
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(5)
signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))
while True:
    c, _ = s.accept(); c.sendall(b"HTTP/1.0 200 OK\r\n\r\n{}"); c.close()
PY
cat > "$WORK/lstub.sh" <<'SH'
#!/usr/bin/env bash
# lstub.sh <server.py> <port>: a launcher that runs the board and exits when it dies
python3 "$1" "$2" & b=$!
trap 'kill "$b" 2>/dev/null; exit 0' TERM
wait "$b"
SH
mk_live() { # <install> <state dir> <port> [daemon mode]  sets DPID BPID LPID (board and launcher only when a port is given)
  local inst="$1" state="$2" port="$3" mode="${4:-}"
  mkdir -p "$inst/tools/sprint-check-app"; cp "$WORK/bstub.py" "$inst/tools/sprint-check-app/server.py"
  ( exec -a "$inst/tools/cockpit-daemon/cockpit-daemon" bash "$WORK/dstub.sh" "$state" $mode ) & DPID=$!; killlist+=("$DPID")
  BPID=""; LPID=""
  if [ -n "$port" ]; then
    ( exec -a "bash $inst/tools/canon" bash "$WORK/lstub.sh" "$inst/tools/sprint-check-app/server.py" "$port" ) & LPID=$!; killlist+=("$LPID")
    for _ in $(seq 1 50); do curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$port/" && break; sleep 0.1; done
    BPID="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t | head -1)"; killlist+=("$BPID")
  fi
  for _ in $(seq 1 50); do [ -f "$state/daemon.json" ] && break; sleep 0.1; done
}
alive() { kill -0 "$1" 2>/dev/null; }
runl() { # <inst> <h> <port> <TMPDIR> args...  (a live-process run: real curl/ps/lsof, a throwaway tmpdir, a short stop wait)
  local inst="$1" h="$2" port="$3" t="$4"; shift 4
  set +e; out="$(HOME="$h" TMPDIR="$t" CANON_COCKPIT_PORT="$port" CANON_STOP_WAIT=3 CANON_HOME= "$inst/tools/canon" uninstall "$@" </dev/null 2>&1)"; rc=$?; set -e
}
if command -v lsof >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  # 1. board + launcher + daemon, no sessions: stopped by the command, runtime state removed, install removed
  inst="$WORK/L1"; h="$WORK/hL1"; t="$WORK/tL1"; mkdir -p "$t"; mk_install "$inst"; mk_home "$h" "$inst"; mk_project "$WORK/pL1" "$h"
  port="$(free_port)"; mk_live "$inst" "$t/canon-cockpit-board" "$port"
  alive "$DPID" && alive "$BPID" && alive "$LPID" || fail "fixture: the stub daemon, board and launcher must be running"
  runl "$inst" "$h" "$port" "$t" --dry-run; assert_eq 0 "$rc"; assert_contains "$out" "will stop: the Cockpit board (pid $BPID, port $port)"; assert_contains "$out" "will stop: the Cockpit daemon (pid $DPID)"
  assert_contains "$out" "will delete: $t/canon-cockpit-board"; refute_contains "$out" "BLOCKED"
  alive "$DPID" && alive "$BPID" && alive "$LPID" || fail "a dry run must not signal anything"
  runl "$inst" "$h" "$port" "$t" --yes; [[ "$rc" == 0 ]] || fail "uninstall with a live board and daemon failed ($rc): $out"
  assert_contains "$out" "[stopped]  the Cockpit daemon (pid $DPID)"; assert_contains "$out" "[stopped]  the Cockpit board (pid $BPID)"
  for pp in "$DPID" "$BPID" "$LPID"; do ! alive "$pp" || fail "pid $pp is still running after the uninstall"; done
  [[ ! -e "$t/canon-cockpit-board" && ! -e "$inst" ]] || fail "the runtime state dir and the install must be gone: $(ls -d "$t"/* "$inst" 2>&1 | tr "\n" " ") :: $out"
  # 2. an orphaned daemon (the board was closed first): stopped through the pid in daemon.json
  inst="$WORK/L2"; h="$WORK/hL2"; t="$WORK/tL2"; mkdir -p "$t"; mk_install "$inst"; mk_home "$h" "$inst"
  mk_live "$inst" "$t/canon-cockpit-board" ""
  runl "$inst" "$h" "$(free_port)" "$t" --yes; [[ "$rc" == 0 ]] || fail "uninstall with an orphaned daemon failed ($rc): $out"
  ! alive "$DPID" || fail "the orphaned daemon is still running"; [[ ! -e "$t/canon-cockpit-board" && ! -e "$inst" ]] || fail "state dir and install must be gone"
  # 3. live agent sessions: refused without --force (nothing signalled, nothing deleted), allowed with it
  inst="$WORK/L3"; h="$WORK/hL3"; t="$WORK/tL3"; mkdir -p "$t"; mk_install "$inst"; mk_home "$h" "$inst"
  port="$(free_port)"; mk_live "$inst" "$t/canon-cockpit-board" "$port"
  printf '[{"sid": "a", "id": "s-1"}, {"sid": "b", "id": "s-2"}]' > "$t/canon-cockpit-board/sessions.json"
  before="$(digest "$inst"; digest "$h")"
  runl "$inst" "$h" "$port" "$t" --yes; assert_eq 1 "$rc"; assert_contains "$out" "2 live agent session(s)"; assert_contains "$out" "Nothing was changed."
  alive "$DPID" && alive "$BPID" || fail "a refusal for live sessions must not signal anything"; assert_eq "$before" "$(digest "$inst"; digest "$h")"; [[ -d "$t/canon-cockpit-board" ]] || fail "state dir must survive a refusal"
  runl "$inst" "$h" "$port" "$t" --yes --force; [[ "$rc" == 0 ]] || fail "--force must end the sessions and proceed ($rc): $out"; ! alive "$DPID" || fail "--force left the daemon running"
  # 4a. daemon.json naming an UNRELATED live process: never signalled; the other process's state dir is kept; the rest proceeds
  inst="$WORK/L4"; h="$WORK/hL4"; t="$WORK/tL4"; mkdir -p "$t/canon-cockpit-board"; mk_install "$inst"; mk_home "$h" "$inst"
  ( exec sleep 120 ) & other=$!; killlist+=("$other")
  printf '{"addr": "x", "token": "t", "pid": "%s"}' "$other" > "$t/canon-cockpit-board/daemon.json"
  runl "$inst" "$h" "$(free_port)" "$t" --yes; [[ "$rc" == 0 ]] || fail "an unrelated pid in daemon.json must not block ($rc): $out"
  alive "$other" || fail "an unrelated process named by daemon.json was signalled"; [[ -f "$t/canon-cockpit-board/daemon.json" ]] || fail "a state dir used by a foreign daemon must be kept"
  assert_contains "$out" "a daemon of another install is still using it"; kill "$other" 2>/dev/null || true
  # 4b. a listener on the port that is NOT this install's board: refuse, never signal
  inst="$WORK/L5"; h="$WORK/hL5"; t="$WORK/tL5"; mkdir -p "$t"; mk_install "$inst"; mk_home "$h" "$inst"; port="$(free_port)"
  mkdir -p "$WORK/foreign"; cp "$WORK/bstub.py" "$WORK/foreign/server.py"
  ( exec python3 "$WORK/foreign/server.py" "$port" ) & fb=$!; killlist+=("$fb"); for _ in $(seq 1 50); do curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$port/" && break; sleep 0.1; done
  before="$(digest "$inst"; digest "$h")"; runl "$inst" "$h" "$port" "$t" --yes
  assert_eq 1 "$rc"; assert_contains "$out" "is not this install's board"; alive "$fb" || fail "a foreign listener was signalled"; assert_eq "$before" "$(digest "$inst"; digest "$h")"; kill "$fb" 2>/dev/null || true
  # 5. a daemon that ignores SIGTERM: reported by pid, nothing deleted, no SIGKILL
  inst="$WORK/L6"; h="$WORK/hL6"; t="$WORK/tL6"; mkdir -p "$t"; mk_install "$inst"; mk_home "$h" "$inst"
  mk_live "$inst" "$t/canon-cockpit-board" "" ignore-term; before="$(digest "$inst"; digest "$h")"
  set +e; out="$(HOME="$h" TMPDIR="$t" CANON_COCKPIT_PORT="$(free_port)" CANON_STOP_WAIT=1 CANON_HOME= "$inst/tools/canon" uninstall --yes </dev/null 2>&1)"; rc=$?; set -e
  assert_eq 1 "$rc"; assert_contains "$out" "the Cockpit daemon (pid $DPID) did not exit within 1s; nothing was deleted"; alive "$DPID" || fail "no SIGKILL: the stuck daemon must still be there"
  assert_eq "$before" "$(digest "$inst"; digest "$h")"; kill -9 "$DPID" 2>/dev/null || true
  # 6. another process from the install folder still blocks, and nothing is signalled before that refusal
  inst="$WORK/L7"; h="$WORK/hL7"; t="$WORK/tL7"; mkdir -p "$t"; mk_install "$inst"; mk_home "$h" "$inst"
  mk_live "$inst" "$t/canon-cockpit-board" ""; ( exec -a "$inst/tools/fake-helper" sleep 120 ) & fh=$!; killlist+=("$fh"); sleep 0.3
  runl "$inst" "$h" "$(free_port)" "$t" --yes; assert_eq 1 "$rc"; assert_contains "$out" "fake-helper"; alive "$DPID" || fail "nothing may be signalled while another install process blocks"; kill "$DPID" "$fh" 2>/dev/null || true
  # 7. state-dir guards: a dir that is not named like a Cockpit state dir, or has no state file, is never removed
  inst="$WORK/L8"; h="$WORK/hL8"; t="$WORK/tL8"; mkdir -p "$t/canon-cockpit-board" "$WORK/odd-dir"; mk_install "$inst"; mk_home "$h" "$inst"
  echo x > "$t/canon-cockpit-board/unrelated.txt"; printf '{}' > "$WORK/odd-dir/daemon.json"
  set +e; out="$(HOME="$h" TMPDIR="$t" COCKPIT_STATE_DIR="$WORK/odd-dir" CANON_COCKPIT_PORT="$(free_port)" CANON_HOME= "$inst/tools/canon" uninstall --yes </dev/null 2>&1)"; rc=$?; set -e
  [[ "$rc" == 0 ]] || fail "state-dir guard run failed ($rc): $out"; [[ -f "$WORK/odd-dir/daemon.json" && -f "$t/canon-cockpit-board/unrelated.txt" ]] || fail "a misnamed or state-file-less dir was removed"
  assert_contains "$out" "not named like a Cockpit state dir"; assert_contains "$out" "no Cockpit state file in it"
  # 8. a recycled pid: the probe verified a pid, and by the time of the signal it belongs to something else (the prompt sits in between). stop_verified
  #    re-verifies at the signal and must not touch it.
  (
    INSTALL="$WORK/L-rec"; PORT=1; HOME="$WORK/hrec"; mkdir -p "$INSTALL"
    source "$ROOT/tools/platform-lib.sh"; source "$ROOT/tools/cockpit-stop-lib.sh"
    ( exec sleep 120 ) & v=$!
    stop_verified "$v" daemon || fail "an unrelated process must not count as a failed stop"; alive "$v" || fail "a recycled pid was signalled (daemon)"
    stop_verified "$v" board || fail "an unrelated process must not count as a failed stop (board)"; alive "$v" || fail "a recycled pid was signalled (board)"
    kill "$v" 2>/dev/null || true
    # the foreign-dir list matches whole lines only: a dir that is merely the tail of a foreign one is not "used by another install"
    DAEMON_FOREIGN_DIRS=$'/var/tmp/canon-cockpit-board\n'
    _foreign_uses "/var/tmp/canon-cockpit-board" || fail "an exact foreign dir must match"
    ! _foreign_uses "/tmp/canon-cockpit-board" || fail "a dir that is only the tail of a foreign dir must not match"
  )
  # 9. a zombie daemon: the board never reaps the daemon it spawned, so a stopped daemon lingers as a defunct child of a live parent. That is gone, not stuck.
  cat > "$WORK/zparent.py" <<'PY'
import os, subprocess, sys, time
d, stub, state = os.environ["DPATH"], sys.argv[1], sys.argv[2]   # the install path is passed by environment: argv would make the parent itself an install-folder process
subprocess.Popen(["bash", "-c", 'exec -a "$0" bash "$1" "$2"', d, stub, state])
time.sleep(300)
PY
  inst="$WORK/L9"; h="$WORK/hL9"; t="$WORK/tL9"; mkdir -p "$t/canon-cockpit-board"; mk_install "$inst"; mk_home "$h" "$inst"
  ( exec env DPATH="$inst/tools/cockpit-daemon/cockpit-daemon" python3 "$WORK/zparent.py" "$WORK/dstub.sh" "$t/canon-cockpit-board" ) & zp=$!; killlist+=("$zp")
  for _ in $(seq 1 50); do [ -f "$t/canon-cockpit-board/daemon.json" ] && break; sleep 0.1; done
  zd="$(sed -n 's/.*"pid": "\([0-9]*\)".*/\1/p' "$t/canon-cockpit-board/daemon.json")"; killlist+=("$zd")
  # (the zombie check on its own: a TERMed child whose parent never reaps it must read as no process at all, independent of the identity re-check)
  kill -TERM "$zd"; sleep 0.5
  ( INSTALL="$inst"; PORT=1; HOME="$h"; source "$ROOT/tools/platform-lib.sh"; source "$ROOT/tools/cockpit-stop-lib.sh"
    [[ -z "$(_proc_ident "$zd")" ]] || fail "a zombie (exited, not reaped) must read as gone, saw: $(_proc_ident "$zd")" )
  mkdir -p "$t/canon-cockpit-board"; printf '{"pid": "%s"}' "$zd" > "$t/canon-cockpit-board/daemon.json"   # (a stale record of the now-dead daemon)
  runl "$inst" "$h" "$(free_port)" "$t" --yes; [[ "$rc" == 0 ]] || fail "a daemon that becomes a zombie must count as stopped ($rc): $out"
  [[ ! -e "$inst" ]] || fail "the install must be removed once the zombie daemon is gone"; alive "$zp" || fail "the (non-install) parent of the daemon must be left alone"; kill "$zp" 2>/dev/null || true
  # 10. an install path with a space, and another install whose folder merely shares this one's name as a prefix
  inst="$WORK/sp ace/L10"; h="$WORK/hL10"; t="$WORK/tL10"; mkdir -p "$t"; mk_install "$inst"; mk_home "$h" "$inst"
  mk_live "$inst" "$t/canon-cockpit-board" ""; runl "$inst" "$h" "$(free_port)" "$t" --yes; [[ "$rc" == 0 ]] || fail "an install path with a space failed ($rc): $out"; ! alive "$DPID" || fail "the daemon under a spaced path was not stopped"
  inst="$WORK/L11"; instx="$WORK/L11x"; h="$WORK/hL11"; t="$WORK/tL11"; mkdir -p "$t"; mk_install "$inst"; mk_install "$instx"; mk_home "$h" "$inst"
  mk_live "$instx" "$t/canon-cockpit-board" ""; runl "$inst" "$h" "$(free_port)" "$t" --yes; [[ "$rc" == 0 ]] || fail "uninstalling L11 failed ($rc): $out"
  alive "$DPID" || fail "the daemon of an install whose folder starts with this one's name (L11x) was signalled"; [[ -f "$t/canon-cockpit-board/daemon.json" ]] || fail "another install's state must be kept"; kill "$DPID" 2>/dev/null || true
  # 11. two state dirs, each used by a live daemon of another install: both are kept (the guard keeps a list, not the last hit)
  inst="$WORK/L12"; h="$WORK/hL12"; t="$WORK/tL12"; mkdir -p "$t/canon-cockpit-board" "$WORK/f12/canon-cockpit-board"; mk_install "$inst"; mk_home "$h" "$inst"
  ( exec sleep 120 ) & o1=$!; ( exec sleep 120 ) & o2=$!; killlist+=("$o1" "$o2")
  printf '{"pid": "%s"}' "$o1" > "$WORK/f12/canon-cockpit-board/daemon.json"; printf '{"pid": "%s"}' "$o2" > "$t/canon-cockpit-board/daemon.json"
  set +e; out="$(HOME="$h" TMPDIR="$t" COCKPIT_STATE_DIR="$WORK/f12/canon-cockpit-board" CANON_COCKPIT_PORT="$(free_port)" CANON_HOME= "$inst/tools/canon" uninstall --yes </dev/null 2>&1)"; rc=$?; set -e
  [[ "$rc" == 0 ]] || fail "two foreign state dirs run failed ($rc): $out"; [[ -f "$WORK/f12/canon-cockpit-board/daemon.json" && -f "$t/canon-cockpit-board/daemon.json" ]] || fail "both foreign-used state dirs must be kept"
  kill "$o1" "$o2" 2>/dev/null || true
  # 12. CANON_STOP_WAIT=08: a leading zero is invalid octal in $(( )) and used to skip the whole stop block silently, deleting the install with the
  #     Cockpit still running. It must stop the daemon (or refuse), never delete around a live process.
  inst="$WORK/L13"; h="$WORK/hL13"; t="$WORK/tL13"; mkdir -p "$t"; mk_install "$inst"; mk_home "$h" "$inst"; port="$(free_port)"; mk_live "$inst" "$t/canon-cockpit-board" "$port"
  set +e; out="$(HOME="$h" TMPDIR="$t" CANON_COCKPIT_PORT="$port" CANON_STOP_WAIT=08 CANON_HOME= "$inst/tools/canon" uninstall --yes </dev/null 2>&1)"; rc=$?; set -e
  [[ "$rc" == 0 ]] || fail "CANON_STOP_WAIT=08 broke the uninstall ($rc): $out"
  ! alive "$DPID" && ! alive "$BPID" || fail "CANON_STOP_WAIT=08 skipped part of the stop: the board is still running while the install was removed"
  # 13. the world changes while the confirmation prompt is open: a live session appears after the plan was printed. The prompt only exists on a
  #     terminal, so a pty drives it; the command must decide again after 'yes' and refuse, signalling nothing.
  cat > "$WORK/ptydrive.py" <<'PY'
import os, pty, select, sys, time
canon, state = sys.argv[1], sys.argv[2]
pid, fd = pty.fork()
if pid == 0:
    os.execv(canon, [canon, "uninstall"])
buf = b""; deadline = time.time() + 30; sent = False
while time.time() < deadline:
    r, _, _ = select.select([fd], [], [], 0.5)
    if r:
        try: chunk = os.read(fd, 4096)
        except OSError: break
        if not chunk: break
        buf += chunk
    if not sent and b"Type yes to continue" in buf:
        with open(os.path.join(state, "sessions.json"), "w") as f: f.write('[{"sid": "late", "id": "s-9"}]')
        os.write(fd, b"yes\n"); sent = True
_, status = os.waitpid(pid, 0)
sys.stdout.write(buf.decode("utf-8", "replace")); sys.stdout.write("\nEXIT=%d\n" % (os.waitstatus_to_exitcode(status) if hasattr(os, "waitstatus_to_exitcode") else (status >> 8)))
PY
  inst="$WORK/L14"; h="$WORK/hL14"; t="$WORK/tL14"; mkdir -p "$t"; mk_install "$inst"; mk_home "$h" "$inst"; mk_live "$inst" "$t/canon-cockpit-board" ""
  before="$(digest "$inst"; digest "$h")"
  out="$(HOME="$h" TMPDIR="$t" CANON_COCKPIT_PORT="$(free_port)" CANON_STOP_WAIT=3 CANON_HOME= python3 "$WORK/ptydrive.py" "$inst/tools/canon" "$t/canon-cockpit-board" 2>&1)" || true
  assert_contains "$out" "EXIT=1"; assert_contains "$out" "1 live agent session(s)"; alive "$DPID" || fail "a session that appeared during the prompt was ended without --force"
  assert_eq "$before" "$(digest "$inst"; digest "$h")"; kill "$DPID" 2>/dev/null || true
else
  echo "canon-uninstall: lsof or python3 missing; live-process cases skipped (reported, not hidden)"
fi

# a failing project cleanup stops the run before the data and the install folder are touched
inst="$WORK/i19"; h="$WORK/h19"; mk_install "$inst"; mk_home "$h" "$inst"; mk_project "$WORK/p19" "$h"; mkdir -p "$h/.canon/cockpit"; echo d > "$h/.canon/cockpit/f"
printf '#!/usr/bin/env bash\necho "skills.sh boom" >&2; exit 1\n' > "$inst/tools/skills.sh"
before="$(digest "$inst"; digest "$h"; digest "$WORK/p19")"
mkdir -p "$TMPDIR/canon-cockpit-board/hooks"   # the daemon's runtime state: it goes with the data, so a failed project cleanup must leave it too (t-70a2)
run "$h" "$inst" --yes; assert_eq 1 "$rc"; assert_contains "$out" "skills.sh uninstall failed; the Cockpit data and the install folder were left in place"
assert_eq "$before" "$(digest "$inst"; digest "$h"; digest "$WORK/p19")"
[[ -d "$TMPDIR/canon-cockpit-board/hooks" ]] || fail "a failed project cleanup must not have deleted the Cockpit runtime state"; rm -rf "$TMPDIR/canon-cockpit-board"

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
# t-70a2, Windows identity rules: a process is this install's daemon or board only by the EXACT exe path (case-insensitive); another exe in the
# same folder, a longer name, another install whose folder merely shares the prefix, and a process elsewhere are all someone else's.
(
  export PATH="$STUBS:$PATH"; INSTALL="$WORK/i15"; PORT=1; HOME="$WORK/hx"
  source "$ROOT/tools/platform-lib.sh"; source "$ROOT/tools/cockpit-stop-lib.sh"
  w="C:$(printf '%s' "$INSTALL" | tr '/' '\\')"
  _is_our_daemon "$w\\tools\\cockpit-daemon-win.exe" || fail "the install's own daemon exe must be recognised"
  _is_our_daemon "$(printf '%s' "$w" | tr 'a-z' 'A-Z')\\TOOLS\\COCKPIT-DAEMON-WIN.EXE" || fail "Windows paths ignore case"
  ! _is_our_daemon "$w\\tools\\sprint-check-win.exe" || fail "the board exe is not the daemon"
  ! _is_our_daemon "$w\\tools\\cockpit-daemon-win.exe.bak" || fail "a longer name is not the daemon"
  ! _is_our_daemon "${w}x\\tools\\cockpit-daemon-win.exe" || fail "another install whose folder shares the prefix is not ours"
  ! _is_our_daemon "C:\\other\\tools\\cockpit-daemon-win.exe" || fail "a daemon elsewhere is not ours"
  _is_our_board "$w\\tools\\sprint-check-win.exe" || fail "the install's own board exe must be recognised"
  _is_our_board "$(printf '%s' "$w" | tr 'a-z' 'A-Z')\\TOOLS\\SPRINT-CHECK-WIN.EXE" || fail "Windows paths ignore case (board)"
  ! _is_our_board "$w\\tools\\cockpit-daemon-win.exe" || fail "the daemon exe is not the board"
  ! _is_our_board "${w}x\\tools\\sprint-check-win.exe" || fail "another install's board is not ours"
)
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
before="$(digest "$inst"; digest "$h")"; PROCS="4242 C:\\fake\\cockpit-daemon-win.exe" runw --yes; assert_eq 1 "$rc"; assert_contains "$out" "processes are running from $inst"; assert_eq "$before" "$(digest "$inst"; digest "$h")"
runw --yes; [[ "$rc" == 0 ]] || fail "windows branch failed ($rc): $out"
ps="$(cat "$WORK/psargs")"; assert_contains "$ps" "-File"; assert_contains "$ps" "-InstallDir C:$(printf '%s' "$inst" | tr '/' '\\')"; assert_contains "$ps" "-ToolsEntry $winentry"; assert_contains "$ps" "-KeepName cockpit"; assert_contains "$ps" "-KeepCockpit 0"; assert_contains "$ps" "-LogFile"
[[ -d "$inst/tools" ]] || fail "on Windows bash must leave the install folder for the PowerShell helper"
assert_eq 1 "$(grep -c "cleaned $WORK/p15" "$WORK/stub.log")"; refute_contains "$(cat "$WORK/stub.log")" "cleaned C:"   # the portable steps ran first, once per project

# ── the PowerShell tail: structure always, the PATH logic when pwsh exists ──────────────────────────────────────────────────────────────────
ps1="$ROOT/tools/canon-uninstall.ps1"
grep -q 'function Remove-PathEntry' "$ps1" && grep -q "Test-CanonInstall" "$ps1" && grep -q "User PATH before:" "$ps1" || fail "canon-uninstall.ps1 lost a load-bearing piece"
grep -q '"`"$helper`""' "$ps1" && grep -q '"`"$InstallDir`""' "$ps1" || fail "canon-uninstall.ps1 must quote the helper arguments (Start-Process does not; a profile path with a space breaks)"
grep -q 'no such entry' "$ps1" || fail "Remove-PathEntry must leave the PATH byte-identical when the entry is absent"
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

[[ "$(real_state_sig)" == "$REAL_STATE_BEFORE" ]] || fail "this test changed the real Cockpit state dir ($REAL_TMP/canon-cockpit-board): it must stay hermetic"
echo "canon-uninstall: ok (dry-run and refusals change nothing, safety rule, keep-data, both registries, blockers, rc report-only, Windows branch against stubs, real skills.sh uninstall, idempotent, docs)"
