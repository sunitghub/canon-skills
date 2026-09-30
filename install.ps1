# Canon Installer for Windows (PowerShell)
# Usage:
#   irm https://raw.githubusercontent.com/sunitghub/canon-skills/main/install.ps1 | iex   (bootstrap)
#   .\install.ps1                                                                          (finish, from a clone/extract)
# Bootstrap mode (no tools\ beside this script) installs Git for Windows' bash if missing, fetches canon as a zip
# into ~\.canon, then runs finish mode there. `return` (never `exit`) so `| iex` doesn't close the user's window.

$ZipUrl = "https://github.com/sunitghub/canon-skills/archive/refs/heads/main.zip"
$GitDownload = "https://git-scm.com/download/win"
$RerunCmd = "irm https://raw.githubusercontent.com/sunitghub/canon-skills/main/install.ps1 | iex"

function Find-GitBash {
  # Same places tools\canon.cmd looks.
  $candidates = @(
    "$env:ProgramFiles\Git\bin\bash.exe",
    "$env:ProgramFiles\Git\usr\bin\bash.exe",
    "${env:ProgramFiles(x86)}\Git\bin\bash.exe",
    "$env:LocalAppData\Programs\Git\bin\bash.exe"
  )
  foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
  return $null
}

function Install-GitForWindows {
  Write-Host "canon's tools run in Git Bash, which comes with Git for Windows. It is not installed yet."
  Write-Host "This installs it once with winget. Windows will show an admin (UAC) prompt; click Yes."
  Write-Host ""
  if ($env:CANON_YES -ne "1") {
    $answer = Read-Host "Install Git for Windows now? [Y/n]"
    if ($answer -match '^\s*n') { return $false }
  }
  if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Host "winget is not available on this PC."
    return $false
  }
  winget install --id Git.Git -e --source winget
  return ($LASTEXITCODE -eq 0 -and $null -ne (Find-GitBash))
}

function Install-CanonFiles($Dest) {
  $ErrorActionPreference = "Stop"  # function-scoped; must not leak into the user's session under | iex
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ("canon-install-" + [guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $tmp | Out-Null
  try {
    $zip = Join-Path $tmp "canon.zip"
    Write-Host "==> Downloading canon"
    Invoke-WebRequest -UseBasicParsing -Uri $ZipUrl -OutFile $zip
    Expand-Archive -Path $zip -DestinationPath $tmp
    $src = Get-ChildItem -Path $tmp -Directory | Select-Object -First 1
    if (-not $src -or -not (Test-Path (Join-Path $src.FullName "tools"))) { throw "The download did not contain canon's tools folder." }
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    # No /MIR: cockpit\ (registry, change store) must survive an update. Stale removed files linger; acceptable.
    robocopy $src.FullName $Dest /E /XD cockpit .git /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "Copying canon into $Dest failed (robocopy code $LASTEXITCODE)." }
  } finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
  }
}

$ScriptPath = $MyInvocation.MyCommand.Path
$CanonRoot = if ($ScriptPath) { Split-Path -Parent $ScriptPath } else { $null }
$Bootstrap = -not ($CanonRoot -and (Test-Path (Join-Path $CanonRoot "tools\canon.cmd")))

if ($Bootstrap) {
  $CanonRoot = Join-Path $env:USERPROFILE ".canon"
  Write-Host "==> Installing canon into $CanonRoot"
  if (-not (Find-GitBash)) {
    if (-not (Install-GitForWindows)) {
      Write-Host ""
      Write-Host "Nothing was installed. Get Git for Windows from $GitDownload, then run this again:"
      Write-Host "  $RerunCmd"
      return
    }
  }
  if (Test-Path (Join-Path $CanonRoot ".git")) {
    Write-Host "==> $CanonRoot holds a developer checkout (.git); leaving its files as they are"
  } else {
    try { Install-CanonFiles $CanonRoot } catch { Write-Host "Install failed: $_"; return }
  }
}

$ToolsPath = Join-Path $CanonRoot "tools"

if (-not (Test-Path $ToolsPath)) {
  Write-Error "tools folder not found at $ToolsPath. Run this from the extracted canon folder."
  Read-Host "Press Enter to close"
  return
}

if (-not $Bootstrap) {
  Write-Host "Using canon from:"
  Write-Host "  $CanonRoot"
  Write-Host ""
}

$CurrentPath = [Environment]::GetEnvironmentVariable("PATH", "Process")
if (($CurrentPath -split ';') -notcontains $ToolsPath) {
  $env:PATH = "$CurrentPath;$ToolsPath"
}

$UserPath = [Environment]::GetEnvironmentVariable("PATH", "User")
if (($UserPath -split ';') -notcontains $ToolsPath) {
  $nextUserPath = if ([string]::IsNullOrWhiteSpace($UserPath)) { $ToolsPath } else { "$UserPath;$ToolsPath" }
  [Environment]::SetEnvironmentVariable("PATH", $nextUserPath, "User")
}

if (-not $Bootstrap -and -not (Get-Command bash -ErrorAction SilentlyContinue)) {
  Write-Warning "bash not found on PATH. canon's CLI tools (canon, sprint, tkt, skills.sh) and its git-native pre-commit hook require bash."
  Write-Warning "If Git for Windows is already installed (``where git`` works), bash is at 'C:\Program Files\Git\bin\bash.exe' but is NOT on PATH by default -- only git.exe (in \cmd) is. Fix: run canon's CLI tools from the Git Bash terminal, or add 'C:\Program Files\Git\bin' to your PATH."
  Write-Warning "If Git is not installed at all, get it from https://git-scm.com/download/win"
  Write-Host ""
}

if ($Bootstrap) {
  Write-Host "==> Added $ToolsPath to your user PATH"
  if (-not $ScriptPath) {
    Write-Host "==> This PowerShell window: run canon"
    Write-Host "==> Future PowerShell windows: open a new window and run canon"
  } else {
    Write-Host "==> Open a new PowerShell window and run: canon"
  }
  Write-Host "canon installed successfully."
  return
}

Write-Host "Done. Added this workshop tools folder to your user PATH:"
Write-Host "  $ToolsPath"
Write-Host ""

Write-Host "Fully quit and reopen VS Code, then from your project folder run:"
Write-Host "  skills add sprint"
Write-Host ""
Write-Host "For this terminal only, you can also run:"
Write-Host "  `$env:Path += `";$ToolsPath`""
Write-Host ""
Write-Host "For a guided example:"
Write-Host "  Read $CanonRoot\examples\restaurant-bill-split\README.md"
Write-Host "  and give its starting prompt to your agent."
if (-not $Bootstrap) { Read-Host "Press Enter to close" }
