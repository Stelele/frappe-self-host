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
$ErrorActionPreference = "Stop"
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
  & wsl.exe --import $script:Distro $DistroDir $RootfsTar
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
  # fresh installs only; upgrades keep existing creds via restore
  if (Test-Path $CredsFile) { Write-BasaLog "credentials exist -- keeping"; return }
  $bytes = New-Object byte[] 16
  [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
  $pw = ([convert]::ToBase64String($bytes) -replace '[+/=]', '').Substring(0, 16)
  Set-Content -Path $CredsFile -Value "user=$($script:Distro)`nadmin_user=Administrator`npassword=$pw" -Encoding ascii
  icacls $CredsFile /inheritance:r /grant:r "$env:USERNAME`:F" | Out-Null
  Write-BasaLog "generated admin password -> config\credentials.txt"
  & wsl.exe -d $script:Distro -u frappe -- bash -c "cd /home/frappe/bench && bench --site basapos.local set-admin-password '$pw'"
  if ($LASTEXITCODE -ne 0) { throw "set-admin-password failed" }
}

function Backup-SiteForUpgrade {
  Write-BasaLog "upgrade: backing up site before swap"
  $ts = Get-Date -Format "yyyyMMdd_HHmmss"
  $dest = Join-Path $InstallRoot "backups\pre-upgrade\$ts"
  New-Item -ItemType Directory -Force -Path $dest | Out-Null
  & wsl.exe -d $script:Distro -u frappe -- bash -c "cd /home/frappe/bench && bench --site basapos.local backup --with-files --backup-path /home/frappe/bench/backups/$ts"
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
  $files = Get-ChildItem $Dest -Filter "*.sql.gz" | Sort-Object Name
  if (-not $files) { throw "no sql backup found in $Dest" }
  $inWsl = Convert-ToWslPath $files[-1].FullName
  & wsl.exe -d $script:Distro -u frappe -- bash -c "cd /home/frappe/bench && bench --site basapos.local --force restore '$inWsl'"
  if ($LASTEXITCODE -ne 0) { throw "restore failed" }
  Get-ChildItem $Dest -Filter "*.tar" | ForEach-Object {
    $tarInWsl = Convert-ToWslPath $_.FullName
    & wsl.exe -d $script:Distro -u frappe -- bash -c "cd /home/frappe/bench && bench --site basapos.local restore-files --with-private-files '$tarInWsl'"
  }
  & wsl.exe -d $script:Distro -u frappe -- bash -c "cd /home/frappe/bench && bench --site basapos.local migrate && bench --site basapos.local clear-cache"
  if ($LASTEXITCODE -ne 0) { throw "post-restore migrate failed" }
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
$isUpgrade = $Upgrade -or ((Test-Path $InstalledMarker) -and (Test-DistroPresent -InstallRoot $InstallRoot))

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

$backupDest = $null
if ($isUpgrade -and (Test-DistroPresent -InstallRoot $InstallRoot)) {
  try { $backupDest = Backup-SiteForUpgrade } catch { Write-BasaLog "FATAL: $($_.Exception.Message)"; Set-SetupStatus "ERROR_BACKUP"; exit 1 }
  & wsl.exe --unregister $script:Distro 2>$null
  Import-RootfsIfNeeded -Force
  Restore-LatestBackup -Dest $backupDest
} else {
  Import-RootfsIfNeeded
  New-Credentials
}

Ensure-HostsEntry
Ensure-WslConfig
& wsl.exe --shutdown 2>$null

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "register-autostart.ps1") -InstallRoot $InstallRoot

$url = Get-SiteUrl
Write-BasaLog "waiting for $url ..."
$deadline = (Get-Date).AddMinutes(10)
$online = $false
while ((Get-Date) -lt $deadline) {
  if (Test-DistroPresent) { & wsl.exe -d $script:Distro -u root --exec /bin/true 2>$null }
  if (Test-SiteOnline -Url $url) { $online = $true; break }
  Start-Sleep -Seconds 10
}
if ($online) { Write-BasaLog "site online" } else { Write-BasaLog "WARN: site not yet online; autostart will finish booting" }

New-Item -ItemType File -Path $InstalledMarker -Force | Out-Null
if ($online) { Set-SetupStatus "SETUP_COMPLETE" }
else { Set-SetupStatus "SETUP_COMPLETE_DEGRADED" }
Write-BasaLog "==== setup complete ===="
