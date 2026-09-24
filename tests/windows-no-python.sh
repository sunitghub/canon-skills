#!/usr/bin/env bash
# tests/windows-no-python.sh — t-55c1: canon on a Windows machine that has only Git for Windows.
# End users have no Python; python3 may be missing, a do-nothing Store placeholder, or the Python install
# manager's alias, which installs Python when run. canon must detect all three without ever running an alias.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
probe() { PATH="$1:$PATH" bash -c 'source "$1/tools/skills/lib.sh"; have_python' _ "$ROOT"; }

# A python3 that records every run and would "work" (prints 1) — the install manager after it has
# installed Python. Under WindowsApps it must never be executed.
recording_python3() {
  mkdir -p "$1"
  printf '#!/usr/bin/env bash\ntouch "%s/ran"\necho 1\n' "$1" > "$1/python3"
  chmod +x "$1/python3"
}

# --- 0. never execute a WindowsApps python3 (live: running it installed Python 3.14.7) ------------
wa="$tmp/Users/x/AppData/Local/Microsoft/WindowsApps"
recording_python3 "$wa"
if probe "$wa"; then fail "have_python accepted a WindowsApps python3"; fi
[[ ! -e "$wa/ran" ]] || fail "have_python executed a WindowsApps python3 (it can install Python)"

# Case-insensitive, as Windows paths are.
wa2="$tmp/users/x/APPDATA/local/MICROSOFT/windowsapps"
recording_python3 "$wa2"
if probe "$wa2"; then fail "have_python accepted an upper/lower-case WindowsApps python3"; fi
[[ ! -e "$wa2/ran" ]] || fail "have_python executed a mixed-case WindowsApps python3"

# Control: the same recorder elsewhere IS run and accepted, so the checks above can fail.
ok="$tmp/opt/python/bin"
recording_python3 "$ok"
probe "$ok" || fail "have_python rejected a working python3 outside WindowsApps"
[[ -e "$ok/ran" ]] || fail "control: a normal python3 should have been executed"

# Do-nothing placeholder (exit 0, no output) outside WindowsApps: executed but rejected.
stub="$tmp/stub"; mkdir -p "$stub"; printf '#!/usr/bin/env bash\nexit 0\n' > "$stub/python3"; chmod +x "$stub/python3"
if probe "$stub"; then fail "have_python accepted a do-nothing python3"; fi

printf 'windows-no-python: ok\n'
