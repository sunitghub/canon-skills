@echo off
setlocal

set "EXE=%~dp0sprint-check.exe"
set "SCRIPT=%~dp0sprint-check"
set "BASH="

if exist "%EXE%" (
  "%EXE%" %*
  exit /b %ERRORLEVEL%
)

if exist "%ProgramFiles%\Git\bin\bash.exe" set "BASH=%ProgramFiles%\Git\bin\bash.exe"
if not defined BASH if exist "%ProgramFiles%\Git\usr\bin\bash.exe" set "BASH=%ProgramFiles%\Git\usr\bin\bash.exe"
if not defined BASH if exist "%ProgramFiles(x86)%\Git\bin\bash.exe" set "BASH=%ProgramFiles(x86)%\Git\bin\bash.exe"
if not defined BASH if exist "%LocalAppData%\Programs\Git\bin\bash.exe" set "BASH=%LocalAppData%\Programs\Git\bin\bash.exe"
if not defined BASH (
  for /f "delims=" %%B in ('where bash.exe 2^>nul') do (
    echo %%B | findstr /i "\\Git\\.*bash.exe" >nul && set "BASH=%%B" && goto :found_bash
  )
)

:found_bash
if not defined BASH (
  echo Error: sprint-check.exe was not found and Git for Windows bash is unavailable.
  exit /b 1
)

"%BASH%" "%SCRIPT%" %*
exit /b %ERRORLEVEL%
