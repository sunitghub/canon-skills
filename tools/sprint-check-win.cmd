@echo off
setlocal enabledelayedexpansion

rem sprint-check-win.cmd -- open the current project's board inside Canon
rem Cockpit (t-4700). No longer starts a private per-project server of its
rem own -- delegates into the single canon-cockpit instance (starting it if
rem none is running), registers the current project, and deep-links into its
rem tab. Mirrors tools/sprint-check (bash) and tools/canon-cockpit-win.cmd.

set "EXE=%~dp0sprint-check-win.exe"
if not exist "%EXE%" (
  echo Error: sprint-check-win.exe was not found.
  exit /b 1
)

set "PORT=%~1"
if "%PORT%"=="" set "PORT=8899"
if not "%CANON_COCKPIT_PORT%"=="" if "%~1"=="" set "PORT=%CANON_COCKPIT_PORT%"
set "ROOT=%CD%"
set "BASE=http://127.0.0.1:%PORT%"

netstat -ano | findstr /r /c:"127.0.0.1:%PORT% .*LISTENING" >nul 2>&1
if %ERRORLEVEL%==0 (
  echo Opening this project in the running Canon Cockpit ^(port %PORT%^).
  call :openproject
  exit /b 0
)

rem No cockpit instance running yet -- start it in its own console window
rem (suppress its own browser-open; this script owns opening the right URL).
set "SPRINT_CHECK_NO_BROWSER=1"
start "Canon Cockpit (%PORT%) - close this window to stop it" "%EXE%" %PORT%

for /l %%i in (1,1,50) do (
  netstat -ano | findstr /r /c:"127.0.0.1:%PORT% .*LISTENING" >nul 2>&1
  if !ERRORLEVEL!==0 goto :ready
  timeout /t 1 /nobreak >nul
)
:ready
call :openproject
exit /b 0

:openproject
set "PROJID="
for /f "usebackq delims=" %%i in (`powershell -NoProfile -Command ^
  "$ErrorActionPreference='SilentlyContinue';" ^
  "$h=@{Origin='%BASE%'};" ^
  "$body=(@{path='%ROOT%'}|ConvertTo-Json -Compress);" ^
  "try{$r=Invoke-RestMethod -Uri '%BASE%/api/projects' -Method Post -Body $body -ContentType 'application/json' -Headers $h}catch{$r=$null};" ^
  "if($r -and $r.ok){$r.project.id}else{try{$l=Invoke-RestMethod -Uri '%BASE%/api/projects' -Headers $h}catch{$l=@()};($l ^| Where-Object{$_.path -eq '%ROOT%'} ^| Select-Object -First 1).id}"`) do set "PROJID=%%i"

if not "%PROJID%"=="" (
  start "" "%BASE%/cockpit#open=%PROJID%"
) else (
  echo Could not register this project with Cockpit -- opening the Projects list.
  start "" "%BASE%/cockpit"
)
goto :eof
