#Requires -Version 5.1
<#
.SYNOPSIS
  Fetch live Cloud Run URL for marketing-dashboard using SA credentials.
  Run scripts/auth.ps1 first (or set GOOGLE_APPLICATION_CREDENTIALS + SA_KEY_PATH).

.EXAMPLE
  .\scripts\get-url.ps1
  .\scripts\get-url.ps1 -Region us-central1 -ServiceName marketing-dashboard
#>
param(
  [string]$ProjectId = $(if ($env:GCP_PROJECT_ID) { $env:GCP_PROJECT_ID } elseif ($env:GOOGLE_CLOUD_PROJECT) { $env:GOOGLE_CLOUD_PROJECT } else { "resumora-live" }),
  [string]$Region = "us-central1",
  [string]$ServiceName = "marketing-dashboard",
  [string]$SaKeyPath = $(if ($env:GOOGLE_APPLICATION_CREDENTIALS) { $env:GOOGLE_APPLICATION_CREDENTIALS } else { $env:SA_KEY_PATH })
)

$ErrorActionPreference = "Stop"

if (-not [string]::IsNullOrWhiteSpace($SaKeyPath) -and (Test-Path -LiteralPath $SaKeyPath)) {
  gcloud auth activate-service-account --key-file="$SaKeyPath" --quiet | Out-Null
  $env:GOOGLE_APPLICATION_CREDENTIALS = (Resolve-Path -LiteralPath $SaKeyPath).Path
}

gcloud config set project $ProjectId --quiet | Out-Null

$url = gcloud run services describe $ServiceName `
  --region=$Region `
  --project=$ProjectId `
  --format="value(status.url)" 2>&1

if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($url) -or $url -match "ERROR") {
  Write-Host "Cloud Run service '$ServiceName' not found or not ready." -ForegroundColor Yellow
  Write-Host "Ensure cloud_run_image was applied and auth.ps1 was run with a deployer SA." -ForegroundColor Yellow
  Write-Host $url
  exit 1
}

Write-Host $url
# Also emit for piping
$url | Write-Output
