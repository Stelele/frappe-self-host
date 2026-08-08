#!/usr/bin/env pwsh
param(
    [string]$SiteName = "basapos.local"
)

docker context use default 2>$null

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host ""
Write-Host "=== BasaPOS Frappe Deploy: Full Pipeline ==="
Write-Host ""

Write-Host ">>> Step 1: Prerequisites"
& "$ScriptDir\setup.ps1"

Write-Host ""
Write-Host ">>> Step 2: Build Docker image"
& "$ScriptDir\build.ps1"

Write-Host ""
Write-Host ">>> Step 3: Deploy stack"
& "$ScriptDir\deploy.ps1"

Write-Host ""
Write-Host ">>> Step 4: Verify"
& "$ScriptDir\verify.ps1"

Write-Host ""
Write-Host ">>> Step 5: Create site ($SiteName)"
& "$ScriptDir\create-site.ps1" $SiteName

Write-Host ""
Write-Host "=== All done! ==="
