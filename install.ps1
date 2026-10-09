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

# t-34f1: a release zip is installed only if the published manifest (getcanon.dev/releases.txt, the canon-site repo: a different write path from
# the canon-skills repo that holds the zip) lists it, and the downloaded file hashes to the manifest's SHA-256. Line format and rules are the same
# as tools/release-manifest.sh (the git installs' version of this check): exactly one distinct, well-formed line for the tag, else refuse.
# Lines for other tags that do not parse are ignored. There is no override; CANON_MANIFEST_URL only says where to read it (file:// for tests).
function Get-CanonReleaseSha256($Ref) {
  $manifestUrl = if ($env:CANON_MANIFEST_URL) { $env:CANON_MANIFEST_URL } else { "https://getcanon.dev/releases.txt" }
  try {
    if ($manifestUrl -like "file://*") { $text = [IO.File]::ReadAllText(([Uri]$manifestUrl).LocalPath) }
    elseif ($manifestUrl.StartsWith("https:", [StringComparison]::OrdinalIgnoreCase)) { $text = (Invoke-WebRequest -UseBasicParsing -TimeoutSec 30 -Uri $manifestUrl).Content }
    else { throw "only an https or file manifest is read" }
    if ($text -is [byte[]]) { $text = [Text.Encoding]::UTF8.GetString($text) }
    if ($null -eq $text) { $text = "" }
  } catch {
    throw "Cannot read the release manifest at $manifestUrl ($_); refusing to install $Ref unverified. 'canon update --to main' needs no manifest."
  }
  if ($text.Length -gt 1048576) { throw "The release manifest at $manifestUrl is over 1 MB; refusing." }
  if ($text.IndexOf([char]0) -ge 0) { throw "The release manifest at $manifestUrl contains a NUL byte; refusing." }
  $values = @(); $malformed = $false
  foreach ($raw in ($text -split "`n")) {
    $line = $raw.TrimEnd("`r")
    $trim = $line.Trim(" ", "`t")
    if ($trim.Length -eq 0 -or $line.StartsWith("#")) { continue }
    if ((($trim -split "[ `t]+")[0]) -cne $Ref) { continue }
    if ($line -cnotmatch '^v[0-9]+\.[0-9]+\.[0-9]+ [0-9a-f]{64} [0-9a-f]{40}\z') { $malformed = $true; continue }
    $f = $line -split " "
    if ($values -notcontains "$($f[1]) $($f[2])") { $values += "$($f[1]) $($f[2])" }
  }
  if ($malformed) { throw "The manifest line for $Ref is malformed; refusing to install it." }
  if ($values.Count -gt 1) { throw "The manifest lists $Ref twice with different values; refusing to install it." }
  if ($values.Count -eq 0) { throw "$Ref is not in the release manifest at $manifestUrl; refusing to install it unverified." }
  return ($values[0] -split " ")[0]
}

function Install-CanonFiles($Dest) {
  $ErrorActionPreference = "Stop"  # function-scoped; must not leak into the user's session under | iex
  $ProgressPreference = "SilentlyContinue"  # Windows PowerShell 5.1 redraws the progress bar per chunk, making downloads ~10x slower
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ("canon-install-" + [guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $tmp | Out-Null
  try {
    $zip = Join-Path $tmp "canon.zip"
    # t-30fc: `canon update --to <ref>` sets CANON_REF; only main or a release tag like v0.3.0 reaches the URL.
    $ref = if ($env:CANON_REF) { $env:CANON_REF } else { "main" }
    if ($ref -cne "main" -and $ref -cnotmatch '^v[0-9]+\.[0-9]+\.[0-9]+$') { throw "CANON_REF must be main or a release tag like v0.3.0 (got '$ref')." }
    $expected = $null
    if ($ref -ceq "main") {
      $url = $ZipUrl
    } else {
      $expected = Get-CanonReleaseSha256 $ref   # throws before anything is downloaded or touched
      $url = "https://github.com/sunitghub/canon-skills/releases/download/$ref/canon-$($ref.Substring(1)).zip"
    }
    Write-Host "==> Downloading canon ($ref)"
    if ($ref -ceq "main") { Write-Host "    main moves with every change and is not checksum-verified; 'canon update --to vX.Y.Z' installs a verified release." }
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $zip
    if ($expected) {
      $actual = (Get-FileHash -Algorithm SHA256 -Path $zip).Hash.ToLower()
      if ($actual -cne $expected) { throw "The downloaded $ref zip does not match the published checksum (got $actual, the manifest says $expected); nothing was installed." }
      Write-Host "==> Verified $ref (SHA-256 matches the published manifest)"
    }
    # Expand-Archive is very slow in Windows PowerShell 5.1 and its progress bar ignores $ProgressPreference.
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $tmp)
    $src = Get-ChildItem -Path $tmp -Directory | Select-Object -First 1
    if (-not $src -or -not (Test-Path (Join-Path $src.FullName "tools"))) { throw "The download did not contain canon's tools folder." }
    # Windows will not overwrite a running .exe, and robocopy's default is to retry a locked file a million
    # times at 30s each, silently (live: the update hung with the board open). Ask first, and fail fast below.
    $running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith("$Dest\", [StringComparison]::OrdinalIgnoreCase) })
    # The daemon owns live agent sessions, so only `canon stop` (which refuses while agents run) may end it.
    if (@($running | Where-Object { $_.ProcessName -like "cockpit-daemon*" }).Count -gt 0) {
      throw "canon's daemon is running. Run 'canon stop', then run this again."
    }
    # The board server holds no state: end exactly the processes running from the folder we are replacing.
    foreach ($p in $running) {
      Write-Host "==> Closing the running canon board ($($p.ProcessName))"
      Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
      $p.WaitForExit(5000) | Out-Null
    }
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    # No /MIR: cockpit\ (registry, change store) must survive an update. Stale removed files linger; acceptable.
    robocopy $src.FullName $Dest /E /XD cockpit .git /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "Copying canon into $Dest failed (robocopy code $LASTEXITCODE)." }
  } finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
  }
}

