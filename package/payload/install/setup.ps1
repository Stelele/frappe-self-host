<#
  BasaPOS installer payload orchestrator. Runs elevated from Inno Setup.
  Idempotent. Modes:
    fresh   : enable WSL -> import rootfs -> stamp hosts/.wslconfig -> creds ->
              autostart -> boot+verify
    upgrade : backup site -> unregister distro -> import new rootfs -> restore ->
              keep existing credentials
    resume  : continue after reboot (skips WSL feature install)
  Usage: setup.ps1 -AppDir <{app}> [-Resume] [-Upgrade]
#>
param(
  [Parameter(Mandatory=$true)][string]$AppDir,
  [switch]$Resume,
  [switch]$Upgrade
)
# Continue, not Stop: PS 5.1 turns benign native stderr (e.g. WSL's
# "Failed to start the systemd user session") into terminating errors.
# Every critical native call below checks $LASTEXITCODE explicitly.
$ErrorActionPreference = "Continue"
$InstallRoot = $AppDir
$PayloadDir = Join-Path $PSScriptRoot ".."
$RootfsTar = Join-Path $InstallRoot "rootfs\basapos-rootfs.tar.gz"
$WslMsi = Join-Path $InstallRoot "wsl\wsl.msi"
$DistroDir = Join-Path $InstallRoot "data\distro"
$ConfigDir = Join-Path $InstallRoot "config"
$CredsFile = Join-Path $ConfigDir "credentials.txt"
$StatusFile = Join-Path $InstallRoot "setup-status.txt"
$InstalledMarker = Join-Path $InstallRoot "installed.txt"
$ResumeTask = "BasaPOS-Setup-Resume"
$RequiredFreeGB = 12

New-Item -ItemType Directory -Force -Path $ConfigDir, (Join-Path $InstallRoot "logs") | Out-Null
# Write install root to a system-wide location so boot-wrapper can find it in S4U context
$bootHint = Join-Path $env:ProgramData "BasaPOS"
New-Item -ItemType Directory -Force -Path $bootHint | Out-Null
Set-Content -Path (Join-Path $bootHint "install-root.txt") -Value $InstallRoot -Encoding ascii -Force
$env:BASA_LOG_FILE = Join-Path $InstallRoot "logs\setup.log"
# Also write a debug file at a known path (the drill will hex-dump this)
$DebugFile = Join-Path $InstallRoot "setup-debug.txt"
[System.IO.File]::WriteAllText($DebugFile, (Get-Date).ToString() + " BOOT AppDir=" + $AppDir + "`n")
# Also write logs to debug file as fallback (the logs/ subdir may not be visible)
$env:BASA_DEBUG_FILE = $DebugFile
# Clear stale status so Inno Setup's polling loop doesn't exit on a
# leftover SETUP_COMPLETE from a previous run.
$StatusFile = Join-Path $InstallRoot "setup-status.txt"
Remove-Item $StatusFile -Force -ErrorAction SilentlyContinue
. (Join-Path $PSScriptRoot "common.ps1")
Write-BasaLog "==== setup starting (AppDir=$InstallRoot Resume=$Resume Upgrade=$Upgrade) ===="

function Set-SetupStatus([string]$s) { Set-Content -Path $StatusFile -Value $s -Encoding ascii }

function Enable-WslFeatures {
  foreach ($f in @("Microsoft-Windows-Subsystem-Linux", "VirtualMachinePlatform")) {
    try {
      $r = Enable-WindowsOptionalFeature -Online -FeatureName $f -All -NoRestart
      Write-BasaLog ("feature {0}: restartNeeded={1}" -f $f, $r.RestartNeeded)
    } catch { Write-BasaLog "Enable-WindowsOptionalFeature ${f}: $($_.Exception.Message)" }
  }
}

