#Requires -Version 5.1
<#
.SYNOPSIS
  Push main to origin, skipping Git hooks (--no-verify).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\push-now.ps1
#>

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location -LiteralPath $ScriptDir

Write-Host "==> Pushing main to origin (--no-verify)..." -ForegroundColor Cyan
Write-Host "    cwd: $ScriptDir" -ForegroundColor DarkGray

git push origin main --no-verify
if ($LASTEXITCODE -ne 0) {
  Write-Host "FAIL: git push origin main --no-verify exited with code $LASTEXITCODE" -ForegroundColor Red
  exit $LASTEXITCODE
}

Write-Host "OK: Pushed main to origin (hooks skipped)." -ForegroundColor Green
exit 0
