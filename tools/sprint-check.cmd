@echo off
setlocal

set "EXE=%~dp0sprint-check.exe"
set "SCRIPT=%~dp0sprint-check"
set "BASH=bash.exe"

if exist "%EXE%" (
  "%EXE%" %*
  exit /b %ERRORLEVEL%
)

where "%BASH%" >nul 2>nul
if errorlevel 1 if exist "%ProgramFiles%\Git\bin\bash.exe" set "BASH=%ProgramFiles%\Git\bin\bash.exe"
if errorlevel 1 if exist "%LocalAppData%\Programs\Git\bin\bash.exe" set "BASH=%LocalAppData%\Programs\Git\bin\bash.exe"
if errorlevel 1 if "%BASH%"=="bash.exe" (
  echo Error: sprint-check.exe was not found and Git for Windows bash is unavailable.
  exit /b 1
)

"%BASH%" "%SCRIPT%" %*
exit /b %ERRORLEVEL%
