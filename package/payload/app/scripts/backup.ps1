param(
  [string]$Distro = "BasaPOS",
  [string]$Site = "basapos.local"
)
$ErrorActionPreference = "Stop"

$AppDir = Split-Path -Parent $PSScriptRoot
$Base = Split-Path -Parent $AppDir
$BackupDir = Join-Path $Base "backups"
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null

Write-Host "Waking the appliance..."
& wsl.exe -d $Distro -u root -- /bin/true 2>$null

Write-Host "Backing up site $Site in distro $Distro..."
& wsl.exe -d $Distro -u frappe -- bash -c "cd /home/frappe/bench && bench --site $Site backup --with-files --backup-path /home/frappe/bench/backups/$Timestamp"
if ($LASTEXITCODE -ne 0) { Write-Error "bench backup failed (exit $LASTEXITCODE)"; exit 1 }

Write-Host "Copying backup files to host..."
Copy-Item -Path "\\wsl$\$Distro\home\frappe\bench\backups\$Timestamp" -Destination $BackupDir -Recurse -Force
Write-Host "Backup saved to $BackupDir\$Timestamp"
