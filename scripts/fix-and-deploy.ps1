#Requires -Version 5.1
<#
.SYNOPSIS
  Fix GitHub secret-scan block, push a CLEAN resumora-marketing-intel tree,
  set GitHub Actions secrets (SA key), and trigger/monitor Terraform CI/CD.

.DESCRIPTION
  - Does NOT commit .env or any secrets.
  - Does NOT rewrite the full BossMind monorepo history.
  - Builds a fresh orphan commit containing only resumora-marketing-intel/
    (excluding .env / keys), then force-pushes to the standalone remote.
  - Restores BossMind origin to BossMind-prod if it was redirected.

.NOTES
  Run from anywhere:
    powershell -ExecutionPolicy Bypass -File D:\BossMind\resumora-marketing-intel\scripts\fix-and-deploy.ps1
#>
param(
  [string]$ProjectRoot = "D:\BossMind\resumora-marketing-intel",
  [string]$BossMindRoot = "D:\BossMind",
  [string]$RemoteUrl = "https://github.com/ahmadlatifdev/resumora-marketing-intel.git",
  [string]$GitHubRepo = "ahmadlatifdev/resumora-marketing-intel",
  [string]$BossMindRemoteUrl = "https://github.com/ahmadlatifdev/BossMind-prod.git",
  [string]$GcpProjectId = "key-journal-378204",  # INSERT override if needed
  [string]$SaKeyPath = $env:SA_KEY_PATH,
  [string]$SlackWebhookUrl = $env:SLACK_WEBHOOK_URL,
  [switch]$SkipSecrets,
  [switch]$SkipPush,
  [switch]$SkipWatch,
  [switch]$AllowSecretOnGitHub  # opens unblock docs; default is clean removal
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Write-Step([string]$Message) {
  Write-Host ""
  Write-Host "==> $Message" -ForegroundColor Cyan
}
function Write-Ok([string]$Message) { Write-Host "    OK: $Message" -ForegroundColor Green }
function Write-Warn([string]$Message) { Write-Host "    WARN: $Message" -ForegroundColor Yellow }
function Write-Fail([string]$Message) {
  Write-Host "    FAIL: $Message" -ForegroundColor Red
  exit 1
}

function Test-Command([string]$Name) {
  return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Ensure-GitignoreHasEnv([string]$GitignorePath) {
  $lines = @(
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
    Set-Content -LiteralPath $GitignorePath -Value ($lines -join "`n") -Encoding UTF8
    return
  }
  $existing = Get-Content -LiteralPath $GitignorePath -ErrorAction SilentlyContinue
  foreach ($line in $lines) {
    if ($existing -notcontains $line) {
      Add-Content -LiteralPath $GitignorePath -Value $line -Encoding UTF8
    }
  }
}

# ---------------------------------------------------------------------------
Write-Host "============================================================" -ForegroundColor Magenta
Write-Host " Resumora Marketing Intel — fix-and-deploy (no secret push)" -ForegroundColor Magenta
Write-Host "============================================================" -ForegroundColor Magenta

if (-not (Test-Path -LiteralPath $ProjectRoot)) {
  Write-Fail "Project folder not found: $ProjectRoot"
}

# Prerequisites
Write-Step "Checking prerequisites"
if (-not (Test-Command "git")) { Write-Fail "Git is not installed or not on PATH." }
Write-Ok "git found"

$hasGh = Test-Command "gh"
if ($hasGh) { Write-Ok "gh found" } else { Write-Warn "gh not found — secrets will need manual UI steps (or winget install)." }

if (Test-Command "gcloud") { Write-Ok "gcloud found (optional)" } else { Write-Warn "gcloud not on PATH (optional for local SA validate)" }

# Optional: allow secret on GitHub instead of scrubbing
if ($AllowSecretOnGitHub) {
  Write-Step "Allow-secret path (NOT recommended)"
  Write-Host @"
  GitHub blocked a push because a secret was detected in git history.
  To allow it instead of scrubbing (weaker security):

  1) Open the unblock URL from your push error email/CLI output
     (GitHub → Security → Secret scanning alerts → Allow secret)
  2) Re-run push.

  Prefer the default clean approach in this script.
"@ -ForegroundColor Yellow
  Write-Fail "Re-run WITHOUT -AllowSecretOnGitHub to scrub .env and push cleanly."
}

