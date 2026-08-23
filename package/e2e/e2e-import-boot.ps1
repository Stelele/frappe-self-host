<#
  CI E2E: imports the appliance rootfs into WSL2 on a windows-latest runner,
  boots it, and asserts services + site health. Proves the M1 artifact boots
  for real (first runtime validation of systemd units, firstboot TLS, etc.).
  Usage: e2e-import-boot.ps1 -RootfsTar <path>
#>
param(
  [Parameter(Mandatory=$true)][string]$RootfsTar
)
$ErrorActionPreference = 'Stop'
$Distro = 'BasaPOS'
$fail = 0

function Check([string]$name, [bool]$ok) {
  if ($ok) { Write-Host "  [PASS] $name" } else { Write-Host "  [FAIL] $name"; $script:fail++ }
}

Write-Host '== enable WSL =='
wsl --install --no-distribution | Out-Null
$env:WSL_UTF8 = '1'

Write-Host '== WSL diagnostics =='
wsl --version
wsl --status
# Ensure modern store WSL (systemd support) and WSL2 default for imports.
wsl --update
wsl --set-default-version 2

Write-Host '== import rootfs =='
$distroDir = Join-Path $env:RUNNER_TEMP 'basapos-distro'
New-Item -ItemType Directory -Force -Path $distroDir | Out-Null
wsl --import $Distro $distroDir $RootfsTar
Check 'wsl --import exit 0' ($LASTEXITCODE -eq 0)

Write-Host '== boot (systemd starts all units) =='
wsl -d $Distro -u root --exec /bin/true
Check 'distro boots' ($LASTEXITCODE -eq 0)

# wsl.conf [boot] systemd=true is parsed at distro start; terminate + restart
# once so a pre-update WSL session can't shadow it.
wsl --terminate $Distro
Start-Sleep -Seconds 5
wsl -d $Distro -u root --exec /bin/true

Write-Host '== assert systemd is PID 1 =='
$pid1 = wsl -d $Distro -u root -- bash -c "ps -p 1 -o comm="
Write-Host ("PID1: " + "$pid1".Trim())
Check 'systemd is init' ("$pid1".Trim() -eq 'systemd')

Write-Host '== wait for services (max 6 min) =='
$services = 'nginx basapos-gunicorn basapos-socketio basapos-scheduler basapos-worker-short basapos-worker-long mariadb redis-server'
$deadline = (Get-Date).AddMinutes(6)
$allActive = $false
while ((Get-Date) -lt $deadline) {
  $out = wsl -d $Distro -u root -- bash -c "systemctl is-active $services"
  $states = @($out | Where-Object { $_ })
  if (($states.Count -eq 8) -and (-not ($states -ne 'active'))) { $allActive = $true; break }
  Start-Sleep -Seconds 10
}
Check 'all 8 services active' $allActive

Write-Host '== site health (inside distro) =='
$out = wsl -d $Distro -u root -- bash -c "curl -sk -o /dev/null -w '%{http_code}' https://basapos.local/api/method/ping"
Check 'site responds 200' ("$out".Trim() -eq '200')

Write-Host '== firstboot TLS generated =='
$out = wsl -d $Distro -u root -- bash -c "openssl x509 -in /etc/nginx/ssl/basapos.crt -noout -subject"
Check ('cert subject CN=basapos.local -> ' + "$out".Trim()) ("$out" -match 'subject=.*basapos\.local')

Write-Host ''
if ($script:fail -gt 0) { Write-Host "E2E FAILED ($($script:fail) checks)"; exit 1 }
Write-Host 'E2E PASSED'