function Install-WslMsi {
  if (-not (Test-Path $WslMsi)) { Write-BasaLog "WARN: WSL MSI not found: $WslMsi"; return }
  $p = Start-Process msiexec.exe -ArgumentList "/i `"$WslMsi`" /qn /norestart" -Wait -PassThru
  Write-BasaLog "WSL MSI exit $($p.ExitCode)"
}

function Import-RootfsIfNeeded {
  param([switch]$Force)
  if (-not $Force -and (Test-DistroPresent -InstallRoot $InstallRoot)) {
    Write-BasaLog "distro already present -- skipping import"; return
  }
  if (-not (Test-Path $RootfsTar)) { throw "rootfs tarball missing: $RootfsTar" }
  $freeGB = [math]::Round((Get-PSDrive ($InstallRoot.Substring(0,1)) -ErrorAction Stop).Free / 1GB, 1)
  if ($freeGB -lt $RequiredFreeGB) { throw "only $freeGB GB free; need ~$RequiredFreeGB GB" }
  New-Item -ItemType Directory -Force -Path $DistroDir | Out-Null
  Write-BasaLog "importing appliance rootfs (minutes)..."
  & wsl.exe --import $script:Distro $DistroDir $RootfsTar 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "wsl --import failed (exit $LASTEXITCODE)" }
  $deadline = (Get-Date).AddSeconds(60)
  while (-not (Test-DistroPresent) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 3 }
  if (-not (Test-DistroPresent)) { throw "distro not listed after import" }
  Write-BasaLog "appliance imported"
}

function Ensure-HostsEntry {
  $hosts = "$env:SystemRoot\System32\drivers\etc\hosts"
  $content = Get-Content $hosts -ErrorAction SilentlyContinue
  if (-not ($content -match [regex]::Escape($script:Domain))) {
    Add-Content -Path $hosts -Value "127.0.0.1 $($script:Domain)"
    Write-BasaLog "hosts entry added"
  } else { Write-BasaLog "hosts entry already present" }
}

function Ensure-WslConfig {
  # Section-aware .wslconfig editing (drill-failure-catalog D14 / WIN-012):
  # removes keys from wrong sections, sets them under the owning section,
  # never creates duplicate headers. Must run BEFORE the first `wsl -d`
  # boots the imported distro — .wslconfig is only read at VM start.
  # (The old append-at-end writer put vmIdleTimeout under a duplicate
  # [wsl2] header and instanceIdleTimeout under [general], so neither key
  # reliably took effect and the VM idled out between drill phases.)
  $cfg = Join-Path $env:USERPROFILE ".wslconfig"
  $want = @(
    @{ key = 'vmIdleTimeout';       section = 'wsl2' },
    @{ key = 'instanceIdleTimeout'; section = 'wsl2' }
  )
  $lines = @(Get-Content $cfg -ErrorAction SilentlyContinue)
  foreach ($w in $want) {
    # pass 1: drop occurrences outside the owning section
    $out = New-Object System.Collections.Generic.List[string]
    $cur = ''
    foreach ($l in $lines) {
      if ($l -match '^\s*\[(.+)\]') { $cur = $Matches[1].Trim() }
      if (($cur -ne $w.section) -and ($l -match ("^\s*" + $w.key + "\s*="))) { continue }
      $out.Add($l)
    }
    $lines = @($out)
    # pass 2: set-or-insert inside the owning section
    $inSection = $false; $done = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
      if ($lines[$i] -match '^\s*\[(.+)\]') { $inSection = ($Matches[1].Trim() -eq $w.section); continue }
      if ($inSection -and $lines[$i] -match ("^\s*" + $w.key + "\s*=")) { $lines[$i] = "$($w.key)=-1"; $done = $true; break }
    }
    if (-not $done) {
      $has = $false
      foreach ($l in $lines) { if ($l -match ("^\s*\[" + $w.section + "\]")) { $has = $true; break } }
      if (-not $has) { $lines += ("[" + $w.section + "]") }
      $idx = -1
      for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match ("^\s*\[" + $w.section + "\]")) { $idx = $i } }
      if ($idx -eq ($lines.Count - 1)) { $lines += "$($w.key)=-1" }
      else { $lines = @($lines[0..$idx]) + @("$($w.key)=-1") + @($lines[($idx+1)..($lines.Count-1)]) }
    }
    Write-BasaLog ".wslconfig: $($w.key)=-1 under [$($w.section)]"
  }
  Set-Content -Path $cfg -Value $lines -Encoding ascii
}

function Wait-MariaDbReady {
  # systemd cold-boot can take minutes on slow disks; bench fails instantly
  # against a not-yet-ready mariadb (drill-failure-catalog D12/D13).
  # Runs as root with the provisioned password — the old `mysqladmin ping`
  # ran as the default user (frappe) and got Access Denied, burning the full
  # timeout while validating nothing.
  & wsl.exe -d $script:Distro -- bash -c "timeout 120 bash -c 'while ! mysqladmin ping -u root -pBasaPOS-root-2026 --silent 2>/dev/null; do sleep 2; done' > /dev/null 2>&1"
  Write-BasaLog ("mariadb-ready check exit: " + $LASTEXITCODE)
}

function New-Credentials {
  $existing = Test-Path $CredsFile
  if (-not $existing) {
    $bytes = New-Object byte[] 16
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $pw = ([convert]::ToBase64String($bytes) -replace '[+/=]', '').Substring(0, 16)
    Set-Content -Path $CredsFile -Value ("user=" + $script:Distro + [char]10 + "admin_user=Administrator" + [char]10 + "password=" + $pw) -Encoding ascii
    icacls $CredsFile /inheritance:r /grant:r "$env:USERNAME`:F" | Out-Null
    Write-BasaLog "generated admin password -> config\credentials.txt"
  }
  # ALWAYS sync the appliance password to whatever the file says (covers repair:
  # freshly imported image ships a throwaway pw)
  $pw = Get-Content $CredsFile | Where-Object { $_ -match '^password=' } | ForEach-Object { $_.Substring(9).Trim() } | Select-Object -First 1
  if (-not $pw) { throw "credentials.txt missing password line" }
  & wsl.exe -d $script:Distro -u frappe -- bash -c "cd /home/frappe/bench && bench --site basapos.local set-admin-password '$pw'" 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "set-admin-password failed" }
}

