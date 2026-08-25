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
$env:BASA_LOG_FILE = Join-Path $InstallRoot "logs\setup.log"
# Also write a debug file at a known path (the drill will hex-dump this)
$DebugFile = Join-Path $InstallRoot "setup-debug.txt"
[System.IO.File]::WriteAllText($DebugFile, "$(Get-Date) BOOT AppDir=$AppDir`n")
# Clear stale status so Inno Setup's polling loop doesn't exit on a
# leftover SETUP_COMPLETE from a previous run.
$StatusFile = Join-Path $InstallRoot "setup-status.txt"
Remove-Item $StatusFile -Force -ErrorAction SilentlyContinue
# Clear stale status so Inno Setup's polling loop doesn't exit on a
# leftover SETUP_COMPLETE from a previous run.
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
  $cfg = Join-Path $env:USERPROFILE ".wslconfig"
  $want = @{ vmIdleTimeout = "[wsl2]"; instanceIdleTimeout = "[general]" }
  $lines = @(Get-Content $cfg -ErrorAction SilentlyContinue)
  foreach ($k in $want.Keys) {
    $kv = "$k=-1"; $section = $want[$k]
    $exists = ($lines | Select-String "^\s*$k\s*=") -ne $null
    if (-not $exists) {
      $hasSection = ($lines | Select-String "^\s*\[$( $section.Trim('[]') )\]") -ne $null
      if (-not $hasSection) { $lines += $section }
      $lines += $kv
      Write-BasaLog ".wslconfig += $kv"
    }
  }
  Set-Content -Path $cfg -Value $lines -Encoding ascii
}

function New-Credentials {
  $existing = Test-Path $CredsFile
  if (-not $existing) {
    $bytes = New-Object byte[] 16
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $pw = ([convert]::ToBase64String($bytes) -replace '[+/=]', '').Substring(0, 16)
    Set-Content -Path $CredsFile -Value "user=$($script:Distro)`nadmin_user=Administrator`npassword=$pw" -Encoding ascii
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
  $ts = Get-Date -Format "yyyyMMdd_HHmmss"
  $dest = Join-Path $InstallRoot "backups\pre-upgrade\$ts"
  New-Item -ItemType Directory -Force -Path $dest | Out-Null
  & wsl.exe -d $script:Distro -u frappe -- bash -c "cd /home/frappe/bench && bench --site basapos.local backup --with-files --backup-path /home/frappe/bench/backups/$ts" 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "pre-upgrade bench backup failed" }
  Copy-Item "\\wsl$\$script:Distro\home\frappe\bench\backups\$ts\*" $dest -Recurse -Force
  Write-BasaLog "backup at $dest"
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
  $inSql = Convert-ToWslPath $sql.FullName
  $tars  = @(Get-ChildItem $Dest -Filter "*.tar")
  $priv  = $tars | Where-Object { $_.Name -match '-private-files\.tar$' } | Select-Object -Last 1
  $files = $tars | Where-Object { $_.Name -notmatch '-private-files\.tar$' } | Select-Object -Last 1
  $cmd = "bench --site basapos.local restore '$inSql' --force"
  if ($files) { $cmd += " --with-public-files '" + (Convert-ToWslPath $files.FullName) + "'" }
  if ($priv)  { $cmd += " --with-private-files '" + (Convert-ToWslPath $priv.FullName) + "'" }
  $fullCmd = "cd /home/frappe/bench && $cmd && bench --site basapos.local migrate && bench --site basapos.local clear-cache"
  $logDir = Join-Path $InstallRoot "logs"
  $restoreLog = Join-Path $logDir "restore.log"
  Write-BasaLog "restore cmd: $fullCmd"
  & wsl.exe -d $script:Distro -- bash -c $fullCmd > $restoreLog 2>&1
  $exitCode = $LASTEXITCODE
  Write-BasaLog "restore wsl exit: $exitCode"
  if (Test-Path $restoreLog) {
    $tail = Get-Content $restoreLog -Tail 30 -ErrorAction SilentlyContinue
    if ($tail) { Write-BasaLog "restore log tail: $($tail -join '; ')" }
  }
  if ($exitCode -ne 0) { throw "restore failed (exit $exitCode)" }
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
  [System.IO.File]::AppendAllText($DebugFile, "$(Get-Date) UPGRADE-DETECT: installed.txt found`n")
  $Upgrade = $true
}
$isUpgrade = $Upgrade -or ((Test-Path $InstalledMarker) -and (Test-DistroPresent -InstallRoot $InstallRoot))
[System.IO.File]::AppendAllText($DebugFile, "$(Get-Date) UPGRADE-DETECT: Upgrade=$Upgrade isUpgrade=$isUpgrade`n")

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

