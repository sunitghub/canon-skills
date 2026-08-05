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

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
if errorlevel 1 (
  echo.
  echo install.ps1 exited with an error ^(code %errorlevel%^).
  pause
)
