#Requires -Version 5.1
<#
.SYNOPSIS
  DeepSeek Harness (dsh) one-click env check, deps, credentials, launch.

.DESCRIPTION
  Recommended:
    $env:DSH_ONBOARD_CONFIG_URL='https://<site>/config/defaults.json'
    irm https://<site>/scripts/bootstrap.ps1 | iex

  Local:
    .\bootstrap.ps1
    .\bootstrap.ps1 -CheckOnly
    .\bootstrap.ps1 -NoLaunch
    .\bootstrap.ps1 -ApiKey 'sk-xxx' -BaseURL 'https://api.example/v1'

  Env overrides:
    DSH_ONBOARD_API_KEY, DSH_ONBOARD_BASE_URL, DSH_ONBOARD_CONFIG_URL
#>
[CmdletBinding()]
param(
  [string]$ApiKey,
  [string]$BaseURL,
  [string]$ConfigUrl,
  [string]$Package = '@deepseek-ai/dsh',
  [string[]]$LaunchArgs = @('web'),
  [switch]$CheckOnly,
  [switch]$NoLaunch,
  [switch]$SkipNodeInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ==== Built-in defaults (edit before deploy; defaults.json / env can override) ====
$Script:DefaultApiKey = 'sk-PGHkWh0C8rV1FMuQ2D4jXAtYBnSRILcz07zpQ7NR16RMYfbJ'
$Script:DefaultBaseURL = 'https://newapi.dapeng.uno/v1'
# ==============================================================================

function Write-Step {
  param(
    [string]$Message,
    [ValidateSet('info', 'ok', 'warn', 'err', 'title')]
    [string]$Level = 'info'
  )
  $prefix = switch ($Level) {
    'ok' { '[ OK ]' }
    'warn' { '[WARN]' }
    'err' { '[ERR ]' }
    'title' { '[====]' }
    default { '[ .. ]' }
  }
  $color = switch ($Level) {
    'ok' { 'Green' }
    'warn' { 'Yellow' }
    'err' { 'Red' }
    'title' { 'Cyan' }
    default { 'Gray' }
  }
  Write-Host ("{0} {1}" -f $prefix, $Message) -ForegroundColor $color
}

function Read-RemoteConfig {
  param([string]$Url)
  if ([string]::IsNullOrWhiteSpace($Url)) { return $null }
  try {
    Write-Step ("Fetch config: {0}" -f $Url)
    return Invoke-RestMethod -Uri $Url -Method Get -TimeoutSec 20
  } catch {
    Write-Step ("Config fetch failed, fallback to built-in/params: {0}" -f $_.Exception.Message) 'warn'
    return $null
  }
}

function Test-NodeVersion {
  param([version]$Version)
  if ($Version.Major -eq 22 -and $Version.Minor -ge 19) { return $true }
  if ($Version.Major -ge 24) { return $true }
  return $false
}

function Get-NodeVersionObject {
  $cmd = Get-Command node -ErrorAction SilentlyContinue
  if ($null -eq $cmd) { return $null }
  try {
    $raw = (& node -v 2>$null)
    if ($null -eq $raw) { return $null }
    $text = ([string]$raw).Trim()
    if ($text -match '^v?(\d+)\.(\d+)\.(\d+)') {
      return [version]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3])
    }
  } catch {
    return $null
  }
  return $null
}

function Update-SessionPath {
  $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
  $user = [Environment]::GetEnvironmentVariable('Path', 'User')
  $env:Path = "{0};{1}" -f $machine, $user
}

function Add-UserPathEntry {
  param([string]$Dir)
  if ([string]::IsNullOrWhiteSpace($Dir) -or -not (Test-Path -LiteralPath $Dir)) { return }
  $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
  if ([string]::IsNullOrWhiteSpace($userPath)) {
    [Environment]::SetEnvironmentVariable('Path', $Dir, 'User')
  } else {
    $parts = @($userPath -split ';' | Where-Object { $_ -and $_.Trim() })
    $exists = $false
    foreach ($p in $parts) {
      if ([string]::Equals($p, $Dir, [StringComparison]::OrdinalIgnoreCase)) { $exists = $true; break }
    }
    if (-not $exists) {
      [Environment]::SetEnvironmentVariable('Path', ($Dir + ';' + $userPath), 'User')
    }
  }
  if ($env:Path -notlike ("*{0}*" -f $Dir)) {
    $env:Path = "{0};{1}" -f $Dir, $env:Path
  }
}

