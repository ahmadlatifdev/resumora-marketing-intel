#Requires -Version 5.1
<#
.SYNOPSIS
  Scrub .env from what gets pushed, force-push clean main to GitHub,
  set Actions secrets, and trigger/watch Terraform CI/CD.

.DESCRIPTION
  - Never commits .env or prints secret values.
  - If this folder is nested inside the BossMind monorepo (common), builds a
    CLEAN orphan export and force-pushes ONLY that tree (BossMind history
    contains a root .env that would keep failing secret scanning).
  - If this folder is its own git root, untracks .env, filters history, force-pushes.
  - Restores BossMind origin to BossMind-prod if it was redirected here.

.EXAMPLE
  cd D:\BossMind\resumora-marketing-intel
  $env:SA_KEY_PATH = "D:\secure\deployer-sa.json"
  $env:GCP_PROJECT_ID = "key-journal-378204"
  # optional: $env:SLACK_WEBHOOK_URL = "https://hooks.slack.com/services/..."
  powershell -ExecutionPolicy Bypass -File .\fix-and-deploy.ps1
#>

param(
  [string]$RemoteUrl = "https://github.com/ahmadlatifdev/resumora-marketing-intel.git",
  [string]$GitHubRepo = "ahmadlatifdev/resumora-marketing-intel",
  [string]$BossMindRemoteUrl = "https://github.com/ahmadlatifdev/BossMind-prod.git",
  [string]$GcpProjectId = $(if ($env:GCP_PROJECT_ID) { $env:GCP_PROJECT_ID } else { "key-journal-378204" }),
  [string]$SaKeyPath = $env:SA_KEY_PATH,
  [string]$SlackWebhookUrl = $env:SLACK_WEBHOOK_URL,
  [switch]$SkipSecrets,
  [switch]$SkipPush,
  [switch]$SkipWatch
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# Resolve project root = directory containing this script
$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $ProjectRoot) { $ProjectRoot = (Get-Location).Path }
$ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path

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

function Ensure-EnvIgnored([string]$GitignorePath) {
  $needed = @(
    ".env",
    ".env.*",
    "!.env.example",
    "*.pem",
    "*-sa-key.json",
    "gcp-key.json",
    "deployer-sa.json",
    "service-account*.json"
  )
  if (-not (Test-Path -LiteralPath $GitignorePath)) {
    Set-Content -LiteralPath $GitignorePath -Value ($needed -join [Environment]::NewLine) -Encoding UTF8
    return
  }
  $existing = @(Get-Content -LiteralPath $GitignorePath -ErrorAction SilentlyContinue)
  foreach ($line in $needed) {
    if ($existing -notcontains $line) {
      Add-Content -LiteralPath $GitignorePath -Value $line -Encoding UTF8
    }
  }
}

