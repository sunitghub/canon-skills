#!/usr/bin/env bash
# platform-lib.sh — OS and interpreter probes shared by skills.sh and the Cockpit launchers (t-55c1).
# Source, don't execute. No dependencies beyond bash + coreutils: on Windows, canon may assume only
# Git for Windows (Git Bash and its bundled tools) plus Windows' own cmd.exe/powershell.exe.

_is_windows() {
  case "$(uname -s 2>/dev/null)" in MINGW*|CYGWIN*|MSYS*) return 0 ;; esac
  return 1
}

# A python3 that actually runs. `command -v` isn't enough: Windows ships App execution aliases under
# WindowsApps (a Microsoft Store placeholder, or the Python install manager) that exist without Python,
# and running one can download and install Python (live on the VM, 2026-09-24: `python3 -c "print(1)"`
# installed Python 3.14.7). So a WindowsApps python3 is judged by its path and never executed; anything
# else must actually print 1. Output is CR-stripped (native Windows Python prints \r\n).
have_python() {
  local py out
  py="$(command -v python3 2>/dev/null)" || return 1
  case "$(printf '%s' "$py" | tr '[:upper:]\\' '[:lower:]/')" in
    */appdata/local/microsoft/windowsapps/*) return 1 ;;
  esac
  out="$("$py" -c 'print(1)' 2>/dev/null | tr -d '\r')" || return 1
  [ "$out" = "1" ]
}

# board_rel_path — the board server binary, relative to a canon install (t-15d8: the Go board on every OS). The one owner of
# this path: cockpit-launch-lib.sh starts it and cockpit-stop-lib.sh recognises the running board by it. tools/fetch-daemon.sh's
# component table names the same destination (it runs standalone, without this file).
board_rel_path() {
  if _is_windows; then echo tools/sprint-check-win.exe; else echo tools/sprint-check-bin/sprint-check; fi
}
