#Requires -Version 5.1
<#
.SYNOPSIS
  Windows portable bootstrap: temp runtime -> install agent -> durable machine setup.

.DESCRIPTION
  1) Use bundled (or downloaded) Node inside this package as a TEMP runtime
  2) Promote Node to %LOCALAPPDATA%\dsh-onboarding\node (durable)
  3) Run the environment agent (credentials + optional launch)
  4) Write install-state + a durable start-dsh.cmd
  5) You may delete THIS package folder via cleanup.cmd afterwards
#>
[CmdletBinding()]
param(
  [switch]$NoLaunch,
  [switch]$SkipWarmup,
  [string]$ConfigUrl = $env:DSH_ONBOARD_CONFIG_URL
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-PortableStep {
  param([string]$Message, [ValidateSet('info','ok','warn','err','title')][string]$Level = 'info')
  $prefix = switch ($Level) {
    'ok' { '[ OK ]' } 'warn' { '[WARN]' } 'err' { '[ERR ]' } 'title' { '[====]' } default { '[ .. ]' }
  }
  $color = switch ($Level) {
    'ok' { 'Green' } 'warn' { 'Yellow' } 'err' { 'Red' } 'title' { 'Cyan' } default { 'Gray' }
  }
  Write-Host ("{0} {1}" -f $prefix, $Message) -ForegroundColor $color
}

function Test-NodeOk {
  param([string]$NodeExe)
  if (-not (Test-Path -LiteralPath $NodeExe)) { return $false }
  try {
    $raw = & $NodeExe -v 2>$null
    $text = ([string]$raw).Trim()
    if ($text -match '^v?(\d+)\.(\d+)\.(\d+)') {
      $major = [int]$Matches[1]; $minor = [int]$Matches[2]
      if ($major -eq 22 -and $minor -ge 19) { return $true }
      if ($major -ge 24) { return $true }
    }
  } catch {}
  return $false
}

function Get-PackageNodeExe {
  param([string]$Root)
  $direct = Join-Path $Root 'runtime\node\node.exe'
  if (Test-NodeOk $direct) { return $direct }
  $dirs = Get-ChildItem -LiteralPath (Join-Path $Root 'runtime') -Directory -ErrorAction SilentlyContinue
  foreach ($d in @($dirs)) {
    $cand = Join-Path $d.FullName 'node.exe'
    if (Test-NodeOk $cand) { return $cand }
    $nested = Get-ChildItem -LiteralPath $d.FullName -Filter node.exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -ne $nested -and (Test-NodeOk $nested.FullName)) { return $nested.FullName }
  }
  return $null
}

function Get-PreferredNodeVersion {
  $fallback = '22.22.0'
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $idx = Invoke-RestMethod -Uri 'https://nodejs.org/dist/index.json' -TimeoutSec 30
    $pick = $idx | Where-Object {
      $_.version -match '^v22\.' -and
      [int]($_.version.TrimStart('v').Split('.')[1]) -ge 19 -and
      $_.files -contains 'win-x64-zip'
    } | Select-Object -First 1
    if ($null -ne $pick) { return $pick.version.TrimStart('v') }
  } catch {}
  return $fallback
}

function Install-TempNodeIntoPackage {
  param([string]$Root)
  $ver = Get-PreferredNodeVersion
  $zipName = "node-v$ver-win-x64.zip"
  $url = "https://nodejs.org/dist/v$ver/$zipName"
  $zipPath = Join-Path $env:TEMP $zipName
  $runtimeRoot = Join-Path $Root 'runtime'
  $extract = Join-Path $runtimeRoot '_extract'
  $target = Join-Path $runtimeRoot 'node'

  Write-PortableStep ("Downloading temp Node v{0} into package runtime..." -f $ver) 'title'
  Write-PortableStep $url
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $wc = New-Object System.Net.WebClient
  $wc.DownloadFile($url, $zipPath)

  if (Test-Path -LiteralPath $extract) { Remove-Item -LiteralPath $extract -Recurse -Force }
  if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
  New-Item -ItemType Directory -Path $extract -Force | Out-Null
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $extract)
  $inner = Get-ChildItem -LiteralPath $extract -Directory | Select-Object -First 1
  if ($null -eq $inner) { throw 'Node zip layout unexpected' }
  Move-Item -LiteralPath $inner.FullName -Destination $target
  Remove-Item -LiteralPath $extract -Recurse -Force -ErrorAction SilentlyContinue

  $exe = Join-Path $target 'node.exe'
  if (-not (Test-NodeOk $exe)) { throw 'Temp Node install failed validation' }
  Write-PortableStep ("Temp runtime ready: {0}" -f $target) 'ok'
  return $exe
}

