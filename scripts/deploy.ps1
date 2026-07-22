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

# Allow shorthand DOMAIN=example.com if user doesn't want to write SITES_RULE syntax
$envVars = @{}
Get-Content $EnvFile | ForEach-Object {
  if ($_ -match '^([^#=]+)=(.*)$') {
    $envVars[$matches[1].Trim()] = $matches[2].Trim()
  }
}

if ($envVars.ContainsKey('SITES_RULE')) {
  $env:SITES_RULE = $envVars['SITES_RULE']
} elseif ($envVars.ContainsKey('DOMAIN')) {
  $env:SITES_RULE = "Host(`$($envVars['DOMAIN'])`)"
}

if (-not $env:SITES_RULE) {
  Write-Error "Set SITES_RULE or DOMAIN in .env"
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

Write-Host "Starting all services (restart: unless-stopped is the default)..."
docker compose --env-file $EnvFile -f "$RepoDir/compose.custom.yaml" up -d

Write-Host "Deploy complete."
Write-Host "Next: scripts\create-site.ps1 <your-domain.com>
Or:  scripts\verify.ps1"
