#!/usr/bin/env bash
# cockpit-stop-lib.sh — find and stop THIS install's Cockpit board and daemon, and clear their runtime state (t-70a2). Source, don't execute.
#
# The rule: identify a process positively, or leave it alone. Nothing is ever matched by name. The daemon is found through the pid it records in
# daemon.json (in its state dir), the board through whatever listens on its port; both are then checked against their full command line / exe
# path, which must belong to this install. A recycled pid, another install's daemon or an unrelated listener is reported and never signalled.
# Stopping is SIGTERM only (the daemon's handler reaps every agent session cleanly), a bounded wait, and a report if the process stays; there
# is no SIGKILL. On Windows the processes of this install are stopped by exact exe path, as install.ps1 does.
#
# Needs from the caller: INSTALL (the physical install folder), PORT (the board's port), platform-lib.sh already sourced.
# Results: BOARD_STATUS none|ours|foreign|unknown, BOARD_PID, BOARD_FOREIGN; LAUNCHER_PID; DAEMON_STATUS none|ours|foreign, DAEMON_PID,
# DAEMON_FOREIGN_DIR; SESSIONS (live agent sessions recorded by the daemon).

CANON_STOP_WAIT="${CANON_STOP_WAIT:-8}"
BOARD_STATUS=none; BOARD_PID=""; BOARD_FOREIGN=""; LAUNCHER_PID=""
DAEMON_STATUS=none; DAEMON_PID=""; DAEMON_FOREIGN_DIR=""; DAEMON_DIR_OF_OURS=""; SESSIONS=0

# Every place a daemon or board may keep its runtime state: the board's dir (server.py `_cockpit_state_dir`: <tmp>/canon-cockpit-board), an
# explicit COCKPIT_STATE_DIR, and the daemon's own default (main.go `defaultStateDir`).
cockpit_state_dirs() {
  local tmp="${TMPDIR:-${TEMP:-/tmp}}"
  if _is_windows && command -v cygpath >/dev/null 2>&1 && [ -n "${TEMP:-}" ]; then tmp="$(cygpath -u "$TEMP" 2>/dev/null)" || tmp="${TMPDIR:-/tmp}"; fi
  tmp="${tmp%/}"
  if [ -n "${COCKPIT_STATE_DIR:-}" ]; then printf '%s\n' "${COCKPIT_STATE_DIR%/}"; fi
  printf '%s\n' "$tmp/canon-cockpit-board"
  if [ -n "${XDG_RUNTIME_DIR:-}" ]; then printf '%s\n' "${XDG_RUNTIME_DIR%/}/canon-cockpit"; fi
  case "$(uname -s)" in
    Darwin) printf '%s\n' "$HOME/Library/Caches/canon-cockpit" ;;
    *) printf '%s\n' "${XDG_CACHE_HOME:-$HOME/.cache}/canon-cockpit" ;;
  esac
}
_state_dir_name_ok() { case "$(basename "$1")" in canon-cockpit-board|canon-cockpit) return 0 ;; *) return 1 ;; esac; }
# A cockpit state dir is recognised by what the daemon and board put in it. A cleanly stopped daemon removes its own daemon.json, so the dir's
# own layout (hooks/ and scratch/, as seen on a real install after a clean stop) counts too, and so does an empty dir of that exact name.
_has_state_file() { [ -f "$1/daemon.json" ] || [ -f "$1/sessions.json" ] || [ -f "$1/interrupted.json" ] || [ -d "$1/hooks" ] || [ -d "$1/scratch" ] || [ -z "$(ls -A "$1" 2>/dev/null)" ]; }

# What a process is, as one string: its full command line (Unix) or its exe path (Windows). Empty when it does not exist.
_win_install() { cygpath -w "$INSTALL" 2>/dev/null; }
_proc_ident() {
  if _is_windows && command -v powershell.exe >/dev/null 2>&1; then
    powershell.exe -NoProfile -Command "(Get-Process -Id $1 -ErrorAction SilentlyContinue).Path" 2>/dev/null | tr -d '\r' | sed '/^[[:space:]]*$/d' | head -1 || true
  else
    ps -o command= -p "$1" 2>/dev/null | sed 's/^ *//' || true
  fi
}
_is_our_daemon() { # <ident>
  if _is_windows; then
    local w; w="$(_win_install)"
    case "$(printf '%s' "$1" | tr 'A-Z' 'a-z')" in "$(printf '%s' "$w" | tr 'A-Z' 'a-z')\\tools\\cockpit-daemon-win.exe"|"$(printf '%s' "$w" | tr 'A-Z' 'a-z')\\tools\\cockpit-daemon\\cockpit-daemon.exe") return 0 ;; esac
    return 1
  fi
  case "$1" in "$INSTALL/tools/cockpit-daemon/cockpit-daemon"|"$INSTALL/tools/cockpit-daemon/cockpit-daemon "*) return 0 ;; esac
  return 1
}
_is_our_board() { # <ident>
  if _is_windows; then
    local w; w="$(_win_install)"
    [ "$(printf '%s' "$1" | tr 'A-Z' 'a-z')" = "$(printf '%s' "$w" | tr 'A-Z' 'a-z')\\tools\\sprint-check-win.exe" ]; return
  fi
  case "$1" in *" $INSTALL/tools/sprint-check-app/server.py"|*" $INSTALL/tools/sprint-check-app/server.py "*) return 0 ;; esac
  return 1
}
_pid_alive() { kill -0 "$1" 2>/dev/null; }

