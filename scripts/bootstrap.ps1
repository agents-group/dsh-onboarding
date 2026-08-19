#Requires -Version 5.1
<#
.SYNOPSIS
  DeepSeek Harness (dsh) environment agent: observe, diagnose, remediate, launch.

.DESCRIPTION
  Runs a local multi-round agent loop (not an LLM):
    observe machine facts -> diagnose issues -> apply fixes -> re-check
  until the goal is met or blocked with clear next steps.

  Recommended:
    $env:DSH_ONBOARD_CONFIG_URL='https://<site>/config/defaults.json'
    irm https://<site>/scripts/bootstrap.ps1 | iex

  Local:
    .\bootstrap.ps1
    .\bootstrap.ps1 -CheckOnly
    .\bootstrap.ps1 -NoLaunch
    .\bootstrap.ps1 -ApiKey 'sk-xxx' -BaseURL 'https://api.example/v1'
    .\bootstrap.ps1 -MaxRounds 8

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
  [int]$MaxRounds = 6,
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

function Test-HttpReachable {
  param([string]$Url, [int]$TimeoutSec = 12)
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $req = [System.Net.WebRequest]::Create($Url)
    $req.Method = 'HEAD'
    $req.Timeout = $TimeoutSec * 1000
    $resp = $req.GetResponse()
    $resp.Close()
    return $true
  } catch {
    try {
      $req = [System.Net.WebRequest]::Create($Url)
      $req.Method = 'GET'
      $req.Timeout = $TimeoutSec * 1000
      $resp = $req.GetResponse()
      $resp.Close()
      return $true
    } catch {
      return $false
    }
  }
}

function Find-PortableNodeHomes {
  $root = Join-Path $env:LOCALAPPDATA 'dsh-onboarding\node'
  if (-not (Test-Path -LiteralPath $root)) { return @() }
  return @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'node.exe') } |
    Sort-Object Name -Descending |
    ForEach-Object { $_.FullName })
}

function Repair-NodePath {
  $homes = Find-PortableNodeHomes
  foreach ($home in $homes) {
    Add-UserPathEntry -Dir $home
    $env:Path = "{0};{1}" -f $home, $env:Path
  }
  Update-SessionPath
  foreach ($home in $homes) {
    if ($env:Path -notlike ("*{0}*" -f $home)) {
      $env:Path = "{0};{1}" -f $home, $env:Path
    }
  }
  return (Get-NodeVersionObject)
}

function Get-NpmVersionSafe {
  try {
    $v = & npm -v 2>$null
    if ($null -eq $v) { return $null }
    return ([string]$v).Trim()
  } catch { return $null }
}

function Test-NpxAvailable {
  $c = Get-Command npx -ErrorAction SilentlyContinue
  return ($null -ne $c)
}

