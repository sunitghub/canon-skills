# Canon Workshop Installer for Windows (PowerShell)
# Usage: .\install.ps1

$CanonRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ToolsPath = Join-Path $CanonRoot "tools"

if (-not (Test-Path $ToolsPath)) {
  Write-Error "tools folder not found at $ToolsPath. Run this from the extracted canon folder."
  Read-Host "Press Enter to close"
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

if (-not (Get-Command bash -ErrorAction SilentlyContinue)) {
  Write-Warning "bash not found on PATH. Install Git for Windows from https://git-scm.com/download/win"
  Write-Warning "canon's CLI tools and git-native pre-commit hook require bash to run."
  Write-Host ""
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
Read-Host "Press Enter to close"
