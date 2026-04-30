# ============================================================
# push-to-github.ps1
# Clone aro-manager repo, update script, commit & push
# ============================================================

$ErrorActionPreference = "Stop"

$REPO_URL   = "https://github.com/nauthnael/aro-manager.git"
$SCRIPT_SRC = "$PSScriptRoot\aro-manager.sh"
$TEMP_DIR   = "$env:TEMP\aro-manager-push-$(Get-Random)"

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  ARO Manager - Push to GitHub" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Sanity checks
if (!(Test-Path $SCRIPT_SRC)) {
    Write-Host "[ERROR] aro-manager.sh not found at: $SCRIPT_SRC" -ForegroundColor Red
    exit 1
}

if (!(Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "[ERROR] git not found in PATH" -ForegroundColor Red
    exit 1
}

Write-Host "[1/5] Cloning repo to temp folder..." -ForegroundColor Yellow
git clone $REPO_URL $TEMP_DIR
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Clone failed. Check credentials / network." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "[2/5] Copying updated aro-manager.sh..." -ForegroundColor Yellow
Copy-Item -Force $SCRIPT_SRC "$TEMP_DIR\aro-manager.sh"
Write-Host "      Done."

Write-Host ""
Write-Host "[3/5] Staging changes..." -ForegroundColor Yellow
Set-Location $TEMP_DIR
git add aro-manager.sh
git status

Write-Host ""
Write-Host "[4/5] Committing..." -ForegroundColor Yellow
$DATE = Get-Date -Format "yyyy-MM-dd HH:mm"
git commit -m "feat: fix nc bug, add stuck-connecting watchdog and reward persistence v3.3.0 ($DATE)"
if ($LASTEXITCODE -ne 0) {
    Write-Host "[INFO] Nothing to commit (file may already be up to date)." -ForegroundColor Gray
}

Write-Host ""
Write-Host "[5/5] Pushing to GitHub..." -ForegroundColor Yellow
git push origin main
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Push failed. Check credentials." -ForegroundColor Red
    Set-Location $PSScriptRoot
    Remove-Item -Recurse -Force $TEMP_DIR -ErrorAction SilentlyContinue
    exit 1
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "  Push complete!" -ForegroundColor Green
Write-Host "  https://github.com/nauthnael/aro-manager/blob/main/aro-manager.sh" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""

# Cleanup
Set-Location $PSScriptRoot
Remove-Item -Recurse -Force $TEMP_DIR -ErrorAction SilentlyContinue