if (Test-RebootPending) {
  Write-BasaLog "reboot pending -- registering resume task"
  Register-ResumeTask
  Set-SetupStatus "NEEDS_REBOOT"
  exit 0
}

try {
  $backupDest = $null
  if ($isUpgrade) {
    [System.IO.File]::AppendAllText($DebugFile, "$(Get-Date) PATH: entering UPGRADE path`n")
    try { $backupDest = Backup-SiteForUpgrade } catch { Write-BasaLog "FATAL: $($_.Exception.Message)"; Set-SetupStatus "ERROR_BACKUP"; exit 1 }
    [System.IO.File]::AppendAllText($DebugFile, "$(Get-Date) PATH: backup done dest=$backupDest`n")

    [System.IO.File]::AppendAllText($DebugFile, "$(Get-Date) PATH: unregistering distro`n")
    $unregJob = Start-Job -ScriptBlock { param($d) & wsl.exe --unregister $d 2>$null; $LASTEXITCODE } -ArgumentList $script:Distro
    $unregTimeout = 120
    $completed = Wait-Job $unregJob -Timeout $unregTimeout
    if ($null -eq $completed) {
      [System.IO.File]::AppendAllText($DebugFile, "$(Get-Date) PATH: unregister TIMED OUT after ${unregTimeout}s, stopping`n")
      Stop-Job $unregJob
    }
    $unregResult = Receive-Job $unregJob
    Remove-Job $unregJob -Force
    [System.IO.File]::AppendAllText($DebugFile, "$(Get-Date) PATH: unregister exit $unregResult`n")
    if ($unregResult -ne 0) { Write-BasaLog "WARN: unregister exit $unregResult (continuing)" }

    [System.IO.File]::AppendAllText($DebugFile, "$(Get-Date) PATH: importing rootfs`n")
    Import-RootfsIfNeeded -Force
    [System.IO.File]::AppendAllText($DebugFile, "$(Get-Date) PATH: rootfs imported, booting distro`n")
    & wsl.exe -d $script:Distro -- bash -c "timeout 30 true" > $null 2>&1
    Start-Sleep -Seconds 5
    & wsl.exe -d $script:Distro -- bash -c "timeout 60 systemctl is-system-running --wait" > $null 2>&1
    [System.IO.File]::AppendAllText($DebugFile, "$(Get-Date) PATH: distro booted, restoring backup`n")
    Restore-LatestBackup -Dest $backupDest
  } else {
    [System.IO.File]::AppendAllText($DebugFile, "$(Get-Date) PATH: entering FRESH install path`n")
    Import-RootfsIfNeeded
    New-Credentials
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
  if ($online) { Write-BasaLog "site online" } else { Write-BasaLog "WARN: site not yet online; autostart will finish booting" }

  New-Item -ItemType File -Path $InstalledMarker -Force | Out-Null
  [System.IO.File]::AppendAllText($DebugFile, "$(Get-Date) FINAL: online=$online isUpgrade=$isUpgrade`n")
  if ($online) { Set-SetupStatus "SETUP_COMPLETE" }
  else { Set-SetupStatus "SETUP_COMPLETE_DEGRADED" }
  Unregister-ScheduledTask -TaskName $ResumeTask -Confirm:$false -ErrorAction SilentlyContinue

  Write-BasaLog "==== setup complete ===="
} catch {
  Write-BasaLog "FATAL: $($_.Exception.Message)"
  Set-SetupStatus ("ERROR: " + $_.Exception.Message)
  exit 1
}
