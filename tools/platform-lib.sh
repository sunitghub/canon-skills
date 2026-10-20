#!/usr/bin/env bash
# platform-lib.sh — OS probes and the board binary, shared by skills.sh, the Cockpit launchers and sprint-headless(-eval) (t-55c1).
# Source, don't execute. No dependencies beyond bash + coreutils: on Windows, canon may assume only
# Git for Windows (Git Bash and its bundled tools) plus Windows' own cmd.exe/powershell.exe.

_is_windows() {
  case "$(uname -s 2>/dev/null)" in MINGW*|CYGWIN*|MSYS*) return 0 ;; esac
  return 1
}

# board_rel_path — the board server binary, relative to a canon install (t-15d8: the Go board on every OS). The one owner of
# this path: cockpit-launch-lib.sh starts it and cockpit-stop-lib.sh recognises the running board by it. tools/fetch-daemon.sh's
# component table names the same destination (it runs standalone, without this file).
board_rel_path() {
  if _is_windows; then echo tools/sprint-check-win.exe; else echo tools/sprint-check-bin/sprint-check; fi
}

# board_bin — the board binary of this install: <install>/$(board_rel_path), or SPRINT_CHECK_BIN when set (a test's build).
board_bin() {
  if [[ -n "${SPRINT_CHECK_BIN:-}" ]]; then echo "$SPRINT_CHECK_BIN"; return; fi
  echo "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/$(board_rel_path)"
}

# board_helper_bin — board_bin when it has the helper subcommands (t-b62a: they replaced inline python3); else says how to get it
# and fails. Callers check first, so a missing binary never surfaces after a paid `claude -p` run. Checked through --help: an older
# board takes an unknown first word for a port and would start serving instead of answering.
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
