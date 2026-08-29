<#
  Drill phase 2/3: upgrade (re-run Setup.exe over an existing install).
  Requires drill-install.ps1 to have run on the SAME runner (state: distro,
  installed.txt, credentials). Runs as its own CI step: failures attribute to
  UPGRADE and the uninstall phase is still exercised (as a separate job run).
  Usage: drill-upgrade.ps1 -SetupExe <path\to\BasaPOS-Setup-x.y.z.exe>
#>
param(
  [Parameter(Mandatory=$true)][string]$SetupExe
)
. (Join-Path $PSScriptRoot 'drill-common.ps1')
trap { Copy-CiLogs; Write-Host "DRILL DIED: $_"; exit 1 }

Write-Host '== 3. upgrade drill (re-run setup) =='
# D3: kill any ORPHANED setup.ps1 left over from the install step. Inno
# spawns setup.ps1 with ewNoWait; if the install step's Setup.exe exited
# early (its 10-min poll), setup.ps1 may still be running and would race
# this upgrade (two writers to setup-status.txt, concurrent wsl ops).
# (Match on the command line; the drill itself runs drill-upgrade.ps1
# under pwsh, so it can never match itself.)
Get-CimInstance Win32_Process -Filter "Name LIKE 'powershell%'" -ErrorAction SilentlyContinue |
  Where-Object { "$($_.CommandLine)" -match 'setup\.ps1' } |
  ForEach-Object {
    Write-Host "  killing orphaned setup PID $($_.ProcessId)"
    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
  }
Start-Sleep -Seconds 3

# Ensure WSL is running before upgrade (idempotent wake; the VM may have
# idled out since the install phase - .wslconfig idle-disable is not
# reliably applied, drill-failure-catalog D14). Bounded (D2): a wedged
# wsl.exe must not hang the drill.
$j = Start-Job -ScriptBlock { & wsl.exe -d BasaPOS -u root --exec /bin/true 2>$null; $LASTEXITCODE }
if (-not (Wait-Job $j -Timeout 120)) {
  Write-Host '  [TIMEOUT] wsl wake exceeded 120s - killing job'
  Stop-Job $j
}
Remove-Job $j -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 5

# Capture the pre-upgrade password BEFORE touching anything (this is the
# value the upgrade must preserve).
$pwBefore = (Get-Content "$AppDir\config\credentials.txt" -ErrorAction SilentlyContinue |
  Select-String '^password=').Line

# Kill anything that could stall Inno's CloseApplications check.
# NOTE: conhost is deliberately NOT killed - Stop-Process on all conhost.exe
# murders the drill's own console (0xE9 "No process on the other end of the
# pipe" - drill-failure-catalog D10).
$oldEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& taskkill /F /IM wsl.exe /T 2>$null
Get-Process -Name 'wsl','BasaPOS' -ErrorAction SilentlyContinue |
  Stop-Process -Force -ErrorAction SilentlyContinue
$ErrorActionPreference = $oldEap
Start-Sleep -Seconds 3

$p2 = Invoke-SilentSetup -SetupExe $SetupExe -LogName 'inno-upgrade.log'
Check "second setup exit 0 (got $($p2.ExitCode))" ($p2.ExitCode -eq 0)
# D3: gate on setup.ps1 actually finishing (Setup.exe's poll can expire
# while the ewNoWait child is still restoring).
$terminal2 = Wait-SetupTerminal -Minutes 10
Check "upgrade reached terminal status (got: '$terminal2')" ($terminal2 -ne '')
$backupRoot = "$AppDir\backups\pre-upgrade"
Check 'pre-upgrade backup taken' ((Test-Path $backupRoot) -and
  ((Get-ChildItem $backupRoot -Directory -ErrorAction SilentlyContinue).Count -ge 1))
$credsAfter = Get-Content "$AppDir\config\credentials.txt" -ErrorAction SilentlyContinue
$pwAfter = ($credsAfter | Select-String '^password=').Line
Check 'credentials preserved across upgrade' ("$pwAfter" -eq "$pwBefore")
$status2 = (Get-Content "$AppDir\setup-status.txt" -ErrorAction SilentlyContinue) -join ''
# Strict anchor (both ends): SETUP_COMPLETE_DEGRADED must FAIL here, not
# launder through to the flakier TLS check below.
Check 'post-upgrade SETUP_COMPLETE' ("$status2" -match '^SETUP_COMPLETE$')

# Upgrade re-imports the rootfs -> firstboot generates a NEW cert. setup.ps1
# must have re-imported it into the Windows trust store (no -k here). WSL2
# networking on the Windows host can take minutes to settle after a distro
# re-import, so poll instead of failing on the first attempt.
# --ssl-no-revoke: schannel cannot do revocation on a self-signed cert with
# no CRL/OCSP endpoints (would fail-closed even when correctly trusted).
# -m 20 bounds each attempt (a stalled relay must not hang a single curl).
$codeTrusted2 = $null
$deadline2 = (Get-Date).AddMinutes(5)
do {
  $codeTrusted2 = & curl.exe -s --ssl-no-revoke -m 20 -o NUL -w "%{http_code}" 'https://basapos.local/api/method/ping' 2>$null
  if ("$codeTrusted2" -eq '200') { break }
  Start-Sleep -Seconds 30
} while ((Get-Date) -lt $deadline2)
Check "post-upgrade TLS trusted by Windows store (got $codeTrusted2)" ("$codeTrusted2" -eq '200')

# After upgrade the restore-script confirms site health from inside WSL.
# WSL2 networking may be broken after distro re-import, so verify via
# the restore-steps.log instead of a separate ping.
$stepsLog = Join-Path $AppDir "logs\restore-steps.log"
$restored = $false
if (Test-Path $stepsLog) {
  $steps = Get-Content $stepsLog -ErrorAction SilentlyContinue
  $restored = ($steps -join ' ') -match 'site confirmed online'
}
Check "site confirmed online post-upgrade (via restore log)" $restored

Exit-Drill 'UPGRADE'
