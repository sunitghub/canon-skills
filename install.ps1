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

$ToolsPath = Join-Path $Target "tools"
$CurrentPath = [Environment]::GetEnvironmentVariable("PATH", "Process")
if (($CurrentPath -split ';') -notcontains $ToolsPath) {
  $env:PATH = "$CurrentPath;$ToolsPath"
}

$UserPath = [Environment]::GetEnvironmentVariable("PATH", "User")
if (($UserPath -split ';') -notcontains $ToolsPath) {
  [Environment]::SetEnvironmentVariable("PATH", "$UserPath;$ToolsPath", "User")
}

Write-Host ""
Write-Host "Done. Added canon tools to your user PATH:"
Write-Host "  $ToolsPath"
Write-Host ""
Write-Host "Open a new VS Code terminal, then start a sprint board from any project:"
Write-Host "  sprint-check"
Write-Host ""
Write-Host "For the Todo walkthrough:"
Write-Host "  Copy-Item -Recurse `"$Target\examples\canon-todo-walkthrough`" `"$HOME\canon-todo-walkthrough`""