# Ensure local ignore rules (never commit .env)
Write-Step "Ensuring .env is ignored locally"
Ensure-GitignoreHasEnv (Join-Path $ProjectRoot ".gitignore")
Write-Ok ".gitignore updated for .env / SA JSON patterns"

# If .env is tracked inside project worktree of BossMind, unstage only (keep file)
Write-Step "Untracking .env if present in index (keep local file)"
Push-Location $BossMindRoot
try {
  $tracked = @(git ls-files -- "resumora-marketing-intel/.env" ".env" 2>$null)
  foreach ($t in $tracked) {
    if ($t -eq "resumora-marketing-intel/.env" -or $t -eq ".env") {
      git rm --cached --ignore-unmatch -- "$t" 2>$null | Out-Null
      Write-Ok "Removed from index: $t (file kept on disk if present)"
    }
  }
  if (-not $tracked -or $tracked.Count -eq 0) {
    Write-Ok "No project .env currently in the index"
  }
} finally {
  Pop-Location
}

# ---------------------------------------------------------------------------
# CRITICAL: Do not force-push entire BossMind history (contains root .env
# with DeepSeek key from old commits). Push a CLEAN orphan tree instead.
# ---------------------------------------------------------------------------
if (-not $SkipPush) {
  Write-Step "Building clean orphan export (excludes .env / secrets)"
  Write-Warn "Force-push will REPLACE remote main on $GitHubRepo with a clean tree."
  Write-Warn "BossMind monorepo history is NOT rewritten."

  $staging = Join-Path $env:TEMP ("rmi-clean-" + [guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $staging -Force | Out-Null

  try {
    # Copy project files excluding secrets / junk
    $excludeDirs = @(".git", ".venv", ".terraform", "__pycache__", ".pytest_cache", "node_modules", "artifacts")
    $excludeFiles = @(".env", ".env.local", "gcp-key.json", "deployer-sa.json", "tfplan", "*.tfstate", "*.tfstate.*")

    Write-Host "    Copying $ProjectRoot -> $staging" -ForegroundColor DarkGray
    Get-ChildItem -LiteralPath $ProjectRoot -Force | ForEach-Object {
      $name = $_.Name
      if ($excludeDirs -contains $name) { return }
      if ($name -eq ".env" -or $name -like ".env.*" -and $name -ne ".env.example") { return }
      if ($name -match 'sa-key|gcp-key|service-account.*\.json$') { return }
      Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $staging $name) -Recurse -Force
    }

    # Extra scrub: delete any leaked env/key files if copied
    Get-ChildItem -LiteralPath $staging -Recurse -Force -File -ErrorAction SilentlyContinue |
      Where-Object {
        $_.Name -eq ".env" -or
        ($_.Name -like ".env.*" -and $_.Name -ne ".env.example") -or
        $_.Name -match '(?i)(sa-key|gcp-key|service-account).*\.json$'
      } |
      ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Force
        Write-Warn "Scrubbed from staging: $($_.FullName)"
      }

    Ensure-GitignoreHasEnv (Join-Path $staging ".gitignore")

    # Verify no DeepSeek/OpenAI-looking assignments in staged text (names only heuristic)
    $leakHits = Get-ChildItem -LiteralPath $staging -Recurse -Include *.env,*.yml,*.yaml,*.json,*.tfvars -File -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -ne ".env.example" } |
      Select-String -Pattern '(?i)(DEEPSEEK_API_KEY|OPENAI_API_KEY|sk-[a-zA-Z0-9]{20,}|hooks\.slack\.com/services/)' -ErrorAction SilentlyContinue
    if ($leakHits) {
      Write-Fail "Refusing to push: possible secret material still in staging. Remove it first."
    }
    Write-Ok "Staging scrub passed"

    Push-Location $staging
    try {
      git init -b main | Out-Null
      git config user.email "deploy@resumora.net"
      git config user.name "Resumora Deploy Script"
      git add -A
      # Guard: never add .env
      git rm -r --cached --ignore-unmatch .env 2>$null | Out-Null
      git commit -m "deploy: production-ready marketing intelligence stack (secret-free)" | Out-Null
      git remote add origin $RemoteUrl
      Write-Ok "Clean orphan commit created"

      Write-Step "Force-pushing clean main -> $RemoteUrl"
      git push -u origin main --force
      if ($LASTEXITCODE -ne 0) { Write-Fail "git push failed (exit $LASTEXITCODE). Check auth / secret scan / permissions." }
      Write-Ok "Push succeeded (clean history, no .env)"
    } finally {
      Pop-Location
    }
  } finally {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
  }

  # Restore BossMind origin if it was redirected at the marketing-intel repo
  Write-Step "Checking BossMind monorepo remote"
  Push-Location $BossMindRoot
  try {
    $originUrl = (git remote get-url origin 2>$null)
    if ($originUrl -match "resumora-marketing-intel") {
      Write-Warn "BossMind origin currently points at resumora-marketing-intel — restoring to BossMind-prod"
      git remote set-url origin $BossMindRemoteUrl
      Write-Ok "BossMind origin -> $BossMindRemoteUrl"
    } else {
      Write-Ok "BossMind origin is $originUrl"
    }
  } finally {
    Pop-Location
  }
} else {
  Write-Warn "SkipPush set — not pushing"
}

