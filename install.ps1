# Canon Workshop Installer for Windows (PowerShell)
# Usage: .\install.ps1

$CanonRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ToolsPath = Join-Path $CanonRoot "tools"

if (-not (Test-Path $ToolsPath)) {
  Write-Error "tools folder not found at $ToolsPath. Run this from the extracted canon folder."
  exit 1
}

Write-Host "Using canon from:"
Write-Host "  $CanonRoot"
Write-Host ""

$CurrentPath = [Environment]::GetEnvironmentVariable("PATH", "Process")
if (($CurrentPath -split ';') -notcontains $ToolsPath) {
  $env:PATH = "$CurrentPath;$ToolsPath"
}

$UserPath = [Environment]::GetEnvironmentVariable("PATH", "User")
if (($UserPath -split ';') -notcontains $ToolsPath) {
  $nextUserPath = if ([string]::IsNullOrWhiteSpace($UserPath)) { $ToolsPath } else { "$UserPath;$ToolsPath" }
  [Environment]::SetEnvironmentVariable("PATH", $nextUserPath, "User")
}

Write-Host "Done. Added this workshop tools folder to your user PATH:"
Write-Host "  $ToolsPath"
Write-Host ""
Write-Host "Fully quit and reopen VS Code, then verify:"
Write-Host "  tkt ls"
Write-Host "  sprint-check-win --help"
Write-Host ""
Write-Host "For this terminal only, you can also run:"
Write-Host "  `$env:Path += `";$ToolsPath`""
Write-Host ""
Write-Host "For the Todo walkthrough:"
Write-Host "  `$dest = `"$HOME\canon-todo-walkthrough`""
Write-Host "  Remove-Item -Recurse -Force `$dest -ErrorAction SilentlyContinue"
Write-Host "  Copy-Item -Recurse `"$CanonRoot\examples\canon-todo-walkthrough`" `$dest"
Write-Host "  cd `$dest"
Write-Host "  skills add sprint"
