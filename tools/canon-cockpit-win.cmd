@echo off
setlocal

set "EXE=%~dp0sprint-check-win.exe"
if not exist "%EXE%" (
  echo Error: sprint-check-win.exe was not found.
  exit /b 1
)

set "PORT=%~1"
if "%PORT%"=="" set "PORT=8899"
if not "%CANON_COCKPIT_PORT%"=="" if "%~1"=="" set "PORT=%CANON_COCKPIT_PORT%"

set "URL=http://127.0.0.1:%PORT%/cockpit"

REM Single-instance: if the port is already serving, just open the URL.
netstat -ano | findstr /r /c:"127.0.0.1:%PORT% .*LISTENING" >nul 2>&1
if %ERRORLEVEL%==0 (
  echo Canon Cockpit already running on port %PORT% - opening it.
  start "" "%URL%"
  exit /b 0
)

start "" "%URL%"
"%EXE%" %PORT%
exit /b %ERRORLEVEL%
