<#
  Installer drill: proves the SHIPPED Setup.exe end-to-end on a real Windows runner.
  1. Silent install      -> markers, hosts, .wslconfig, autostart task, creds, site 200
  2. Autostart wrapper   -> schtasks /run -> appliance-status.txt reaches RUNNING
  3. Upgrade drill       -> re-run Setup: backup taken, creds preserved, site 200
  4. Silent uninstall    -> task/hosts/VHD gone
  Usage: install-drill.ps1 -SetupExe <path\to\BasaPOS-Setup-x.y.z.exe>
#>
param(
  [Parameter(Mandatory=$true)][string]$SetupExe
)
$ErrorActionPreference = 'Stop'
$script:fail = 0
function Check([string]$name, [bool]$ok) {
  if ($ok) { Write-Host "  [PASS] $name" } else { Write-Host "  [FAIL] $name"; $script:fail++ }
}
$AppDir = Join-Path $env:LOCALAPPDATA 'Programs\BasaPOS'
$HostsFile = "$env:SystemRoot\System32\drivers\etc\hosts"
$ping = { (& curl.exe -sk -o NUL -w '%{http_code}' 'https://basapos.local/api/method/ping' 2>$null) }

function Invoke-SilentSetup([string]$logName) {
  $p = Start-Process -FilePath $SetupExe `
    -ArgumentList '/VERYSILENT','/NORESTART','/SUPPRESSMSGBOXES','/FORCECLOSEAPPLICATIONS',"/LOG=$env:RUNNER_TEMP\$logName" `
    -PassThru
  # 15 min timeout
  $killed = -not $p.WaitForExit(900000)
  if ($killed) {
    Write-Host "  [TIMEOUT] setup.exe did not exit in 15 min - killing"
    $p | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep 2
  }
  # Dump diagnostic context regardless of outcome
  Write-Host '--- setup-status.txt ---'
  Get-Content "$AppDir\setup-status.txt" -ErrorAction SilentlyContinue | Select-Object -Last 5
  Write-Host '--- setup.log (tail) ---'
  Get-Content "$AppDir\logs\setup.log" -ErrorAction SilentlyContinue | Select-Object -Last 50
  Write-Host '--- restore.log (tail) ---'
  Get-Content "$AppDir\logs\restore.log" -ErrorAction SilentlyContinue | Select-Object -Last 50
  Write-Host '--- setup-diag.txt ---'
  Get-Content "$AppDir\setup-diag.txt" -ErrorAction SilentlyContinue
  Write-Host '--- setup-debug.txt ---'
  if (Test-Path "$AppDir\setup-debug.txt") {
    $dbgRaw = [System.IO.File]::ReadAllBytes("$AppDir\setup-debug.txt")
    Write-Host "  $($dbgRaw.Length) bytes"
    Write-Host "  $([System.IO.File]::ReadAllText("$AppDir\setup-debug.txt"))"
  } else { Write-Host '  NOT FOUND' }
  Write-Host '--- inno log (tail) ---'
  Get-Content "$env:RUNNER_TEMP\$logName" -ErrorAction SilentlyContinue | Select-Object -Last 20
  return $p
}

# ---------------------------------------------------------------- 1 - INSTALL
Write-Host '== 1. silent install =='
$p = Invoke-SilentSetup 'inno-install.log'
Check "setup exit 0 (got $($p.ExitCode))" ($p.ExitCode -eq 0)
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
$pwBefore = ($creds | Select-String '^password=').Line

# ------------------------------------------------------ 2 - AUTOSTART WRAPPER
Write-Host '== 2. autostart wrapper reaches RUNNING =='
& wsl.exe --terminate BasaPOS 2>$null
Remove-Item "$AppDir\appliance-status.txt" -Force -ErrorAction SilentlyContinue
schtasks /run /tn BasaPOS-Appliance | Out-Null
$deadline = (Get-Date).AddMinutes(8)
$running = $false
while ((Get-Date) -lt $deadline) {
  $st = (Get-Content "$AppDir\appliance-status.txt" -ErrorAction SilentlyContinue) -join ''
  if ("$st" -eq 'RUNNING') { $running = $true; break }
  Start-Sleep -Seconds 10
}
Check 'boot-wrapper stamps RUNNING' $running

