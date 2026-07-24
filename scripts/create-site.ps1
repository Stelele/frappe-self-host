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

# Extract all app names from apps.json (excluding frappe itself)
$installApps = @("erpnext")
$appsJson = "$RepoDir/apps.json"
if (Test-Path $appsJson) {
  $apps = Get-Content $appsJson | ConvertFrom-Json
  $customApps = $apps | ForEach-Object {
    $name = $_.url.Split('/')[-1]
    if ($name -notin @('frappe', 'erpnext')) { $name }
  }
  $installApps += $customApps
}

$adminPwd = if ($EnvVars['ADMIN_PASSWORD']) { $EnvVars['ADMIN_PASSWORD'] } else { "admin" }

Write-Host "Creating site $SiteName with apps: $($installApps -join ' ')..."

docker compose -f "$RepoDir/compose.custom.yaml" exec backend `
  bench new-site `
    --mariadb-user-host-login-scope=% `
    --db-root-password $EnvVars['DB_PASSWORD'] `
    --install-app $($installApps -join ' ') `
    --admin-password $adminPwd `
    $SiteName
