#Requires -Version 5.1
<#
.SYNOPSIS
  Upload Windows portable zip to Cloudflare R2 (requires token with R2 edit).

.EXAMPLE
  $env:CLOUDFLARE_API_TOKEN='...'
  $env:CLOUDFLARE_ACCOUNT_ID='...'
  ./scripts/upload-win-package-r2.ps1 -ZipPath ./dist/dsh-onboarding-windows-portable.zip
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$ZipPath,
  [string]$AccountId = $env:CLOUDFLARE_ACCOUNT_ID,
  [string]$ApiToken = $env:CLOUDFLARE_API_TOKEN,
  [string]$Bucket = $(if ($env:DSH_ONBOARD_R2_BUCKET) { $env:DSH_ONBOARD_R2_BUCKET } else { 'dsh-onboarding-assets' }),
  [string]$ObjectKey = 'dsh-onboarding-windows-portable.zip'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ZipPath)) { throw "Zip not found: $ZipPath" }
if ([string]::IsNullOrWhiteSpace($AccountId)) { throw 'CLOUDFLARE_ACCOUNT_ID required' }
if ([string]::IsNullOrWhiteSpace($ApiToken)) { throw 'CLOUDFLARE_API_TOKEN required (needs R2 edit)' }

Write-Host "[====] Upload to R2 $Bucket/$ObjectKey"

# Prefer wrangler if available
$wrangler = Get-Command wrangler -ErrorAction SilentlyContinue
if ($null -ne $wrangler) {
  $env:CLOUDFLARE_API_TOKEN = $ApiToken
  $env:CLOUDFLARE_ACCOUNT_ID = $AccountId
  & wrangler r2 bucket create $Bucket 2>$null
  & wrangler r2 object put "$Bucket/$ObjectKey" --file=$ZipPath --remote --content-type=application/zip
  if ($LASTEXITCODE -ne 0) { throw "wrangler upload failed: $LASTEXITCODE" }
  Write-Host '[ OK ] Uploaded via wrangler'
  Write-Host 'Enable public access on the bucket (r2.dev) in Cloudflare dashboard if not already.'
  Write-Host "Then set site/package URL, e.g. https://pub-xxxxx.r2.dev/$ObjectKey"
  exit 0
}

throw 'wrangler not found. Install: npm i -g wrangler  (or add R2 upload in CI with cloudflare/wrangler-action)'
