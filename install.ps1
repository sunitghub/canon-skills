# Canon Workshop Installer for Windows (PowerShell)
# Usage: .\install.ps1 [-Target "C:\path\to\dir"]

param(
  [string]$Target = (Join-Path $HOME ".canon")
)

Write-Host "Installing canon to $Target..."

if (-not (Test-Path $Target)) {
  New-Item -ItemType Directory -Force -Path $Target | Out-Null
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Copy-Item -Recurse -Force (Join-Path $ScriptDir "*") $Target

Write-Host ""
Write-Host "Done. To use canon tools from any terminal, add to your PATH:"
Write-Host "  `$env:PATH += `";$Target\tools`""
Write-Host ""
Write-Host "To make it permanent, add that line to your PowerShell profile:"
Write-Host "  notepad `$PROFILE"
Write-Host ""
Write-Host "Then start a sprint board from any project:"
Write-Host "  sprint-check"