function Backup-SiteForUpgrade {
  Write-BasaLog "upgrade: backing up site before swap"
  # mariadb may still be cold-booting after the wake (D13)
  Wait-MariaDbReady
  $ts = Get-Date -Format "yyyyMMdd_HHmmss"
  $dest = Join-Path $InstallRoot "backups\pre-upgrade\$ts"
  New-Item -ItemType Directory -Force -Path $dest | Out-Null
  & wsl.exe -d $script:Distro -u frappe -- bash -c "cd /home/frappe/bench && bench --site basapos.local backup --with-files --backup-path /home/frappe/bench/backups/$ts" 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "pre-upgrade bench backup failed" }
  # Copy-out with retries (D17): the \\wsl$ 9P share can take seconds to
  # serve a fresh distro session; a single-shot Copy-Item fails the whole
  # upgrade on a transient.
  $copied = $false
  for ($i = 1; $i -le 3; $i++) {
    try {
      Copy-Item "\\wsl$\$script:Distro\home\frappe\bench\backups\$ts\*" $dest -Recurse -Force -ErrorAction Stop
      $copied = $true; break
    } catch {
      Write-BasaLog "backup copy attempt ${i} failed: $($_.Exception.Message)"
      Start-Sleep -Seconds 10
    }
  }
  if (-not $copied) { throw "backup copy-out failed after 3 attempts" }
  # Verify the backup BEFORE the distro is destroyed (D17/R4-10): a partial
  # copy must fail HERE, not after the only other copy is unregistered.
  $sqlOk = Get-ChildItem $dest -Filter '*.sql.gz' -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt 1024 }
  if (-not $sqlOk) { throw "backup verification failed: no non-trivial *.sql.gz in $dest" }
  Write-BasaLog "backup at $dest (verified)"
  return $dest
}

function Convert-ToWslPath([string]$WinPath) {
  # C:\Users\me\file.sql.gz -> /mnt/c/Users/me/file.sql.gz
  $p = $WinPath -replace '\\', '/'
  $drive = $p.Substring(0, 1).ToLower()
  return "/mnt/$drive" + $p.Substring(2)
}

