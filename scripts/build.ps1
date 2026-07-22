#!/usr/bin/env pwsh
param()

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoDir = Split-Path -Parent $ScriptDir

Set-Location "$RepoDir/frappe_docker"

Write-Host "Building BasaPOS Frappe v16 image with apps from ../apps.json..."

docker build `
  --build-arg=FRAPPE_PATH=https://github.com/frappe/frappe `
  --build-arg=FRAPPE_BRANCH=version-16 `
  --build-arg=CACHE_BUST="$(Get-Date -Format o)" `
  --secret=id=apps_json,src=../apps.json `
  --tag=BasaPOS:16 `
  --file=images/layered/Containerfile

Write-Host "Build complete: BasaPOS:16"
