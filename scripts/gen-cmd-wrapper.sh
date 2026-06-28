#!/usr/bin/env bash
# gen-cmd-wrapper.sh — generate a Windows .cmd wrapper for a tool in tools/
set -euo pipefail

name="${1:?Usage: gen-cmd-wrapper.sh <tool-name>}"
TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../tools" && pwd)"

# Determine script target: prefer .sh, fall back to extensionless
if [[ -f "$TOOLS_DIR/${name}.sh" ]]; then
  target="${name}.sh"
elif [[ -f "$TOOLS_DIR/${name}" ]]; then
  target="${name}"
else
  echo "Warning: neither tools/${name}.sh nor tools/${name} found — generating wrapper anyway" >&2
  target="${name}.sh"
fi

out="$TOOLS_DIR/${name}.cmd"

cat > "$out" << EOF
@echo off
setlocal

set "SCRIPT=%~dp0${target}"
set "BASH="

if exist "%ProgramFiles%\Git\bin\bash.exe" set "BASH=%ProgramFiles%\Git\bin\bash.exe"
if not defined BASH if exist "%ProgramFiles%\Git\usr\bin\bash.exe" set "BASH=%ProgramFiles%\Git\usr\bin\bash.exe"
if not defined BASH if exist "%ProgramFiles(x86)%\Git\bin\bash.exe" set "BASH=%ProgramFiles(x86)%\Git\bin\bash.exe"
if not defined BASH if exist "%LocalAppData%\Programs\Git\bin\bash.exe" set "BASH=%LocalAppData%\Programs\Git\bin\bash.exe"
if not defined BASH (
  for /f "delims=" %%B in ('where bash.exe 2^>nul') do (
    echo %%B | findstr /i "\\\\Git\\\\.*bash.exe" >nul && set "BASH=%%B" && goto :found_bash
  )
)

:found_bash
if not defined BASH (
  echo Error: Git for Windows is required. Install it from https://git-scm.com/download/win
  exit /b 1
)

"%BASH%" "%SCRIPT%" %*
exit /b %ERRORLEVEL%
EOF

echo "Generated: $out"
