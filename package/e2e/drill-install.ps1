<#
  Drill phase 1/3: silent install + boot-wrapper.
  Proves the SHIPPED Setup.exe installs cleanly and the appliance reaches
  RUNNING on a real Windows runner. Runs as its own CI step so failures are
  attributed to INSTALL and later phases are skipped.
  Usage: drill-install.ps1 -SetupExe <path\to\BasaPOS-Setup-x.y.z.exe>
#>
param(
  [Parameter(Mandatory=$true)][string]$SetupExe
)
. (Join-Path $PSScriptRoot 'drill-common.ps1')
trap { Copy-CiLogs; Write-Host "DRILL DIED: $_"; exit 1 }

# ---------------------------------------------------------------- 1 - INSTALL
Add-CiDefenderExclusions
Write-Host '== 1. silent install =='
$p = Invoke-SilentSetup -SetupExe $SetupExe -LogName 'inno-install.log'
Check "setup exit 0 (got $($p.ExitCode))" ($p.ExitCode -eq 0)
# D3: Setup.exe's own poll may give up while setup.ps1 (ewNoWait) is still
# running. Wait for the status file to reach a terminal state before any
# other check reads install state.
$terminal = Wait-SetupTerminal -Minutes 10
Check "setup reached terminal status (got: '$terminal')" ($terminal -ne '')
Check 'installed.txt marker' (Test-Path "$AppDir\installed.txt")
$status = (Get-Content "$AppDir\setup-status.txt" -ErrorAction SilentlyContinue) -join ''
Check "SETUP_COMPLETE (got: $status)" ("$status" -match '^SETUP_COMPLETE$')
Check 'hosts entry' (Select-String -Path $HostsFile -Pattern 'basapos\.local' -Quiet)
$wslcfg = (Get-Content "$env:USERPROFILE\.wslconfig" -Raw -ErrorAction SilentlyContinue) -join ''
Check '.wslconfig idle timeouts disabled' (($wslcfg -match 'vmIdleTimeout=-1') -and ($wslcfg -match 'instanceIdleTimeout=-1'))
$taskQ = (schtasks /query /tn BasaPOS-Appliance 2>&1) -join ''
Check 'autostart task registered' ("$taskQ" -match 'BasaPOS-Appliance')
$creds = Get-Content "$AppDir\config\credentials.txt" -ErrorAction SilentlyContinue
Check 'credentials generated (16-char pw)' (($creds -join "`n") -match 'password=\S{16}')
$code = & $ping
Check "site responds 200 from host (got $code)" ("$code" -eq '200')

# D18: prove WSL actually runs systemd as PID 1. Without it no services
# start, and every downstream check chases symptoms (WIN-004's CI twin).
# Bounded: a wedged wsl.exe must not hang the drill (D2).
$pid1 = (Invoke-BoundedWsl -BashCommand "ps -p 1 -o comm= 2>/dev/null" -Seconds 60).Trim()
Check "WSL systemd is PID 1 (got: $pid1)" ($pid1 -eq 'systemd')

# TLS regression armour: NO -k flag -> curl.exe validates via schannel
# against the Windows trust store. Fails if the installer forgot to import
# the appliance's self-signed cert (Cert:\LocalMachine\Root).
# --ssl-no-revoke: schannel fail-closes on missing revocation info
# (CRYPT_E_NO_REVOCATION_CHECK) for self-signed certs that carry no CRL/OCSP
# endpoints -- without this the check can NEVER pass even with correct trust.
# Chain + hostname validation stay fully enforced.
$codeTrusted = & curl.exe -s --ssl-no-revoke -m 20 -o NUL -w "%{http_code}" 'https://basapos.local/api/method/ping' 2>$null
Check "TLS trusted by Windows store, no -k (got $codeTrusted)" ("$codeTrusted" -eq '200')

