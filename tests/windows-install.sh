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

# Only HTTPS canon-skills / git-scm URLs, and the one release manifest (t-34f1); no git clone.
while read -r url; do
  [[ "$url" == https://github.com/sunitghub/canon-skills/* || "$url" == https://raw.githubusercontent.com/sunitghub/canon-skills/* || "$url" == https://git-scm.com/* || "$url" == https://getcanon.dev/releases.txt ]] \
    || fail "unexpected URL in installer: $url"
done < <(code "$PS1" "$CMD" | grep -oE 'https?://[^" ]+')
if code "$PS1" | grep -qE 'git +clone'; then fail "install.ps1 uses git clone"; fi

# t-34f1: a release zip is verified against the published manifest BEFORE it is extracted, and the manifest is read before anything is downloaded.
# PowerShell cannot run here (the Windows VM checks the behavior); this pins the order and the absence of any bypass.
ln() { grep -n "^[^#]*$1" "$PS1" | head -1 | cut -d: -f1; }   # first line where it appears before any `#`, i.e. as code
[[ -n "$(ln 'Get-CanonReleaseSha256 \$ref')" && -n "$(ln 'Get-FileHash')" && -n "$(ln 'ExtractToDirectory')" ]] || fail "install.ps1 lost its manifest check or the extraction"
[[ "$(ln 'Get-CanonReleaseSha256 \$ref')" -lt "$(ln 'Invoke-WebRequest -UseBasicParsing -Uri \$url')" ]] || fail "install.ps1 reads the manifest after it downloads the zip"
[[ "$(ln 'Get-FileHash')" -lt "$(ln 'ExtractToDirectory')" ]] || fail "install.ps1 extracts the zip before it checks its SHA-256"
code "$PS1" | grep -qE 'cne \$expected' && code "$PS1" | grep -q 'does not match the published checksum' || fail "install.ps1 does not refuse a zip whose SHA-256 differs from the manifest"
if code "$PS1" | grep -qiE 'CANON_(INSECURE|SKIP|NO_?VERIFY|UNVERIFIED)'; then fail "install.ps1 has a way to skip verification"; fi

# Update in place must never delete user data: no /MIR or /PURGE, and cockpit + .git excluded.
if code "$PS1" | grep -qiE 'robocopy.*(/MIR|/PURGE)'; then fail "robocopy would delete files under ~\\.canon"; fi
code "$PS1" | grep -qE 'robocopy .*/XD cockpit \.git' || fail "robocopy does not exclude cockpit and .git"

# A running canon locks its .exe files: the installer must ask first, and robocopy must not retry forever.
code "$PS1" | grep -q "daemon is running. Run 'canon stop'" || fail "installer does not stop when the daemon is running (it owns live sessions)"
code "$PS1" | grep -q 'Stop-Process -Id' || fail "installer does not close the running board server before copying"
if code "$PS1" | grep -qiE 'Stop-Process +-Name|taskkill|pkill'; then fail "installer kills by name instead of by exact PID"; fi
code "$PS1" | grep -qE 'robocopy .*/R:[0-9]+ /W:[0-9]+' || fail "robocopy has no retry limit (hangs on a locked file)"

# A stopped install must tell `canon update` (it would otherwise refresh projects after a failed install).
[[ "$(code "$PS1" | grep -c 'CanonInstallFailed = \$true')" -ge 2 ]] || fail "a failed or declined install does not set CanonInstallFailed"
grep -q 'global:CanonInstallFailed' "$ROOT/tools/canon" || fail "canon update ignores a failed install"

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