function Get-EnvFacts {
  param(
    [string]$ApiKeyValue,
    [string]$BaseUrlValue,
    [string]$Pkg,
    [string[]]$Args,
    [bool]$WantCredentials,
    [bool]$WantLaunch
  )

  Update-SessionPath
  $nodeVer = Get-NodeVersionObject
  if ($null -eq $nodeVer) {
    $nodeVer = Repair-NodePath
  }

  $nodeOk = ($null -ne $nodeVer -and (Test-NodeVersion $nodeVer))
  $npmVer = $null
  $npmOk = $false
  $npxOk = $false
  if ($nodeOk) {
    $npmVer = Get-NpmVersionSafe
    $npmOk = -not [string]::IsNullOrWhiteSpace($npmVer)
    $npxOk = Test-NpxAvailable
  }

  $dshHome = Get-DshHome
  $credPath = Join-Path $dshHome '.credentials.yaml'
  $envPath = Join-Path $dshHome '.env'
  $credOk = $false
  $envOk = $false
  if (-not $WantCredentials) {
    $credOk = $true
    $envOk = $true
  } else {
    if (Test-Path -LiteralPath $credPath) {
      $raw = Get-Content -LiteralPath $credPath -Raw -ErrorAction SilentlyContinue
      if ($raw -and $raw -match 'DEEPSEEK_API_KEY\s*:\s*\S+') { $credOk = $true }
    }
    if (Test-Path -LiteralPath $envPath) {
      $raw = Get-Content -LiteralPath $envPath -Raw -ErrorAction SilentlyContinue
      if ($raw -and $raw -match 'DEEPSEEK_BASE_URL\s*=\s*\S+') { $envOk = $true }
    }
  }

  $keyOk = -not [string]::IsNullOrWhiteSpace($ApiKeyValue) -and ($ApiKeyValue -notmatch 'REPLACE_WITH_YOUR_KEY|sk-xxx|changeme')
  $baseOk = -not [string]::IsNullOrWhiteSpace($BaseUrlValue)

  return [pscustomobject]@{
    Platform        = ("Windows | PowerShell {0}" -f $PSVersionTable.PSVersion)
    NodeVersion     = $(if ($nodeVer) { "v$nodeVer" } else { $null })
    NodeOk          = $nodeOk
    NpmVersion      = $npmVer
    NpmOk           = $npmOk
    NpxOk           = $npxOk
    HasWinget       = [bool](Get-Command winget -ErrorAction SilentlyContinue)
    HasChoco        = [bool](Get-Command choco -ErrorAction SilentlyContinue)
    PortableNode    = @(Find-PortableNodeHomes)
    ReachNodejsOrg  = $null  # filled lazily when needed
    DshHome         = $dshHome
    CredPath        = $credPath
    EnvPath         = $envPath
    CredOk          = $credOk
    EnvOk           = $envOk
    KeyOk           = $keyOk
    BaseOk          = $baseOk
    Package         = $Pkg
    LaunchArgs      = $Args
    WantCredentials = $WantCredentials
    WantLaunch      = $WantLaunch
  }
}

function Write-EnvFacts {
  param($Facts)
  Write-Step 'Agent observe: environment facts' 'title'
  Write-Step ("platform: {0}" -f $Facts.Platform)
  Write-Step ("node: {0} (ok={1})" -f $(if ($Facts.NodeVersion) { $Facts.NodeVersion } else { 'missing' }), $Facts.NodeOk)
  Write-Step ("npm: {0} | npx: {1}" -f $(if ($Facts.NpmOk) { $Facts.NpmVersion } else { 'missing' }), $Facts.NpxOk)
  Write-Step ("tools: winget={0} choco={1} portable_node={2}" -f $Facts.HasWinget, $Facts.HasChoco, $Facts.PortableNode.Count)
  Write-Step ("dsh_home: {0}" -f $Facts.DshHome)
  Write-Step ("credentials_ready: {0} | env_ready: {1} | key_ok: {2}" -f $Facts.CredOk, $Facts.EnvOk, $Facts.KeyOk)
}

