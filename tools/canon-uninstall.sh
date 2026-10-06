#!/usr/bin/env bash
# canon-uninstall.sh — `canon uninstall` (t-3897). Plan first, confirm, then remove canon from this machine.
#
# Destructive, so: nothing is written until the plan is printed and confirmed; anything doubtful REFUSES and says why (a dirty or unpushed git
# clone is never deleted: the exact manual `rm -rf` is printed instead, even with --yes); a running board or any process started from the install
# folder blocks the run (never killed by name; Windows locks those files). `skills.sh uninstall` does the per-project work (hooks, symlinks,
# imports, registrations); this script adds the daemon stop, the data and install-folder removal, empty .claude/.agents folders, and on Windows
# the user PATH entry (tools/canon-uninstall.ps1, run detached after this process exits). Shell rc lines are reported, never edited (t-f01d).
#
# Usage: canon uninstall [--dry-run] [--yes] [--keep-data] [--force]
# Exit: 0 done / dry-run / nothing to do, 1 refused or failed, 2 usage or no terminal and no --yes.
set -euo pipefail

# Bumped on every change to this command, and shown in the plan and --help, so a stale copy of the script is obvious on a machine that was updated by hand.
UNINSTALL_REV=9
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
INSTALL="$(cd "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=platform-lib.sh
source "$SCRIPT_DIR/platform-lib.sh"
# shellcheck source=cockpit-stop-lib.sh
source "$SCRIPT_DIR/cockpit-stop-lib.sh"

usage() {
  echo "canon uninstall — remove canon from this machine   [uninstall rev $UNINSTALL_REV]"
  cat <<'EOF'

Usage: canon uninstall [--dry-run] [--yes] [--keep-data] [--force]

  --dry-run    Print what would be removed and change nothing
  --yes        Skip the confirmation prompt (never overrides a refusal)
  --keep-data  Keep the Cockpit data (~/.canon/cockpit: project registrations and the
               restore snapshots of projects without git) and the skills registrations
  --force      Also end live agent sessions (without it, running sessions make the uninstall refuse)

With no terminal and no --yes it prints the plan and exits 2 without changing anything.
It stops this install's Cockpit board and daemon itself (found by their recorded pid or port and
verified against this install; never by name). Anything else running from the install folder still blocks it.
EOF
}

dry=0; yes=0; keep=0; force=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry=1 ;;
    --yes|-y) yes=1 ;;
    --keep-data) keep=1 ;;
    --force) force=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "canon uninstall: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

[ -n "${HOME:-}" ] && [ -d "$HOME" ] || { echo "canon uninstall: HOME is not set to an existing folder." >&2; exit 1; }
HOME_P="$(cd "$HOME" && pwd -P)"
CONFIG_DIR="$HOME/.config/canon"
DATA_ROOT="${CANON_HOME:-$HOME/.canon}"
DATA_DIR="$DATA_ROOT/cockpit"
PORT="${CANON_COCKPIT_PORT:-8899}"