function Restore-LatestBackup {
  param([string]$Dest)
  Write-BasaLog "restoring pre-upgrade backup"
  $sql = Get-ChildItem $Dest -Filter "*.sql.gz" | Sort-Object Name | Select-Object -Last 1
  if (-not $sql) { throw "no sql backup found in $Dest" }
  $tars  = @(Get-ChildItem $Dest -Filter "*.tar")
  $priv  = $tars | Where-Object { $_.Name -match '-private-files\.tar$' } | Select-Object -Last 1
  $files = $tars | Where-Object { $_.Name -notmatch '-private-files\.tar$' } | Select-Object -Last 1

  # Copy backup files to WSL native filesystem — reading from /mnt/c/ (9P mount)
  # is 10-50x slower than native ext4 I/O inside the WSL virtual disk.
  $stagingDir = "/home/frappe/bench/sites/__restore_staging"
  & wsl.exe -d $script:Distro -- bash -c "mkdir -p '$stagingDir'"

  $wslSql = "$stagingDir/$($sql.Name)"
  Write-BasaLog "copying SQL dump to WSL native fs: $wslSql"
  & wsl.exe -d $script:Distro -- bash -c "cp '$(Convert-ToWslPath $sql.FullName)' '$wslSql'"

  $wslFiles = $null
  if ($files) {
    $wslFiles = "$stagingDir/$($files.Name)"
    Write-BasaLog "copying public files tar to WSL native fs: $wslFiles"
    & wsl.exe -d $script:Distro -- bash -c "cp '$(Convert-ToWslPath $files.FullName)' '$wslFiles'"
  }
  $wslPriv = $null
  if ($priv) {
    $wslPriv = "$stagingDir/$($priv.Name)"
    Write-BasaLog "copying private files tar to WSL native fs: $wslPriv"
    & wsl.exe -d $script:Distro -- bash -c "cp '$(Convert-ToWslPath $priv.FullName)' '$wslPriv'"
  }

  # Read admin password from credentials file for bench restore --admin-password
  $adminPw = Get-Content $CredsFile -ErrorAction SilentlyContinue |
    Where-Object { $_ -match '^password=' } |
    ForEach-Object { $_.Substring(9).Trim() } |
    Select-Object -First 1
  if (-not $adminPw) { throw "credentials.txt missing password for restore" }
  $restoreCmd = "bench --site basapos.local restore '$wslSql' --force --db-root-username root --db-root-password 'BasaPOS-root-2026' --admin-password '$adminPw'"
  if ($wslFiles) { $restoreCmd += " --with-public-files '$wslFiles'" }
  if ($wslPriv)  { $restoreCmd += " --with-private-files '$wslPriv'" }
  $logDir = Join-Path $InstallRoot "logs"
  $restoreLog = Join-Path $logDir "restore.log"
  Write-BasaLog "restore cmd: $restoreCmd"
  # Write restore script — runs as root, bench commands via su - frappe
  $tmpScript = Join-Path $logDir "restore-script.sh"
  $wslLogDir = Convert-ToWslPath $logDir
  $scriptContent = @"
#!/bin/bash
set -x
LOGFILE="$wslLogDir/restore-steps.log"
ts() { date '+%Y-%m-%d %H:%M:%S'; }
echo "`$(ts) restore-script started (pwd=`$(pwd) user=`$(whoami))" > "`$LOGFILE"
cd /home/frappe/bench
echo "`$(ts) setting root credentials in site_config.json..." >> "`$LOGFILE"
python3 -c "import json; f='/home/frappe/bench/sites/basapos.local/site_config.json'; c=json.load(open(f)); c['root_login']='root'; c['root_password']='BasaPOS-root-2026'; c['mariadb_root_password']='BasaPOS-root-2026'; json.dump(c, open(f,'w'), indent=2)" >> "`$LOGFILE" 2>&1
rc=`$?
echo "`$(ts) site_config root credentials set: `$rc" >> "`$LOGFILE"
echo "`$(ts) running bench restore..." >> "`$LOGFILE"
su frappe -c "$restoreCmd" >> "`$LOGFILE" 2>&1
rc=`$?
echo "`$(ts) restore exit: `$rc" >> "`$LOGFILE"
# D9: a failed restore MUST abort. Continuing would clear-cache + restart the
# FACTORY database and report "site confirmed online" on a data-wiped appliance.
if [ "`$rc" -ne 0 ]; then
  echo "`$(ts) restore FAILED - aborting before any post-restore steps" >> "`$LOGFILE"
  exit "`$rc"
fi
echo "`$(ts) running bench migrate..." >> "`$LOGFILE"
su frappe -c "bench --site basapos.local migrate" >> "`$LOGFILE" 2>&1
rc=`$?
echo "`$(ts) migrate exit: `$rc" >> "`$LOGFILE"
if [ "`$rc" -ne 0 ]; then
  echo "`$(ts) migrate FAILED - aborting (schema drift on a version upgrade)" >> "`$LOGFILE"
  exit "`$rc"
fi
echo "`$(ts) running clear-cache..." >> "`$LOGFILE"
su frappe -c "bench --site basapos.local clear-cache" >> "`$LOGFILE" 2>&1
rc=`$?
echo "`$(ts) clear-cache exit: `$rc" >> "`$LOGFILE"
echo "`$(ts) setting maintenance_mode=0, pause_scheduler=0..." >> "`$LOGFILE"
su frappe -c "bench --site basapos.local set-config -gp maintenance_mode 0" >> "`$LOGFILE" 2>&1
su frappe -c "bench --site basapos.local set-config -gp pause_scheduler 0" >> "`$LOGFILE" 2>&1
echo "`$(ts) cleaning up staging files..." >> "`$LOGFILE"
rm -rf "$stagingDir" 2>/dev/null || true
echo "`$(ts) resetting failed services..." >> "`$LOGFILE"
systemctl reset-failed basapos-gunicorn basapos-socketio basapos-worker-short basapos-worker-long basapos-scheduler >> "`$LOGFILE" 2>&1 || true
echo "`$(ts) restarting services..." >> "`$LOGFILE"
systemctl restart basapos-gunicorn basapos-socketio basapos-worker-short basapos-worker-long basapos-scheduler >> "`$LOGFILE" 2>&1
rc=`$?
echo "`$(ts) systemctl restart exit: `$rc" >> "`$LOGFILE"
sleep 5
echo "`$(ts) service status after restart:" >> "`$LOGFILE"
for svc in basapos-gunicorn basapos-socketio basapos-worker-short basapos-worker-long basapos-scheduler; do
  echo "  `$svc: `$(systemctl is-active `$svc 2>&1)" >> "`$LOGFILE"
done
echo "`$(ts) checking site health..." >> "`$LOGFILE"
# D15: gunicorn --preload cold start routinely exceeds 30s on 2 vCPU -
# poll 18 x 10s (3 min) instead of 6 x 5s.
for i in `$(seq 1 18); do
  code=`$(curl -sk -m 20 -o /dev/null -w '%{http_code}' https://basapos.local/api/method/ping 2>/dev/null || true)
  echo "  attempt `$i: http `$code" >> "`$LOGFILE"
  if [ "`$code" = "200" ]; then echo "`$(ts) site confirmed online" >> "`$LOGFILE"; break; fi
  sleep 10
done
echo "`$(ts) journal errors (last 30 lines):" >> "`$LOGFILE"
journalctl -u basapos-gunicorn --no-pager -n 30 --since "10 min ago" >> "`$LOGFILE" 2>&1
echo "`$(ts) restore-script done" >> "`$LOGFILE"
"@
  # Write with LF only — WriteAllLines uses CRLF on Windows which breaks bash
  $lfContent = $scriptContent -replace "`r`n", "`n"
  [System.IO.File]::WriteAllText($tmpScript, $lfContent, [System.Text.UTF8Encoding]::new($false))
  $wslScript = Convert-ToWslPath $tmpScript
  & wsl.exe -d $script:Distro -u root -- bash -c "cp '$wslScript' /tmp/restore-script.sh && chmod +x /tmp/restore-script.sh"
  # Run as root — su - frappe handles user switch for bench commands.
  # D9: capture rc immediately and exit with it — the old trailing `echo`
  # became the last command, so wsl.exe returned 0 even when the restore
  # failed and the `if ($exitCode -ne 0)` below was dead code.
  & wsl.exe -d $script:Distro -u root -- bash -c "bash /tmp/restore-script.sh > /tmp/restore.log 2>&1; rc=`$?; echo WSL_EXIT:`$rc >> /tmp/restore.log; exit `$rc"
  $exitCode = $LASTEXITCODE
  $rawLog = & wsl.exe -d $script:Distro -- bash -c "cat /tmp/restore.log"
  [System.IO.File]::WriteAllText($restoreLog, ($rawLog -join "`n"), [System.Text.UTF8Encoding]::new($false))
  # Read restore steps log directly from Windows filesystem (written to logs/ by the script)
  $stepsLogFile = Join-Path $logDir "restore-steps.log"
  if (Test-Path $stepsLogFile) {
    $stepsLog = Get-Content $stepsLogFile -ErrorAction SilentlyContinue
    if ($stepsLog) { Write-BasaLog "restore steps: $($stepsLog -join '; ')" }
  }
  Write-BasaLog "restore wsl exit: $exitCode"
  if (Test-Path $restoreLog) {
    $tail = Get-Content $restoreLog -Tail 30 -ErrorAction SilentlyContinue
    if ($tail) { Write-BasaLog "restore log tail: $($tail -join '; ')" }
  }
  if ($exitCode -ne 0) { throw "restore failed (exit $exitCode)" }
  # Keep WSL alive: after setup.exe exits, no Windows process touches WSL.
  # Without a foreground process, WSL shuts down and kills systemd + all services.
  & wsl.exe -d $script:Distro -- bash -c "nohup bash -c 'while true; do sleep 60; done' >/dev/null 2>&1 &"
  Write-BasaLog "restore complete"
}

function Register-ResumeTask {
  $setup = Join-Path $PSScriptRoot "setup.ps1"
  $a = "-NoProfile -ExecutionPolicy Bypass -File `"$setup`" -AppDir `"$InstallRoot`" -Resume"
  $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $a
  $trigger = New-ScheduledTaskTrigger -AtLogOn
  $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
    -LogonType Interactive -RunLevel Highest
  Register-ScheduledTask -TaskName $ResumeTask -Action $action -Trigger $trigger `
    -Principal $principal -Force | Out-Null
}

# ---------------- main flow ----------------
# Auto-detect upgrade: if installed.txt exists, this is an upgrade regardless
# of what the ISS passes.  The ISS [Code] section's FileExists check may not
# work in all elevated contexts.
if (-not $Upgrade -and (Test-Path $InstalledMarker)) {
  [System.IO.File]::AppendAllText($DebugFile, (Get-Date).ToString() + " UPGRADE-DETECT: installed.txt found`n")
  $Upgrade = $true
}
$isUpgrade = $Upgrade -or ((Test-Path $InstalledMarker) -and (Test-DistroPresent -InstallRoot $InstallRoot))
[System.IO.File]::AppendAllText($DebugFile, (Get-Date).ToString() + " UPGRADE-DETECT: Upgrade=" + $Upgrade + " isUpgrade=" + $isUpgrade + "`n")

if ($Resume -and (Test-Path $InstalledMarker) -and (Test-Path $StatusFile) -and
    ((Get-Content $StatusFile -ErrorAction SilentlyContinue) -match 'SETUP_COMPLETE')) {
  Write-BasaLog "setup already complete; nothing to resume"
  Unregister-ScheduledTask -TaskName $ResumeTask -Confirm:$false -ErrorAction SilentlyContinue
  exit 0
}

if (-not $Resume) {
  Enable-WslFeatures
  if (-not (Test-WslInstalled)) { Install-WslMsi }
}

# D20: CI runners ship spurious RebootPending keys (leftover CBS/PFR entries)
# while WSL is already enabled, and no reboot/logon ever happens there - the
# resume task would never fire and every install would die at NEEDS_REBOOT.
# Skip the diversion under CI (GitHub Actions sets CI=true, inherited through
# Inno's non-elevating admin context).
if ((Test-RebootPending) -and (-not $env:CI)) {
  Write-BasaLog "reboot pending -- registering resume task"
  Register-ResumeTask
  Set-SetupStatus "NEEDS_REBOOT"
  exit 0
}

try {
  $backupDest = $null
  if ($isUpgrade) {
    try { $backupDest = Backup-SiteForUpgrade } catch { Write-BasaLog "FATAL: $($_.Exception.Message)"; Set-SetupStatus "ERROR_BACKUP"; exit 1 }

    # D16: hard-gate the unregister. Continuing after a failed/timed-out
    # unregister leaves the old ext4.vhdx beside the new import -> name
    # collision or C: exhaustion mid-import.
    $unregJob = Start-Job -ScriptBlock { param($d) & wsl.exe --unregister $d 2>$null; $LASTEXITCODE } -ArgumentList $script:Distro
    $completed = Wait-Job $unregJob -Timeout 300
    if ($null -eq $completed) {
      Stop-Job $unregJob; Remove-Job $unregJob -Force
      throw "wsl --unregister did not finish in 300s"
    }
    $unregResult = Receive-Job $unregJob
    Remove-Job $unregJob -Force
    if ($unregResult -ne 0) { throw "wsl --unregister failed (exit $unregResult) - aborting before re-import" }
    # vhdx files can outlive deregistration (locked handles) - make the
    # import target pristine so --import starts clean
    if (Test-Path $DistroDir) { Remove-Item $DistroDir -Recurse -Force -ErrorAction SilentlyContinue }

    Import-RootfsIfNeeded -Force
    & wsl.exe -d $script:Distro -- bash -c "timeout 30 true" > $null 2>&1
    Start-Sleep -Seconds 5
    & wsl.exe -d $script:Distro -- bash -c "timeout 60 systemctl is-system-running --wait" > $null 2>&1
    # D12: root creds + real exit visibility (old version ran as the default
    # user, got Access Denied, and validated nothing)
    Wait-MariaDbReady
    Restore-LatestBackup -Dest $backupDest
    # D25: re-sync the admin password explicitly. bench restore sets it via
    # --admin-password, but relying on that alone leaves a lockout window if
    # any restore path skips the flag. New-Credentials is a no-op for
    # generation here (credentials.txt exists on upgrade) and always re-runs
    # set-admin-password, which throws on failure.
    New-Credentials
  } else {
    # D14: .wslconfig must exist BEFORE the first `wsl -d` boots the distro
    # (it is only read at VM start) - so hosts+wslconfig first, then wake.
    Ensure-HostsEntry
    Ensure-WslConfig
    Import-RootfsIfNeeded
    # D13: wait for mariadb before bench touches the cold-booting distro
    Wait-MariaDbReady
    New-Credentials
    # Keep WSL alive on the FRESH path too (previously restore-only): the
    # idle-timeout keys are belt-and-braces, this is the guarantee (D14).
    & wsl.exe -d $script:Distro -- bash -c "nohup bash -c 'while true; do sleep 60; done' >/dev/null 2>&1 &"
  }

  Ensure-HostsEntry
  Ensure-WslConfig
  # NOTE: wsl.exe --shutdown removed — it hangs in headless CI contexts and
  # blocks Inno Setup exit.  The CI runner / uninstaller cleans up WSL state.

  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "register-autostart.ps1") -InstallRoot $InstallRoot 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) { Write-BasaLog "WARN: register-autostart exit $LASTEXITCODE" }

  # Health check: shorter for upgrades (site was already confirmed online pre-upgrade).
  $healthMinutes = if ($isUpgrade) { 5 } else { 10 }
  $url = Get-SiteUrl
  Write-BasaLog "waiting for $url (max ${healthMinutes} min) ..."
  $deadline = (Get-Date).AddMinutes($healthMinutes)
  $online = $false
  while ((Get-Date) -lt $deadline) {
    if (Test-DistroPresent) { & wsl.exe -d $script:Distro -u root --exec /bin/true 2>$null }
    if (Test-SiteOnline -Url $url) { $online = $true; break }
    Start-Sleep -Seconds 10
  }
  if ($online) {
    Write-BasaLog "site online"
  } else { Write-BasaLog "WARN: site not yet online; autostart will finish booting" }
  # Trust the appliance's self-signed TLS cert (LocalMachine\Root) so the
  # browser doesn't mark https://basapos.local as "Not secure".
  # D7: run UNCONDITIONALLY, not gated on $online — after an upgrade the
  # Windows-side WSL2 localhost relay can lag while the site is healthy
  # inside the distro; gating on the Windows curl made the new cert's
  # trust import impossible exactly when it was needed. Ensure-TrustedCert
  # self-guards on cert-file existence; boot-wrapper re-runs it if the
  # cert was not present yet.
  $null = Ensure-TrustedCert -InstallRoot $InstallRoot

  New-Item -ItemType File -Path $InstalledMarker -Force | Out-Null
  [System.IO.File]::AppendAllText($DebugFile, (Get-Date).ToString() + " FINAL: online=" + $online + " isUpgrade=" + $isUpgrade + "`n")
  if ($online) { Set-SetupStatus "SETUP_COMPLETE" }
  else { Set-SetupStatus "SETUP_COMPLETE_DEGRADED" }
  Unregister-ScheduledTask -TaskName $ResumeTask -Confirm:$false -ErrorAction SilentlyContinue

  Write-BasaLog "==== setup complete ===="
} catch {
  Write-BasaLog "FATAL: $($_.Exception.Message)"
  Set-SetupStatus ("ERROR: " + $_.Exception.Message)
  exit 1
}