function Get-Issues {
  param($Facts)

  $issues = New-Object System.Collections.Generic.List[object]

  if (-not $Facts.KeyOk) {
    $issues.Add([pscustomobject]@{
        Id       = 'config.key'
        Severity = 'block'
        Summary  = 'API key missing or still a placeholder'
        Fix      = 'manual-key'
      }) | Out-Null
  }
  if (-not $Facts.BaseOk) {
    $issues.Add([pscustomobject]@{
        Id       = 'config.baseurl'
        Severity = 'block'
        Summary  = 'Base URL missing'
        Fix      = 'manual-baseurl'
      }) | Out-Null
  }
  if (-not $Facts.NodeOk) {
    $sev = 'auto'
    $fix = 'install-node'
    if ($Facts.PortableNode.Count -gt 0) {
      $fix = 'repair-node-path'
      $summary = 'Node portable install exists but is not usable on PATH'
    } elseif ($null -ne $Facts.NodeVersion) {
      $summary = ("Node {0} is outside required range ^22.19 || >=24" -f $Facts.NodeVersion)
    } else {
      $summary = 'Node.js not found'
    }
    $issues.Add([pscustomobject]@{
        Id       = 'runtime.node'
        Severity = $sev
        Summary  = $summary
        Fix      = $fix
      }) | Out-Null
  }
  if ($Facts.NodeOk -and -not $Facts.NpmOk) {
    $issues.Add([pscustomobject]@{
        Id       = 'runtime.npm'
        Severity = 'auto'
        Summary  = 'npm missing alongside Node'
        Fix      = 'install-node'
      }) | Out-Null
  }
  if ($Facts.NodeOk -and -not $Facts.NpxOk) {
    $issues.Add([pscustomobject]@{
        Id       = 'runtime.npx'
        Severity = 'auto'
        Summary  = 'npx missing alongside Node'
        Fix      = 'install-node'
      }) | Out-Null
  }
  if ($Facts.WantCredentials -and -not $Facts.CredOk) {
    $issues.Add([pscustomobject]@{
        Id       = 'config.credentials'
        Severity = 'auto'
        Summary  = 'DEEPSEEK_API_KEY not written to .credentials.yaml'
        Fix      = 'write-credentials'
      }) | Out-Null
  }
  if ($Facts.WantCredentials -and -not $Facts.EnvOk) {
    $issues.Add([pscustomobject]@{
        Id       = 'config.envfile'
        Severity = 'auto'
        Summary  = 'DEEPSEEK_BASE_URL not written to .env'
        Fix      = 'write-credentials'
      }) | Out-Null
  }
  if ($Facts.WantLaunch -and $Facts.NodeOk -and $Facts.NpxOk -and $Facts.KeyOk -and (
      (-not $Facts.WantCredentials) -or ($Facts.CredOk -and $Facts.EnvOk)
    )) {
    # launch is the final intentional action, represented as an issue only when ready
    $issues.Add([pscustomobject]@{
        Id       = 'launch.dsh'
        Severity = 'auto'
        Summary  = ("Ready to launch: npx -y {0} {1}" -f $Facts.Package, ($Facts.LaunchArgs -join ' '))
        Fix      = 'launch'
      }) | Out-Null
  }

  # Materialize Generic.List to object[] — `@($list)` can throw "Argument types do not match" on Windows PowerShell 5.1.
  return @($issues.ToArray())
}

function Invoke-Fix {
  param(
    $Issue,
    $Facts,
    [string]$ApiKeyValue,
    [string]$BaseUrlValue,
    [string]$Pkg,
    [string[]]$Args,
    [bool]$SkipNodeInstall
  )

  Write-Step ("Agent act: [{0}] {1}" -f $Issue.Fix, $Issue.Summary) 'title'

  switch ($Issue.Fix) {
    'manual-key' {
      Write-Step 'Set a real key in config/defaults.json or pass -ApiKey / DSH_ONBOARD_API_KEY' 'err'
      return 'blocked'
    }
    'manual-baseurl' {
      Write-Step 'Set baseURL in config/defaults.json or pass -BaseURL / DSH_ONBOARD_BASE_URL' 'err'
      return 'blocked'
    }
    'repair-node-path' {
      $null = Repair-NodePath
      $ver = Get-NodeVersionObject
      if ($null -ne $ver -and (Test-NodeVersion $ver)) {
        Write-Step ("PATH repaired; Node {0} visible" -f $ver) 'ok'
        return 'changed'
      }
      Write-Step 'PATH repair insufficient; will try reinstall' 'warn'
      if ($SkipNodeInstall) { return 'blocked' }
      if (Install-NodeWindows) { return 'changed' }
      return 'failed'
    }
    'install-node' {
      if ($SkipNodeInstall) {
        Write-Step 'SkipNodeInstall set; cannot auto-install Node' 'err'
        return 'blocked'
      }
      # Probe network only when install is needed
      Write-Step 'Probing https://nodejs.org/ ...'
      $okNet = Test-HttpReachable -Url 'https://nodejs.org/dist/index.json'
      if (-not $okNet) {
        Write-Step 'nodejs.org not reachable from this machine; install Node manually or fix network/proxy' 'err'
        return 'blocked'
      }
      if (Install-NodeWindows) { return 'changed' }
      return 'failed'
    }
    'write-credentials' {
      $dshHome = Get-DshHome
      $credPath = Join-Path $dshHome '.credentials.yaml'
      $envPath = Join-Path $dshHome '.env'
      Set-YamlKey -Path $credPath -Key 'DEEPSEEK_API_KEY' -Value $ApiKeyValue
      Set-DotEnvKey -Path $envPath -Key 'DEEPSEEK_BASE_URL' -Value $BaseUrlValue
      Set-DotEnvKey -Path $envPath -Key 'DEEPSEEK_API_KEY' -Value $ApiKeyValue
      Write-Step ("Wrote {0}" -f $credPath) 'ok'
      Write-Step ("Wrote {0}" -f $envPath) 'ok'
      return 'changed'
    }
    'launch' {
      $env:DEEPSEEK_API_KEY = $ApiKeyValue
      $env:DEEPSEEK_BASE_URL = $BaseUrlValue
      Write-Step ("Launch: npx -y {0} {1}" -f $Pkg, ($Args -join ' ')) 'title'
      Write-Step 'Default Web UI: http://127.0.0.1:3080 (see terminal output)' 'info'
      & npx -y $Pkg @Args
      $code = $LASTEXITCODE
      if ($null -eq $code) { $code = 0 }
      if ($code -eq 0) { return 'launched' }
      Write-Step ("npx exited with code {0}" -f $code) 'err'
      return 'failed'
    }
    default {
      Write-Step ("Unknown fix: {0}" -f $Issue.Fix) 'err'
      return 'failed'
    }
  }
}

