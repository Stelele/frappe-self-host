#!/usr/bin/env pwsh
param()

docker context use default 2>$null

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoDir = Split-Path -Parent $ScriptDir
$EnvFile = "$RepoDir/.env"
$ComposeDir = "$RepoDir/frappe_docker"

if (-not (Test-Path $EnvFile)) {
  Write-Error ".env file not found at $EnvFile. Copy .env.example to .env and fill in your values."
  exit 1
}

# Ensure PULL_POLICY is set
$envContent = Get-Content $EnvFile -Raw
if ($envContent -notmatch '^PULL_POLICY=') {
  Add-Content $EnvFile "`nPULL_POLICY=missing"
}

# Read vars
$envVars = @{}
Get-Content $EnvFile | ForEach-Object {
  if ($_ -match '^([^#=]+)=(.*)$') {
    $envVars[$matches[1].Trim()] = $matches[2].Trim()
  }
}

# Determine offline mode
$offline = $envVars['OFFLINE'] -eq 'true'

# Derive SITES_RULE
if ($envVars.ContainsKey('SITES_RULE')) {
  $env:SITES_RULE = $envVars['SITES_RULE']
} elseif ($envVars.ContainsKey('DOMAIN')) {
  $env:SITES_RULE = "Host(`$($envVars['DOMAIN'])`)"
}

if (-not $env:SITES_RULE) {
  Write-Error "Set DOMAIN or SITES_RULE in .env"
  exit 1
}

Write-Host "Generating compose configuration..."
Set-Location $ComposeDir

$composeFiles = @(
  "-f", "compose.yaml",
  "-f", "overrides/compose.mariadb.yaml",
  "-f", "overrides/compose.redis.yaml",
  "-f", "overrides/compose.proxy.yaml"
)

if ($offline) {
  Write-Host "Mode: OFFLINE — self-signed HTTPS"
  $domain = $envVars['DOMAIN']
  if ($domain -and $domain -match '\.local$') {
    $hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
    $hostsContent = Get-Content $hostsPath -ErrorAction SilentlyContinue
    if (-not ($hostsContent -match [regex]::Escape($domain))) {
      Write-Host "Adding $domain to Windows hosts file (requires admin)..."
      try {
        Add-Content -Path $hostsPath -Value "127.0.0.1 $domain" -ErrorAction Stop
        Write-Host "  Added $domain to hosts file"
      } catch {
        Write-Host "  Could not add to hosts file — run as Administrator:"
        Write-Host "  Add-Content -Path `"$hostsPath`" -Value `"127.0.0.1 $domain`""
      }
    }
  }
  & "$ScriptDir\setup-ssl.ps1"
  $composeFiles += @("-f", "..\overrides\compose.selfsigned.yaml")
} else {
  Write-Host "Mode: ONLINE — HTTPS with Let's Encrypt"
  $composeFiles += @("-f", "overrides/compose.https.yaml")
}

docker compose --env-file $EnvFile $composeFiles config > "$RepoDir/compose.custom.yaml"

Write-Host "Starting all services..."
docker compose --env-file $EnvFile -f "$RepoDir/compose.custom.yaml" up -d

# On first deploy, DB needs time to init before configurator can run.
Write-Host "Waiting for DB health check, then ensuring all services start..."
Start-Sleep -Seconds 15
docker compose -f "$RepoDir/compose.custom.yaml" start configurator 2>$null
Start-Sleep -Seconds 10
docker compose -f "$RepoDir/compose.custom.yaml" start backend frontend websocket queue-short queue-long scheduler 2>$null

Write-Host "Deploy complete."
Write-Host "Next: scripts\create-site.ps1 <your-domain>
Or:  scripts\verify.ps1"