# The daemon: the pid it wrote into daemon.json, checked against this install.
probe_daemon() {
  DAEMON_STATUS=none; DAEMON_PID=""; DAEMON_FOREIGN_DIR=""; DAEMON_DIR_OF_OURS=""; SESSIONS=0
  local d pid ident
  while IFS= read -r d; do
    [ -f "$d/daemon.json" ] || continue
    pid="$(sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*"\{0,1\}\([0-9][0-9]*\).*/\1/p' "$d/daemon.json" 2>/dev/null | head -1)" || pid=""
    [ -n "$pid" ] || continue
    ident="$(_proc_ident "$pid")"
    [ -n "$ident" ] || continue                      # no such process: a stale file, nothing to stop
    if _is_our_daemon "$ident"; then DAEMON_STATUS=ours; DAEMON_PID="$pid"; DAEMON_DIR_OF_OURS="$d"
      if [ -f "$d/sessions.json" ]; then SESSIONS="$(grep -o '"sid"' "$d/sessions.json" 2>/dev/null | wc -l | tr -d ' ')" || SESSIONS=0; fi
    else DAEMON_FOREIGN_DIR="$d"; [ "$DAEMON_STATUS" = ours ] || DAEMON_STATUS=foreign; fi
  done < <(cockpit_state_dirs | awk '!seen[$0]++')
}

# The board: whatever listens on its port. Ours only if its command line is this install's server.py (or, on Windows, its exe).
probe_board() {
  BOARD_STATUS=none; BOARD_PID=""; BOARD_FOREIGN=""; LAUNCHER_PID=""
  local pids="" p ident
  if _is_windows; then
    command -v powershell.exe >/dev/null 2>&1 || { board_up && BOARD_STATUS=unknown; return 0; }
    pids="$(powershell.exe -NoProfile -Command "Get-NetTCPConnection -LocalPort $PORT -State Listen -ErrorAction SilentlyContinue | ForEach-Object { \$_.OwningProcess } | Sort-Object -Unique" 2>/dev/null | tr -d '\r' | sed '/^[[:space:]]*$/d')" || pids=""
  elif command -v lsof >/dev/null 2>&1; then
    pids="$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | sort -u)" || pids=""
  elif command -v ss >/dev/null 2>&1; then
    pids="$(ss -ltnpH "sport = :$PORT" 2>/dev/null | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | sort -u)" || pids=""
  else
    board_up && BOARD_STATUS=unknown                 # something answers but nothing can say who: never guess
    return 0
  fi
  if [ -z "$pids" ]; then board_up && BOARD_STATUS=unknown; return 0; fi
  for p in $pids; do
    ident="$(_proc_ident "$p")"
    if _is_our_board "$ident"; then BOARD_STATUS=ours; BOARD_PID="$p"
    else BOARD_STATUS=foreign; BOARD_FOREIGN="$p ${ident:-?}"; return 0; fi
  done
  # the terminal's `canon` launcher is the board's parent; it exits on its own once the board is gone
  if ! _is_windows && [ -n "$BOARD_PID" ]; then
    local pp; pp="$(ps -o ppid= -p "$BOARD_PID" 2>/dev/null | tr -d ' ')" || pp=""
    if [ -n "$pp" ]; then
      ident="$(_proc_ident "$pp")"
      case "$ident" in "bash $INSTALL/tools/canon"|"bash $INSTALL/tools/canon "*|"$INSTALL/tools/canon"|"$INSTALL/tools/canon "*) LAUNCHER_PID="$pp" ;; esac
    fi
  fi
}

# Stop one verified process: SIGTERM (Windows: Stop-Process), then wait up to CANON_STOP_WAIT seconds. 0 = gone, 1 = still running.
stop_verified() { # <pid> <what>
  local pid="$1" waited=0 ident
  ident="$(_proc_ident "$pid")"; [ -n "$ident" ] || return 0     # already gone
  if _is_windows; then powershell.exe -NoProfile -Command "Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue" >/dev/null 2>&1 || true
  else kill -TERM "$pid" 2>/dev/null || true; fi
  while [ "$waited" -lt $((CANON_STOP_WAIT * 5)) ]; do
    [ -n "$(_proc_ident "$pid")" ] || return 0
    sleep 0.2; waited=$((waited + 1))
  done
  return 1
}

# Remove the runtime state dirs: only a dir with the exact name of a cockpit state dir that holds a cockpit state file, and never one a live
# daemon of another install still uses. Prints one line per dir.
remove_state_dirs() {
  local d
  while IFS= read -r d; do
    [ -d "$d" ] || continue
    if ! _state_dir_name_ok "$d"; then echo "  [kept]  $d (not named like a Cockpit state dir; left alone)"; continue; fi
    if ! _has_state_file "$d"; then echo "  [kept]  $d (no Cockpit state file in it; left alone)"; continue; fi
    if [ "$DAEMON_FOREIGN_DIR" = "$d" ]; then echo "  [kept]  $d (a daemon of another install is still using it)"; continue; fi
    rm -rf -- "$d" && echo "  [removed]  $d" || echo "  [fail]  could not remove $d" >&2
  done < <(cockpit_state_dirs | awk '!seen[$0]++')
}
state_dirs_to_remove() { # the dirs remove_state_dirs would delete, for the plan
  local d
  while IFS= read -r d; do
    [ -d "$d" ] && _state_dir_name_ok "$d" && _has_state_file "$d" && [ "$DAEMON_FOREIGN_DIR" != "$d" ] && printf '%s\n' "$d"
  done < <(cockpit_state_dirs | awk '!seen[$0]++')
  return 0
}