function Resolve-BootstrapConfig {
  param(
    [string]$ApiKeyParam,
    [string]$BaseURLParam,
    [string]$ConfigUrlParam,
    [string]$PackageParam,
    [string[]]$LaunchArgsParam
  )

  $cfg = $null
  $resolvedConfigUrl = $ConfigUrlParam
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

  $apiKeyValue = $ApiKeyParam
  if ([string]::IsNullOrWhiteSpace($apiKeyValue)) { $apiKeyValue = $env:DSH_ONBOARD_API_KEY }
  if ([string]::IsNullOrWhiteSpace($apiKeyValue) -and $null -ne $cfg -and $null -ne $cfg.apiKey) {
    $apiKeyValue = [string]$cfg.apiKey
  }
  if ([string]::IsNullOrWhiteSpace($apiKeyValue)) { $apiKeyValue = $Script:DefaultApiKey }

  $baseUrlValue = $BaseURLParam
  if ([string]::IsNullOrWhiteSpace($baseUrlValue)) { $baseUrlValue = $env:DSH_ONBOARD_BASE_URL }
  if ([string]::IsNullOrWhiteSpace($baseUrlValue) -and $null -ne $cfg -and $null -ne $cfg.baseURL) {
    $baseUrlValue = [string]$cfg.baseURL
  }
  if ([string]::IsNullOrWhiteSpace($baseUrlValue)) { $baseUrlValue = $Script:DefaultBaseURL }

  $pkg = $PackageParam
  $args = $LaunchArgsParam
  if ($null -ne $cfg -and $null -ne $cfg.cliPackage -and -not [string]::IsNullOrWhiteSpace([string]$cfg.cliPackage)) {
    $pkg = [string]$cfg.cliPackage
  }
  if ($null -ne $cfg -and $null -ne $cfg.launchArgs) {
    $args = @($cfg.launchArgs | ForEach-Object { [string]$_ })
  }

  return [pscustomobject]@{
    ApiKey     = $apiKeyValue
    BaseURL    = $baseUrlValue
    Package    = $pkg
    LaunchArgs = $args
  }
}

# ---------------- agent main ----------------
Write-Step 'DeepSeek Harness environment agent' 'title'
Write-Step 'Loop: observe -> diagnose -> act -> verify (local playbook agent, not an LLM)'

