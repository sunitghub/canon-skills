# canon-uninstall.ps1 - the Windows tail of `canon uninstall` (t-3897). Copied to %TEMP% and run by tools/canon-uninstall.sh after the
# plan was confirmed, the daemon stopped and skills.sh uninstall ran. It cannot delete the install folder itself while canon.cmd / bash run
# from it, so it (1) removes exactly the <install>\tools entry from the USER PATH now, printing the old value, and (2) starts a hidden
# helper that deletes the folder once nothing holds it (retrying for up to 60 s) and writes what it removed or could not remove to the log.
param(
  [Parameter(Mandatory = $true)][string]$InstallDir,
  [Parameter(Mandatory = $true)][string]$ToolsEntry,
  [int]$KeepCockpit = 0,
  [string]$KeepName = 'cockpit',
  [Parameter(Mandatory = $true)][string]$LogFile
)

# Pure string logic (unit-tested with pwsh where available): drop every entry equal to $Entry, ignoring case and a trailing backslash.
function Remove-PathEntry([string]$PathValue, [string]$Entry) {
  if ([string]::IsNullOrEmpty($PathValue)) { return $PathValue }
  $want = $Entry.TrimEnd('\').ToLowerInvariant()
  $parts = @($PathValue -split ';')
  $kept = @($parts | Where-Object { $_.TrimEnd('\').ToLowerInvariant() -ne $want })
  if ($kept.Count -eq $parts.Count) { return $PathValue }   # no such entry: leave the value byte-identical
  return ($kept -join ';')
}

# A folder is only ever deleted when it is a canon install: tools\canon and tools\skills.sh exist and it is not a drive root or the profile.
function Test-CanonInstall([string]$Dir) {
  if ([string]::IsNullOrWhiteSpace($Dir)) { return $false }
  $full = [IO.Path]::GetFullPath($Dir).TrimEnd('\')
  if ($full.Length -le 3) { return $false }
  if ($full -ieq [IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\')) { return $false }
  return ((Test-Path (Join-Path $full 'tools\canon')) -and (Test-Path (Join-Path $full 'tools\skills.sh')))
}

if ($MyInvocation.InvocationName -eq '.') { return }   # dot-sourced by a test: only the functions are wanted

if (-not (Test-CanonInstall $InstallDir)) {
  Write-Host "canon uninstall: $InstallDir is not a canon install folder; nothing was removed."
  exit 1
}

$old = [Environment]::GetEnvironmentVariable('PATH', 'User')
$new = Remove-PathEntry $old $ToolsEntry
if ($new -ne $old) {
  Write-Host "User PATH before: $old"
  [Environment]::SetEnvironmentVariable('PATH', $new, 'User')
  Write-Host "Removed $ToolsEntry from the user PATH. Open a new terminal for it to take effect."
} else {
  Write-Host "The user PATH has no entry $ToolsEntry."
}

# The helper: its own script file so quoting survives; runs hidden, detached from this console.
$helper = Join-Path ([IO.Path]::GetDirectoryName($LogFile)) 'canon-uninstall-helper.ps1'
@'
param([string]$InstallDir, [int]$KeepCockpit, [string]$KeepName, [string]$LogFile)
$ErrorActionPreference = 'Continue'
function Log($m) { Add-Content -LiteralPath $LogFile -Value ("{0}  {1}" -f (Get-Date -Format s), $m) }
Log "start: removing $InstallDir (keep cockpit: $KeepCockpit)"
$deadline = (Get-Date).AddSeconds(60)
do {
  if ($KeepCockpit -eq 1) {
    Get-ChildItem -LiteralPath $InstallDir -Force | Where-Object { $_.Name -ne $KeepName } | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    $left = @(Get-ChildItem -LiteralPath $InstallDir -Force | Where-Object { $_.Name -ne $KeepName })
  } else {
    if (Test-Path -LiteralPath $InstallDir) { Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction SilentlyContinue }
    $left = @(); if (Test-Path -LiteralPath $InstallDir) { $left = @(Get-ChildItem -LiteralPath $InstallDir -Recurse -Force -ErrorAction SilentlyContinue) }
  }
  if ($left.Count -eq 0) { break }
  Start-Sleep -Seconds 1
} while ((Get-Date) -lt $deadline)
if ($left.Count -eq 0) { Log "done: removed" } else { Log ("incomplete: {0} item(s) are still in use, e.g. {1}; close canon windows and delete {2} by hand" -f $left.Count, $left[0].FullName, $InstallDir) }
'@ | Set-Content -LiteralPath $helper -Encoding UTF8

Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$helper`"", '-InstallDir', "`"$InstallDir`"", '-KeepCockpit', $KeepCockpit, '-KeepName', "`"$KeepName`"", '-LogFile', "`"$LogFile`"")   # Start-Process does not quote: a profile path with a space needs it
Write-Host "The install folder is being removed in the background (it can take a few seconds). Result: $LogFile"
