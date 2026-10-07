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

rem t-4700: suppress the exe's own browser-open (it would otherwise also open
rem the bare root ~400ms later, alongside the /cockpit URL opened below).
set "SPRINT_CHECK_NO_BROWSER=1"
rem t-302d: open the URL only once the board answers (the exe below runs in the foreground, so poll from a background window).
start "" /b powershell -NoProfile -WindowStyle Hidden -Command "for($i=0;$i -lt 100;$i++){try{Invoke-WebRequest -UseBasicParsing -TimeoutSec 1 -Uri 'http://127.0.0.1:%PORT%/api/version' | Out-Null; Start-Process '%URL%'; break}catch{Start-Sleep -Milliseconds 100}}"
"%EXE%" %PORT%
exit /b %ERRORLEVEL%
