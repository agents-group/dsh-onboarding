#Requires -Version 5.1
<#
.SYNOPSIS
  One-line Windows bootstrap: download temp runtime from CDN, run install agent, leave durable setup.

.DESCRIPTION
  Usage (copy from site):
    irm https://dsh-onboarding.pages.dev/scripts/bootstrap-win.ps1 | iex

  Flow:
    1) Create temp work dir under %TEMP%
    2) Fetch agent + config from Cloudflare Pages (or -BaseUrl)
    3) Fetch portable Node (npmmirror first, nodejs.org fallback; or full zip if -PackageUrl / R2)
    4) Promote Node to %LOCALAPPDATA%\dsh-onboarding\node
    5) Run environment agent (credentials + optional launch)
    6) Remove temp dir (always for successful configure; launch may keep session)

  Optional full portable zip (e.g. Cloudflare R2):
    $env:DSH_ONBOARD_WIN_PACKAGE_URL = 'https://.../dsh-onboarding-windows-portable.zip'
    irm https://dsh-onboarding.pages.dev/scripts/bootstrap-win.ps1 | iex
#>
[CmdletBinding()]
param(
  [string]$BaseUrl = $(if ($env:DSH_ONBOARD_BASE_SITE) { $env:DSH_ONBOARD_BASE_SITE } else { 'https://dsh-onboarding.pages.dev' }),
  [string]$PackageUrl = $(if ($env:DSH_ONBOARD_WIN_PACKAGE_URL) { $env:DSH_ONBOARD_WIN_PACKAGE_URL } else { '' }),
  [string]$ConfigUrl,
  [string]$NodeVersion,
  [switch]$NoLaunch,
  [switch]$KeepTemp,
  [switch]$SkipWarmup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Boot {
  param([string]$Message, [ValidateSet('info','ok','warn','err','title')][string]$Level = 'info')
  $prefix = switch ($Level) {
    'ok' { '[ OK ]' } 'warn' { '[WARN]' } 'err' { '[ERR ]' } 'title' { '[====]' } default { '[ .. ]' }
  }
  $color = switch ($Level) {
    'ok' { 'Green' } 'warn' { 'Yellow' } 'err' { 'Red' } 'title' { 'Cyan' } default { 'Gray' }
  }
  Write-Host ("{0} {1}" -f $prefix, $Message) -ForegroundColor $color
}

function Get-BaseUrlNormalized {
  param([string]$Url)
  return $Url.Trim().TrimEnd('/')
}

function Invoke-Download {
  param(
    [string]$Url,
    [string]$OutFile,
    [int]$TimeoutSec = 600
  )
  Write-Boot ("Download: {0}" -f $Url)
  Write-Boot ("     to: {0}" -f $OutFile)
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $dir = Split-Path -Parent $OutFile
  if (-not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
  # Prefer BITS-less WebClient with progress-ish length check
  $wc = New-Object System.Net.WebClient
  $wc.Headers.Add('User-Agent', 'dsh-onboarding-bootstrap-win')
  try {
    $wc.DownloadFile($Url, $OutFile)
  } finally {
    $wc.Dispose()
  }
  if (-not (Test-Path -LiteralPath $OutFile) -or ((Get-Item -LiteralPath $OutFile).Length -lt 32)) {
    throw "Download failed or file too small: $Url"
  }
}

function Test-NodeExe {
  param([string]$Exe)
  if (-not (Test-Path -LiteralPath $Exe)) { return $false }
  try {
    $raw = & $Exe -v 2>$null
    $t = ([string]$raw).Trim()
    if ($t -match '^v?(\d+)\.(\d+)\.(\d+)') {
      $maj = [int]$Matches[1]; $min = [int]$Matches[2]
      if ($maj -eq 22 -and $min -ge 19) { return $true }
      if ($maj -ge 24) { return $true }
    }
  } catch {}
  return $false
}

function Get-NodeVersionPick {
  if (-not [string]::IsNullOrWhiteSpace($NodeVersion)) { return $NodeVersion.TrimStart('v') }
  $fallback = '22.22.0'
  $mirrors = @(
    'https://cdn.npmmirror.com/binaries/node/index.json',
    'https://nodejs.org/dist/index.json'
  )
  foreach ($u in $mirrors) {
    try {
      [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
      $idx = Invoke-RestMethod -Uri $u -TimeoutSec 20
      $pick = $idx | Where-Object {
        $_.version -match '^v22\.' -and
        [int]($_.version.TrimStart('v').Split('.')[1]) -ge 19 -and
        ($_.files -contains 'win-x64-zip' -or -not $_.files)
      } | Select-Object -First 1
      if ($null -ne $pick) { return $pick.version.TrimStart('v') }
    } catch {
      Write-Boot ("Node index via {0} failed: {1}" -f $u, $_.Exception.Message) 'warn'
    }
  }
  return $fallback
}

function Expand-Zip {
  param([string]$ZipPath, [string]$Dest)
  if (Test-Path -LiteralPath $Dest) { Remove-Item -LiteralPath $Dest -Recurse -Force }
  New-Item -ItemType Directory -Path $Dest -Force | Out-Null
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $Dest)
}

function Install-NodeFromMirrors {
  param([string]$WorkRoot)
  $ver = Get-NodeVersionPick
  $name = "node-v$ver-win-x64.zip"
  $urls = @(
    "https://cdn.npmmirror.com/binaries/node/v$ver/$name",
    "https://npmmirror.com/mirrors/node/v$ver/$name",
    "https://nodejs.org/dist/v$ver/$name"
  )
  $zipPath = Join-Path $WorkRoot $name
  $ok = $false
  foreach ($u in $urls) {
    try {
      Invoke-Download -Url $u -OutFile $zipPath
      $ok = $true
      break
    } catch {
      Write-Boot ("Node download failed: {0}" -f $_.Exception.Message) 'warn'
    }
  }
  if (-not $ok) { throw 'Could not download portable Node from any mirror' }

  $extract = Join-Path $WorkRoot 'node-extract'
  Expand-Zip -ZipPath $zipPath -Dest $extract
  $inner = Get-ChildItem -LiteralPath $extract -Directory | Select-Object -First 1
  if ($null -eq $inner) { throw 'Node zip layout unexpected' }
  $nodeHome = Join-Path $WorkRoot 'node'
  if (Test-Path -LiteralPath $nodeHome) { Remove-Item -LiteralPath $nodeHome -Recurse -Force }
  Move-Item -LiteralPath $inner.FullName -Destination $nodeHome
  $exe = Join-Path $nodeHome 'node.exe'
  if (-not (Test-NodeExe $exe)) { throw 'Downloaded Node failed validation' }
  Write-Boot ("Temp Node ready: {0}" -f $nodeHome) 'ok'
  return $nodeHome
}

function Promote-DurableNode {
  param([string]$SourceHome)
  $exe = Join-Path $SourceHome 'node.exe'
  $ver = (& $exe -v).ToString().Trim().TrimStart('v')
  $root = Join-Path $env:LOCALAPPDATA 'dsh-onboarding\node'
  # NOTE: never use $home — PowerShell aliases it to read-only $HOME.
  $nodeHomeDir = Join-Path $root ("v{0}" -f $ver)
  $destExe = Join-Path $nodeHomeDir 'node.exe'
  if (Test-NodeExe $destExe) {
    Write-Boot ("Durable Node exists: {0}" -f $nodeHomeDir) 'ok'
  } else {
    Write-Boot ("Promote Node -> {0}" -f $nodeHomeDir) 'title'
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    if (Test-Path -LiteralPath $nodeHomeDir) { Remove-Item -LiteralPath $nodeHomeDir -Recurse -Force }
    Copy-Item -LiteralPath $SourceHome -Destination $nodeHomeDir -Recurse -Force
    if (-not (Test-NodeExe (Join-Path $nodeHomeDir 'node.exe'))) { throw 'Durable promote failed' }
    Write-Boot 'Durable Node promoted' 'ok'
  }

  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  if ([string]::IsNullOrWhiteSpace($userPath)) {
    [Environment]::SetEnvironmentVariable('Path', $nodeHomeDir, 'User')
  } elseif ($userPath -notlike ("*{0}*" -f $nodeHomeDir)) {
    [Environment]::SetEnvironmentVariable('Path', ($nodeHomeDir + ';' + $userPath), 'User')
  }
  $env:Path = "{0};{1}" -f $nodeHomeDir, $env:Path
  return $nodeHomeDir
}

function Write-DurableLauncher {
  param([string]$DurableHome, [string]$PackageName)
  $base = Join-Path $env:LOCALAPPDATA 'dsh-onboarding'
  New-Item -ItemType Directory -Path $base -Force | Out-Null
  $launcher = Join-Path $base 'start-dsh.cmd'
  $content = @"
@echo off
setlocal
set "PATH=$DurableHome;%PATH%"
echo Starting DeepSeek Harness...
npx -y $PackageName web
endlocal
"@
  $utf8 = New-Object System.Text.UTF8Encoding $false
  [System.IO.File]::WriteAllText($launcher, $content, $utf8)
  return $launcher
}

function Write-InstallState {
  param([string]$DurableHome, [string]$Launcher, [string]$WorkRoot, [string]$PackageName, [string]$BaseURL)
  $base = Join-Path $env:LOCALAPPDATA 'dsh-onboarding'
  $statePath = Join-Path $base 'install-state.json'
  $obj = [ordered]@{
    installedAt = (Get-Date).ToString('o')
    durableNodeHome = $DurableHome
    launcher = $Launcher
    workRoot = $WorkRoot
    package = $PackageName
    baseURL = $BaseURL
    dshHome = $(if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $HOME '.dsh' })
    bootstrap = 'bootstrap-win.ps1'
    tempRemovable = $true
  }
  $utf8 = New-Object System.Text.UTF8Encoding $false
  [System.IO.File]::WriteAllText($statePath, ($obj | ConvertTo-Json -Depth 5), $utf8)
  return $statePath
}

function Get-FromFullPackage {
  param([string]$Url, [string]$WorkRoot)
  $zip = Join-Path $WorkRoot 'portable.zip'
  Invoke-Download -Url $Url -OutFile $zip
  $extract = Join-Path $WorkRoot 'portable'
  Expand-Zip -ZipPath $zip -Dest $extract
  # zip may contain nested folder or flat files
  $start = Get-ChildItem -LiteralPath $extract -Filter 'start.ps1' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
  $agent = Get-ChildItem -LiteralPath $extract -Filter 'bootstrap.ps1' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
  $node = Get-ChildItem -LiteralPath $extract -Filter 'node.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -eq $agent -and $null -eq $start) {
    throw 'Portable zip missing agent/start.ps1'
  }
  return [pscustomobject]@{
    Root = $extract
    StartPs1 = $(if ($start) { $start.FullName } else { $null })
    Agent = $(if ($agent) { $agent.FullName } else { $null })
    NodeHome = $(if ($node) { Split-Path -Parent $node.FullName } else { $null })
  }
}