# ---------------------------------------------------------------------------
Write-Step "GitHub secrets"
if ($SkipSecrets) {
  Write-Warn "SkipSecrets set — not updating secrets"
} elseif (-not $hasGh) {
  Write-Warn "gh CLI missing. Install then re-run, or add secrets manually:"
  Write-Host @"

  winget install --id GitHub.cli

  Or UI: https://github.com/$GitHubRepo/settings/secrets/actions
    GCP_PROJECT_ID     = $GcpProjectId
    GCP_SA_KEY         = (full JSON of deployer SA key)
    SLACK_WEBHOOK_URL  = (optional incoming webhook)

"@ -ForegroundColor Yellow

  $install = Read-Host "Install GitHub CLI with winget now? (y/N)"
  if ($install -match '^(y|yes)$') {
    winget install --id GitHub.cli -e --accept-source-agreements --accept-package-agreements
    $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path", "User")
    $hasGh = Test-Command "gh"
    if (-not $hasGh) { Write-Fail "gh still not on PATH — open a new terminal and re-run this script." }
  } else {
    Write-Fail "Cannot set secrets without gh. Add them in the UI, then re-run with -SkipPush."
  }
}

if (-not $SkipSecrets -and $hasGh) {
  # Auth check
  gh auth status 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Write-Warn "gh not authenticated — starting gh auth login (browser once for gh, not gcloud)"
    gh auth login
  }

  if ([string]::IsNullOrWhiteSpace($SaKeyPath)) {
    $SaKeyPath = Read-Host "Path to GCP service account JSON key (for secret GCP_SA_KEY)"
  }
  if (-not (Test-Path -LiteralPath $SaKeyPath)) {
    Write-Fail "SA key file not found: $SaKeyPath"
  }

  # Validate JSON shape without printing secrets
  try {
    $raw = Get-Content -LiteralPath $SaKeyPath -Raw -Encoding UTF8
    $json = $raw | ConvertFrom-Json
    if (-not $json.type -or $json.type -ne "service_account") {
      Write-Fail "File does not look like a GCP service_account JSON key."
    }
    if (-not $json.private_key -or -not $json.client_email) {
      Write-Fail "SA JSON missing private_key / client_email."
    }
    Write-Ok "SA JSON looks valid (client_email present — value not printed)"
  } catch {
    Write-Fail "Failed to parse SA JSON: $($_.Exception.Message)"
  }

  Write-Host "    Setting GCP_PROJECT_ID=$GcpProjectId" -ForegroundColor DarkGray
  $GcpProjectId | gh secret set GCP_PROJECT_ID --repo $GitHubRepo
  if ($LASTEXITCODE -ne 0) { Write-Fail "Failed to set GCP_PROJECT_ID" }
  Write-Ok "GCP_PROJECT_ID set"

  # Pipe file to gh without echoing contents
  Get-Content -LiteralPath $SaKeyPath -Raw -Encoding UTF8 | gh secret set GCP_SA_KEY --repo $GitHubRepo
  if ($LASTEXITCODE -ne 0) { Write-Fail "Failed to set GCP_SA_KEY" }
  Write-Ok "GCP_SA_KEY set (value not printed)"

  if ([string]::IsNullOrWhiteSpace($SlackWebhookUrl)) {
    $SlackWebhookUrl = Read-Host "SLACK_WEBHOOK_URL (optional — Enter to skip)"
  }
  if (-not [string]::IsNullOrWhiteSpace($SlackWebhookUrl)) {
    $SlackWebhookUrl | gh secret set SLACK_WEBHOOK_URL --repo $GitHubRepo
    if ($LASTEXITCODE -ne 0) { Write-Fail "Failed to set SLACK_WEBHOOK_URL" }
    Write-Ok "SLACK_WEBHOOK_URL set (value not printed)"
  } else {
    Write-Warn "SLACK_WEBHOOK_URL skipped"
  }

  Write-Host "    Secret names present:" -ForegroundColor DarkGray
  gh secret list --repo $GitHubRepo
}