function Promote-NodeToDurable {
  param([string]$SourceNodeExe)
  $sourceDir = Split-Path -Parent $SourceNodeExe
  $verText = (& $SourceNodeExe -v).ToString().Trim().TrimStart('v')
  $durableRoot = Join-Path $env:LOCALAPPDATA 'dsh-onboarding\node'
  $durableHome = Join-Path $durableRoot ("v{0}" -f $verText)
  $durableExe = Join-Path $durableHome 'node.exe'

  if (Test-NodeOk $durableExe) {
    Write-PortableStep ("Durable Node already present: {0}" -f $durableHome) 'ok'
    return $durableHome
  }

  Write-PortableStep ("Promoting Node to durable location: {0}" -f $durableHome) 'title'
  New-Item -ItemType Directory -Path $durableRoot -Force | Out-Null
  if (Test-Path -LiteralPath $durableHome) {
    Remove-Item -LiteralPath $durableHome -Recurse -Force
  }
  Copy-Item -LiteralPath $sourceDir -Destination $durableHome -Recurse -Force

  if (-not (Test-NodeOk (Join-Path $durableHome 'node.exe'))) {
    throw 'Durable Node promotion failed'
  }

  # Persist user PATH
  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  if ([string]::IsNullOrWhiteSpace($userPath)) {
    [Environment]::SetEnvironmentVariable('Path', $durableHome, 'User')
  } elseif ($userPath -notlike ("*{0}*" -f $durableHome)) {
    [Environment]::SetEnvironmentVariable('Path', ($durableHome + ';' + $userPath), 'User')
  }
  $env:Path = "{0};{1}" -f $durableHome, $env:Path
  Write-PortableStep 'Durable Node promoted and added to user PATH' 'ok'
  return $durableHome
}

function Write-DurableLauncher {
  param(
    [string]$DurableHome,
    [string]$PackageName,
    [string[]]$LaunchArgs
  )
  $base = Join-Path $env:LOCALAPPDATA 'dsh-onboarding'
  New-Item -ItemType Directory -Path $base -Force | Out-Null
  $launcher = Join-Path $base 'start-dsh.cmd'
  $argsLine = ($LaunchArgs | ForEach-Object { $_ }) -join ' '
  $content = @"
@echo off
setlocal
set "PATH=$DurableHome;%PATH%"
set "DEEPSEEK_API_KEY="
rem Credentials are read from %USERPROFILE%\.dsh by dsh itself.
echo Starting DeepSeek Harness...
npx -y $PackageName $argsLine
endlocal
"@
  # UTF-8 without BOM for cmd
  $utf8 = New-Object System.Text.UTF8Encoding $false
  [System.IO.File]::WriteAllText($launcher, $content, $utf8)
  Write-PortableStep ("Durable launcher: {0}" -f $launcher) 'ok'
  return $launcher
}

function Write-InstallState {
  param(
    [string]$DurableHome,
    [string]$Launcher,
    [string]$PackageRoot,
    [string]$PackageName,
    [string]$BaseURL
  )
  $base = Join-Path $env:LOCALAPPDATA 'dsh-onboarding'
  $statePath = Join-Path $base 'install-state.json'
  $state = [ordered]@{
    installedAt     = (Get-Date).ToString('o')
    durableNodeHome = $DurableHome
    launcher        = $Launcher
    packageRoot     = $PackageRoot
    package         = $PackageName
    baseURL         = $BaseURL
    dshHome         = $(if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $HOME '.dsh' })
    portableCanDelete = $true
    note            = 'This portable folder is temporary. After success run cleanup.cmd to remove it. Keep durable Node + ~/.dsh.'
  }
  $json = $state | ConvertTo-Json -Depth 5
  $utf8 = New-Object System.Text.UTF8Encoding $false
  [System.IO.File]::WriteAllText($statePath, $json, $utf8)
  # marker inside package
  [System.IO.File]::WriteAllText((Join-Path $PackageRoot '.install-ok'), $json, $utf8)
  Write-PortableStep ("Install state: {0}" -f $statePath) 'ok'
  return $statePath
}

# ban --- main ---
$PackageRoot = $PSScriptRoot
Write-PortableStep 'DeepSeek Harness Windows portable bootstrap' 'title'
Write-PortableStep 'Temp runtime in this folder -> durable install on machine -> optional cleanup' 
Write-PortableStep ("Package: {0}" -f $PackageRoot)

# 1) temp node in package
$nodeExe = Get-PackageNodeExe -Root $PackageRoot
if (-not $nodeExe) {
  Write-PortableStep 'Bundled runtime not found; downloading temp Node into package...' 'warn'
  $nodeExe = Install-TempNodeIntoPackage -Root $PackageRoot
} else {
  Write-PortableStep ("Using package temp Node: {0}" -f $nodeExe) 'ok'
}

