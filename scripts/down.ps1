#!/usr/bin/env pwsh
param()

docker context use default 2>$null

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoDir = Split-Path -Parent $ScriptDir
$ComposeFile = "$RepoDir/compose.custom.yaml"

if (-not (Test-Path $ComposeFile)) {
  Write-Host "No compose.custom.yaml found — nothing to tear down."
  exit 0
}

Write-Host "Stopping and removing all containers, volumes, and networks..."
docker compose -f $ComposeFile down -v

Write-Host "Done."
