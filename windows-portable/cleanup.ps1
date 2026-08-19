#Requires -Version 5.1
<#
.SYNOPSIS
  Remove the temporary portable package after a successful durable install.
#>
[CmdletBinding()]
param(
  [switch]$Force,
  [switch]$AlsoRemoveDurableNode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-CleanStep {
  param([string]$Message, [ValidateSet('info','ok','warn','err','title')][string]$Level = 'info')
  $prefix = switch ($Level) {
    'ok' { '[ OK ]' } 'warn' { '[WARN]' } 'err' { '[ERR ]' } 'title' { '[====]' } default { '[ .. ]' }
  }
  $color = switch ($Level) {
    'ok' { 'Green' } 'warn' { 'Yellow' } 'err' { 'Red' } 'title' { 'Cyan' } default { 'Gray' }
  }
  Write-Host ("{0} {1}" -f $prefix, $Message) -ForegroundColor $color
}

$PackageRoot = $PSScriptRoot
$statePath = Join-Path $env:LOCALAPPDATA 'dsh-onboarding\install-state.json'
$marker = Join-Path $PackageRoot '.install-ok'

Write-CleanStep 'Portable package cleanup' 'title'
Write-CleanStep ("Package: {0}" -f $PackageRoot)

if (-not (Test-Path -LiteralPath $marker) -and -not (Test-Path -LiteralPath $statePath) -and -not $Force) {
  Write-CleanStep 'No successful install marker found. Refusing to delete (use -Force to override).' 'err'
  exit 2
}

# Verify durable node still exists
$durableOk = $false
if (Test-Path -LiteralPath $statePath) {
  try {
    $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($state.durableNodeHome -and (Test-Path -LiteralPath (Join-Path $state.durableNodeHome 'node.exe'))) {
      $durableOk = $true
      Write-CleanStep ("Durable Node OK: {0}" -f $state.durableNodeHome) 'ok'
      if ($state.launcher) {
        Write-CleanStep ("Launcher: {0}" -f $state.launcher) 'ok'
      }
    }
  } catch {
    Write-CleanStep ("Could not parse install-state: {0}" -f $_.Exception.Message) 'warn'
  }
}

if (-not $durableOk -and -not $Force) {
  Write-CleanStep 'Durable Node not verified. Abort cleanup so you do not lose the only runtime.' 'err'
  Write-CleanStep 'If you are sure, re-run: powershell -File cleanup.ps1 -Force' 'warn'
  exit 3
}

if ($AlsoRemoveDurableNode) {
  $durableRoot = Join-Path $env:LOCALAPPDATA 'dsh-onboarding'
  Write-CleanStep ("Removing durable onboarding data: {0}" -f $durableRoot) 'warn'
  if (Test-Path -LiteralPath $durableRoot) {
    Remove-Item -LiteralPath $durableRoot -Recurse -Force
  }
}

Write-CleanStep 'Removing temporary portable package folder...' 'title'
# Schedule deletion after this process exits (cannot delete own directory while running easily on Windows)
$target = $PackageRoot
$ps = @"
Start-Sleep -Seconds 1
try {
  if (Test-Path -LiteralPath '$($target.Replace("'","''"))') {
    Remove-Item -LiteralPath '$($target.Replace("'","''"))' -Recurse -Force -ErrorAction Stop
  }
} catch {
  exit 1
}
"@
$encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($ps))
Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded) -WindowStyle Hidden | Out-Null

Write-CleanStep 'Cleanup scheduled. This window can be closed.' 'ok'
Write-CleanStep 'Later: %LOCALAPPDATA%\dsh-onboarding\start-dsh.cmd' 'info'
exit 0
