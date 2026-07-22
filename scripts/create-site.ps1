#!/usr/bin/env pwsh
param(
  [Parameter(Mandatory=$true, Position=0)]
  [string]$SiteName
)

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

Write-Host "Creating site $SiteName..."

docker compose -f "$RepoDir/compose.custom.yaml" exec backend `
  bench new-site `
    --mariadb-user-host-login-scope=% `
    --db-root-password $EnvVars['DB_PASSWORD'] `
    --install-app erpnext `
    --admin-password $EnvVars['ADMIN_PASSWORD'] `
    $SiteName
