#Requires -Version 5.1
<#
.SYNOPSIS
  Hands-free GCP auth using a Service Account JSON key only.
  NEVER runs interactive "gcloud auth login".

.EXAMPLE
  .\scripts\auth.ps1
  .\scripts\auth.ps1 -SaKeyPath "D:\secrets\github-mkt-intel-deployer.json" -ProjectId "resumora-live"
#>
param(
  [string]$SaKeyPath = $env:SA_KEY_PATH,
  [string]$ProjectId = $(if ($env:GCP_PROJECT_ID) { $env:GCP_PROJECT_ID } elseif ($env:GOOGLE_CLOUD_PROJECT) { $env:GOOGLE_CLOUD_PROJECT } else { "resumora-live" })
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($SaKeyPath)) {
  $SaKeyPath = Read-Host "Path to Service Account JSON key (SA_KEY_PATH)"
}

if (-not (Test-Path -LiteralPath $SaKeyPath)) {
  throw "SA key file not found: $SaKeyPath"
}

$SaKeyPath = (Resolve-Path -LiteralPath $SaKeyPath).Path

Write-Host "==> Activating service account (no browser login)..." -ForegroundColor Cyan
gcloud auth activate-service-account --key-file="$SaKeyPath" --quiet
if ($LASTEXITCODE -ne 0) { throw "gcloud auth activate-service-account failed" }

# Session + process env for Terraform / Python ADC
$env:GOOGLE_APPLICATION_CREDENTIALS = $SaKeyPath
$env:SA_KEY_PATH = $SaKeyPath
$env:GCP_PROJECT_ID = $ProjectId
$env:GOOGLE_CLOUD_PROJECT = $ProjectId
$env:CLOUDSDK_CORE_PROJECT = $ProjectId

# Persist for current User session so new shells inherit (still SA-based)
[Environment]::SetEnvironmentVariable("GOOGLE_APPLICATION_CREDENTIALS", $SaKeyPath, "User")
[Environment]::SetEnvironmentVariable("GCP_PROJECT_ID", $ProjectId, "User")
[Environment]::SetEnvironmentVariable("GOOGLE_CLOUD_PROJECT", $ProjectId, "User")

gcloud config set project $ProjectId --quiet
if ($LASTEXITCODE -ne 0) { throw "gcloud config set project failed" }

Write-Host "OK: SA activated" -ForegroundColor Green
Write-Host "    GOOGLE_APPLICATION_CREDENTIALS=$SaKeyPath"
Write-Host "    project=$ProjectId"
Write-Host "Next: cd terraform; terraform init ...; terraform apply -var-file=prod.tfvars"
Write-Host "Then: .\scripts\get-url.ps1"
