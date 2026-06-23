@echo off
setlocal

set "SCRIPT=%~dp0tkt"
set "BASH=bash.exe"

where "%BASH%" >nul 2>nul
if errorlevel 1 if exist "%ProgramFiles%\Git\bin\bash.exe" set "BASH=%ProgramFiles%\Git\bin\bash.exe"
if errorlevel 1 if exist "%LocalAppData%\Programs\Git\bin\bash.exe" set "BASH=%LocalAppData%\Programs\Git\bin\bash.exe"
if errorlevel 1 if "%BASH%"=="bash.exe" (
  echo Error: Git for Windows is required. Install it from https://git-scm.com/download/win
  exit /b 1
)

"%BASH%" "%SCRIPT%" %*
exit /b %ERRORLEVEL%
