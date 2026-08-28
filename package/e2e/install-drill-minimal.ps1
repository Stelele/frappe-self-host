param(
  [Parameter(Mandatory=$true)][string]$SetupExe
)
# Minimal drill: install + boot-wrapper only (skip upgrade/uninstall)
$ErrorActionPreference = 'Stop'
$AppDir = Join-Path $env:LOCALAPPDATA 'Programs\BasaPOS'
$ping = { curl.exe -sk -o /dev/null -w '%{http_code}' https://basapos.local/api/method/ping 2>$null }
$fail = 0

function Check([string]$name, [bool]$ok) {
  if ($ok) { Write-Host "  [PASS] $name" } else { Write-Host "  [FAIL] $name"; $script:fail++ }
}
function Matches([string]$text, [string]$pat) { return [bool]($text -match $pat) }

# ---- Step 1: Fresh install ----
Write-Host '== 1. silent install =='
$p = Start-Process -FilePath $SetupExe `
  -ArgumentList '/VERYSILENT','/NORESTART','/SUPPRESSMSGBOXES','/FORCECLOSEAPPLICATIONS',"/LOG=$env:RUNNER_TEMP\inno-install.log" `
  -PassThru
$killed = -not $p.WaitForExit(900000)
if ($killed) {
  Write-Host "  [TIMEOUT] setup.exe did not exit in 15 min - killing"
  $p | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep 2
}

# Dump all logs
Write-Host '--- setup-status.txt ---'
$s = Get-Content "$AppDir\setup-status.txt" -ErrorAction SilentlyContinue
if ($s) { $s | ForEach-Object { Write-Host "  $_" } } else { Write-Host '  (empty or missing)' }
Write-Host '--- setup-debug.txt ---'
if (Test-Path "$AppDir\setup-debug.txt") {
  $dbgRaw = [System.IO.File]::ReadAllBytes("$AppDir\setup-debug.txt")
  Write-Host "  $($dbgRaw.Length) bytes"
  Write-Host "  $([System.IO.File]::ReadAllText("$AppDir\setup-debug.txt"))"
} else { Write-Host '  NOT FOUND' }
Write-Host '--- setup.log (tail) ---'
$lg = Get-Content "$AppDir\logs\setup.log" -ErrorAction SilentlyContinue | Select-Object -Last 50
if ($lg) { $lg | ForEach-Object { Write-Host "  $_" } } else { Write-Host '  (empty or missing)' }
Write-Host '--- restore.log (tail) ---'
$rl = Get-Content "$AppDir\logs\restore.log" -ErrorAction SilentlyContinue | Select-Object -Last 50
if ($rl) { $rl | ForEach-Object { Write-Host "  $_" } } else { Write-Host '  (empty or missing)' }
Write-Host '--- restore-steps.log ---'
$rs = Get-Content "$AppDir\logs\restore-steps.log" -ErrorAction SilentlyContinue | Select-Object -Last 50
if ($rs) { $rs | ForEach-Object { Write-Host "  $_" } } else { Write-Host '  (empty or missing)' }
Write-Host '--- autostart.log ---'
$al = Get-Content "$AppDir\logs\autostart.log" -ErrorAction SilentlyContinue | Select-Object -Last 30
if ($al) { $al | ForEach-Object { Write-Host "  $_" } } else { Write-Host '  (empty or missing)' }
Write-Host '--- inno log (tail) ---'
Get-Content "$env:RUNNER_TEMP\inno-install.log" -ErrorAction SilentlyContinue | Select-Object -Last 20 | ForEach-Object { Write-Host "  $_" }

Check "setup exit 0 (got $($p.ExitCode))" ($p.ExitCode -eq 0)
Check 'installed.txt marker' (Test-Path "$AppDir\installed.txt")
$status1 = (Get-Content "$AppDir\setup-status.txt" -ErrorAction SilentlyContinue) -join ''
Check "SETUP_COMPLETE (got: $status1)" ([bool]("$status1" -match '^SETUP_COMPLETE'))
Check 'hosts entry' ([bool]((Get-Content "$env:SystemRoot\System32\drivers\etc\hosts" -ErrorAction SilentlyContinue) -match 'basapos\.local'))
$wslcfg = Get-Content "$env:USERPROFILE\.wslconfig" -ErrorAction SilentlyContinue | Out-String
Check '.wslconfig idle timeouts disabled' ([bool](($wslcfg -match 'vmIdleTimeout=-1') -and ($wslcfg -match 'instanceIdleTimeout=-1')))
$taskQ = (schtasks /query /tn BasaPOS-Appliance 2>&1) -join ''
Check 'autostart task registered' ([bool]("$taskQ" -match 'BasaPOS-Appliance'))
$creds = Get-Content "$AppDir\config\credentials.txt" -ErrorAction SilentlyContinue
Check 'credentials generated (16-char pw)' ([bool](($creds -join "`n") -match 'password=\S{16}'))
$code = & $ping
Check "site responds 200 from host (got $code)" ([bool]("$code" -eq '200'))

# TLS regression armour: NO -k flag -> curl.exe validates via schannel
# against the Windows trust store (installer must import the appliance cert).
$codeTrusted = & curl.exe -s -o NUL -w "%{http_code}" 'https://basapos.local/api/method/ping' 2>$null
Check "TLS trusted by Windows store, no -k (got $codeTrusted)" ([bool]("$codeTrusted" -eq '200'))

# Unstyled-page regression armour: login page stylesheet must load with 200
# (fails when /assets/* 404s due to /home/frappe traversal perms).
$html = (& curl.exe -sk 'https://basapos.local/login' 2>$null) -join "`n"
$m = [regex]::Match($html, 'href="([^"]+?\.css[^"]*)"')
if ($m.Success) {
  $asset = $m.Groups[1].Value
  if ($asset.StartsWith('/')) { $asset = "https://basapos.local$asset" }
  $assetCode = & curl.exe -sk -o NUL -w "%{http_code}" "$asset" 2>$null
  Check "login stylesheet loads (got $assetCode)" ([bool]("$assetCode" -eq '200'))
} else {
  Check 'login page references a stylesheet' $false
}

# ---- Step 2: Boot-wrapper ----
Write-Host '== 2. autostart wrapper reaches RUNNING =='
# Run boot-wrapper directly (scheduled task context broken in CI S4U/Interactive).
# Don't terminate WSL — wsl --terminate leaves the distro in a corrupted state
# on CI runners where wsl -d then hangs indefinitely.  In production the task
# runs at startup (WSL simply hasn't started yet), so the realistic CI test is:
# distro already running → boot-wrapper confirms site health → stamps RUNNING.
Remove-Item "$AppDir\appliance-status.txt" -Force -ErrorAction SilentlyContinue
$wrapper = Join-Path $AppDir "payload\install\boot-wrapper.ps1"
Write-Host "Running boot-wrapper: $wrapper"
Write-Host "boot-wrapper output follows:"
& powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& '$wrapper'"
$wrapperExit = $LASTEXITCODE
Write-Host "boot-wrapper exit code: $wrapperExit"
$st = (Get-Content "$AppDir\appliance-status.txt" -ErrorAction SilentlyContinue) -join ''
Write-Host "appliance-status.txt = '$st'"
Check 'boot-wrapper stamps RUNNING' ("$st" -eq 'RUNNING')

# Diagnostic dumps on failure
Write-Host '--- appliance-status.txt ---'
$apSt = Get-Content "$AppDir\appliance-status.txt" -ErrorAction SilentlyContinue
if ($apSt) { $apSt | ForEach-Object { Write-Host "  $_" } } else { Write-Host '  (empty or missing)' }
Write-Host '--- setup-debug.txt (post boot-wrapper) ---'
if (Test-Path "$AppDir\setup-debug.txt") {
  $dbgRaw2 = [System.IO.File]::ReadAllBytes("$AppDir\setup-debug.txt")
  Write-Host "  $($dbgRaw2.Length) bytes"
  [System.IO.File]::ReadAllText("$AppDir\setup-debug.txt") -split "`n" | Select-Object -Last 40 | ForEach-Object { Write-Host "  $_" }
} else { Write-Host '  NOT FOUND' }
Write-Host '--- autostart.log ---'
$al2 = Get-Content "$AppDir\logs\autostart.log" -ErrorAction SilentlyContinue | Select-Object -Last 20
if ($al2) { $al2 | ForEach-Object { Write-Host "  $_" } } else { Write-Host '  (empty or missing)' }
Write-Host '--- journal basapos-gunicorn (last 20) ---'
& wsl.exe -d BasaPOS -u root -- bash -c "journalctl -u basapos-gunicorn --no-pager -n 20 --since '15 min ago' 2>/dev/null" 2>$null | ForEach-Object { Write-Host "  $_" }
Write-Host '--- journal basapos-scheduler (last 10) ---'
& wsl.exe -d BasaPOS -u root -- bash -c "journalctl -u basapos-scheduler --no-pager -n 10 --since '15 min ago' 2>/dev/null" 2>$null | ForEach-Object { Write-Host "  $_" }
Write-Host '--- systemctl list-units (failed) ---'
& wsl.exe -d BasaPOS -u root -- bash -c "systemctl --failed --no-pager 2>/dev/null" 2>$null | ForEach-Object { Write-Host "  $_" }
Write-Host '--- service status ---'
foreach ($svc in 'basapos-gunicorn basapos-socketio basapos-worker-short basapos-worker-long basapos-scheduler nginx mariadb redis-server'.Split(' ')) {
  $st = & wsl.exe -d BasaPOS -u root -- bash -c "systemctl is-active $svc 2>/dev/null" 2>$null
  Write-Host "  ${svc}: $("$st".Trim())"
}
Write-Host '--- site ping after boot-wrapper ---'
$code2 = & $ping
Write-Host "  http_code: $code2"

Write-Host ''
if ($fail -gt 0) { Write-Host "DRILL FAILED ($fail checks)"; exit 1 }
Write-Host 'DRILL PASSED'
