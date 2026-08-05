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
  Write-Warning "bash not found on PATH. canon's CLI tools (sprint, tkt, skills.sh) and its git-native pre-commit hook require bash."
  Write-Warning "If Git for Windows is already installed (``where git`` works), bash is at 'C:\Program Files\Git\bin\bash.exe' but is NOT on PATH by default -- only git.exe (in \cmd) is. Fix: run canon's CLI tools from the Git Bash terminal, or add 'C:\Program Files\Git\bin' to your PATH."
  Write-Warning "If Git is not installed at all, get it from https://git-scm.com/download/win"
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
