#!/usr/bin/env pwsh
param()

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
Write-Host "=== All done! ==="
Write-Host "Create a site: $ScriptDir\create-site.ps1 <your-domain>"