# Unstyled-page regression armour: the login page's first stylesheet must
# load. Fails when nginx/www-data cannot traverse /home/frappe (mode 0750)
# and every /assets/* request 404s.
$html = (& curl.exe -sk -m 20 'https://basapos.local/login' 2>$null) -join "`n"
$m = [regex]::Match($html, 'href="([^"]+?\.css[^"]*)"')
if ($m.Success) {
  $asset = $m.Groups[1].Value
  if ($asset.StartsWith('/')) { $asset = "https://basapos.local$asset" }
  $assetCode = & curl.exe -sk -m 20 -o NUL -w "%{http_code}" "$asset" 2>$null
  Check "login stylesheet loads: $asset (got $assetCode)" ("$assetCode" -eq '200')
} else {
  Check 'login page references a stylesheet' $false
}

# ------------------------------------------------------ 2 - AUTOSTART WRAPPER
Write-Host '== 2. autostart wrapper reaches RUNNING =='
# Run boot-wrapper directly (scheduled task context broken in CI)
# Don't terminate WSL — it corrupts the distro on CI runners
Remove-Item "$AppDir\appliance-status.txt" -Force -ErrorAction SilentlyContinue
$wrapper = Join-Path $AppDir "payload\install\boot-wrapper.ps1"
Write-Host "Running boot-wrapper: $wrapper"
# D2: bounded - the wrapper's wsl.exe wake calls have no deadline of their
# own and are documented to hang indefinitely on CI runners.
$wrapperOut = Join-Path $env:RUNNER_TEMP 'boot-wrapper-out.log'
$wp = Start-Process -FilePath 'powershell.exe' `
  -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-Command',"& '$wrapper'") `
  -RedirectStandardOutput $wrapperOut -RedirectStandardError (Join-Path $env:RUNNER_TEMP 'boot-wrapper-err.log') -PassThru
if (-not $wp.WaitForExit(600000)) {
  Write-Host '  [TIMEOUT] boot-wrapper did not exit in 10 min - killing'
  $wp | Stop-Process -Force -ErrorAction SilentlyContinue
  $null = $wp.WaitForExit()
}
Get-Content $wrapperOut -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  wrapper: $_" }
$st = (Get-Content "$AppDir\appliance-status.txt" -ErrorAction SilentlyContinue) -join ''
Write-Host "appliance-status.txt = '$st'"
Check 'boot-wrapper stamps RUNNING' ("$st" -eq 'RUNNING')
if ("$st" -ne 'RUNNING') {
  Write-Host '--- appliance-status.txt ---'
  $apSt = Get-Content "$AppDir\appliance-status.txt" -ErrorAction SilentlyContinue
  if ($apSt) { $apSt | ForEach-Object { Write-Host "  $_" } } else { Write-Host '  (empty or missing)' }
  Write-Host '--- setup-debug.txt (post boot-wrapper) ---'
  if (Test-Path "$AppDir\setup-debug.txt") {
    $dbgRaw2 = [System.IO.File]::ReadAllBytes("$AppDir\setup-debug.txt")
    Write-Host "  $($dbgRaw2.Length) bytes"
    [System.IO.File]::ReadAllText("$AppDir\setup-debug.txt") -split "`n" | Select-Object -Last 30 | ForEach-Object { Write-Host "  $_" }
  } else { Write-Host '  NOT FOUND' }
  Write-Host '--- autostart.log ---'
  $al2 = Get-Content "$AppDir\logs\autostart.log" -ErrorAction SilentlyContinue | Select-Object -Last 20
  if ($al2) { $al2 | ForEach-Object { Write-Host "  $_" } } else { Write-Host '  (empty or missing)' }
  Write-Host '--- journal errors ---'
  # D2: diagnostics bounded too - a hang inside the failure branch must not
  # eat the remaining drill budget.
  Invoke-BoundedWsl -BashCommand "journalctl -u basapos-gunicorn --no-pager -n 20 --since '15 min ago' 2>/dev/null" -Seconds 30 | ForEach-Object { Write-Host "  $_" }
}

Exit-Drill 'INSTALL'