# ---------------------------------------------------------------------------
Write-Step "Trigger / monitor workflow"
if ($hasGh -and -not $SkipWatch) {
  # Push already triggers; also allow manual dispatch
  Write-Host "    Attempting workflow_dispatch for Terraform CI/CD..." -ForegroundColor DarkGray
  gh workflow run "Terraform CI/CD" --repo $GitHubRepo 2>$null
  if ($LASTEXITCODE -ne 0) {
    # Fallback name variants
    gh workflow run terraform-ci-cd.yml --repo $GitHubRepo 2>$null
  }

  Start-Sleep -Seconds 5
  Write-Host "    Recent runs:" -ForegroundColor DarkGray
  gh run list --repo $GitHubRepo --limit 5

  $watch = Read-Host "Watch the latest run until completion? (Y/n)"
  if ($watch -notmatch '^(n|no)$') {
    $runId = gh run list --repo $GitHubRepo --limit 1 --json databaseId --jq ".[0].databaseId" 2>$null
    if ($runId) {
      Write-Host "    Watching run $runId ..." -ForegroundColor Cyan
      gh run watch $runId --repo $GitHubRepo --exit-status
      if ($LASTEXITCODE -eq 0) {
        Write-Ok "Workflow succeeded"
        Write-Host ""
        Write-Host "Cloud Run URL:" -ForegroundColor Green
        Write-Host "  Check the Slack message, or the 'Terraform Apply' / Notify Slack step in:" -ForegroundColor DarkGray
        Write-Host "  https://github.com/$GitHubRepo/actions/runs/$runId" -ForegroundColor Cyan
        Write-Host "  Or after SA auth locally: .\scripts\get-url.ps1" -ForegroundColor Cyan
      } else {
        Write-Warn "Workflow finished with failure — open the run URL above and paste the red step error here."
      }
    } else {
      Write-Warn "No runs found yet. Open https://github.com/$GitHubRepo/actions"
    }
  }
} else {
  Write-Host @"

  Open Actions: https://github.com/$GitHubRepo/actions
  Watch "Terraform CI/CD". On success, Slack (if configured) includes cloud_run_url,
  or run:  .\scripts\get-url.ps1  (after .\scripts\auth.ps1 with your SA key).

"@ -ForegroundColor Yellow
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Magenta
Write-Host " DONE — .env stayed local; never committed by this script" -ForegroundColor Magenta
Write-Host "============================================================" -ForegroundColor Magenta