# ── the install-folder safety rule ──────────────────────────────────────────────────────────────────────────────────────────────────────────
# Sets VERDICT=ok|refuse and VERDICT_WHY. A folder is deleted only when every check passes; a git clone only when clean and fully pushed.
VERDICT=refuse; VERDICT_WHY=""
install_verdict() {
  VERDICT=refuse
  case "$INSTALL" in /*) ;; *) VERDICT_WHY="the install path is not absolute"; return 0 ;; esac
  if [ "$INSTALL" = "/" ]; then VERDICT_WHY="the install folder resolves to /"; return 0; fi
  if [ "$INSTALL" = "$HOME_P" ]; then VERDICT_WHY="the install folder is your home folder"; return 0; fi
  case "$HOME_P/" in "$INSTALL"/*) VERDICT_WHY="the install folder contains your home folder"; return 0 ;; esac
  if [ ! -f "$INSTALL/tools/canon" ] || [ ! -f "$INSTALL/tools/skills.sh" ]; then
    VERDICT_WHY="it does not look like a canon install (tools/canon or tools/skills.sh is missing)"; return 0
  fi
  local ip="$CONFIG_DIR/install_path" rec
  if [ -f "$ip" ]; then
    rec="$(cd "$(cat "$ip")" 2>/dev/null && pwd -P)" || rec=""
    if [ "$rec" != "$INSTALL" ]; then VERDICT_WHY="~/.config/canon/install_path names a different folder ($(cat "$ip"))"; return 0; fi
  fi
  if [ -e "$INSTALL/.git" ]; then
    local dirty up ahead excl=""
    # The Cockpit data dir may live inside the clone (the default); it is not clone state.
    case "$DATA_DIR" in "$INSTALL"/*) excl=":(exclude)${DATA_DIR#"$INSTALL"/}" ;; esac
    if [ -n "$excl" ]; then dirty="$(git -C "$INSTALL" status --porcelain -- . "$excl" 2>/dev/null)" || dirty="?"
    else dirty="$(git -C "$INSTALL" status --porcelain 2>/dev/null)" || dirty="?"; fi
    if [ -n "$dirty" ]; then VERDICT_WHY="the git clone has uncommitted or untracked changes"; return 0; fi
    up="$(git -C "$INSTALL" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)" || up=""
    if [ -z "$up" ]; then VERDICT_WHY="the git clone has no upstream branch, so unpushed work cannot be ruled out"; return 0; fi
    ahead="$(git -C "$INSTALL" rev-list --count '@{u}..HEAD' 2>/dev/null)" || ahead="?"
    if [ "$ahead" != 0 ]; then VERDICT_WHY="the git clone has $ahead commit(s) not on its upstream ($up, as last fetched)"; return 0; fi
    # Work that is not in the working tree or on HEAD's upstream, and that deleting the clone would lose.
    local other
    other="$(git -C "$INSTALL" rev-list --branches --not --remotes 2>/dev/null | head -1)" || other="?"
    if [ -n "$other" ]; then VERDICT_WHY="the git clone has a local branch with commits that are on no remote"; return 0; fi
    if git -C "$INSTALL" rev-parse -q --verify refs/stash >/dev/null 2>&1; then VERDICT_WHY="the git clone has stashed changes"; return 0; fi
    if [ "$(git -C "$INSTALL" worktree list --porcelain 2>/dev/null | grep -c '^worktree ')" -gt 1 ]; then VERDICT_WHY="the git clone has linked worktrees (they would be left pointing at a deleted folder)"; return 0; fi
    if [ -n "$(git -C "$INSTALL" ls-files -v 2>/dev/null | grep -m1 '^[Sh] ')" ]; then VERDICT_WHY="the git clone has local edits hidden with skip-worktree or assume-unchanged"; return 0; fi
  fi
  VERDICT=ok; VERDICT_WHY=""
}

# ── what is registered, running, stored ─────────────────────────────────────────────────────────────────────────────────────────────────────
# Both registries: skills.sh's ~/.config/canon/projects (Git Bash paths such as /c/Users/x) and the Cockpit's projects.json (JSON-escaped, and on Windows
# C:\Users\x): the same project can appear in both spellings, so every path is brought to the Git Bash form first, and the dedupe ignores case on Windows.
normalize_path() {
  local p="$1" q
  if _is_windows && command -v cygpath >/dev/null 2>&1; then
    case "$p" in [A-Za-z]:[\\/]*) if q="$(cygpath -u "$p" 2>/dev/null)" && [ -n "$q" ]; then p="$q"; fi ;; esac
  fi
  printf '%s\n' "$p"
}
projects_union() {
  local raw p
  raw="$({ [ -f "$CONFIG_DIR/projects" ] && cat "$CONFIG_DIR/projects" || true
    if [ -f "$DATA_DIR/projects.json" ]; then
      grep -oE '"path"[[:space:]]*:[[:space:]]*"([^"\\]|\\.)*"' "$DATA_DIR/projects.json" | while IFS= read -r line; do
        p="${line#*\"path\"}"; p="${p#*\"}"; p="${p%\"}"
        p="${p//\\\"/\"}"; p="${p//\\\//\/}"; p="${p//\\\\/\\}"
        printf '%s\n' "$p"
      done || true
    fi; } | sed '/^[[:space:]]*$/d' | sed 's/\r$//')"
  [ -n "$raw" ] || return 0
  printf '%s\n' "$raw" | while IFS= read -r p; do normalize_path "$p"; done | if _is_windows; then awk '!seen[tolower($0)]++' | sort; else sort -u; fi
}

# Processes whose command line mentions the install folder, excluding this script and its ancestors. Printed as "pid command".
install_processes() {
  if _is_windows && command -v powershell.exe >/dev/null 2>&1; then
    # Git Bash's ps has no -axo: ask Windows for the processes whose executable lives in the install folder (it locks those files), as install.ps1 does
    local win; win="$(cygpath -w "$INSTALL")"
    powershell.exe -NoProfile -Command "Get-Process -ErrorAction SilentlyContinue | Where-Object { \$_.Path -and \$_.Path.StartsWith('$win\\', [StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { '{0} {1}' -f \$_.Id, \$_.Path }" 2>/dev/null | tr -d '\r' | sed '/^[[:space:]]*$/d' || true
    return 0
  fi
  local skip=" $$ " pid="$$"
  while [ -n "$pid" ] && [ "$pid" != 0 ] && [ "$pid" != 1 ]; do
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')" || pid=""
    [ -z "$pid" ] || skip="$skip$pid "
  done
  ps -axo pid=,command= 2>/dev/null | while read -r p cmd; do
    case "$skip" in *" $p "*) continue ;; esac
    # this script's own subshells (command substitutions fork with the same command line; bash 3.2 has no $BASHPID to tell them apart)
    case "$cmd" in */canon-uninstall.sh*|*"/tools/canon uninstall"*) continue ;; esac
    case "$cmd" in *"$INSTALL/"*) printf '%s %s\n' "$p" "$cmd" ;; esac
  done || true
}