# ---------------- main ----------------
$BaseUrl = Get-BaseUrlNormalized $BaseUrl
if ([string]::IsNullOrWhiteSpace($ConfigUrl)) {
  $ConfigUrl = $env:DSH_ONBOARD_CONFIG_URL
}
if ([string]::IsNullOrWhiteSpace($ConfigUrl)) {
  $ConfigUrl = "$BaseUrl/config/defaults.json"
}

Write-Boot 'DeepSeek Harness Windows one-click bootstrap' 'title'
Write-Boot 'Download temp runtime -> install agent -> durable setup (Cloudflare-friendly)'
Write-Boot ("Site: {0}" -f $BaseUrl)
Write-Boot ("Config: {0}" -f $ConfigUrl)

$work = Join-Path $env:TEMP ("dsh-onboard-win-" + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $work -Force | Out-Null
Write-Boot ("Temp work: {0}" -f $work)

$cleanup = {
  if ($KeepTemp) {
    Write-Boot ("KeepTemp: left {0}" -f $work) 'warn'
    return
  }
  try {
    if (Test-Path -LiteralPath $work) {
      Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
      Write-Boot 'Temp runtime removed' 'ok'
    }
  } catch {
    Write-Boot ("Temp cleanup deferred: {0}" -f $_.Exception.Message) 'warn'
  }
}

try {
  $pkgName = '@deepseek-ai/dsh'
  $baseURLCfg = ''
  $agentScript = $null
  $nodeHome = $null

  if (-not [string]::IsNullOrWhiteSpace($PackageUrl)) {
    Write-Boot 'Using full portable package URL (R2/CDN)' 'title'
    $pack = Get-FromFullPackage -Url $PackageUrl -WorkRoot $work
    if ($pack.StartPs1) {
      # Delegate to packaged start (already implements promote+agent)
      Write-Boot 'Handing off to packaged start.ps1' 'ok'
      $env:DSH_ONBOARD_CONFIG_URL = $ConfigUrl
      $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $pack.StartPs1)
      if ($NoLaunch) { $args += '-NoLaunch' }
      if ($SkipWarmup) { $args += '-SkipWarmup' }
      & powershell.exe @args
      $code = $LASTEXITCODE
      if (-not $KeepTemp) { & $cleanup }
      exit $code
    }
    $agentScript = $pack.Agent
    $nodeHome = $pack.NodeHome
  }

  if (-not $agentScript) {
    # Thin mode: pull agent+config from Cloudflare Pages, Node from China-friendly mirrors
    Write-Boot 'Thin mode: fetch agent from Cloudflare Pages + Node from mirrors' 'title'
    $agentDir = Join-Path $work 'agent'
    $cfgDir = Join-Path $work 'config'
    New-Item -ItemType Directory -Path $agentDir -Force | Out-Null
    New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null
    Invoke-Download -Url ($BaseUrl + '/scripts/bootstrap.ps1') -OutFile (Join-Path $agentDir 'bootstrap.ps1')
    try {
      Invoke-Download -Url $ConfigUrl -OutFile (Join-Path $cfgDir 'defaults.json')
    } catch {
      Write-Boot ("Config download failed, agent may use built-in defaults: {0}" -f $_.Exception.Message) 'warn'
    }
    $agentScript = Join-Path $agentDir 'bootstrap.ps1'
  }

  if (-not $nodeHome) {
    # Reuse durable node if already good
    $existing = Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'dsh-onboarding\node') -Directory -ErrorAction SilentlyContinue |
      ForEach-Object { Join-Path $_.FullName 'node.exe' } |
      Where-Object { Test-NodeExe $_ } |
      Select-Object -First 1
    if ($existing) {
      $nodeHome = Split-Path -Parent $existing
      Write-Boot ("Reusing durable Node: {0}" -f $nodeHome) 'ok'
    } else {
      $nodeHome = Install-NodeFromMirrors -WorkRoot $work
    }
  }

  $durable = Promote-DurableNode -SourceHome $nodeHome
  $env:Path = "{0};{1}" -f $durable, $env:Path

  # Load package name from config if present
  $cfgFile = Join-Path $work 'config\defaults.json'
  if (Test-Path -LiteralPath $cfgFile) {
    try {
      $cfg = Get-Content -LiteralPath $cfgFile -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($cfg.cliPackage) { $pkgName = [string]$cfg.cliPackage }
      if ($cfg.baseURL) { $baseURLCfg = [string]$cfg.baseURL }
    } catch {}
  }

  Write-Boot 'Run environment agent (configure)...' 'title'
  $env:DSH_ONBOARD_CONFIG_URL = $ConfigUrl
  # Point local config beside agent when available (bootstrap resolves ../config/defaults.json from scripts path — mirror layout)
  $layoutRoot = Join-Path $work 'layout'
  $layoutScripts = Join-Path $layoutRoot 'scripts'
  $layoutConfig = Join-Path $layoutRoot 'config'
  New-Item -ItemType Directory -Path $layoutScripts -Force | Out-Null
  New-Item -ItemType Directory -Path $layoutConfig -Force | Out-Null
  Copy-Item -LiteralPath $agentScript -Destination (Join-Path $layoutScripts 'bootstrap.ps1') -Force
  if (Test-Path -LiteralPath $cfgFile) {
    Copy-Item -LiteralPath $cfgFile -Destination (Join-Path $layoutConfig 'defaults.json') -Force
  }
  $runAgent = Join-Path $layoutScripts 'bootstrap.ps1'

  # Nested scripts under %TEMP% are often blocked by ExecutionPolicy when invoked with "& file.ps1".
  # Always spawn a child powershell with Bypass (does not change machine policy).
  Write-Boot 'Run agent with ExecutionPolicy Bypass (child process)...'
  $agentArgs = @(
    '-NoProfile'
    '-ExecutionPolicy', 'Bypass'
    '-File', $runAgent
    '-SkipNodeInstall'
    '-NoLaunch'
    '-MaxRounds', '8'
  )
  $agentProc = Start-Process -FilePath 'powershell.exe' -ArgumentList $agentArgs -Wait -PassThru -NoNewWindow
  $agentCode = $agentProc.ExitCode
  if ($null -eq $agentCode) { $agentCode = 0 }
  if ($agentCode -ne 0) {
    Write-Boot ("Agent failed code={0}" -f $agentCode) 'err'
    if (-not $KeepTemp) { & $cleanup }
    exit $agentCode
  }

  if (-not $SkipWarmup) {
    Write-Boot 'Warm npx cache...' 'title'
    try { & npx -y $pkgName --help 2>$null | Out-Null; Write-Boot 'npx cache ok' 'ok' } catch {
      Write-Boot ("npx warm warn: {0}" -f $_.Exception.Message) 'warn'
    }
  }

  $launcher = Write-DurableLauncher -DurableHome $durable -PackageName $pkgName
  $state = Write-InstallState -DurableHome $durable -Launcher $launcher -WorkRoot $work -PackageName $pkgName -BaseURL $baseURLCfg

  Write-Boot 'Durable environment ready' 'title'
  Write-Boot ("Node:     {0}" -f $durable) 'ok'
  Write-Boot ("Launcher: {0}" -f $launcher) 'ok'
  Write-Boot ("State:    {0}" -f $state) 'ok'
  Write-Boot ("Creds:    {0}" -f (Join-Path $HOME '.dsh')) 'ok'

  if (-not $KeepTemp) { & $cleanup }

  if ($NoLaunch) {
    Write-Boot 'NoLaunch: skip Web UI' 'ok'
    Write-Boot ("Later: {0}" -f $launcher) 'info'
    exit 0
  }

  Write-Boot ("Launch: npx -y {0} web" -f $pkgName) 'title'
  Write-Boot 'Web UI: http://127.0.0.1:3080' 'info'
  & npx -y $pkgName web
  exit $LASTEXITCODE
} catch {
  Write-Boot $_.Exception.Message 'err'
  if (-not $KeepTemp) {
    try { & $cleanup } catch {}
  } else {
    Write-Boot ("Temp kept for debug: {0}" -f $work) 'warn'
  }
  exit 1
}
