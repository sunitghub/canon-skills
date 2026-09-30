@echo off
REM canon Windows installer wrapper.
REM
REM Windows blocks unsigned .ps1 scripts under the default execution policy
REM ("install.ps1 is not digitally signed / UnauthorizedAccess"), and double-
REM clicking a .ps1 opens it in an editor rather than running it. Batch files
REM are not subject to the PowerShell execution policy, so this wrapper launches
REM install.ps1 for you. The bypass is PROCESS-SCOPED (this one PowerShell
REM process only) and makes no persistent change to your system policy.
REM
REM Usage: double-click install.cmd, or run  install.cmd  from any terminal.

REM Downloaded alone (no install.ps1 beside it)? Fetch it first; it then installs canon itself.
set "PS1=%~dp0install.ps1"
if not exist "%PS1%" (
  set "PS1=%TEMP%\canon-install-%RANDOM%%RANDOM%.ps1"
  curl.exe -fsSL -o "%PS1%" https://raw.githubusercontent.com/sunitghub/canon-skills/main/install.ps1
  if errorlevel 1 (
    echo Could not download install.ps1. Check your connection and try again.
    pause
    exit /b 1
  )
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %*
if errorlevel 1 (
  echo.
  echo install.ps1 exited with an error ^(code %errorlevel%^).
  pause
)