# t-9383: the board, daemon and headless-helper exes are release assets, not part of the zip. tools\fetch-daemon.sh (run by Git Bash,
# which canon needs anyway) downloads each one and moves it into place only after its SHA-256 matches tools\cockpit-daemon.sha256;
# a failure leaves any exe that is already there untouched. Returns $false only when the board or the daemon exe is still missing.
function Install-CanonBinaries($Dest) {
  $ErrorActionPreference = "Continue"  # bash writes its messages to stderr; PowerShell 5.1 would turn each line into a terminating error under "Stop"
  $bash = Find-GitBash
  $fetch = Join-Path $Dest "tools\fetch-daemon.sh"
  Write-Host "==> Fetching canon's prebuilt programs (checksum-verified)"
  if ($bash -and (Test-Path $fetch)) {
    & $bash $fetch 2>&1 | ForEach-Object { Write-Host "    $_" }
  } else {
    Write-Host "    Could not run the fetch (Git Bash or tools\fetch-daemon.sh not found)."
  }
  $board = Test-Path (Join-Path $Dest "tools\sprint-check-win.exe")
  $daemon = Test-Path (Join-Path $Dest "tools\cockpit-daemon-win.exe")
  if (-not (Test-Path (Join-Path $Dest "tools\sprint-headless-json-win.exe"))) {
    Write-Warning "sprint-headless-json-win.exe was not fetched; headless runs (sprint-headless) need it. Run canon update to retry."
  }
  if (-not ($board -and $daemon)) {
    Write-Host ""
    Write-Host "canon needs its board and daemon programs and could not get them (see above). Check your internet connection, then run this again:"
    Write-Host "  $RerunCmd"
    return $false
  }
  return $true
}

$ScriptPath = $MyInvocation.MyCommand.Path
$CanonRoot = if ($ScriptPath) { Split-Path -Parent $ScriptPath } else { $null }
$Bootstrap = -not ($CanonRoot -and (Test-Path (Join-Path $CanonRoot "tools\canon.cmd")))

if ($Bootstrap) {
  $CanonRoot = Join-Path $env:USERPROFILE ".canon"
  $global:CanonInstallFailed = $false  # `canon update` reads this: `return` leaves $? true, so it cannot tell an install stopped
  Write-Host "==> Installing canon into $CanonRoot"
  if (-not (Find-GitBash)) {
    if (-not (Install-GitForWindows)) {
      Write-Host ""
      Write-Host "Nothing was installed. Get Git for Windows from $GitDownload, then run this again:"
      Write-Host "  $RerunCmd"
      $global:CanonInstallFailed = $true
      return
    }
  }
  if (Test-Path (Join-Path $CanonRoot ".git")) {
    Write-Host "==> $CanonRoot holds a developer checkout (.git); leaving its files as they are"
  } else {
    try { Install-CanonFiles $CanonRoot } catch { Write-Host "Install failed: $_"; $global:CanonInstallFailed = $true; return }
  }
  if (-not (Install-CanonBinaries $CanonRoot)) { $global:CanonInstallFailed = $true; return }
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
  Write-Host "==> Your user PATH includes $ToolsPath"
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
Read-Host "Press Enter to close"