function Get-GitToplevel([string]$Path) {
  Push-Location $Path
  try {
    $top = (& git rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -ne 0) { return $null }
    return ($top -replace '/', '\').Trim()
  } finally {
    Pop-Location
  }
}

Write-Host "============================================================" -ForegroundColor Magenta
Write-Host " fix-and-deploy.ps1 — resumora-marketing-intel" -ForegroundColor Magenta
Write-Host " Remote: $RemoteUrl" -ForegroundColor Magenta
Write-Host "============================================================" -ForegroundColor Magenta
Write-Host "Project: $ProjectRoot" -ForegroundColor DarkGray

# --- Prerequisites ---
Write-Step "Prerequisites"
if (-not (Test-Cmd "git")) { Write-Fail "Git not found on PATH." }
Write-Ok "git"

$hasGh = Test-Cmd "gh"
if ($hasGh) {
  Write-Ok "gh"
} else {
  Write-Warn "gh not found — attempting winget install"
  if (Test-Cmd "winget") {
    winget install --id GitHub.cli -e --accept-source-agreements --accept-package-agreements
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$machinePath;$userPath"
    $hasGh = Test-Cmd "gh"
  }
  if ($hasGh) { Write-Ok "gh installed" } else {
    Write-Warn "gh still unavailable. Secrets must be added via GitHub UI if SkipSecrets is not used."
  }
}

# --- .gitignore ---
Write-Step "Ensure .env is gitignored (local file kept)"
$gitignore = Join-Path $ProjectRoot ".gitignore"
Ensure-EnvIgnored $gitignore
Write-Ok ".gitignore includes .env patterns"

# Detect nested vs standalone
$gitTop = Get-GitToplevel $ProjectRoot
$isStandalone = $false
if ($gitTop) {
  $normTop = $gitTop.TrimEnd('\')
  $normProj = $ProjectRoot.TrimEnd('\')
  $isStandalone = ($normTop -ieq $normProj)
  Write-Host "    git toplevel: $gitTop" -ForegroundColor DarkGray
  if ($isStandalone) { Write-Ok "Standalone git repo" } else { Write-Warn "Nested under monorepo ($gitTop) — will use CLEAN orphan push" }
} else {
  Write-Warn "No git repo detected at/above project — will init clean orphan for push"
}

# --- Untrack .env if present in current repo index ---
Write-Step "Untrack .env from index if tracked (keep disk file)"
if ($gitTop) {
  Push-Location $gitTop
  try {
    $candidates = @(".env", "resumora-marketing-intel/.env")
    foreach ($rel in $candidates) {
      & git ls-files --error-unmatch -- $rel 2>$null | Out-Null
      if ($LASTEXITCODE -eq 0) {
        & git rm --cached --ignore-unmatch -- $rel | Out-Null
        Write-Ok "git rm --cached $rel"
      }
    }
  } finally {
    Pop-Location
  }
} else {
  Write-Ok "Nothing to untrack (no parent git)"
}

# --- Push clean code ---
if (-not $SkipPush) {
  Write-Step "Prepare clean history and force-push to origin main"
  Write-Warn "Force-push will replace remote main on $GitHubRepo"
  Write-Warn "This does NOT rewrite BossMind-prod history."

  $staging = Join-Path $env:TEMP ("rmi-clean-" + [guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $staging -Force | Out-Null

  try {
    $excludeDirs = @(".git", ".venv", ".terraform", "__pycache__", ".pytest_cache", "node_modules", "artifacts")
    Get-ChildItem -LiteralPath $ProjectRoot -Force | ForEach-Object {
      $n = $_.Name
      if ($excludeDirs -contains $n) { return }
      if ($n -eq ".env") { return }
      if ($n -like ".env.*" -and $n -ne ".env.example") { return }
      if ($n -match '(?i)(sa-key|gcp-key|service-account).*\.json$') { return }
      if ($n -eq "fix-and-deploy.ps1") {
        # include the script itself
      }
      Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $staging $n) -Recurse -Force
    }

    # Scrub any leaked secret files
    Get-ChildItem -LiteralPath $staging -Recurse -Force -File -ErrorAction SilentlyContinue |
      Where-Object {
        $_.Name -eq ".env" -or
        ($_.Name -like ".env.*" -and $_.Name -ne ".env.example") -or
        $_.Extension -eq ".pem" -or
        $_.Name -match '(?i)(sa-key|gcp-key|service-account).*\.json$'
      } |
      ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Force
        Write-Warn "Removed from staging: $($_.Name)"
      }

    Ensure-EnvIgnored (Join-Path $staging ".gitignore")

    # Heuristic leak check (do not print matched values)
    $leak = Get-ChildItem -LiteralPath $staging -Recurse -Include *.env,*.yml,*.yaml,*.json,*.tfvars,*.ps1 -File -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -ne ".env.example" } |
      Select-String -Pattern '(?i)(DEEPSEEK_API_KEY\s*=\s*\S+|OPENAI_API_KEY\s*=\s*\S+|sk-[a-zA-Z0-9]{20,})' -ErrorAction SilentlyContinue
    if ($leak) {
      Write-Fail "Possible secret material still in staging — aborting push."
    }
    Write-Ok "Staging scrub passed"

    Push-Location $staging
    try {
      if ($isStandalone) {
        # Standalone: prefer filter-repo on a clone of current repo if available
        Write-Host "    Mode: standalone clean export (orphan)" -ForegroundColor DarkGray
      } else {
        Write-Host "    Mode: monorepo-safe orphan export" -ForegroundColor DarkGray
      }

      & git init -b main | Out-Null
      & git config user.email "deploy@resumora.net"
      & git config user.name "Resumora Deploy Script"
      & git add -A
      & git rm -r --cached --ignore-unmatch -- .env 2>$null | Out-Null
      & git commit -m "deploy: production-ready marketing intelligence stack (secret-free)" | Out-Null
      if ($LASTEXITCODE -ne 0) { Write-Fail "git commit failed" }

      & git remote add origin $RemoteUrl
      Write-Step "git push -u origin main --force"
      & git push -u origin main --force
      if ($LASTEXITCODE -ne 0) {
        Write-Fail "Push failed (secret scan / auth / permissions). Fix and re-run."
      }
      Write-Ok "Force-push succeeded (clean main, no .env)"
    } finally {
      Pop-Location
    }
  } finally {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
  }

  # Restore BossMind remote if redirected
  if ($gitTop -and -not $isStandalone) {
    Write-Step "Verify BossMind monorepo origin"
    Push-Location $gitTop
    try {
      $originUrl = (& git remote get-url origin 2>$null)
      if ($originUrl -and ($originUrl -match "resumora-marketing-intel")) {
        Write-Warn "BossMind origin pointed at marketing-intel — restoring BossMind-prod"
        & git remote set-url origin $BossMindRemoteUrl
        Write-Ok "origin -> $BossMindRemoteUrl"
      } else {
        Write-Ok "BossMind origin OK ($originUrl)"
      }
    } finally {
      Pop-Location
    }
  }
} else {
  Write-Warn "SkipPush — not pushing"
}

# --- GitHub secrets ---
Write-Step "GitHub Actions secrets"
if ($SkipSecrets) {
  Write-Warn "SkipSecrets — skipping"
} elseif (-not $hasGh) {
  Write-Host @"

  Add secrets manually:
    https://github.com/$GitHubRepo/settings/secrets/actions

    GCP_PROJECT_ID    = $GcpProjectId
    GCP_SA_KEY        = (full contents of deployer SA JSON)
    SLACK_WEBHOOK_URL = (optional)

"@ -ForegroundColor Yellow
  Write-Fail "gh required for automated secret set. Install GitHub CLI and re-run with -SkipPush if code is already pushed."
} else {
  & gh auth status 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Write-Warn "gh not authenticated — run interactive login once"
    & gh auth login
    if ($LASTEXITCODE -ne 0) { Write-Fail "gh auth login failed" }
  }
  Write-Ok "gh authenticated"

  if ([string]::IsNullOrWhiteSpace($GcpProjectId)) {
    $GcpProjectId = Read-Host "GCP_PROJECT_ID"
  }
  if ([string]::IsNullOrWhiteSpace($GcpProjectId)) { Write-Fail "GCP_PROJECT_ID is required" }

  if ([string]::IsNullOrWhiteSpace($SaKeyPath)) {
    $SaKeyPath = Read-Host "Path to GCP service account JSON (GCP_SA_KEY)"
  }
  if ([string]::IsNullOrWhiteSpace($SaKeyPath) -or -not (Test-Path -LiteralPath $SaKeyPath)) {
    Write-Fail "SA key file not found: $SaKeyPath"
  }
  $SaKeyPath = (Resolve-Path -LiteralPath $SaKeyPath).Path

  # Validate JSON without printing secrets
  try {
    $saRaw = Get-Content -LiteralPath $SaKeyPath -Raw -Encoding UTF8
    $saObj = $saRaw | ConvertFrom-Json
    if ($saObj.type -ne "service_account") { Write-Fail "JSON type is not service_account" }
    if (-not $saObj.private_key -or -not $saObj.client_email) { Write-Fail "SA JSON missing required fields" }
    Write-Ok "SA JSON shape OK (email not printed)"
  } catch {
    Write-Fail "Invalid SA JSON: $($_.Exception.Message)"
  }

  $GcpProjectId | & gh secret set GCP_PROJECT_ID --repo $GitHubRepo
  if ($LASTEXITCODE -ne 0) { Write-Fail "Failed setting GCP_PROJECT_ID" }
  Write-Ok "GCP_PROJECT_ID set (= $GcpProjectId)"

  # Pipe file to gh — never Write-Host the contents
  Get-Content -LiteralPath $SaKeyPath -Raw -Encoding UTF8 | & gh secret set GCP_SA_KEY --repo $GitHubRepo
  if ($LASTEXITCODE -ne 0) { Write-Fail "Failed setting GCP_SA_KEY" }
  Write-Ok "GCP_SA_KEY set"

  if ([string]::IsNullOrWhiteSpace($SlackWebhookUrl)) {
    $SlackWebhookUrl = Read-Host "SLACK_WEBHOOK_URL (optional — press Enter to skip)"
  }
  if (-not [string]::IsNullOrWhiteSpace($SlackWebhookUrl)) {
    $SlackWebhookUrl | & gh secret set SLACK_WEBHOOK_URL --repo $GitHubRepo
    if ($LASTEXITCODE -ne 0) { Write-Fail "Failed setting SLACK_WEBHOOK_URL" }
    Write-Ok "SLACK_WEBHOOK_URL set"
  } else {
    Write-Warn "SLACK_WEBHOOK_URL skipped"
  }

  Write-Host "    Secrets currently configured:" -ForegroundColor DarkGray
  & gh secret list --repo $GitHubRepo
}

# --- Trigger + watch workflow ---
Write-Step "Trigger / monitor workflow"
if ($hasGh -and -not $SkipWatch) {
  & gh workflow run "Terraform CI/CD" --repo $GitHubRepo 2>$null
  if ($LASTEXITCODE -ne 0) {
    & gh workflow run "terraform-ci-cd.yml" --repo $GitHubRepo 2>$null
  }
  Start-Sleep -Seconds 4
  Write-Host "    Recent runs:" -ForegroundColor DarkGray
  & gh run list --repo $GitHubRepo --limit 5

  $watch = Read-Host "Watch latest run until completion? (Y/n)"
  if ($watch -notmatch '^(n|no)$') {
    $runId = & gh run list --repo $GitHubRepo --limit 1 --json databaseId --jq ".[0].databaseId" 2>$null
    if ($runId) {
      Write-Host "    Watching run $runId ..." -ForegroundColor Cyan
      & gh run watch $runId --repo $GitHubRepo --exit-status
      if ($LASTEXITCODE -eq 0) {
        Write-Ok "Workflow succeeded"
      } else {
        Write-Warn "Workflow failed — open the run and paste the red step error for a fix"
      }
      Write-Host ""
      Write-Host "Actions run: https://github.com/$GitHubRepo/actions/runs/$runId" -ForegroundColor Cyan
    } else {
      Write-Warn "No runs yet — open https://github.com/$GitHubRepo/actions"
    }
  }
} else {
  Write-Host "    Open: https://github.com/$GitHubRepo/actions" -ForegroundColor Cyan
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Magenta
Write-Host " DONE" -ForegroundColor Magenta
Write-Host " - .env stayed local and was not committed" -ForegroundColor Green
Write-Host " - Check Actions (or Slack) for cloud_run_url" -ForegroundColor Green
Write-Host " - Or after SA auth: .\scripts\get-url.ps1" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Magenta