$tempNodeDir = Split-Path -Parent $nodeExe
$env:Path = "{0};{1}" -f $tempNodeDir, $env:Path

# 2) promote to durable
$durableHome = Promote-NodeToDurable -SourceNodeExe $nodeExe
$env:Path = "{0};{1}" -f $durableHome, $env:Path

# 3) locate agent script + config inside package
$agentScript = Join-Path $PackageRoot 'agent\bootstrap.ps1'
if (-not (Test-Path -LiteralPath $agentScript)) {
  # dev layout: repo windows-portable next to scripts/
  $devAgent = Join-Path $PackageRoot '..\scripts\bootstrap.ps1'
  if (Test-Path -LiteralPath $devAgent) { $agentScript = (Resolve-Path $devAgent).Path }
}
if (-not (Test-Path -LiteralPath $agentScript)) {
  throw "bootstrap agent not found. Expected: $PackageRoot\agent\bootstrap.ps1"
}

$localConfig = Join-Path $PackageRoot 'config\defaults.json'
if ([string]::IsNullOrWhiteSpace($ConfigUrl) -and (Test-Path -LiteralPath $localConfig)) {
  # Prefer packaged config for offline-ish first boot; remote still works if set.
  Write-PortableStep ("Using packaged config: {0}" -f $localConfig) 'ok'
} elseif ([string]::IsNullOrWhiteSpace($ConfigUrl)) {
  $ConfigUrl = 'https://dsh-onboarding.pages.dev/config/defaults.json'
}

# 4) run environment agent in NoLaunch mode first (must finish before we write durable artifacts)
Write-PortableStep 'Starting environment install agent (configure only)...' 'title'
if (-not [string]::IsNullOrWhiteSpace($ConfigUrl)) {
  $env:DSH_ONBOARD_CONFIG_URL = $ConfigUrl
}

& $agentScript -SkipNodeInstall -NoLaunch -MaxRounds 8
$agentCode = $LASTEXITCODE
if ($null -eq $agentCode) { $agentCode = 0 }
if ($agentCode -ne 0) {
  Write-PortableStep ("Install agent exited with code {0}" -f $agentCode) 'err'
  exit $agentCode
}

# Read package name from config if possible
$pkgName = '@deepseek-ai/dsh'
$baseURL = ''
$cfgPath = $localConfig
if (Test-Path -LiteralPath $cfgPath) {
  try {
    $cfg = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($cfg.cliPackage) { $pkgName = [string]$cfg.cliPackage }
    if ($cfg.baseURL) { $baseURL = [string]$cfg.baseURL }
  } catch {}
}

# 5) warm npx cache so first real launch is faster (optional)
if (-not $SkipWarmup) {
  Write-PortableStep 'Warming npx package cache (one-time)...' 'title'
  try {
    & npx -y $pkgName --help 2>$null | Out-Null
    Write-PortableStep 'npx cache warmed' 'ok'
  } catch {
    Write-PortableStep ("npx warm skipped: {0}" -f $_.Exception.Message) 'warn'
  }
}

# 6) durable launcher + state (before interactive launch so cleanup is always available)
$launcher = Write-DurableLauncher -DurableHome $durableHome -PackageName $pkgName -LaunchArgs @('web')
$statePath = Write-InstallState -DurableHome $durableHome -Launcher $launcher -PackageRoot $PackageRoot -PackageName $pkgName -BaseURL $baseURL

Write-PortableStep 'Install phase finished — durable environment is ready' 'title'
Write-PortableStep 'Durable pieces (keep these):' 'ok'
Write-PortableStep ("  Node:     {0}" -f $durableHome)
Write-PortableStep ("  Launcher: {0}" -f $launcher)
Write-PortableStep ("  State:    {0}" -f $statePath)
Write-PortableStep ("  Creds:    {0}" -f (Join-Path $HOME '.dsh'))
Write-PortableStep 'Temporary piece (safe to delete after you close dsh):' 'warn'
Write-PortableStep ("  This folder: {0}" -f $PackageRoot)
Write-PortableStep 'Run cleanup.cmd in this folder to remove the temp package.' 'info'

if ($NoLaunch) {
  Write-PortableStep 'NoLaunch set — not starting Web UI now.' 'ok'
  Write-PortableStep ("Start later: {0}" -f $launcher) 'info'
  exit 0
}

# 7) launch dsh (blocking). Portable folder remains until user runs cleanup.
Write-PortableStep ("Launch: npx -y {0} web" -f $pkgName) 'title'
Write-PortableStep 'Default Web UI: http://127.0.0.1:3080' 'info'
& npx -y $pkgName web
exit $LASTEXITCODE
