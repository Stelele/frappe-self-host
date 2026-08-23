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
  Start-Process -FilePath $SetupExe `
    -ArgumentList '/VERYSILENT','/NORESTART','/SUPPRESSMSGBOXES',"/LOG=$env:RUNNER_TEMP\$logName" `
    -Wait -PassThru
}

# ---------------------------------------------------------------- 1 · INSTALL
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

# ------------------------------------------------------ 2 · AUTOSTART WRAPPER
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

# -------------------------------------------------------- 3 · UPGRADE DRILL
Write-Host '== 3. upgrade drill (re-run setup) =='
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
$code2 = & $ping
Check "site responds 200 post-upgrade (got $code2)" ("$code2" -eq '200')

# ------------------------------------------------------------ 4 · UNINSTALL
Write-Host '== 4. silent uninstall =='
& wsl.exe --shutdown
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
if ($script:fail -gt 0) { Write-Host "INSTALL DRILL FAILED ($($script:fail) checks)"; exit 1 }
Write-Host 'INSTALL DRILL PASSED'
