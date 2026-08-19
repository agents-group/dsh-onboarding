#Requires -Version 5.1
<#
.SYNOPSIS
  Build dsh-onboarding-windows-portable.zip (download-and-run package).
#>
[CmdletBinding()]
param(
  [string]$NodeVersion,
  [switch]$SkipNodeDownload,
  [string]$OutDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
if ([string]::IsNullOrWhiteSpace($OutDir)) {
  $OutDir = Join-Path $RepoRoot 'dist'
}
$stageName = 'dsh-onboarding-windows-portable'
$stage = Join-Path $OutDir $stageName
$zipPath = Join-Path $OutDir ($stageName + '.zip')

function Write-Build {
  param([string]$Message, [string]$Level = 'info')
  $p = switch ($Level) { 'ok' { '[ OK ]' } 'warn' { '[WARN]' } 'err' { '[ERR ]' } 'title' { '[====]' } default { '[ .. ]' } }
  Write-Host ("{0} {1}" -f $p, $Message)
}

function Get-NodeVersionToBundle {
  if (-not [string]::IsNullOrWhiteSpace($NodeVersion)) { return $NodeVersion.TrimStart('v') }
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $idx = Invoke-RestMethod -Uri 'https://nodejs.org/dist/index.json' -TimeoutSec 45
    $pick = $idx | Where-Object {
      $_.version -match '^v22\.' -and
      [int]($_.version.TrimStart('v').Split('.')[1]) -ge 19 -and
      $_.files -contains 'win-x64-zip'
    } | Select-Object -First 1
    if ($null -ne $pick) { return $pick.version.TrimStart('v') }
  } catch {
    Write-Build ("index.json failed: {0}" -f $_.Exception.Message) 'warn'
  }
  return '22.22.0'
}

Write-Build 'Build Windows portable package' 'title'
Write-Build ("Repo: {0}" -f $RepoRoot)

if (Test-Path -LiteralPath $stage) {
  Remove-Item -LiteralPath $stage -Recurse -Force
}
New-Item -ItemType Directory -Path $stage -Force | Out-Null

# Copy portable entrypoints
$portableSrc = Join-Path $RepoRoot 'windows-portable'
Copy-Item -LiteralPath (Join-Path $portableSrc 'start.cmd') -Destination $stage
Copy-Item -LiteralPath (Join-Path $portableSrc 'start.ps1') -Destination $stage
Copy-Item -LiteralPath (Join-Path $portableSrc 'cleanup.cmd') -Destination $stage
Copy-Item -LiteralPath (Join-Path $portableSrc 'cleanup.ps1') -Destination $stage
Copy-Item -LiteralPath (Join-Path $portableSrc 'README.md') -Destination (Join-Path $stage 'README.md')

# Agent + config
New-Item -ItemType Directory -Path (Join-Path $stage 'agent') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $stage 'config') -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $RepoRoot 'scripts\bootstrap.ps1') -Destination (Join-Path $stage 'agent\bootstrap.ps1')
Copy-Item -LiteralPath (Join-Path $RepoRoot 'config\defaults.json') -Destination (Join-Path $stage 'config\defaults.json')

# Bundle Node runtime (makes true download-and-run)
if (-not $SkipNodeDownload) {
  $ver = Get-NodeVersionToBundle
  $zipName = "node-v$ver-win-x64.zip"
  $url = "https://nodejs.org/dist/v$ver/$zipName"
  $nodeZip = Join-Path $OutDir $zipName
  New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

  if (-not (Test-Path -LiteralPath $nodeZip)) {
    Write-Build ("Downloading {0}" -f $url) 'title'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $url -OutFile $nodeZip -UseBasicParsing
  } else {
    Write-Build ("Reusing cached {0}" -f $nodeZip) 'ok'
  }

  $extract = Join-Path $stage 'runtime\_extract'
  $target = Join-Path $stage 'runtime\node'
  New-Item -ItemType Directory -Path (Join-Path $stage 'runtime') -Force | Out-Null
  if (Test-Path -LiteralPath $extract) { Remove-Item $extract -Recurse -Force }
  New-Item -ItemType Directory -Path $extract -Force | Out-Null

  Add-Type -AssemblyName System.IO.Compression.FileSystem
  [System.IO.Compression.ZipFile]::ExtractToDirectory($nodeZip, $extract)
  $inner = Get-ChildItem -LiteralPath $extract -Directory | Select-Object -First 1
  if ($null -eq $inner) { throw 'Node zip empty' }
  Move-Item -LiteralPath $inner.FullName -Destination $target
  Remove-Item -LiteralPath $extract -Recurse -Force -ErrorAction SilentlyContinue

  if (-not (Test-Path -LiteralPath (Join-Path $target 'node.exe'))) {
    throw 'Bundled node.exe missing'
  }
  Write-Build ("Bundled Node: {0}" -f $target) 'ok'
} else {
  Write-Build 'SkipNodeDownload: package will fetch Node on first run' 'warn'
}

# Zip result
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
Write-Build ("Compressing {0}" -f $zipPath) 'title'
if (Get-Command Compress-Archive -ErrorAction SilentlyContinue) {
  Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zipPath -Force
} else {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  [System.IO.Compression.ZipFile]::CreateFromDirectory($stage, $zipPath)
}

$item = Get-Item -LiteralPath $zipPath
Write-Build ("Done: {0} ({1:N1} MB)" -f $item.FullName, ($item.Length / 1MB)) 'ok'
Write-Output $zipPath
