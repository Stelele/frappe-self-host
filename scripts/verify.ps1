#!/usr/bin/env pwsh
param()

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoDir = Split-Path -Parent $ScriptDir
$ComposeFile = "$RepoDir/compose.custom.yaml"
$pass = 0
$fail = 0

function Pass($msg) { $script:pass++; Write-Host "  [PASS] $msg" }
function Fail($msg) { $script:fail++; Write-Host "  [FAIL] $msg" }

Write-Host ""
Write-Host "=== Frappe Deploy: Verification ==="
Write-Host ""

# 1. Docker
Write-Host "--- Docker ---"
try {
  $version = docker --version
  Pass "Docker is running ($version)"
} catch {
  Fail "Docker is not running"
}

try {
  docker buildx version | Out-Null
  Pass "BuildKit available"
} catch {
  Fail "BuildKit not available"
}

# 2. Image
Write-Host "--- Image ---"
try {
  $image = docker image inspect basapos:16
  Pass "basapos image basapos:16 exists"
} catch {
  Fail "basapos image basapos:16 not found (run scripts/build.ps1)"
}

# 3. Compose file
Write-Host "--- Configuration ---"
if (Test-Path $ComposeFile) {
  Pass "compose.custom.yaml exists"
} else {
  Fail "compose.custom.yaml not found (run scripts/deploy.ps1)"
}

# 4. Containers
Write-Host "--- Services ---"
if (-not (Test-Path $ComposeFile)) {
  Fail "Cannot check services without compose.custom.yaml"
} else {
  $services = @("backend", "frontend", "websocket", "queue-short", "queue-long", "scheduler", "db")

  $running = docker compose -f $ComposeFile ps --status running --format '{{.Name}}'

  foreach ($svc in $services) {
    if ($running -match $svc) {
      Pass "Container '$svc' is running"
    } else {
      Fail "Container '$svc' is not running"
    }
  }
}

# 5. Summary
Write-Host "--- Summary ---"
$total = $pass + $fail
Write-Host "  $pass / $total checks passed"
if ($fail -gt 0) {
  Write-Host "  $fail checks failed — review issues above."
  exit 1
}
Write-Host "  All systems operational."