# -------------------------------------------------------- 3 - UPGRADE DRILL
Write-Host '== 3. upgrade drill (re-run setup) =='
# Kill anything that could stall Inno's CloseApplications check
$oldEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& taskkill /F /IM wsl.exe /T 2>$null
Get-Process -Name 'wsl','BasaPOS','conhost' -ErrorAction SilentlyContinue |
  Stop-Process -Force -ErrorAction SilentlyContinue
$ErrorActionPreference = $oldEap
Start-Sleep -Seconds 3
$p2 = Invoke-SilentSetup 'inno-upgrade.log'
Check "second setup exit 0 (got $($p2.ExitCode))" ($p2.ExitCode -eq 0)
$backupRoot = "$AppDir\backups\pre-upgrade"
Check 'pre-upgrade backup taken' ((Test-Path $backupRoot) -and
  ((Get-ChildItem $backupRoot -Directory -ErrorAction SilentlyContinue).Count -ge 1))
$credsAfter = Get-Content "$AppDir\config\credentials.txt"
$pwAfter = ($credsAfter | Select-String '^password=').Line
Check 'credentials preserved across upgrade' ("$pwAfter" -eq "$pwBefore")
$status2 = (Get-Content "$AppDir\setup-status.txt") -join ''
Check 'post-upgrade SETUP_COMPLETE' ("$status2" -match '^SETUP_COMPLETE')
# After upgrade, distro is freshly imported - boot-wrapper must start bench services
Remove-Item "$AppDir\appliance-status.txt" -Force -ErrorAction SilentlyContinue
schtasks /run /tn BasaPOS-Appliance 2>$null | Out-Null
$siteOk = $false
$siteDeadline = (Get-Date).AddMinutes(8)
while ((Get-Date) -lt $siteDeadline) {
  $st = (Get-Content "$AppDir\appliance-status.txt" -ErrorAction SilentlyContinue) -join ''
  if ("$st" -eq 'RUNNING') {
    $code2 = & $ping
    if ("$code2" -eq '200') { $siteOk = $true; break }
  }
  Start-Sleep -Seconds 10
}
Check "site responds 200 post-upgrade (got $code2)" $siteOk

# ------------------------------------------------------------ 4 - UNINSTALL
Write-Host '== 4. silent uninstall =='
$oldEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& taskkill /F /IM wsl.exe /T 2>$null
$ErrorActionPreference = $oldEap
Start-Sleep -Seconds 5
$unins = Get-ChildItem $AppDir -Filter 'unins*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
Check 'uninstaller present' ($null -ne $unins)
if ($unins) {
  $p3 = Start-Process -FilePath $unins.FullName -ArgumentList '/SILENT','/SUPPRESSMSGBOXES' -Wait -PassThru
  Start-Sleep -Seconds 5
}
$taskAfter = $null
$oldEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$taskAfter = (schtasks /query /tn BasaPOS-Appliance 2>&1) -join ''
$ErrorActionPreference = $oldEap
Check 'autostart task removed' (-not ("$taskAfter" -match 'BasaPOS-Appliance'))
Check 'hosts entry removed' (-not (Select-String -Path $HostsFile -Pattern 'basapos\.local' -Quiet))
Check 'VHD removed' (-not (Test-Path "$AppDir\data\distro\ext4.vhdx"))

Write-Host ''
if ($script:fail -gt 0) {
  $msg = 'INSTALL DRILL FAILED - ' + $script:fail + ' checks'
  Write-Host $msg
  exit 1
}
Write-Host 'INSTALL DRILL PASSED'
