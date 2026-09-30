#!/usr/bin/env bash
# tests/windows-install.sh — t-8716: static safety checks for the one-line Windows installer.
# No PowerShell here, so this pins the properties from the script text; the Windows VM run is the real proof.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

PS1="$ROOT/install.ps1"
CMD="$ROOT/install.cmd"
code() { grep -hv '^\s*#' "$@"; }

# Never change the machine/user execution policy, never depend on Python.
if code "$PS1" | grep -qi 'Set-ExecutionPolicy'; then fail "install.ps1 sets an execution policy"; fi
if code "$CMD" | grep -qi 'Set-ExecutionPolicy'; then fail "install.cmd sets an execution policy"; fi
if code "$PS1" "$CMD" | grep -qiE 'python'; then fail "installer depends on python"; fi
code "$CMD" | grep -q -- '-ExecutionPolicy Bypass' || fail "install.cmd lost its process-scoped bypass"

# Only HTTPS canon-skills / git-scm URLs; no git clone.
while read -r url; do
  [[ "$url" == https://github.com/sunitghub/canon-skills/* || "$url" == https://raw.githubusercontent.com/sunitghub/canon-skills/* || "$url" == https://git-scm.com/* ]] \
    || fail "unexpected URL in installer: $url"
done < <(code "$PS1" "$CMD" | grep -oE 'https?://[^" ]+')
if code "$PS1" | grep -qE 'git +clone'; then fail "install.ps1 uses git clone"; fi

# Update in place must never delete user data: no /MIR or /PURGE, and cockpit + .git excluded.
if code "$PS1" | grep -qiE 'robocopy.*(/MIR|/PURGE)'; then fail "robocopy would delete files under ~\\.canon"; fi
code "$PS1" | grep -qE 'robocopy .*/XD cockpit \.git' || fail "robocopy does not exclude cockpit and .git"

# Prompt precedes winget; CANON_YES skips it; a decline stops before anything is installed.
prompt_line="$(grep -n 'Install Git for Windows now? \[Y/n\]' "$PS1" | head -1 | cut -d: -f1)"
winget_line="$(grep -n '^\s*winget install' "$PS1" | head -1 | cut -d: -f1)"
[[ -n "$prompt_line" && -n "$winget_line" && "$prompt_line" -lt "$winget_line" ]] || fail "winget install does not come after the [Y/n] prompt"
grep -q 'CANON_YES' "$PS1" || fail "CANON_YES does not skip the prompt"

# Under `| iex`, exit would close the user's window.
if code "$PS1" | grep -qE '^\s*exit\b'; then fail "install.ps1 uses exit (closes the window under | iex)"; fi

# Finish-mode PATH logic still adds tools\ to the user PATH without duplicating.
code "$PS1" | grep -q 'SetEnvironmentVariable("PATH", $nextUserPath, "User")' || fail "finish mode no longer sets the user PATH"
code "$PS1" | grep -q "notcontains \$ToolsPath" || fail "finish mode no longer guards against duplicate PATH entries"

# install.cmd fetches install.ps1 when it is not beside it.
code "$CMD" | grep -q 'curl.exe' || fail "install.cmd does not download install.ps1 when missing"

printf 'windows-install: ok\n'
