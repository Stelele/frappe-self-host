#!/usr/bin/env pwsh
param()

docker context use default 2>$null

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoDir = Split-Path -Parent $ScriptDir
$BackupDir = "$RepoDir/backups"
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null

Write-Host "Backing up all sites..."
docker compose -f "$RepoDir/compose.custom.yaml" exec backend `
  bench --site all backup --with-files --backup-path "/home/frappe/frappe-bench/backups/$Timestamp"

Write-Host "Copying backup files to host..."
docker compose -f "$RepoDir/compose.custom.yaml" cp `
  "backend:/home/frappe/frappe-bench/backups/$Timestamp" "$BackupDir/$Timestamp"

Write-Host "Backup saved to $BackupDir/$Timestamp"
