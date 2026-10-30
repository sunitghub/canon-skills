#!/usr/bin/env bash
# platform-lib.sh — OS probes and the board binary, shared by skills.sh, the Cockpit launchers and sprint-headless(-eval) (t-55c1).
# Source, don't execute. No dependencies beyond bash + coreutils: on Windows, canon may assume only
# Git for Windows (Git Bash and its bundled tools) plus Windows' own cmd.exe/powershell.exe.

_is_windows() {
  case "$(uname -s 2>/dev/null)" in MINGW*|CYGWIN*|MSYS*) return 0 ;; esac
  return 1
}

# utf8_locale — a UTF-8 locale to run ps under (the current one if it is UTF-8), or nothing and 1 when the machine has none (t-50f7).
# Under the C locale ps escapes the bytes of a non-ASCII path in a command line (macOS: M-CM-), so matching a process to an install folder
# by its path would silently miss; with a UTF-8 locale it prints them as they are.
utf8_locale() {
  local cur="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" all c
  case "$cur" in *.[Uu][Tt][Ff]-8|*.[Uu][Tt][Ff]8|*.[Uu][Tt][Ff]-8@*|*.[Uu][Tt][Ff]8@*) printf '%s\n' "$cur"; return 0 ;; esac
  all="$(locale -a 2>/dev/null)" || all=""
  for c in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
    case $'\n'"$all"$'\n' in *$'\n'"$c"$'\n'*) printf '%s\n' "$c"; return 0 ;; esac
  done
  return 1
}

# ps_utf8 <ps arguments...> — ps under utf8_locale when there is one (command lines then carry non-ASCII paths as bytes).
ps_utf8() {
  local l
  if l="$(utf8_locale)"; then LC_ALL="$l" ps "$@"; else ps "$@"; fi
}

# has_non_ascii <text> — the text has a byte outside printable ASCII (what a ps without a UTF-8 locale cannot show as it is).
has_non_ascii() { [ -n "$(printf '%s' "$1" | LC_ALL=C tr -d ' -~')" ]; }

# board_rel_path — canon's program, canon-go (the board server and the Cockpit daemon in one, t-bdb0), relative to a canon install
# (t-15d8: the Go board on every OS). The one owner of this path: cockpit-launch-lib.sh starts it (`canon-go board <port>`) and
# cockpit-stop-lib.sh recognises the running board and daemon by it plus their mode word. tools/fetch-daemon.sh's component table
# names the same destination (it runs standalone, without this file).
board_rel_path() {
  if _is_windows; then echo tools/canon-go-win.exe; else echo tools/canon-go-bin/canon-go; fi
}

# board_bin — canon-go of this install: <install>/$(board_rel_path), or SPRINT_CHECK_BIN when set (a test's build).
board_bin() {
  if [[ -n "${SPRINT_CHECK_BIN:-}" ]]; then echo "$SPRINT_CHECK_BIN"; return; fi
  echo "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/$(board_rel_path)"
}

# board_helper_bin — board_bin when it has the helper subcommands (t-b62a: they replaced inline python3); else says how to get it
# and fails. Callers check first, so a missing binary never surfaces after a paid `claude -p` run. Checked through --help: an older
# board takes an unknown first word for a port and would start serving instead of answering. canon-go takes a helper word as the
# board's (only `daemon` and `board` are mode words, t-bdb0), so callers run `<bin> headless-json` as before.
board_helper_bin() {
  local b h; b="$(board_bin)"
  h="$("$b" --help 2>/dev/null)" || h=""
  case "$h" in *headless-json*) echo "$b"; return 0 ;; esac
  echo "canon's board binary ($b) is missing, does not run, or is older than these tools; run canon update to fetch it." >&2
  return 1
}

# headless_parse <board> — `claude -p --output-format json` on stdin; sets IS_ERROR (True/False/PARSE_ERROR), SESSION_ID and
# RESULT_TEXT for tools/sprint-headless and tools/sprint-headless-eval.
headless_parse() {
  local parsed; parsed="$("$1" headless-json)"
  IS_ERROR="$(printf '%s\n' "$parsed" | cut -f1)"
  SESSION_ID="$(printf '%s\n' "$parsed" | cut -f2)"
  RESULT_TEXT="$(printf '%s\n' "$parsed" | cut -f3- | tr '\002' '\n')"
}

# canon_event <kind> <source> <project dir> key=value... — one event line (t-f182) through the board binary, after the write it
# describes succeeded. Observer-only: never prints, never fails, never waits on a missing or older board (it is skipped).
# The board is checked once per shell (_CANON_EVENT_BOARD: a path, or "-" for none), through its --help: a board from
# before t-f182 has the other helpers but not `event`, and would take the word for a port and serve forever.
canon_event() {
  local root b h
  if [ -z "${_CANON_EVENT_BOARD:-}" ]; then
    _CANON_EVENT_BOARD=-
    b="$(board_bin)"; h="$("$b" --help 2>/dev/null)" || h=""
    case "$h" in *"event <kind>"*) _CANON_EVENT_BOARD="$b" ;; esac
    case "$h" in *"[--actor "*) _CANON_EVENT_ACTOR_OK=1 ;; *) _CANON_EVENT_ACTOR_OK= ;; esac
  fi
  [ "$_CANON_EVENT_BOARD" != - ] || return 0
  root="$(cd "$3" 2>/dev/null && pwd -P)" || root="$3"
  # t-7c89: CANON_EVENT_ACTOR=system marks a record canon makes itself; a board without --actor writes the line without it.
  local actor=()
  [ -z "${CANON_EVENT_ACTOR:-}" ] || [ -z "${_CANON_EVENT_ACTOR_OK:-}" ] || actor=(--actor "$CANON_EVENT_ACTOR")
  "$_CANON_EVENT_BOARD" event "$1" --source "$2" --project "$root" ${actor[@]+"${actor[@]}"} "${@:4}" </dev/null >/dev/null 2>&1 || true
  return 0
}
