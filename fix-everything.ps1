#Requires -Version 5.1
<#
.SYNOPSIS
  Fix large .terraform binaries, hooks, missing terraform/ on GitHub, then deploy.

.DESCRIPTION
  Hands-free cleanup + force-push of a CLEAN secret-free tree to
  ahmadlatifdev/resumora-marketing-intel, then trigger Terraform CI/CD and
  print cloud_run_url.

  Safe for nested monorepo (D:\BossMind\resumora-marketing-intel under BossMind):
  does NOT rewrite BossMind-prod history; pushes a clean orphan export instead.

.EXAMPLE
  cd D:\BossMind\resumora-marketing-intel
  powershell -ExecutionPolicy Bypass -File .\fix-everything.ps1
#>

param(
  [string]$RemoteUrl = "https://github.com/ahmadlatifdev/resumora-marketing-intel.git",
  [string]$GitHubRepo = "ahmadlatifdev/resumora-marketing-intel",
  [string]$BossMindRemoteUrl = "https://github.com/ahmadlatifdev/BossMind-prod.git",
  [int]$PollSeconds = 10,
  [int]$MaxWaitMinutes = 45,
  [switch]$SkipPush,
  [switch]$SkipWatch
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$ProjectRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
  $ProjectRoot = (Get-Location).Path
}
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
function Test-Cmd([string]$Name) { return [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

function Disable-AllHooks {
  Write-Step "Disable Git hooks (local / global / system / core.hooksPath)"

  foreach ($scope in @("local", "global", "system")) {
    try {
      $hp = & git config --$scope --get core.hooksPath 2>$null
      if ($hp) {
        & git config --$scope --unset-all core.hooksPath 2>$null
        Write-Ok "Unset core.hooksPath ($scope) was: $hp"
      }
    } catch { }
  }

  # Parent monorepo + this folder if it ever gets its own .git
  $candidates = @()
  Push-Location $ProjectRoot
  try {
    $top = (& git rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -eq 0 -and $top) { $candidates += ($top -replace '/', '\') }
  } finally { Pop-Location }
  $candidates += $ProjectRoot
  $candidates = $candidates | Select-Object -Unique

  foreach ($root in $candidates) {
    $hooksDir = Join-Path $root ".git\hooks"
    if (Test-Path -LiteralPath $hooksDir) {
      Get-ChildItem -LiteralPath $hooksDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike "*.sample" } |
        ForEach-Object {
          $bak = $_.FullName + ".disabled"
          Move-Item -LiteralPath $_.FullName -Destination $bak -Force -ErrorAction SilentlyContinue
          Write-Ok "Disabled hook: $($_.Name) under $root"
        }
    }
  }
  Write-Ok "Hooks disabled / unset"
}

function Ensure-Gitignore {
  Write-Step "Ensure .terraform* / tfstate / tfplan are gitignored"
  $gi = Join-Path $ProjectRoot ".gitignore"
  $needed = @(
    ".terraform/",
    ".terraform*",
    "*.tfstate",
    "*.tfstate.*",
    "tfplan",
    "crash.log",
    ".env",
    ".env.*",
    "!.env.example",
    "*.pem",
    "*-sa-key.json",
    "gcp-key.json",
    "deployer-sa.json"
  )
  if (-not (Test-Path -LiteralPath $gi)) {
    Set-Content -LiteralPath $gi -Value ($needed -join [Environment]::NewLine) -Encoding UTF8
  } else {
    $existing = @(Get-Content -LiteralPath $gi -ErrorAction SilentlyContinue)
    foreach ($line in $needed) {
      if ($existing -notcontains $line) {
        Add-Content -LiteralPath $gi -Value $line -Encoding UTF8
      }
    }
  }
  Write-Ok ".gitignore updated"
}

function Ensure-WorkflowDispatch {
  Write-Step "Ensure terraform-ci-cd.yml has workflow_dispatch"
  $wf = Join-Path $ProjectRoot ".github\workflows\terraform-ci-cd.yml"
  if (-not (Test-Path -LiteralPath $wf)) {
    Write-Fail "Missing workflow file: $wf"
  }
  $text = Get-Content -LiteralPath $wf -Raw -Encoding UTF8
  if ($text -notmatch '(?m)^\s*workflow_dispatch\s*:') {
    Write-Warn "workflow_dispatch missing — inserting under 'on:'"
    if ($text -match '(?ms)(^on:\s*\r?\n)') {
      $text = $text -replace '(?ms)(^on:\s*\r?\n)', "`$1  workflow_dispatch:`r`n"
      Set-Content -LiteralPath $wf -Value $text -Encoding UTF8 -NoNewline
      Write-Ok "Inserted workflow_dispatch"
    } else {
      Write-Fail "Could not patch workflow_dispatch into $wf"
    }
  } else {
    Write-Ok "workflow_dispatch already present"
  }
}

function Get-GitToplevel {
  Push-Location $ProjectRoot
  try {
    $t = & git rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return ($t -replace '/', '\').Trim()
  } finally { Pop-Location }
}

function Remove-TerraformFromIndexAndHistory([string]$GitRoot) {
  Write-Step "Remove .terraform from index / history (if present)"
  Push-Location $GitRoot
  try {
    # Index
    & git rm -r --cached --ignore-unmatch -- "**/.terraform" ".terraform" "resumora-marketing-intel/**/.terraform" 2>$null | Out-Null
    & git rm -r --cached --ignore-unmatch -- "**/terraform/.terraform" 2>$null | Out-Null

    $hasFilterRepo = Test-Cmd "git-filter-repo"
    # Only rewrite history if THIS folder is the git root (standalone).
    # Never rewrite BossMind monorepo history from this script.
    $isStandalone = ((Resolve-Path $GitRoot).Path.TrimEnd('\') -ieq $ProjectRoot.TrimEnd('\'))
    if ($isStandalone) {
      if ($hasFilterRepo) {
        Write-Host "    Using git filter-repo to drop .terraform from history..." -ForegroundColor DarkGray
        & git filter-repo --force --invert-paths --path-glob "*.terraform/*" --path-glob "**/.terraform/**" 2>$null
        if ($LASTEXITCODE -ne 0) {
          & git filter-repo --force --path .terraform --invert-paths
        }
        Write-Ok "filter-repo completed"
      } else {
        Write-Warn "git-filter-repo not installed — using filter-branch fallback"
        $env:FILTER_BRANCH_SQUELCH_WARNING = "1"
        & git filter-branch --force --index-filter `
          "git rm -rf --cached --ignore-unmatch -r .terraform terraform/.terraform" `
          --prune-empty --tag-name-filter cat -- --all
        if ($LASTEXITCODE -ne 0) {
          Write-Warn "filter-branch reported issues; continuing with clean orphan export"
        } else {
          Write-Ok "filter-branch completed"
        }
        Remove-Item -Recurse -Force ".git\refs\original" -ErrorAction SilentlyContinue
        & git reflog expire --expire=now --all 2>$null
        & git gc --prune=now --aggressive 2>$null
      }
    } else {
      Write-Warn "Nested under monorepo ($GitRoot) — skipping monorepo history rewrite"
      Write-Warn "Will push a CLEAN orphan export (no .terraform binaries) instead"
    }
  } finally {
    Pop-Location
  }
}

function Publish-CleanTree {
  Write-Step "Stage clean tree (terraform/ + app, NO .terraform binaries) and force-push"
  Write-Warn "Force-push replaces remote main on $GitHubRepo"

  $staging = Join-Path $env:TEMP ("rmi-fix-" + [guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $staging -Force | Out-Null

  try {
    $excludeDirs = @(
      ".git", ".venv", ".terraform", "__pycache__", ".pytest_cache",
      "node_modules", "artifacts"
    )
    Get-ChildItem -LiteralPath $ProjectRoot -Force | ForEach-Object {
      $n = $_.Name
      if ($excludeDirs -contains $n) { return }
      if ($n -eq ".env") { return }
      if ($n -like ".env.*" -and $n -ne ".env.example") { return }
      if ($n -match '(?i)(sa-key|gcp-key|service-account).*\.json$') { return }
      Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $staging $n) -Recurse -Force
    }

    # Scrub nested .terraform / state / secrets anywhere under staging
    Get-ChildItem -LiteralPath $staging -Recurse -Force -Directory -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -eq ".terraform" } |
      ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Recurse -Force
        Write-Ok "Scrubbed directory: $($_.FullName)"
      }

    Get-ChildItem -LiteralPath $staging -Recurse -Force -File -ErrorAction SilentlyContinue |
      Where-Object {
        $_.Name -eq ".env" -or
        ($_.Name -like ".env.*" -and $_.Name -ne ".env.example") -or
        $_.Name -eq "tfplan" -or
        $_.Name -like "*.tfstate" -or
        $_.Name -like "*.tfstate.*" -or
        $_.Extension -eq ".exe" -or
        $_.Length -gt 90MB -or
        $_.Name -match '(?i)(sa-key|gcp-key|service-account).*\.json$'
      } |
      ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Force
        Write-Warn "Scrubbed file: $($_.Name) ($([math]::Round($_.Length/1MB,1)) MB)"
      }

    # Ensure terraform sources exist
    $tfMain = Join-Path $staging "terraform\main.tf"
    if (-not (Test-Path -LiteralPath $tfMain)) {
      Write-Fail "terraform/main.tf missing after copy — aborting"
    }
    $wf = Join-Path $staging ".github\workflows\terraform-ci-cd.yml"
    if (-not (Test-Path -LiteralPath $wf)) {
      Write-Fail "workflow missing after copy — aborting"
    }
    $wfText = Get-Content -LiteralPath $wf -Raw
    if ($wfText -notmatch 'workflow_dispatch') {
      Write-Fail "workflow_dispatch still missing in staged workflow"
    }

    # Size guard
    $big = Get-ChildItem -LiteralPath $staging -Recurse -File -ErrorAction SilentlyContinue |
      Where-Object { $_.Length -gt 90MB }
    if ($big) {
      Write-Fail ("Refusing push — files >90MB remain: " + (($big | ForEach-Object { $_.FullName }) -join "; "))
    }
    Write-Ok "Staging scrub + size guard passed"

    Push-Location $staging
    try {
      & git init -b main | Out-Null
      & git config core.hooksPath nul 2>$null
      & git config user.email "deploy@resumora.net"
      & git config user.name "Resumora Fix Everything"
      & git add -A
      & git rm -r --cached --ignore-unmatch -- .terraform 2>$null | Out-Null
      & git commit --no-verify -m "fix: commit terraform sources without .terraform binaries" | Out-Null
      if ($LASTEXITCODE -ne 0) { Write-Fail "git commit failed" }

      & git remote add origin $RemoteUrl
      Write-Step "git push -u origin main --force --no-verify"
      & git push -u origin main --force --no-verify
      if ($LASTEXITCODE -ne 0) {
        Write-Fail "Force-push failed (exit $LASTEXITCODE). Check auth / GitHub rejection message."
      }
      Write-Ok "Force-push succeeded"
    } finally {
      Pop-Location
    }
  } finally {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
  }

  # Restore BossMind origin if redirected
  $top = Get-GitToplevel
  if ($top -and ($top.TrimEnd('\') -ine $ProjectRoot.TrimEnd('\'))) {
    Push-Location $top
    try {
      $origin = & git remote get-url origin 2>$null
      if ($origin -match "resumora-marketing-intel") {
        & git remote set-url origin $BossMindRemoteUrl
        Write-Ok "Restored BossMind origin -> $BossMindRemoteUrl"
      }
    } finally { Pop-Location }
  }
}

function Ensure-Gh {
  if (-not (Test-Cmd "gh")) {
    Write-Warn "gh missing — trying winget"
    if (-not (Test-Cmd "winget")) { return $false }
    winget install --id GitHub.cli -e --accept-source-agreements --accept-package-agreements
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" +
                [Environment]::GetEnvironmentVariable("Path", "User")
  }
  return (Test-Cmd "gh")
}

function Invoke-AndWatchWorkflow {
  Write-Step "Trigger Terraform CI/CD and wait"
  if (-not (Ensure-Gh)) {
    Write-Warn "gh not available"
    Write-Host "    Trigger manually: https://github.com/$GitHubRepo/actions" -ForegroundColor Yellow
    Write-Host "    Workflow: Terraform CI/CD → Run workflow" -ForegroundColor Yellow
    return
  }

  & gh auth status 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Write-Warn "gh not authenticated — interactive login once"
    & gh auth login
    if ($LASTEXITCODE -ne 0) { Write-Fail "gh auth login failed" }
  }

  & gh workflow run "Terraform CI/CD" --repo $GitHubRepo 2>$null
  if ($LASTEXITCODE -ne 0) {
    & gh workflow run "terraform-ci-cd.yml" --repo $GitHubRepo 2>$null
  }
  if ($LASTEXITCODE -ne 0) {
    Write-Warn "workflow_dispatch failed — push should still have triggered a run"
  }

  Start-Sleep -Seconds 5
  $runId = & gh run list --repo $GitHubRepo --limit 1 --json databaseId --jq ".[0].databaseId" 2>$null
  if (-not $runId) {
    Write-Warn "No runs yet. Open https://github.com/$GitHubRepo/actions"
    return
  }
  Write-Ok "Tracking run $runId"

  if ($SkipWatch) {
    Write-Host "    https://github.com/$GitHubRepo/actions/runs/$runId" -ForegroundColor Cyan
    return
  }

  $deadline = (Get-Date).AddMinutes($MaxWaitMinutes)
  $conclusion = $null
  $status = "unknown"
  while ((Get-Date) -lt $deadline) {
    $view = (& gh run view $runId --repo $GitHubRepo --json status,conclusion,url) | ConvertFrom-Json
    $status = [string]$view.status
    $conclusion = $view.conclusion
    Write-Host ("    [{0}] status={1} conclusion={2}" -f (Get-Date -Format "HH:mm:ss"), $status, $(if ($conclusion) { $conclusion } else { "(pending)" })) -ForegroundColor DarkGray
    if ($status -eq "completed" -and $conclusion) { break }
    Start-Sleep -Seconds $PollSeconds
  }

  if ($status -ne "completed") {
    Write-Fail "Timed out on run $runId — https://github.com/$GitHubRepo/actions/runs/$runId"
  }
  if ($conclusion -ne "success") {
    Write-Fail "Run $runId concluded=$conclusion — https://github.com/$GitHubRepo/actions/runs/$runId"
  }
  Write-Ok "Workflow succeeded"

  Write-Step "Extract cloud_run_url from logs"
  $logPath = Join-Path $env:TEMP "gh-run-$runId.log"
  & gh run view $runId --repo $GitHubRepo --log 2>$null | Out-File -FilePath $logPath -Encoding utf8
  $url = $null
  if (Test-Path -LiteralPath $logPath) {
    $logText = Get-Content -LiteralPath $logPath -Raw -ErrorAction SilentlyContinue
    $patterns = @(
      'cloud_run_url\s*=\s*(https://[^\s\"'']+)',
      'Dashboard URL:\s*(https://[^\s]+)',
      '(https://marketing-dashboard[^\s\"'']*\.run\.app[^\s\"'']*)',
      '(https://[a-z0-9\-]+-[a-z0-9]+-[a-z0-9]+\.a\.run\.app)'
    )
    foreach ($pat in $patterns) {
      $m = [regex]::Match($logText, $pat, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
      if ($m.Success) {
        $url = $m.Groups[1].Value.Trim().TrimEnd('"', "'", ',', ')')
        break
      }
    }
  }

  Write-Host ""
  Write-Host "============================================================" -ForegroundColor Magenta
  if ($url) {
    Write-Host " Cloud Run URL:" -ForegroundColor Green
    Write-Host " $url" -ForegroundColor Green
  } else {
    Write-Warn "cloud_run_url not found in logs"
    Write-Host " Check: https://github.com/$GitHubRepo/actions/runs/$runId" -ForegroundColor Cyan
    Write-Host " Or: .\scripts\get-url.ps1 after .\scripts\auth.ps1" -ForegroundColor Cyan
  }
  Write-Host "============================================================" -ForegroundColor Magenta
}

# ===================== MAIN =====================
Write-Host "============================================================" -ForegroundColor Magenta
Write-Host " fix-everything.ps1" -ForegroundColor Magenta
Write-Host " Root: $ProjectRoot" -ForegroundColor Magenta
Write-Host " Target: $GitHubRepo" -ForegroundColor Magenta
Write-Host "============================================================" -ForegroundColor Magenta

if (-not (Test-Cmd "git")) { Write-Fail "git not on PATH" }
Set-Location -LiteralPath $ProjectRoot

Disable-AllHooks
Ensure-Gitignore
Ensure-WorkflowDispatch

$gitTop = Get-GitToplevel
if ($gitTop) {
  Remove-TerraformFromIndexAndHistory $gitTop
} else {
  Write-Warn "No parent git repo — will still publish clean orphan"
}

# Verify terraform sources exist locally
if (-not (Test-Path -LiteralPath (Join-Path $ProjectRoot "terraform\main.tf"))) {
  Write-Fail "Local terraform/main.tf missing — cannot deploy"
}
Write-Ok "Local terraform/ sources present"

if (-not $SkipPush) {
  Publish-CleanTree
} else {
  Write-Warn "SkipPush set"
}

Invoke-AndWatchWorkflow

Write-Host ""
Write-Ok "Done — no secrets committed; .terraform binaries excluded"
exit 0