board_up() { curl -s -o /dev/null --max-time 3 "http://127.0.0.1:$PORT/api/version" 2>/dev/null; }

human_size() { du -sk "$1" 2>/dev/null | awk '{ s=$1; if (s>=1048576) printf "%.1f GB", s/1048576; else if (s>=1024) printf "%.1f MB", s/1024; else printf "%d KB", s }'; }

rc_lines() {  # shell rc files naming <install>/tools: "file:line: text"
  local f
  for f in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile" "$HOME/.bash_profile" "$HOME/.zprofile"; do
    [ -f "$f" ] || continue
    grep -nF "$INSTALL/tools" "$f" 2>/dev/null | sed "s#^#$f:#" || true
  done
}

windows_path_entry() { printf '%s\\tools' "$(cygpath -w "$INSTALL")"; }

user_path_value() { powershell.exe -NoProfile -Command "[Environment]::GetEnvironmentVariable('PATH','User')" 2>/dev/null | tr -d '\r'; }
user_path_has_entry() {  # Windows only: 0 yes, 1 no, 2 cannot tell
  local cur
  cur="$(user_path_value)" || return 2
  [ -n "$cur" ] || return 2
  printf '%s\n' "$cur" | tr ';' '\n' | grep -qixF "$(windows_path_entry)"
}
other_canon_path_entries() {  # user PATH entries that look like canon but are not this install's: reported, never touched
  user_path_value | tr ';' '\n' | grep -i 'canon' | grep -vixF "$(windows_path_entry)" || true
}