function Get-PreferredNodeWinAsset {
  # Prefer current Node 22.x win zip (matches dsh engines ^22.19 || >=24), no admin required.
  $fallback = [pscustomobject]@{
    version = '22.22.0'
    arch = $(if ([Environment]::Is64BitOperatingSystem) { 'x64' } else { 'x86' })
  }
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $idx = Invoke-RestMethod -Uri 'https://nodejs.org/dist/index.json' -TimeoutSec 30
    $pick = $idx | Where-Object {
      $_.version -match '^v22\.' -and
      [int]($_.version.TrimStart('v').Split('.')[1]) -ge 19 -and
      $_.files -contains $(if ([Environment]::Is64BitOperatingSystem) { 'win-x64-zip' } else { 'win-x86-zip' })
    } | Select-Object -First 1
    if ($null -ne $pick) {
      return [pscustomobject]@{
        version = $pick.version.TrimStart('v')
        arch = $(if ([Environment]::Is64BitOperatingSystem) { 'x64' } else { 'x86' })
      }
    }
  } catch {
    Write-Step ("Could not query nodejs.org index, using fallback v{0}: {1}" -f $fallback.version, $_.Exception.Message) 'warn'
  }
  return $fallback
}

function Install-NodePortableZip {
  param([int]$TimeoutSec = 180)

  $asset = Get-PreferredNodeWinAsset
  $ver = $asset.version
  $arch = $asset.arch
  $zipName = "node-v{0}-win-{1}.zip" -f $ver, $arch
  $url = "https://nodejs.org/dist/v{0}/{1}" -f $ver, $zipName
  $work = Join-Path $env:LOCALAPPDATA 'dsh-onboarding\node'
  $zipPath = Join-Path $env:TEMP $zipName
  $extractRoot = Join-Path $work 'extract'
  $nodeHome = Join-Path $work ("v{0}" -f $ver)

  Write-Step ("Downloading portable Node.js v{0} ({1}) — no admin/UAC..." -f $ver, $arch)
  Write-Step ("URL: {0}" -f $url)
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $wc = New-Object System.Net.WebClient
    $wc.DownloadFile($url, $zipPath)
  } catch {
    Write-Step ("Portable download failed: {0}" -f $_.Exception.Message) 'warn'
    return $false
  }

  if (-not (Test-Path -LiteralPath $zipPath) -or ((Get-Item -LiteralPath $zipPath).Length -lt 1MB)) {
    Write-Step 'Downloaded Node zip looks invalid' 'warn'
    return $false
  }

  Write-Step 'Extracting portable Node.js...'
  try {
    if (Test-Path -LiteralPath $extractRoot) {
      Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path $extractRoot -Force | Out-Null
    if (Test-Path -LiteralPath $nodeHome) {
      Remove-Item -LiteralPath $nodeHome -Recurse -Force -ErrorAction SilentlyContinue
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zipPath, $extractRoot)
    $inner = Get-ChildItem -LiteralPath $extractRoot -Directory | Select-Object -First 1
    if ($null -eq $inner) { throw 'zip contained no directory' }
    Move-Item -LiteralPath $inner.FullName -Destination $nodeHome
  } catch {
    Write-Step ("Extract failed: {0}" -f $_.Exception.Message) 'warn'
    return $false
  }

  $nodeExe = Join-Path $nodeHome 'node.exe'
  if (-not (Test-Path -LiteralPath $nodeExe)) {
    Write-Step 'node.exe missing after extract' 'warn'
    return $false
  }

  Add-UserPathEntry -Dir $nodeHome
  $Script:PortableNodeHome = $nodeHome
  Write-Step ("Portable Node installed to {0}" -f $nodeHome) 'ok'
  return $true
}