$config = Resolve-BootstrapConfig -ApiKeyParam $ApiKey -BaseURLParam $BaseURL -ConfigUrlParam $ConfigUrl `
  -PackageParam $Package -LaunchArgsParam $LaunchArgs

Write-Step ("goal key={0} base={1} pkg={2} {3}" -f (Mask-Secret $config.ApiKey), $config.BaseURL, $config.Package, ($config.LaunchArgs -join ' '))
Write-Step ("mode: CheckOnly={0} NoLaunch={1} MaxRounds={2}" -f [bool]$CheckOnly, [bool]$NoLaunch, $MaxRounds)

$wantCredentials = -not $CheckOnly
$wantLaunch = (-not $CheckOnly) -and (-not $NoLaunch)
$journal = New-Object System.Collections.Generic.List[string]
$triedFix = @{}

if ($MaxRounds -lt 1) { $MaxRounds = 1 }

for ($round = 1; $round -le $MaxRounds; $round++) {
  Write-Step ("Agent round {0}/{1}" -f $round, $MaxRounds) 'title'

  $facts = Get-EnvFacts -ApiKeyValue $config.ApiKey -BaseUrlValue $config.BaseURL -Pkg $config.Package `
    -Args $config.LaunchArgs -WantCredentials $wantCredentials -WantLaunch $wantLaunch
  Write-EnvFacts -Facts $facts

  $issues = @(Get-Issues -Facts $facts)
  if ($issues.Count -eq 0) {
    if ($CheckOnly) {
      Write-Step 'Agent done: environment checks passed (CheckOnly)' 'ok'
      exit 0
    }
    if ($NoLaunch) {
      Write-Step 'Agent done: credentials configured (-NoLaunch)' 'ok'
      Write-Step ("Manual start: npx -y {0} {1}" -f $config.Package, ($config.LaunchArgs -join ' '))
      exit 0
    }
    Write-Step 'Agent done: no outstanding issues' 'ok'
    exit 0
  }

  Write-Step ("Agent diagnose: {0} issue(s)" -f $issues.Count) 'title'
  foreach ($i in $issues) {
    Write-Step ("- [{0}] {1} (fix={2})" -f $i.Severity, $i.Summary, $i.Fix)
  }

  # In CheckOnly mode, never mutate; report and exit non-zero if anything remains.
  if ($CheckOnly) {
    Write-Step 'CheckOnly: issues remain; no automatic fixes applied' 'warn'
    exit 1
  }

  # Prefer non-launch fixes first so launch happens only when healthy.
  $ordered = @($issues | Where-Object { $_.Fix -ne 'launch' }) + @($issues | Where-Object { $_.Fix -eq 'launch' })
  $issue = $ordered | Select-Object -First 1

  $fixKey = [string]$issue.Fix
  if ($triedFix.ContainsKey($fixKey) -and $fixKey -ne 'launch') {
    Write-Step ("Fix '{0}' already attempted and issue persists — stopping" -f $fixKey) 'err'
    Write-Step 'Manual next steps:' 'warn'
    Write-Step '1) Install Node.js 22.19+ or 24+ from https://nodejs.org/ and reopen the terminal'
    Write-Step '2) Re-run the one-click command'
    Write-Step ("3) Or write credentials manually under {0}" -f (Get-DshHome))
    exit 1
  }

  $result = Invoke-Fix -Issue $issue -Facts $facts -ApiKeyValue $config.ApiKey -BaseUrlValue $config.BaseURL `
    -Pkg $config.Package -Args $config.LaunchArgs -SkipNodeInstall:([bool]$SkipNodeInstall)
  [void]$journal.Add(("{0}: {1} -> {2}" -f $round, $fixKey, $result))

  if ($result -eq 'launched') {
    Write-Step 'Agent done: launch process finished' 'ok'
    exit 0
  }
  if ($result -eq 'blocked') {
    Write-Step 'Agent blocked on an issue that needs manual input' 'err'
    exit 2
  }
  if ($result -eq 'failed') {
    $triedFix[$fixKey] = $true
    Write-Step ("Fix failed: {0}" -f $fixKey) 'warn'
    continue
  }
  if ($result -eq 'changed') {
    $triedFix[$fixKey] = $true
    Write-Step 'Change applied; re-observing...' 'ok'
    continue
  }
}

Write-Step 'Agent stopped: max rounds reached with unresolved issues' 'err'
Write-Step 'Journal:' 'warn'
foreach ($line in $journal) { Write-Step $line }
exit 1