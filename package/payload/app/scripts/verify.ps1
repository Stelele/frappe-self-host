param(
  [string]$Distro = "BasaPOS",
  [string]$Site = "basapos.local"
)
$script:pass = 0; $script:fail = 0
function Pass($m) { $script:pass++; Write-Host "  [PASS] $m" }
function Fail($m) { $script:fail++; Write-Host "  [FAIL] $m" }

Write-Host ""
Write-Host "=== BasaPOS Appliance Verification ==="
Write-Host ""

$oldEap = $ErrorActionPreference
$ErrorActionPreference = "Continue"
& wsl.exe -d $Distro -u root -- /bin/true 2>$null
$wakeExit = $LASTEXITCODE
$ErrorActionPreference = $oldEap

if ($wakeExit -eq 0) { Pass "WSL distro '$Distro' is present" }
else { Fail "WSL distro '$Distro' is missing (re-run the installer)" }

if ($wakeExit -eq 0) {
  Write-Host "--- Services ---"
  $services = @("nginx","basapos-gunicorn","basapos-socketio","basapos-scheduler",
                "basapos-worker-short","basapos-worker-long","mariadb","redis-server")
  $states = @(& wsl.exe -d $Distro -u root -- bash -c "systemctl is-active $($services -join ' ')" 2>$null)
  for ($i = 0; $i -lt $services.Count; $i++) {
    if ($states[$i] -eq "active") { Pass "Service '$($services[$i])' active" }
    else { Fail "Service '$($services[$i])' is '$($states[$i])'" }
  }
}

Write-Host "--- Site ---"
$code = & curl.exe -sk -o NUL -w "%{http_code}" "https://$Site/api/method/ping" 2>$null
if ($code -eq "200") { Pass "Site responds (https://$Site)" }
else { Fail "Site did not respond (HTTP $code)" }

$total = $script:pass + $script:fail
Write-Host "--- Summary ---"
Write-Host "  $($script:pass) / $total checks passed"
if ($script:fail -gt 0) { Write-Host "  $($script:fail) checks failed."; exit 1 }
Write-Host "  All systems operational."
