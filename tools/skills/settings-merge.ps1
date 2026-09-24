# settings-merge.ps1 — permissions rules in .claude/settings.json on Windows without Python (t-55c1).
# The PowerShell port of the python3 merges in tools/skills/prompts.sh; same results, same refusals.
# Windows PowerShell 5.1 compatible (it ships with Windows). Run by prompts.sh via -EncodedCommand,
# which avoids execution-policy blocks on .ps1 files. Inputs come from environment variables:
#   CANON_SETTINGS  Windows path to settings.json
#   CANON_KEY       allow | deny          (the permissions.<key> list)
#   CANON_MODE      status | add | remove
#   CANON_RULES     rules, one per line
# Prints one word: present | absent (status), ok (add/remove), or invalid. An invalid file is never written.

$ErrorActionPreference = 'Stop'
$path  = $env:CANON_SETTINGS
$key   = $env:CANON_KEY
$mode  = $env:CANON_MODE
$rules = @($env:CANON_RULES -split "`n" | ForEach-Object { $_.TrimEnd("`r") } | Where-Object { $_ -ne '' })

if (Test-Path -LiteralPath $path) {
  try { $data = [IO.File]::ReadAllText($path) | ConvertFrom-Json } catch { 'invalid'; exit 0 }
  if (-not ($data -is [System.Management.Automation.PSCustomObject])) { 'invalid'; exit 0 }
} else {
  if ($mode -ne 'add') { if ($mode -eq 'status') { 'absent' } else { 'ok' }; exit 0 }
  $data = New-Object PSObject
}

$perms = $data.permissions
if ($null -eq $perms) {
  if ($mode -ne 'add') { if ($mode -eq 'status') { 'absent' } else { 'ok' }; exit 0 }
  $perms = New-Object PSObject
  $data | Add-Member -NotePropertyName permissions -NotePropertyValue $perms
} elseif (-not ($perms -is [System.Management.Automation.PSCustomObject])) { 'invalid'; exit 0 }

$list = $perms.$key
if ($null -eq $list) { $list = @() } elseif (-not ($list -is [array])) { 'invalid'; exit 0 }

if ($mode -eq 'status') {
  $missing = @($rules | Where-Object { $list -notcontains $_ })
  if ($missing.Count -eq 0) { 'present' } else { 'absent' }
  exit 0
}

if ($mode -eq 'add') {
  $new = @($list)
  foreach ($r in $rules) { if ($new -notcontains $r) { $new += $r } }
} else {
  $new = @($list | Where-Object { $rules -notcontains $_ })
}

if ($new.Count -eq 0 -and $mode -eq 'remove') {
  $perms.PSObject.Properties.Remove($key)
  if (@($perms.PSObject.Properties).Count -eq 0) { $data.PSObject.Properties.Remove('permissions') }
} else {
  $perms | Add-Member -NotePropertyName $key -NotePropertyValue ([object[]]$new) -Force
}

# UTF-8 without a BOM (Out-File/Set-Content in 5.1 would write a BOM or UTF-16).
$json = $data | ConvertTo-Json -Depth 32
[IO.File]::WriteAllText($path, $json + "`n", (New-Object System.Text.UTF8Encoding $false))
'ok'