function Invoke-ProcessWithTimeout {
  param(
    [string]$FilePath,
    [string[]]$ArgumentList,
    [int]$TimeoutSec = 300
  )
  Write-Step ("Running (timeout {0}s): {1} {2}" -f $TimeoutSec, $FilePath, ($ArgumentList -join ' '))
  $stdout = Join-Path $env:TEMP ("dsh-onboard-stdout-{0}.log" -f [guid]::NewGuid().ToString('n'))
  $stderr = Join-Path $env:TEMP ("dsh-onboard-stderr-{0}.log" -f [guid]::NewGuid().ToString('n'))
  try {
    $p = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -NoNewWindow -PassThru `
      -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $finished = $p.WaitForExit($TimeoutSec * 1000)
    if (-not $finished) {
      try { $p.Kill() } catch {}
      Write-Step ("Process timed out after {0}s and was killed" -f $TimeoutSec) 'warn'
      return 124
    }
    return $p.ExitCode
  } catch {
    Write-Step ("Process failed: {0}" -f $_.Exception.Message) 'warn'
    return 1
  } finally {
    foreach ($f in @($stdout, $stderr)) {
      if (Test-Path -LiteralPath $f) {
        Get-Content -LiteralPath $f -ErrorAction SilentlyContinue | Select-Object -Last 20 | ForEach-Object {
          Write-Host ("       {0}" -f $_)
        }
        Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
      }
    }
  }
}

function Install-NodeWindows {
  Write-Step 'Node.js not found. Installing automatically...' 'warn'
  Write-Step 'Prefer portable zip (no UAC). winget is only a fallback and can hang on some PCs.' 'info'

  # 1) Portable zip into %LOCALAPPDATA% — fastest and most reliable for one-click.
  $Script:PortableNodeHome = $null
  if (Install-NodePortableZip) {
    if ($Script:PortableNodeHome) { Add-UserPathEntry -Dir $Script:PortableNodeHome }
    Update-SessionPath
    if ($Script:PortableNodeHome) { $env:Path = "{0};{1}" -f $Script:PortableNodeHome, $env:Path }
    $ver = Get-NodeVersionObject
    if ($null -ne $ver -and (Test-NodeVersion $ver)) { return $true }
    Write-Step 'Portable Node extracted but node command still not visible in this session' 'warn'
  }

  # 2) winget with hard timeout (often hangs waiting for UI/UAC)
  $winget = Get-Command winget -ErrorAction SilentlyContinue
  if ($null -ne $winget) {
    Write-Step 'Trying winget (max 3 minutes, silent)...' 
    $code = Invoke-ProcessWithTimeout -FilePath $winget.Source -TimeoutSec 180 -ArgumentList @(
      'install', '-e', '--id', 'OpenJS.NodeJS.LTS',
      '--accept-package-agreements', '--accept-source-agreements',
      '--disable-interactivity', '--silent'
    )
    Update-SessionPath
    $ver = Get-NodeVersionObject
    if ($code -eq 0 -or ($null -ne $ver -and (Test-NodeVersion $ver))) {
      if ($null -ne $ver -and (Test-NodeVersion $ver)) { return $true }
    }
    Write-Step ("winget finished with code {0}" -f $code) 'warn'
  } else {
    Write-Step 'winget not found, skip' 'warn'
  }

  # 3) Chocolatey if present
  $choco = Get-Command choco -ErrorAction SilentlyContinue
  if ($null -ne $choco) {
    Write-Step 'Trying Chocolatey (max 5 minutes)...'
    $code = Invoke-ProcessWithTimeout -FilePath $choco.Source -TimeoutSec 300 -ArgumentList @('install', 'nodejs-lts', '-y')
    Update-SessionPath
    $ver = Get-NodeVersionObject
    if ($null -ne $ver -and (Test-NodeVersion $ver)) { return $true }
    Write-Step ("choco finished with code {0}" -f $code) 'warn'
  }

  Write-Step 'Automatic Node install failed.' 'err'
  Write-Step 'Install Node.js 22.19+ or 24+ from https://nodejs.org/ then re-open the terminal and run the command again.' 'warn'
  return $false
}

function Get-DshHome {
  if (-not [string]::IsNullOrWhiteSpace($env:DSH_HOME)) {
    return $env:DSH_HOME.Trim()
  }
  return (Join-Path $HOME '.dsh')
}

function Set-YamlKey {
  param([string]$Path, [string]$Key, [string]$Value)
  $dir = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }

  $lines = @()
  if (Test-Path -LiteralPath $Path) {
    $lines = @(Get-Content -LiteralPath $Path -ErrorAction Stop)
  }

  $pattern = '^\s*{0}\s*:' -f [regex]::Escape($Key)
  $replacement = '{0}: {1}' -f $Key, $Value
  $found = $false
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($line in $lines) {
    if ($line -match $pattern) {
      [void]$out.Add($replacement)
      $found = $true
    } else {
      [void]$out.Add([string]$line)
    }
  }
  if (-not $found) { [void]$out.Add($replacement) }

  $content = ($out -join "`n").TrimEnd() + "`n"
  $utf8 = New-Object System.Text.UTF8Encoding $false
  [System.IO.File]::WriteAllText($Path, $content, $utf8)
}

function Set-DotEnvKey {
  param([string]$Path, [string]$Key, [string]$Value)
  $dir = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }

  $lines = @()
  if (Test-Path -LiteralPath $Path) {
    $lines = @(Get-Content -LiteralPath $Path -ErrorAction Stop)
  }

  $pattern = '^\s*{0}\s*=' -f [regex]::Escape($Key)
  $replacement = '{0}={1}' -f $Key, $Value
  $found = $false
  $out = New-Object System.Collections.Generic.List[string]
  foreach ($line in $lines) {
    if ($line -match $pattern) {
      [void]$out.Add($replacement)
      $found = $true
    } else {
      [void]$out.Add([string]$line)
    }
  }
  if (-not $found) { [void]$out.Add($replacement) }

  $content = ($out -join "`n").TrimEnd() + "`n"
  $utf8 = New-Object System.Text.UTF8Encoding $false
  [System.IO.File]::WriteAllText($Path, $content, $utf8)
}

function Mask-Secret {
  param([string]$Value)
  if ([string]::IsNullOrEmpty($Value)) { return '(empty)' }
  if ($Value.Length -le 8) { return ('*' * $Value.Length) }
  $head = $Value.Substring(0, 4)
  $tail = $Value.Substring($Value.Length - 4)
  return ('{0}************{1}' -f $head, $tail)
}

function Ensure-NodeReady {
  param([switch]$CheckOnly, [switch]$SkipNodeInstall)

  $nodeVer = Get-NodeVersionObject
  if ($null -ne $nodeVer -and (Test-NodeVersion $nodeVer)) {
    Write-Step ("Node.js v{0} OK (^22.19 || >=24)" -f $nodeVer) 'ok'
    return
  }

  if ($null -ne $nodeVer) {
    Write-Step ("Node.js v{0} too old; need ^22.19.0 or >=24" -f $nodeVer) 'warn'
  } else {
    Write-Step 'Node.js not found' 'warn'
  }

  if ($CheckOnly) {
    Write-Step 'CheckOnly: environment not ready' 'warn'
    exit 1
  }
  if ($SkipNodeInstall) {
    Write-Step 'Node auto-install skipped' 'err'
    exit 1
  }
  if (-not (Install-NodeWindows)) {
    Write-Step 'Auto-install failed. Install Node.js 22.19+ or 24+ from https://nodejs.org/' 'err'
    exit 1
  }

  $nodeVer = Get-NodeVersionObject
  if ($null -eq $nodeVer -or -not (Test-NodeVersion $nodeVer)) {
    Write-Step 'Node still missing/invalid after install. Open a new terminal and retry.' 'err'
    exit 1
  }
  Write-Step ("Node.js v{0} ready" -f $nodeVer) 'ok'
}

Write-Step 'DeepSeek Harness one-click setup' 'title'
Write-Step ("Platform: Windows | PowerShell {0}" -f $PSVersionTable.PSVersion)

$cfg = $null
$resolvedConfigUrl = $ConfigUrl
if ([string]::IsNullOrWhiteSpace($resolvedConfigUrl)) {
  $resolvedConfigUrl = $env:DSH_ONBOARD_CONFIG_URL
}

if (-not [string]::IsNullOrWhiteSpace($resolvedConfigUrl)) {
  $cfg = Read-RemoteConfig -Url $resolvedConfigUrl
} elseif (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
  $localConfigPath = Join-Path (Split-Path -Parent $PSCommandPath) '..\config\defaults.json'
  if (Test-Path -LiteralPath $localConfigPath) {
    try {
      Write-Step ("Read local config: {0}" -f $localConfigPath)
      $cfg = Get-Content -LiteralPath $localConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
      Write-Step ("Local config parse failed: {0}" -f $_.Exception.Message) 'warn'
      $cfg = $null
    }
  }
}

$apiKey = $ApiKey
if ([string]::IsNullOrWhiteSpace($apiKey)) { $apiKey = $env:DSH_ONBOARD_API_KEY }
if ([string]::IsNullOrWhiteSpace($apiKey) -and $null -ne $cfg -and $null -ne $cfg.apiKey) {
  $apiKey = [string]$cfg.apiKey
}
if ([string]::IsNullOrWhiteSpace($apiKey)) { $apiKey = $Script:DefaultApiKey }

$baseURL = $BaseURL
if ([string]::IsNullOrWhiteSpace($baseURL)) { $baseURL = $env:DSH_ONBOARD_BASE_URL }
if ([string]::IsNullOrWhiteSpace($baseURL) -and $null -ne $cfg -and $null -ne $cfg.baseURL) {
  $baseURL = [string]$cfg.baseURL
}
if ([string]::IsNullOrWhiteSpace($baseURL)) { $baseURL = $Script:DefaultBaseURL }

if ($null -ne $cfg -and $null -ne $cfg.cliPackage -and -not [string]::IsNullOrWhiteSpace([string]$cfg.cliPackage)) {
  $Package = [string]$cfg.cliPackage
}
if ($null -ne $cfg -and $null -ne $cfg.launchArgs) {
  $LaunchArgs = @($cfg.launchArgs | ForEach-Object { [string]$_ })
}

if ($apiKey -match 'REPLACE_WITH_YOUR_KEY|sk-xxx|changeme') {
  Write-Step 'Placeholder API key detected. Set config/defaults.json or script defaults first.' 'err'
  Write-Step 'Or run: .\bootstrap.ps1 -ApiKey sk-your-key -BaseURL https://your-endpoint' 'warn'
  exit 2
}

Write-Step ("API Key: {0}" -f (Mask-Secret $apiKey))
Write-Step ("Base URL: {0}" -f $baseURL)
Write-Step ("Package:  {0} {1}" -f $Package, ($LaunchArgs -join ' '))

Write-Step 'Checking Node.js...' 'title'
Ensure-NodeReady -CheckOnly:$CheckOnly -SkipNodeInstall:$SkipNodeInstall

$npm = Get-Command npm -ErrorAction SilentlyContinue
$npx = Get-Command npx -ErrorAction SilentlyContinue
if ($null -eq $npm -or $null -eq $npx) {
  Write-Step 'npm/npx not found. Fix PATH and retry.' 'err'
  exit 1
}
$npmVersion = & npm -v
Write-Step ("npm {0} / npx OK" -f $npmVersion) 'ok'

if ($CheckOnly) {
  Write-Step 'Environment OK (CheckOnly: no credentials written, no launch)' 'ok'
  exit 0
}

Write-Step 'Writing default credentials and endpoint...' 'title'
$dshHome = Get-DshHome
$credPath = Join-Path $dshHome '.credentials.yaml'
$envPath = Join-Path $dshHome '.env'

Set-YamlKey -Path $credPath -Key 'DEEPSEEK_API_KEY' -Value $apiKey
Set-DotEnvKey -Path $envPath -Key 'DEEPSEEK_BASE_URL' -Value $baseURL
Set-DotEnvKey -Path $envPath -Key 'DEEPSEEK_API_KEY' -Value $apiKey

Write-Step ("Credentials: {0}" -f $credPath) 'ok'
Write-Step ("Env file:    {0}" -f $envPath) 'ok'

if ($NoLaunch) {
  Write-Step 'Configured (-NoLaunch: not starting)' 'ok'
  Write-Step ("Manual start: npx -y {0} {1}" -f $Package, ($LaunchArgs -join ' ')) 'info'
  exit 0
}

Write-Step ("Launch: npx -y {0} {1}" -f $Package, ($LaunchArgs -join ' ')) 'title'
Write-Step 'Default Web UI: http://127.0.0.1:3080 (see terminal output)' 'info'
$env:DEEPSEEK_API_KEY = $apiKey
$env:DEEPSEEK_BASE_URL = $baseURL

& npx -y $Package @LaunchArgs
exit $LASTEXITCODE