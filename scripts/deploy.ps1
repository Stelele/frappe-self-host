#!/usr/bin/env pwsh
param()

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoDir = Split-Path -Parent $ScriptDir
$EnvFile = "$RepoDir/.env"
$ComposeDir = "$RepoDir/frappe_docker"

if (-not (Test-Path $EnvFile)) {
  Write-Error ".env file not found at $EnvFile. Copy .env.example to .env and fill in your values."
  exit 1
}

Write-Host "Generating compose configuration..."
Set-Location $ComposeDir

docker compose --env-file $EnvFile `
  -f compose.yaml `
  -f overrides/compose.mariadb.yaml `
  -f overrides/compose.redis.yaml `
  -f overrides/compose.proxy.yaml `
  -f overrides/compose.https.yaml `
  config > "$RepoDir/compose.custom.yaml"

Write-Host "Starting all services..."
docker compose --env-file $EnvFile -f "$RepoDir/compose.custom.yaml" up -d

Write-Host "Deploy complete. Run scripts/create-site.ps1 to create your first site."
