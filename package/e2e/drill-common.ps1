# Shared helpers for the BasaPOS drill scripts. Dot-source me:
#   . (Join-Path $PSScriptRoot 'drill-common.ps1')
# Keep this file PS 5.1- and pwsh-7-compatible.

$ErrorActionPreference = 'Stop'
# pwsh 7.3+ couples native-command stderr to $ErrorActionPreference by default;
# with 'Stop' above, ANY unredirected native stderr would kill the drill.
# Disable the coupling (no-op on 5.1).
$PSNativeCommandUseErrorActionPreference = $false

$script:fail = 0
function Check([string]$name, [bool]$ok) {
  if ($ok) { Write-Host "  [PASS] $name" } else { Write-Host "  [FAIL] $name"; $script:fail++ }
}
function Exit-Drill([string]$name) {
  Copy-CiLogs
  if ($script:fail -gt 0) {
    Write-Host ''
    Write-Host "${name} DRILL FAILED - $($script:fail) checks"
    exit 1
  }
  Write-Host "${name} DRILL PASSED"
  exit 0
}

$AppDir = Join-Path $env:LOCALAPPDATA 'Programs\BasaPOS'
$HostsFile = "$env:SystemRoot\System32\drivers\etc\hosts"
# -m 20: no curl in the drills may hang forever on a half-open WSL2 relay.
$ping = { (& curl.exe -sk -m 20 -o NUL -w '%{http_code}' 'https://basapos.local/api/method/ping' 2>$null) }

# Copy appliance logs somewhere CI can upload them (upload-artifact cannot
# see %LOCALAPPDATA% - env vars are not expanded in action path inputs).
function Copy-CiLogs {
  if ($env:RUNNER_TEMP -and (Test-Path "$AppDir\logs")) {
    New-Item -ItemType Directory -Force -Path "$env:RUNNER_TEMP\basapos-logs" | Out-Null
    Copy-Item "$AppDir\logs\*" "$env:RUNNER_TEMP\basapos-logs\" -Force -ErrorAction SilentlyContinue
    foreach ($f in @('setup-debug.txt', 'setup-status.txt', 'appliance-status.txt')) {
      Copy-Item (Join-Path $AppDir $f) "$env:RUNNER_TEMP\basapos-logs\" -Force -ErrorAction SilentlyContinue
    }
  }
}

function Invoke-SilentSetup([string]$SetupExe, [string]$logName) {
  $p = Start-Process -FilePath $SetupExe `
    -ArgumentList '/VERYSILENT','/NORESTART','/SUPPRESSMSGBOXES','/FORCECLOSEAPPLICATIONS',"/LOG=$env:RUNNER_TEMP\$logName" `
    -PassThru
  # 15 min timeout
  $killed = -not $p.WaitForExit(900000)
  if ($killed) {
    Write-Host "  [TIMEOUT] setup.exe did not exit in 15 min - killing"
    $p | Stop-Process -Force -ErrorAction SilentlyContinue
    # Reap before anyone reads $p.ExitCode: .NET throws InvalidOperationException
    # ("Process must exit before...") unless the handle has seen the exit.
    $null = $p.WaitForExit()
  }
  # Dump diagnostic context regardless of outcome
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
  Get-Content "$env:RUNNER_TEMP\$logName" -ErrorAction SilentlyContinue | Select-Object -Last 20 | ForEach-Object { Write-Host "  $_" }
  return $p
}

function Add-CiDefenderExclusions {
  # D19: Defender real-time scanning multiplies every GB-scale I/O (2GB tar
  # extract x2, 6-8GB vhdx write x2) and is a prime suspect in the 10/15-min
  # poll timeouts. Runners are admin - exclude the big paths up front.
  # Non-fatal: some runner images have Defender disabled/managed.
  try {
    Add-MpPreference -ExclusionPath $AppDir -ErrorAction Stop | Out-Null
    Add-MpPreference -ExclusionPath $env:RUNNER_TEMP -ErrorAction Stop | Out-Null
    Add-MpPreference -ExclusionPath (Join-Path $env:LOCALAPPDATA 'Temp') -ErrorAction SilentlyContinue | Out-Null
    Write-Host '  [DEFENDER] exclusions added for AppDir, RUNNER_TEMP, LOCALAPPDATA\Temp'
  } catch {
    Write-Host "  [DEFENDER] could not add exclusions: $($_.Exception.Message)"
  }
}

function Wait-SetupTerminal([int]$Minutes = 10) {
  # D3: Setup.exe exits when ITS OWN 10-min poll gives up, while setup.ps1
  # (spawned ewNoWait by Inno) may still be installing. Gate on the status
  # file reaching a terminal state instead of trusting Setup.exe's exit.
  # Returns the terminal status string, or '' on timeout.
  $deadline = (Get-Date).AddMinutes($Minutes)
  while ((Get-Date) -lt $deadline) {
    $st = (Get-Content "$AppDir\setup-status.txt" -ErrorAction SilentlyContinue) -join ''
    if ($st -match 'SETUP_COMPLETE|ERROR|NEEDS_REBOOT') { return $st.Trim() }
    Start-Sleep -Seconds 10
  }
  return ''
}

function Invoke-BoundedWsl([string]$BashCommand, [int]$Seconds = 120) {
  # D2: bare wsl.exe calls hang indefinitely on CI runners after WSL state
  # gets disturbed (documented repeatedly in this repo's history). Run each
  # one under a hard kill-after timeout and return whatever came back.
  $j = Start-Job -ScriptBlock { param($cmd) & wsl.exe -d BasaPOS -u root -- bash -c $cmd 2>$null } -ArgumentList $BashCommand
  if (Wait-Job $j -Timeout $Seconds) {
    $out = @(Receive-Job $j)
  } else {
    $out = @("(<wsl call exceeded ${Seconds}s - killed>)")
  }
  Remove-Job $j -Force -ErrorAction SilentlyContinue
  return ($out -join "`n")
}