# ── the plan ────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
install_verdict
projects="$(projects_union)"
n_projects=0; [ -z "$projects" ] || n_projects="$(printf '%s\n' "$projects" | wc -l | tr -d ' ')"
have_data=0; [ -d "$DATA_DIR" ] && have_data=1
n_snapshots=0
[ "$have_data" = 0 ] || [ ! -d "$DATA_DIR/changes" ] || n_snapshots="$(find "$DATA_DIR/changes" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | wc -l | tr -d ' ')"
data_inside=0; keep_top=cockpit; case "$DATA_DIR" in "$INSTALL"/*) data_inside=1; keep_top="${DATA_DIR#"$INSTALL"/}"; keep_top="${keep_top%%/*}" ;; esac
# The Cockpit board and daemon of THIS install are stopped by the command itself (cockpit-stop-lib.sh); anything else running from the install
# folder still blocks it. A board that answers but cannot be identified as ours (another install, no lsof/ss) keeps the old refusal.
probe_daemon; probe_board
stop_pids=" ${BOARD_PID:-} ${DAEMON_PID:-} ${LAUNCHER_PID:-} "
# (a function, not an inline case: bash 3.2 mis-parses `case ... )` inside $( ))
drop_ours() { local line; while IFS= read -r line; do [ -n "$line" ] || continue; case "$stop_pids" in *" ${line%% *} "*) ;; *) printf '%s\n' "$line" ;; esac; done; }
procs="$(install_processes | drop_ours)" || procs=""
blockers=""
if [ "$DAEMON_STATUS" = ours ] && [ "${SESSIONS:-0}" -gt 0 ] && [ "$force" != 1 ]; then
  blockers="$blockers$SESSIONS live agent session(s) are running in the Cockpit; stopping the daemon ends them. Save & End them in the Cockpit first, or re-run with --force."$'\n'
fi
if [ "$BOARD_STATUS" = foreign ]; then
  blockers="$blockers""port $PORT is held by a process that is not this install's board (${BOARD_FOREIGN}); it is not touched. Stop it yourself, or point CANON_COCKPIT_PORT at this install's port."$'\n'
fi
if [ "$BOARD_STATUS" = unknown ]; then
  blockers="$blockers""something answers on port $PORT but it cannot be identified as this install's Cockpit board; close its window (the terminal running 'canon') and run this again."$'\n'
fi

print_plan() {
  echo "canon uninstall — plan (nothing is changed until you confirm)   [canon $(tr -d '[:space:]' < "$INSTALL/VERSION" 2>/dev/null || echo unknown), uninstall rev $UNINSTALL_REV]"
  echo ""
  echo "Install folder: $INSTALL"
  if [ "$VERDICT" = ok ]; then
    if [ "$keep" = 1 ] && [ "$data_inside" = 1 ]; then echo "  -> DELETE everything in it except $keep_top/ (kept: --keep-data)"
    else echo "  -> DELETE"; fi
  else
    echo "  -> KEEP: $VERDICT_WHY"
    echo "     Remove it yourself when you are sure:  rm -rf \"$INSTALL\""
  fi
  echo ""
  echo "Projects to clean ($n_projects, from ~/.config/canon/projects and the Cockpit registry):"
  if [ -n "$projects" ]; then printf '%s\n' "$projects" | while IFS= read -r p; do
    if [ -d "$p" ]; then echo "  clean   $p"; else echo "  skip    $p (folder missing)"; fi
  done; else echo "  (none)"; fi
  echo "  Per project: canon hooks, skill/agent symlinks, canon imports (via skills.sh uninstall); empty .claude/ and .agents/ folders."
  echo "  Left on purpose: .gitignore canon lines, the .gitattributes canon block, AGENTS.md/CLAUDE.md @ imports, PROMOTED.md, .tickets/."
  echo ""
  echo "Cockpit data: $DATA_DIR"
  if [ "$have_data" = 0 ]; then echo "  (none)"
  elif [ "$keep" = 1 ]; then echo "  -> KEEP (--keep-data): $(human_size "$DATA_DIR"), $n_snapshots restore snapshot(s) of projects without git"
  else echo "  -> DELETE: $(human_size "$DATA_DIR"), including $n_snapshots restore snapshot(s) of projects without git (these cannot be recreated)"; fi
  echo "Config: $CONFIG_DIR  -> $([ "$keep" = 1 ] && echo 'KEEP the skills registrations (--keep-data)' || echo 'removed by skills.sh uninstall')"
  echo ""
  if _is_windows; then
    echo "Windows user PATH entry: $(windows_path_entry)"
    user_path_has_entry && echo "  -> REMOVE (the old PATH value is printed first)" || { [ $? = 1 ] && echo "  (not present)" || echo "  (could not read the user PATH; it will be checked when removing)"; }
    others="$(other_canon_path_entries)"
    if [ -n "$others" ]; then echo "  Other PATH entries that mention canon (a different install or clone; left alone):"; printf '%s\n' "$others" | sed 's/^/    /'; fi
  else
    local rc; rc="$(rc_lines)"
    if [ -n "$rc" ]; then
      echo "Shell rc lines naming $INSTALL/tools (reported, NOT edited):"
      printf '%s\n' "$rc" | sed 's/^/  /'
      echo "  Remove with your editor, or:  sed -i.bak '\\#$INSTALL/tools#d' <file>   (macOS: sed -i '' ...)"
    else echo "Shell rc files: no line names $INSTALL/tools."; fi
  fi
  echo ""
  echo "Cockpit processes:"
  if [ "$BOARD_STATUS" = ours ]; then echo "  will stop: the Cockpit board (pid $BOARD_PID, port $PORT)$([ -n "$LAUNCHER_PID" ] && echo "; the terminal running 'canon' (pid $LAUNCHER_PID) exits with it")"; fi
  if [ "$DAEMON_STATUS" = ours ]; then echo "  will stop: the Cockpit daemon (pid $DAEMON_PID)$([ "${SESSIONS:-0}" -gt 0 ] && echo ", ending $SESSIONS live agent session(s)")"; fi
  if [ "$BOARD_STATUS" != ours ] && [ "$DAEMON_STATUS" != ours ]; then echo "  (none running)"; fi
  rs="$(state_dirs_to_remove)"
  if [ -n "$rs" ]; then echo "Cockpit runtime state (daemon address/token, live-session records):"; printf '%s\n' "$rs" | sed 's/^/  will delete: /'; fi
  echo ""
  if [ -n "$blockers" ]; then printf '%s' "$blockers" | while IFS= read -r b; do echo "BLOCKED: $b"; done; fi
  if [ -n "$procs" ]; then echo "BLOCKED: processes are running from the install folder (not killed by this command):"; printf '%s\n' "$procs" | sed 's/^/  /' | cut -c1-160; fi
}

print_plan
if [ "$dry" = 1 ]; then echo ""; echo "Dry run: nothing was changed."; exit 0; fi

if [ "$yes" != 1 ]; then
  if [ -t 0 ]; then
    printf '\nType yes to continue: '
    read -r answer || answer=""
    [ "$answer" = yes ] || { echo "Nothing was changed."; exit 1; }
  else
    echo ""
    echo "Not a terminal and no --yes: nothing was changed. Re-run with --yes to proceed, or --dry-run to preview."
    exit 2
  fi
fi

echo ""
echo "Working... (nothing below is undone by closing this window; each step prints when it finishes)"
# ── refusals (before any signal or write) ───────────────────────────────────────────────────────────────────────────────────────────────────
if [ -n "$blockers" ]; then
  echo "" >&2
  printf '%s' "$blockers" | while IFS= read -r b; do echo "canon uninstall: $b" >&2; done
  echo "Nothing was changed." >&2
  exit 1
fi
if [ -n "$procs" ]; then
  echo "canon uninstall: processes are running from $INSTALL (not this install's Cockpit board or daemon):" >&2; printf '%s\n' "$procs" | sed 's/^/  /' | cut -c1-160 >&2
  echo "Close them, then run this again. Nothing was changed." >&2
  exit 1
fi

# ── stop the Cockpit ──────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
# Daemon first (its SIGTERM handler ends every agent session cleanly), then the board; a process that will not exit is reported by pid and
# NOTHING is deleted. The `canon` launcher in the board's terminal exits by itself once the board is gone.
echo ""
if [ "$DAEMON_STATUS" = ours ] || [ "$BOARD_STATUS" = ours ]; then
  echo "[1/5] Stopping the Cockpit..."
  if [ "$DAEMON_STATUS" = ours ]; then
    stop_verified "$DAEMON_PID" daemon || { echo "canon uninstall: the Cockpit daemon (pid $DAEMON_PID) did not exit within ${CANON_STOP_WAIT}s; nothing was deleted. Stop it yourself, then run this again." >&2; exit 1; }
    echo "  [stopped]  the Cockpit daemon (pid $DAEMON_PID)"
  fi
  if [ "$BOARD_STATUS" = ours ]; then
    stop_verified "$BOARD_PID" board || { echo "canon uninstall: the Cockpit board (pid $BOARD_PID) did not exit within ${CANON_STOP_WAIT}s; nothing was deleted. Close it yourself, then run this again." >&2; exit 1; }
    echo "  [stopped]  the Cockpit board (pid $BOARD_PID)"
    if [ -n "$LAUNCHER_PID" ]; then
      w=0; while [ "$w" -lt $((CANON_STOP_WAIT * 5)) ] && [ -n "$(_proc_ident "$LAUNCHER_PID")" ]; do sleep 0.2; w=$((w + 1)); done
    fi
  fi
  procs="$(install_processes)"
  if [ -n "$procs" ]; then
    echo "canon uninstall: processes are still running from $INSTALL after the Cockpit was stopped:" >&2; printf '%s\n' "$procs" | sed 's/^/  /' | cut -c1-160 >&2
    echo "Close them, then run this again. Nothing was deleted." >&2
    exit 1
  fi
else
  echo "[1/5] Cockpit board and daemon: not running, nothing to stop."
fi
state_removed="$(remove_state_dirs)"
[ -z "$state_removed" ] || printf '%s\n' "$state_removed"

# ── execute ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
failed=0
echo ""
echo "[2/5] Cleaning $n_projects project(s) with skills.sh uninstall$(_is_windows && echo " (on Windows this can take about 10 seconds per project)")..."
# skills.sh uninstall works from ~/.config/canon/projects: add projects only the Cockpit knows, so they are cleaned too.
if [ -n "$projects" ]; then
  mkdir -p "$CONFIG_DIR"
  printf '%s\n' "$projects" | while IFS= read -r p; do
    grep -qxF "$p" "$CONFIG_DIR/projects" 2>/dev/null || printf '%s\n' "$p" >> "$CONFIG_DIR/projects"
  done
fi
reg_backup=""
if [ "$keep" = 1 ] && [ -f "$CONFIG_DIR/projects" ]; then reg_backup="$(mktemp)"; cp "$CONFIG_DIR/projects" "$reg_backup"; fi
# A failing project cleanup stops the run here: deleting the install folder now would leave project hooks pointing at nothing.
if ! CANON_UNINSTALL_RUNNING=1 SKILLS_SH_NO_TTY=1 bash "$SCRIPT_DIR/skills.sh" uninstall </dev/null; then
  echo "canon uninstall: skills.sh uninstall failed; the Cockpit data and the install folder were left in place. Fix the error above and run this again." >&2
  exit 1
fi
# --keep-data keeps the skills registrations, which skills.sh uninstall deletes along with install_path
if [ -n "$reg_backup" ]; then mkdir -p "$CONFIG_DIR" && cp "$reg_backup" "$CONFIG_DIR/projects" && rm -f "$reg_backup" && echo "  [kept]  $CONFIG_DIR/projects (--keep-data)"; fi
if [ -n "$projects" ]; then printf '%s\n' "$projects" | while IFS= read -r p; do
  [ -d "$p" ] || continue
  rmdir "$p/.claude" "$p/.agents" 2>/dev/null || true   # only when empty
done; fi

if [ "$keep" != 1 ] && [ "$have_data" = 1 ]; then
  echo ""
  echo "[3/5] Removing Cockpit data..."
  # the folder must be exactly <data root>/cockpit and not the home folder or a parent of it
  if [ "$(basename "$DATA_DIR")" = cockpit ] && [ "$DATA_DIR" != "$HOME_P/cockpit" ] && [ "${DATA_DIR#/}" != "$DATA_DIR" ]; then
    rm -rf -- "$DATA_DIR" && echo "  [removed]  $DATA_DIR" || { echo "  [fail]  could not remove $DATA_DIR" >&2; failed=1; }
    [ "$data_inside" = 1 ] || rmdir "$DATA_ROOT" 2>/dev/null || true
  else
    echo "  [refused]  $DATA_DIR is not a <data root>/cockpit folder" >&2; failed=1
  fi
elif [ "$keep" = 1 ]; then
  echo ""
  echo "[3/5] Cockpit data: kept (--keep-data)"
else
  echo ""
  echo "[3/5] Cockpit data: none found, nothing to remove."
fi

echo ""
echo "[4/5] Install folder: $INSTALL"
if [ "$VERDICT" != ok ]; then
  echo "  [kept]  $INSTALL ($VERDICT_WHY)"
  echo "  To remove it:  rm -rf \"$INSTALL\""
elif _is_windows; then
  echo "  Deleted by PowerShell after this command exits (a running script cannot delete its own folder)."
  echo ""
  echo "[5/5] Windows: handing over to PowerShell: it removes the PATH entry now and deletes the folder in the background once nothing holds it; the result goes to the log it names."
  tmpd="$(mktemp -d)"; cp "$SCRIPT_DIR/canon-uninstall.ps1" "$tmpd/canon-uninstall.ps1"
  ps_keep=0; [ "$keep" = 1 ] && [ "$data_inside" = 1 ] && ps_keep=1
  exec "${CANON_UNINSTALL_POWERSHELL:-powershell.exe}" -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$tmpd/canon-uninstall.ps1")" \
    -InstallDir "$(cygpath -w "$INSTALL")" -ToolsEntry "$(windows_path_entry)" -KeepCockpit "$ps_keep" -KeepName "$keep_top" -LogFile "$(cygpath -w "$tmpd/canon-uninstall.log")"
else
  if [ "$keep" = 1 ] && [ "$data_inside" = 1 ]; then
    find "$INSTALL" -mindepth 1 -maxdepth 1 ! -name "$keep_top" -exec rm -rf -- {} + && echo "  [removed]  everything in $INSTALL except $keep_top/" || { echo "  [fail]  could not clear $INSTALL" >&2; failed=1; }
  else
    rm -rf -- "$INSTALL" && echo "  [removed]  $INSTALL" || { echo "  [fail]  could not remove $INSTALL" >&2; failed=1; }
  fi
fi

echo ""
if _is_windows; then echo "[5/5] Windows PATH entry: kept, because the install folder was kept."
else echo "[5/5] Shell rc files: lines naming this install were listed in the plan above; they are not edited."; fi

echo ""
if [ "$failed" = 0 ]; then echo "canon uninstall: done."; else echo "canon uninstall: finished with errors — see [fail] above." >&2; exit 1; fi
