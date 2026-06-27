@echo off
setlocal

set "EXE=%~dp0sprint-check-win.exe"

if not exist "%EXE%" (
  echo Error: sprint-check-win.exe was not found.
  exit /b 1
)

"%EXE%" %*
exit /b %ERRORLEVEL%
