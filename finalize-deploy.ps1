#Requires -Version 5.1
<#
.SYNOPSIS
  Finalize marketing-intel deploy: set GCP_SA_KEY, re-run failed Actions, print Cloud Run URL.

.EXAMPLE
  cd D:\BossMind\resumora-marketing-intel
  powershell -ExecutionPolicy Bypass -File .\finalize-deploy.ps1
#>

param(
  [string]$Repo = "ahmadlatifdev/resumora-marketing-intel",
  [string]$ExpectedProjectId = "key-journal-378204",
  [string]$DownloadsDir = (Join-Path $env:USERPROFILE "Downloads"),
  [string]$SaKeyPath = $env:SA_KEY_PATH,
  [int]$PollSeconds = 10,
  [int]$MaxWaitMinutes = 45
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Write-Step([string]$Msg) {
  Write-Host ""
  Write-Host "==> $Msg" -ForegroundColor Cyan
}
function Write-Ok([string]$Msg) { Write-Host "    OK  $Msg" -ForegroundColor Green }
function Write-Warn([string]$Msg) { Write-Host "    WARN $Msg" -ForegroundColor Yellow }
function Write-Fail([string]$Msg) {
  Write-Host "    FAIL $Msg" -ForegroundColor Red
  exit 1
}
function Test-Cmd([string]$Name) {
  return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

Write-Host "============================================================" -ForegroundColor Magenta
Write-Host " finalize-deploy.ps1" -ForegroundColor Magenta
Write-Host " Repo: $Repo" -ForegroundColor Magenta
Write-Host "============================================================" -ForegroundColor Magenta

# --- 1) Locate SA key ---
Write-Step "Locate GCP service account JSON key"
if ([string]::IsNullOrWhiteSpace($SaKeyPath) -or -not (Test-Path -LiteralPath $SaKeyPath)) {
  $pattern = Join-Path $DownloadsDir "$ExpectedProjectId-*.json"
  $matches = @(Get-ChildItem -Path $pattern -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
  if ($matches.Count -gt 0) {
    $SaKeyPath = $matches[0].FullName
    Write-Ok "Found: $SaKeyPath"
  } else {
    Write-Warn "No match for $pattern"
    $SaKeyPath = Read-Host "Enter full path to service account JSON"
  }
}

if ([string]::IsNullOrWhiteSpace($SaKeyPath) -or -not (Test-Path -LiteralPath $SaKeyPath)) {
  Write-Fail "SA key file not found: $SaKeyPath"
}
$SaKeyPath = (Resolve-Path -LiteralPath $SaKeyPath).Path

try {
  $saRaw = Get-Content -LiteralPath $SaKeyPath -Raw -Encoding UTF8
  $saObj = $saRaw | ConvertFrom-Json
} catch {
  Write-Fail "Invalid JSON: $($_.Exception.Message)"
}

if ($saObj.type -ne "service_account") {
  Write-Fail "JSON type must be service_account (got: $($saObj.type))"
}
if ($saObj.project_id -ne $ExpectedProjectId) {
  Write-Fail "project_id must be '$ExpectedProjectId' (got: $($saObj.project_id))"
}
if (-not $saObj.private_key -or -not $saObj.client_email) {
  Write-Fail "SA JSON missing private_key or client_email"
}
Write-Ok "SA JSON valid for project $ExpectedProjectId (details not printed)"

# --- 2) Ensure gh installed + authenticated ---
Write-Step "Ensure GitHub CLI (gh) is ready"
if (-not (Test-Cmd "gh")) {
  Write-Warn "gh not on PATH — installing via winget"
  if (-not (Test-Cmd "winget")) { Write-Fail "winget not available; install GitHub CLI manually" }
  winget install --id GitHub.cli -e --accept-source-agreements --accept-package-agreements
  $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
              [Environment]::GetEnvironmentVariable("Path", "User")
  if (-not (Test-Cmd "gh")) { Write-Fail "gh still not on PATH — open a new terminal and re-run" }
}
Write-Ok "gh present"

& gh auth status 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
  Write-Warn "gh not authenticated — interactive login required (one-time)"
  & gh auth login
  if ($LASTEXITCODE -ne 0) { Write-Fail "gh auth login failed" }
}
Write-Ok "gh authenticated"

# --- 3) Set GCP_SA_KEY (never echo value) ---
Write-Step "Set GitHub secret GCP_SA_KEY"
# Prefer stdin pipe — safer than --body for large JSON / special chars
Get-Content -LiteralPath $SaKeyPath -Raw -Encoding UTF8 | & gh secret set GCP_SA_KEY --repo $Repo
if ($LASTEXITCODE -ne 0) { Write-Fail "gh secret set GCP_SA_KEY failed" }
Write-Ok "GCP_SA_KEY updated (value not printed)"

Write-Host "    Current secrets:" -ForegroundColor DarkGray
& gh secret list --repo $Repo

# --- 4) Re-run last failed workflow ---
Write-Step "Re-run most recent failed workflow"
$runsJson = & gh run list --repo $Repo --limit 5 --json databaseId,status,conclusion,displayTitle,headBranch,createdAt
if ($LASTEXITCODE -ne 0) { Write-Fail "gh run list failed" }

$runs = $runsJson | ConvertFrom-Json
$failed = @($runs | Where-Object { $_.conclusion -eq "failure" } | Select-Object -First 1)
if (-not $failed -or -not $failed.databaseId) {
  Write-Warn "No failed run in last 5 — dispatching Terraform CI/CD"
  & gh workflow run "Terraform CI/CD" --repo $Repo 2>$null
  if ($LASTEXITCODE -ne 0) {
    & gh workflow run "terraform-ci-cd.yml" --repo $Repo 2>$null
  }
  if ($LASTEXITCODE -ne 0) { Write-Fail "Could not find a failed run or dispatch workflow" }
  Start-Sleep -Seconds 5
  $runsJson = & gh run list --repo $Repo --limit 1 --json databaseId,status,conclusion,displayTitle
  $runId = (($runsJson | ConvertFrom-Json)[0]).databaseId
  Write-Ok "Dispatched new run id=$runId"
} else {
  $runId = [string]$failed.databaseId
  Write-Host "    Failed run: $($failed.displayTitle) id=$runId" -ForegroundColor DarkGray
  # Prefer gh run rerun; fall back to REST
  & gh run rerun $runId --repo $Repo 2>$null
  if ($LASTEXITCODE -ne 0) {
    & gh api -X POST "repos/$Repo/actions/runs/$runId/rerun" | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Fail "Failed to re-run workflow $runId" }
  }
  Write-Ok "Re-run requested for $runId"
}

# --- 5) Wait + extract Cloud Run URL ---
Write-Step "Wait for run $runId to complete (poll ${PollSeconds}s)"
$deadline = (Get-Date).AddMinutes($MaxWaitMinutes)
$conclusion = $null
$status = "unknown"

while ((Get-Date) -lt $deadline) {
  $viewJson = & gh run view $runId --repo $Repo --json status,conclusion,url
  if ($LASTEXITCODE -ne 0) { Write-Fail "gh run view failed" }
  $view = $viewJson | ConvertFrom-Json
  $status = [string]$view.status
  $conclusion = $view.conclusion
  Write-Host ("    [{0}] status={1} conclusion={2}" -f (Get-Date -Format "HH:mm:ss"), $status, $(if ($conclusion) { $conclusion } else { "(pending)" })) -ForegroundColor DarkGray
  if ($status -eq "completed" -and $null -ne $conclusion -and "$conclusion" -ne "") {
    break
  }
  Start-Sleep -Seconds $PollSeconds
}

if ($status -ne "completed") {
  Write-Fail "Timed out waiting for run $runId. Check https://github.com/$Repo/actions/runs/$runId"
}

if ($conclusion -ne "success") {
  Write-Warn "Run finished with conclusion=$conclusion"
  Write-Host "    Logs: https://github.com/$Repo/actions/runs/$runId" -ForegroundColor Yellow
  Write-Fail "Workflow did not succeed — open the run and inspect the red step"
}

Write-Ok "Workflow succeeded"

Write-Step "Extract cloud_run_url from logs"
$logPath = Join-Path $env:TEMP ("gh-run-" + $runId + ".log")
& gh run view $runId --repo $Repo --log 2>$null | Out-File -FilePath $logPath -Encoding utf8
if (-not (Test-Path -LiteralPath $logPath)) {
  Write-Warn "Could not download logs"
  Write-Host "    Open: https://github.com/$Repo/actions/runs/$runId" -ForegroundColor Cyan
  exit 0
}

$url = $null
$patterns = @(
  'cloud_run_url\s*=\s*(https://[^\s\"'']+)',
  'Dashboard URL:\s*(https://[^\s]+)',
  '(https://marketing-dashboard[^\s\"'']+\.run\.app[^\s\"'']*)',
  '(https://[a-z0-9\-]+\-[a-z0-9]+\-[a-z0-9]+\.a\.run\.app)'
)
$logText = Get-Content -LiteralPath $logPath -Raw -ErrorAction SilentlyContinue
foreach ($pat in $patterns) {
  $m = [regex]::Match($logText, $pat, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
  if ($m.Success) {
    $url = $m.Groups[1].Value.Trim().TrimEnd('"', "'", ',', ')')
    break
  }
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Magenta
if ($url) {
  Write-Host " Cloud Run URL:" -ForegroundColor Green
  Write-Host " $url" -ForegroundColor Green
} else {
  Write-Warn "cloud_run_url not found in logs (image may still be empty or output missing)"
  Write-Host " Check Actions: https://github.com/$Repo/actions/runs/$runId" -ForegroundColor Cyan
  Write-Host " Or run: .\scripts\get-url.ps1  (after .\scripts\auth.ps1)" -ForegroundColor Cyan
}
Write-Host "============================================================" -ForegroundColor Magenta

# Never commit secrets
Write-Ok "No secrets were written to git by this script"
exit 0
