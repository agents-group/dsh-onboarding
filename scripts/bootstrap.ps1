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

function Install-NodeWindows {
  Write-Step 'Trying winget to install Node.js LTS...'
  $winget = Get-Command winget -ErrorAction SilentlyContinue
  if ($null -ne $winget) {
    & winget install -e --id OpenJS.NodeJS.LTS --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -eq 0) {
      Update-SessionPath
      return $true
    }
    Write-Step ("winget exit code: {0}" -f $LASTEXITCODE) 'warn'
  } else {
    Write-Step 'winget not found, skip' 'warn'
  }

  Write-Step 'Trying Chocolatey to install Node.js...'
  $choco = Get-Command choco -ErrorAction SilentlyContinue
  if ($null -ne $choco) {
    & choco install nodejs-lts -y
    if ($LASTEXITCODE -eq 0) {
      Update-SessionPath
      return $true
    }
  }
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