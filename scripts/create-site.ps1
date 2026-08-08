#!/usr/bin/env pwsh
param(
  [Parameter(Mandatory=$true, Position=0)]
  [string]$SiteName
)

docker context use default 2>$null

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoDir = Split-Path -Parent $ScriptDir
$EnvFile = "$RepoDir/.env"

if (-not (Test-Path $EnvFile)) {
  Write-Error ".env file not found at $EnvFile"
  exit 1
}

$EnvVars = @{}
Get-Content $EnvFile | ForEach-Object {
  if ($_ -match '^([^#=]+)=(.*)$') {
    $EnvVars[$matches[1]] = $matches[2]
  }
}

# Read installed apps from the image's apps.txt (excludes frappe, includes erpnext and custom apps)
$appsRaw = docker compose -f "$RepoDir/compose.custom.yaml" exec backend `
  cat /home/frappe/frappe-bench/sites/apps.txt 2>$null
if ($LASTEXITCODE -ne 0 -or -not $appsRaw) {
  Write-Error "Could not read apps.txt from backend container"
  exit 1
}
$installApps = ($appsRaw -split '\r?\n' | Where-Object { $_ -and $_ -ne 'frappe' })

$adminPwd = if ($EnvVars['ADMIN_PASSWORD']) { $EnvVars['ADMIN_PASSWORD'] } else { "admin" }

Write-Host "Creating site $SiteName with apps: $($installApps -join ' ')..."

# Build repeated --install-app flags
$installFlags = ($installApps | ForEach-Object { "--install-app $_" }) -join ' '

docker compose -f "$RepoDir/compose.custom.yaml" exec backend `
  bench new-site `
    --mariadb-user-host-login-scope=% `
    --db-root-password $EnvVars['DB_PASSWORD'] `
    $installFlags `
    --admin-password $adminPwd `
    $SiteName

Write-Host ""
Write-Host "Running patches and migrations..."
docker compose -f "$RepoDir/compose.custom.yaml" exec backend `
  bench --site $SiteName migrate

Write-Host ""
Write-Host "Building frontend assets..."
docker compose -f "$RepoDir/compose.custom.yaml" exec backend `
  bench --site $SiteName build

Write-Host ""
Write-Host "Syncing assets to frontend..."
docker compose -f "$RepoDir/compose.custom.yaml" exec backend `
  tar -chf - --exclude='node_modules' -C /home/frappe/frappe-bench assets `
  | docker compose -f "$RepoDir/compose.custom.yaml" exec -T frontend `
  tar -xf - -C /home/frappe/frappe-bench
