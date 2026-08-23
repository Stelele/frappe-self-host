# Windows Installer & Release Flow Implementation Plan (M2–M5, "Plan B")

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** De-hardcoded, CI-built `BasaPOS-Setup.exe`: one-click offline installer importing the M1 appliance into WSL2, auto-starting it at boot without the GUI, surviving upgrades with data intact, publishing releases from tags.

**Architecture:** Inno Setup ships launcher exe + pinned WSL MSI + rootfs tarball + PowerShell payload. Post-install `setup.ps1` (idempotent, elevated) enables WSL, imports the distro, stamps hosts/.wslconfig, generates credentials (fresh) or preserves them (upgrade = backup→swap→restore), registers an S4U autostart task, boots + health-checks. The WinForms launcher is an optional control panel reading config files. GH windows runners compile launcher + ISCC and run a real WSL2 E2E against the M1 artifact.

**Tech Stack:** Inno Setup 6 · .NET 8 WinForms (win-x64 single-file self-contained) · PowerShell 5.1-compatible scripts · Plan A appliance rootfs · GitHub Actions (ubuntu + windows).

**Spec:** `docs/superpowers/specs/2026-08-22-wsl-native-windows-installer-design.md` §2, §5–§9 · Milestones M2–M5.
**Prereq (done):** Plan A merged; `appliance/build.sh` → `appliance/dist/basapos-rootfs.tar.gz`.

---

## Environment reality (verification strategy)

Dev machine is Linux. Locked into every task:

| Component | Local verification | CI verification |
|---|---|---|
| PowerShell payload | none (no pwsh here) | pwsh parse-gate (Task 8 job 1) + real execution (Task 9 E2E) |
| Launcher build | none (WinForms needs Windows SDK) | dotnet publish on windows-latest |
| Inno compile | none | ISCC via chocolatey on windows-latest |
| Workflow YAML | python yaml.safe_load | runs |

Constants used throughout: distro `BasaPOS` · domain `basapos.local` · install dir `{localappdata}\Programs\BasaPOS` · bench path `/home/frappe/bench` (**not** prototype's `frappe-bench`) · scheduler unit `basapos-scheduler` (**not** `basapos-schedule`) · admin user `Administrator`.

## File Structure

```
package/
├── launcher/{BasaPOS.csproj, app.manifest, Program.cs}
├── payload/
│   ├── install/{setup.ps1, common.ps1, boot-wrapper.ps1,
│   │            register-autostart.ps1, remove-basapos.ps1}
│   ├── app/{settings.template.txt, scripts/{backup.ps1,down.ps1,verify.ps1}}
│   └── wsl/                     # MSI staged at assembly time (never committed)
├── BasaPOS.iss                  # de-hardcoded Inno script
├── build.ps1                    # payload assembler + ISCC driver
└── e2e/e2e-import-boot.ps1      # CI E2E script
.github/workflows/{installer-lint.yml, windows-e2e.yml, windows-release.yml}
docs/ops/{usb-update.md, lan-mode.md, troubleshooting.md}
```

---

### Task 1: Scaffold package/ tree from prototype assets

**Files:**
- Create: `package/launcher/BasaPOS.csproj`, `package/launcher/app.manifest` (byte-faithful from prototype zip)
- Create: `package/payload/install/lib/.gitkeep`, `package/payload/app/settings.template.txt`
- Modify: `.gitignore`

- [ ] **Step 1: Copy launcher project files**

```bash
mkdir -p package/launcher package/payload/install/lib package/payload/app/scripts package/payload/wsl package/e2e
cp /tmp/opencode/pkg-inspect/package/launcher/BasaPOS.csproj package/launcher/
cp /tmp/opencode/pkg-inspect/package/launcher/app.manifest package/launcher/
```
If `/tmp/opencode/pkg-inspect` is missing, re-extract: `mkdir -p /tmp/opencode/pkg-inspect && unzip -o package.zip -d /tmp/opencode/pkg-inspect >/dev/null && mkdir -p /tmp/opencode/pkg-inspect/package/launcher && cp <(unzip -p package.zip launcher/BasaPOS.csproj) package/launcher/BasaPOS.csproj` etc. (zip paths: `launcher/BasaPOS.csproj`, `launcher/app.manifest`).
Expected: both files exist under package/launcher/.

- [ ] **Step 2: Create `package/payload/app/settings.template.txt`**

```
# BasaPOS settings (key=value, one per line)
DOMAIN=basapos.local
LAN_MODE=false
```

- [ ] **Step 3: Append to `.gitignore`**

```gitignore

# Installer assembly inputs/outputs
package/payload/wsl/*.msi
package/build/
*.exe.tmp
```

- [ ] **Step 4: Verify + commit**

Run: `find package -type f | sort && tail -6 .gitignore`
Expected: csproj, manifest, template, .gitkeep listed; gitignore ends with the new block.

```bash
git add package .gitignore
git commit -m "feat(package): scaffold installer tree from prototype assets"
```

---

### Task 2: common.ps1 — shared helpers

**Files:**
- Create: `package/payload/install/common.ps1`

- [ ] **Step 1: Write `common.ps1`**

```powershell
# Shared helpers for BasaPOS install payload. Dot-source me.
# PS 5.1-compatible. No profile dependencies.

$script:Distro = "BasaPOS"
$script:Domain = "basapos.local"
$script:BenchPath = "/home/frappe/bench"

function Write-BasaLog {
  param([string]$Message)
  $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
  Write-Host $line
  if ($env:BASA_LOG_FILE) { Add-Content -Path $env:BASA_LOG_FILE -Value $line -Encoding ascii }
}

function Test-RebootPending {
  if (Test-Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations") { return $true }
  if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending") { return $true }
  return $false
}

function Test-WslInstalled {
  try { & wsl.exe --status 2>$null | Out-Null; return ($LASTEXITCODE -eq 0) } catch { return $false }
}

function Invoke-WslCaptured {
  # wsl.exe writes UTF-16 to stdout; PS mangles it. Re-decode captured bytes.
  param([string[]]$WslArgs)
  $old = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $out = & wsl.exe @WslArgs 2>$null
    if ($null -eq $out) { return "" }
    return ([System.Text.Encoding]::Unicode.GetString([System.Text.Encoding]::Default.GetBytes(($out -join "`n"))))
  } finally { $ErrorActionPreference = $old }
}

function Test-DistroPresent {
  param([string]$InstallRoot)   # dir that would contain data\distro\ext4.vhdx
  if ($InstallRoot) {
    $vhd = Join-Path $InstallRoot "data\distro\ext4.vhdx"
    if (Test-Path $vhd) { return $true }
  }
  $text = Invoke-WslCaptured @("--list", "--quiet")
  return ($text -match [regex]::Escape($script:Distro))
}

function Get-SiteUrl {
  param([string]$SettingsFile)
  $domain = $script:Domain
  if ($SettingsFile -and (Test-Path $SettingsFile)) {
    foreach ($line in (Get-Content $SettingsFile)) {
      if ($line -match '^\s*DOMAIN\s*=\s*(.+?)\s*$') { $domain = $Matches[1]; break }
    }
  }
  return "https://$domain"
}

function Test-SiteOnline {
  param([string]$Url)
  try {
    $code = & curl.exe -sk -o NUL -w "%{http_code}" "$Url/api/method/ping" 2>$null
    return ($code -eq "200")
  } catch { return $false }
}
```

- [ ] **Step 2: Verify + commit**

Local check is textual only (no pwsh): confirm no CRLF-only issues by `file package/payload/install/common.ps1` → ASCII/UTF-8 text; grep constants present.

```bash
git add package/payload/install/common.ps1
git commit -m "feat(package): shared PowerShell helpers for installer payload"
```

---

### Task 3: Ops scripts — backup / down / verify (aligned to our appliance)

**Files:**
- Create: `package/payload/app/scripts/{backup.ps1, down.ps1, verify.ps1}`

- [ ] **Step 1: `backup.ps1`**

```powershell
param(
  [string]$Distro = "BasaPOS",
  [string]$Site = "basapos.local"
)
$ErrorActionPreference = "Stop"

$AppDir = Split-Path -Parent $PSScriptRoot
$Base = Split-Path -Parent $AppDir
$BackupDir = Join-Path $Base "backups"
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null

Write-Host "Waking the appliance..."
& wsl.exe -d $Distro -u root -- /bin/true 2>$null

Write-Host "Backing up site $Site in distro $Distro..."
& wsl.exe -d $Distro -u frappe -- bash -c "cd /home/frappe/bench && bench --site $Site backup --with-files --backup-path /home/frappe/bench/backups/$Timestamp"
if ($LASTEXITCODE -ne 0) { Write-Error "bench backup failed (exit $LASTEXITCODE)"; exit 1 }

Write-Host "Copying backup files to host..."
Copy-Item -Path "\\wsl$\$Distro\home\frappe\bench\backups\$Timestamp" -Destination $BackupDir -Recurse -Force
Write-Host "Backup saved to $BackupDir\$Timestamp"
```

- [ ] **Step 2: `down.ps1`**

```powershell
param([string]$Distro = "BasaPOS")
Write-Host "Stopping the BasaPOS appliance (data preserved)..."
& wsl.exe --terminate $Distro 2>$null
if ($LASTEXITCODE -eq 0) { Write-Host "Done." } else { Write-Host "The appliance is already stopped." }
```

- [ ] **Step 3: `verify.ps1`** (unit names match Plan A exactly)

```powershell
param(
  [string]$Distro = "BasaPOS",
  [string]$Site = "basapos.local"
)
$script:pass = 0; $script:fail = 0
function Pass($m) { $script:pass++; Write-Host "  [PASS] $m" }
function Fail($m) { $script:fail++; Write-Host "  [FAIL] $m" }

Write-Host ""
Write-Host "=== BasaPOS Appliance Verification ==="
Write-Host ""

$oldEap = $ErrorActionPreference
$ErrorActionPreference = "Continue"
& wsl.exe -d $Distro -u root -- /bin/true 2>$null
$wakeExit = $LASTEXITCODE
$ErrorActionPreference = $oldEap

if ($wakeExit -eq 0) { Pass "WSL distro '$Distro' is present" }
else { Fail "WSL distro '$Distro' is missing (re-run the installer)" }

if ($wakeExit -eq 0) {
  Write-Host "--- Services ---"
  $services = @("nginx","basapos-gunicorn","basapos-socketio","basapos-scheduler",
                "basapos-worker-short","basapos-worker-long","mariadb","redis-server")
  $states = @(& wsl.exe -d $Distro -u root -- bash -c "systemctl is-active $($services -join ' ')" 2>$null)
  for ($i = 0; $i -lt $services.Count; $i++) {
    if ($states[$i] -eq "active") { Pass "Service '$($services[$i])' active" }
    else { Fail "Service '$($services[$i])' is '$($states[$i])'" }
  }
}

Write-Host "--- Site ---"
$code = & curl.exe -sk -o NUL -w "%{http_code}" "https://$Site/api/method/ping" 2>$null
if ($code -eq "200") { Pass "Site responds (https://$Site)" }
else { Fail "Site did not respond (HTTP $code)" }

$total = $script:pass + $script:fail
Write-Host "--- Summary ---"
Write-Host "  $($script:pass) / $total checks passed"
if ($script:fail -gt 0) { Write-Host "  $($script:fail) checks failed."; exit 1 }
Write-Host "  All systems operational."
```

- [ ] **Step 4: Verify + commit**

```bash
grep -n "frappe-bench\|basapos-schedule\b" package/payload/app/scripts/*.ps1 && echo "PROTOTYPE PATHS LEAKED" || echo OK
git add package/payload/app/scripts
git commit -m "feat(package): ops scripts aligned to M1 appliance paths and unit names"
```

---

### Task 4: Boot wrapper + autostart registration + uninstall

**Files:**
- Create: `package/payload/install/boot-wrapper.ps1`
- Create: `package/payload/install/register-autostart.ps1`
- Create: `package/payload/install/remove-basapos.ps1`

- [ ] **Step 1: `boot-wrapper.ps1`** — the scheduled-task action; boots distro, polls health, retries, stamps status file the launcher reads.

```powershell
param()
$ErrorActionPreference = "Continue"
$InstallRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)   # {app}
$StatusFile = Join-Path $InstallRoot "appliance-status.txt"
$SettingsFile = Join-Path $InstallRoot "app\settings.txt"
$env:BASA_LOG_FILE = Join-Path $InstallRoot "logs\autostart.log"
New-Item -ItemType Directory -Force -Path (Join-Path $InstallRoot "logs") | Out-Null
. (Join-Path $PSScriptRoot "common.ps1")

function Set-Status([string]$s) { Set-Content -Path $StatusFile -Value $s -Encoding ascii }

Set-Status "STARTING"
Write-BasaLog "boot-wrapper: waking distro $script:Distro"

# Boot attempt with up to 3 retries (covers VM cold starts / slow disks)
$woke = $false
for ($i = 1; $i -le 3; $i++) {
  & wsl.exe -d $script:Distro -u root --exec /bin/true 2>$null
  if ($LASTEXITCODE -eq 0) { $woke = $true; break }
  Write-BasaLog "wake attempt $i failed; retrying in 15s"
  Start-Sleep -Seconds 15
}
if (-not $woke) { Set-Status "ERROR_WAKE"; exit 1 }

$url = Get-SiteUrl -SettingsFile $SettingsFile
Write-BasaLog "polling $url/api/method/ping"

$deadline = (Get-Date).AddMinutes(8)
while ((Get-Date) -lt $deadline) {
  if (Test-SiteOnline -Url $url) {
    # LAN_MODE hook (off by default): refresh portproxy so LAN terminals can reach us
    if ((Test-Path $SettingsFile) -and (Get-Content $SettingsFile | Select-String '^LAN_MODE=true')) {
      $ip = (Invoke-WslCaptured @("-d", $script:Distro, "-u", "root", "--", "hostname", "-I")).Trim().Split(" ")[0]
      if ($ip) {
        netsh interface portproxy delete v4tov4 listenport=443 listenaddress=0.0.0.0 2>$null | Out-Null
        netsh interface portproxy add v4tov4 listenport=443 listenaddress=0.0.0.0 connectport=443 connectaddress=$ip | Out-Null
        Write-BasaLog "LAN_MODE: portproxy 0.0.0.0:443 -> ${ip}:443"
      }
    }
    Set-Status "RUNNING"
    exit 0
  }
  Start-Sleep -Seconds 10
}
Set-Status "ERROR_HEALTH"
exit 1
```

- [ ] **Step 2: `register-autostart.ps1`** — S4U task at system startup as installing user.

```powershell
param(
  [Parameter(Mandatory=$true)][string]$InstallRoot,
  [switch]$LogonFallback
)
$ErrorActionPreference = "Stop"
$TaskName = "BasaPOS-Appliance"
$wrapper = Join-Path $InstallRoot "payload\install\boot-wrapper.ps1"
$arg = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$wrapper`""

$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $arg
if ($LogonFallback) {
  $trigger = New-ScheduledTaskTrigger -AtLogOn
} else {
  $trigger = New-ScheduledTaskTrigger -AtStartup
  $trigger.Delay = "PT30S"
}
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
  -LogonType S4U -RunLevel Highest

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
  -Principal $principal -Force | Out-Null
Write-Host "Registered $TaskName (logon type: $(if($LogonFallback){'AtLogOn'}else{'S4U AtStartup'}))"
```

- [ ] **Step 3: `remove-basapos.ps1`** — full uninstall cleanup.

```powershell
param([string]$Distro = "BasaPOS")
$ErrorActionPreference = "Continue"

Unregister-ScheduledTask -TaskName "BasaPOS-Appliance" -Confirm:$false -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName "BasaPOS-Setup-Resume" -Confirm:$false -ErrorAction SilentlyContinue

& wsl.exe --unregister $Distro 2>$null

$hosts = "$env:SystemRoot\System32\drivers\etc\hosts"
if (Test-Path $hosts) {
  $content = Get-Content $hosts | Where-Object { $_ -notmatch 'basapos\.local' }
  Set-Content -Path $hosts -Value $content
}
Write-Host "BasaPOS appliance removed."
```

- [ ] **Step 4: Verify + commit**

```bash
grep -n 'frappe-bench' package/payload/install/*.ps1 && echo LEAK || echo OK
git add package/payload/install/boot-wrapper.ps1 package/payload/install/register-autostart.ps1 package/payload/install/remove-basapos.ps1
git commit -m "feat(package): boot wrapper, S4U autostart task, uninstall cleanup"
```

---

### Task 5: setup.ps1 — orchestrator (fresh / upgrade / resume)

**Files:**
- Create: `package/payload/install/setup.ps1`

- [ ] **Step 1: Write `setup.ps1`**

```powershell
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
  $sql = Get-ChildItem $Dest -Filter "*.sql.gz" | Sort-Object Name | Select-Object -Last 1
  if (-not $sql) { throw "no sql backup found in $Dest" }
  $inSql = Convert-ToWslPath $sql.FullName
  $tars  = @(Get-ChildItem $Dest -Filter "*.tar")
  $priv  = $tars | Where-Object { $_.Name -match '-private-files\.tar$' } | Select-Object -Last 1
  $files = $tars | Where-Object { $_.Name -notmatch '-private-files\.tar$' } | Select-Object -Last 1
  $cmd = "cd /home/frappe/bench && bench --site basapos.local --force restore '$inSql'"
  if ($files) { $cmd += " --with-public-files '" + (Convert-ToWslPath $files.FullName) + "'" }
  if ($priv)  { $cmd += " --with-private-files '" + (Convert-ToWslPath $priv.FullName) + "'" }
  & wsl.exe -d $script:Distro -u frappe -- bash -c $cmd | Out-Host
  if ($LASTEXITCODE -ne 0) { throw "restore failed" }
  & wsl.exe -d $script:Distro -u frappe -- bash -c "cd /home/frappe/bench && bench --site basapos.local migrate && bench --site basapos.local clear-cache" | Out-Host
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
Set-SetupStatus $(if ($online) { "SETUP_COMPLETE" } else { "SETUP_COMPLETE_DEGRADED" })
Write-BasaLog "==== setup complete ===="
```

- [ ] **Step 2: Verify + commit**

```bash
grep -c 'function ' package/payload/install/setup.ps1   # expect >= 9
git add package/payload/install/setup.ps1
git commit -m "feat(package): setup orchestrator with fresh/upgrade/resume flows"
```

---

### Task 6: Launcher refactor (Program.cs)

**Files:**
- Create: `package/launcher/Program.cs` (replaces prototype's)

- [ ] **Step 1: Write the refactored `Program.cs`**

Changes vs prototype: config-driven domain/status; reads `{app}\appliance-status.txt`; surfaces credentials on first run; adds **Repair** action; removes auto-open-browser-on-load; keeps mutex + status dot + log pane. Full file:

```csharp
using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace BasaPOS
{
    static class Program
    {
        [STAThread]
        static void Main()
        {
            using var mutex = new Mutex(true, "BasaPOS_8A2C9B4E5D3F", out bool createdNew);
            if (!createdNew) { NativeMethods.BringToFront(); return; }
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new MainForm());
        }
    }

    static class NativeMethods
    {
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern IntPtr FindWindow(string lpClassName, string lpWindowName);
        [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hWnd);
        [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

        public static void BringToFront()
        {
            var h = FindWindow(null, "BasaPOS");
            if (h != IntPtr.Zero) { ShowWindow(h, 9); SetForegroundWindow(h); }
        }
    }

    class MainForm : Form
    {
        readonly string _appDir;
        readonly string _installedMarker;
        readonly string _statusFile;
        readonly string _credsFile;
        readonly Func<string> _siteUrl;
        Label _statusLabel;
        Panel _statusDot;
        TextBox _log;
        Button _btnStart, _btnStop, _btnBackup, _btnOpen, _btnRepair, _btnCreds;
        Timer _statusTimer;
        bool _busy;

        public MainForm()
        {
            Text = "BasaPOS";
            ClientSize = new Size(860, 500);
            StartPosition = FormStartPosition.CenterScreen;
            FormBorderStyle = FormBorderStyle.FixedSingle;
            MaximizeBox = false;

            _appDir = AppContext.BaseDirectory;
            var installRoot = Path.GetFullPath(_appDir);
            _installedMarker = Path.Combine(installRoot, "installed.txt");
            _statusFile = Path.Combine(installRoot, "appliance-status.txt");
            _credsFile = Path.Combine(installRoot, "config", "credentials.txt");
            var settingsFile = Path.Combine(installRoot, "app", "settings.txt");
            _siteUrl = () => ReadDomain(settingsFile);

            BuildUi();
            Load += async (s, e) => await RefreshStatusAsync();
            _statusTimer = new Timer { Interval = 15000 };
            _statusTimer.Tick += async (s, e) => await RefreshStatusAsync();
            _statusTimer.Start();
            FormClosed += (s, e) => _statusTimer.Dispose();
        }

        string ReadDomain(string settingsFile)
        {
            try
            {
                if (File.Exists(settingsFile))
                    foreach (var line in File.ReadAllLines(settingsFile))
                        if (line.StartsWith("DOMAIN="))
                            return "https://" + line.Substring(7).Trim();
            }
            catch { }
            return "https://basapos.local";
        }

        Button MakeButton(string text, int x)
        {
            var b = new Button
            {
                Text = text, Size = new Size(96, 32), Location = new Point(x, 10),
                FlatStyle = FlatStyle.FlatStyle.Flat,
                BackColor = Color.White, ForeColor = Color.FromArgb(32, 32, 32)
            };
            b.FlatAppearance.BorderColor = Color.FromArgb(200, 200, 200);
            return b;
        }

        void BuildUi()
        {
            var top = new Panel { Dock = DockStyle.Top, Height = 56, Padding = new Padding(10, 10, 10, 6) };
            _statusDot = new Panel { Size = new Size(14, 14), BackColor = Color.Gray, Location = new Point(12, 18) };
            _statusLabel = new Label
            {
                AutoSize = true, Font = new Font("Segoe UI", 10f, FontStyle.Bold),
                ForeColor = Color.FromArgb(64, 64, 64), Location = new Point(34, 18)
            };
            _btnStart = MakeButton("Start", 852);
            _btnStop = MakeButton("Stop", 752);
            _btnBackup = MakeButton("Backup", 652);
            _btnOpen = MakeButton("Open App", 532);
            _btnRepair = MakeButton("Repair", 432);
            _btnCreds = MakeButton("Password", 320);

            _btnStart.Click += async (s, e) => await OnStartAsync();
            _btnStop.Click += async (s, e) => await OnStopAsync();
            _btnBackup.Click += async (s, e) => await OnRunScriptAsync("backup.ps1");
            _btnOpen.Click += async (s, e) => await OnOpenAsync();
            _btnRepair.Click += async (s, e) => await OnRepairAsync();
            _btnCreds.Click += (s, e) => ShowCredentials();

            top.Controls.AddRange(new Control[] { _statusDot, _statusLabel,
                _btnStart, _btnStop, _btnBackup, _btnOpen, _btnRepair, _btnCreds });

            _log = new TextBox
            {
                Dock = DockStyle.Fill, Multiline = true, ReadOnly = true,
                ScrollBars = ScrollBars.Vertical, Font = new Font("Consolas", 9.5f),
                BackColor = Color.FromArgb(30, 30, 30), ForeColor = Color.FromArgb(220, 220, 220)
            };
            var panel = new Panel { Dock = DockStyle.Fill, Padding = new Padding(10, 8, 10, 10) };
            panel.Controls.Add(_log);
            Controls.Add(panel);
            Controls.Add(top);
        }

        void SetBusy(bool busy)
        {
            _busy = busy;
            foreach (var b in new[] { _btnStart, _btnStop, _btnBackup, _btnOpen, _btnRepair })
                b.Enabled = !busy;
        }

        void AppendLog(string line)
        {
            if (InvokeRequired) { BeginInvoke(new Action<string>(AppendLog), line); return; }
            _log.AppendText(line + Environment.NewLine);
            _log.ScrollToCaret();
        }

        void SetStatus(Color c, string text)
        {
            if (InvokeRequired) { BeginInvoke(new Action<Color, string>(SetStatus), c, text); return; }
            _statusDot.BackColor = c;
            _statusDot.Invalidate();
            _statusLabel.Text = text;
        }

        static readonly HttpClient _http = CreateHttpClient();
        static HttpClient CreateHttpClient()
        {
            var handler = new HttpClientHandler();
            handler.ServerCertificateCustomValidationCallback = (m, c, ch, e) => true;
            return new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(8) };
        }

        async Task<bool> IsSiteUpAsync()
        {
            try { using var r = await _http.GetAsync(_siteUrl()); return r.IsSuccessStatusCode; }
            catch { return false; }
        }

        bool DistroVhdPresent()
        {
            return File.Exists(Path.Combine(Path.GetFullPath(_appDir), "data", "distro", "ext4.vhdx"));
        }

        async Task RefreshStatusAsync()
        {
            if (_busy) return;
            if (!File.Exists(_installedMarker)) { SetStatus(Color.Gray, "Not installed"); return; }
            if (!DistroVhdPresent()) { SetStatus(Color.Red, "Appliance missing - use Repair"); return; }
            var st = File.Exists(_statusFile) ? File.ReadAllText(_statusFile).Trim() : "";
            if (await IsSiteUpAsync()) SetStatus(Color.ForestGreen, "Running");
            else if (st == "ERROR_HEALTH" || st == "ERROR_WAKE") SetStatus(Color.Red, "Error (" + st + ") - see Repair / logs");
            else SetStatus(Color.Orange, "Starting...");
        }

        async Task RunProcessAsync(string fileName, string arguments, string workingDir)
        {
            var psi = new ProcessStartInfo
            {
                FileName = fileName, Arguments = arguments, WorkingDirectory = workingDir,
                UseShellExecute = false, CreateNoWindow = true,
                RedirectStandardOutput = true, RedirectStandardError = true
            };
            using var proc = new Process { StartInfo = psi };
            proc.OutputDataReceived += (s, e) => { if (!string.IsNullOrEmpty(e.Data)) AppendLog(e.Data); };
            proc.ErrorDataReceived += (s, e) => { if (!string.IsNullOrEmpty(e.Data)) AppendLog(e.Data); };
            try { proc.Start(); } catch (Exception ex) { AppendLog("Failed to launch: " + ex.Message); return; }
            proc.BeginOutputReadLine();
            proc.BeginErrorReadLine();
            await proc.WaitForExitAsync();
        }

        async Task OnStartAsync()
        {
            if (_busy || !File.Exists(_installedMarker)) return;
            SetBusy(true); AppendLog("== Starting ==");
            await WaitForSiteAsync(TimeSpan.FromMinutes(5));
            AppendLog("== Done =="); await RefreshStatusAsync(); SetBusy(false);
        }

        async Task<bool> WaitForSiteAsync(TimeSpan timeout)
        {
            AppendLog("Booting appliance (services start automatically)...");
            await RunProcessAsync("wsl.exe", $"-d BasaPOS -u root --exec /bin/true", _appDir);
            var deadline = DateTime.UtcNow + timeout;
            while (DateTime.UtcNow < deadline)
            {
                if (await IsSiteUpAsync()) { AppendLog("Site is ready."); return true; }
                await Task.Delay(3000);
            }
            AppendLog("WARN: site not responding yet.");
            return false;
        }

        async Task OnStopAsync()
        {
            if (_busy || !File.Exists(_installedMarker)) return;
            SetBusy(true); AppendLog("== Stopping (data preserved) ==");
            await RunProcessAsync("wsl.exe", "--terminate BasaPOS", _appDir);
            SetStatus(Color.Gray, "Stopped");
            AppendLog("== Done =="); SetBusy(false);
        }

        async Task OnRunScriptAsync(string script)
        {
            if (_busy || !File.Exists(_installedMarker)) return;
            SetBusy(true); AppendLog("== " + script + " ==");
            var root = Path.GetFullPath(_appDir);
            var p = Path.Combine(root, "app", "scripts", script);
            if (!File.Exists(p)) p = Path.Combine(root, "payload", "install", script);
            await RunProcessAsync("powershell.exe",
                $"-NoProfile -ExecutionPolicy Bypass -File \"{p}\"",
                Path.GetDirectoryName(p)!);
            AppendLog("== Done =="); await RefreshStatusAsync(); SetBusy(false);
        }

        async Task OnOpenAsync()
        {
            if (_busy || !File.Exists(_installedMarker)) return;
            SetBusy(true);
            try
            {
                await WaitForSiteAsync(TimeSpan.FromMinutes(5));
                Process.Start(new ProcessStartInfo(_siteUrl()) { UseShellExecute = true });
            }
            catch (Exception ex) { AppendLog("Could not open app: " + ex.Message); }
            finally { await RefreshStatusAsync(); SetBusy(false); }
        }

        async Task OnRepairAsync()
        {
            if (_busy || !File.Exists(_installedMarker)) return;
            SetBusy(true); AppendLog("== Repair ==");
            var installRoot = Path.GetFullPath(_appDir);
            var install = Path.Combine(installRoot, "payload", "install");
            if (!DistroVhdPresent())
                await RunProcessAsync("wsl.exe",
                    "--import BasaPOS \"" + Path.Combine(installRoot, "data", "distro") + "\" \"" + Path.Combine(installRoot, "rootfs", "basapos-rootfs.tar.gz") + "\"",
                    _appDir);
            AppendLog("import step finished (see log above for errors).");
            await RunProcessAsync("powershell.exe",
                "-NoProfile -ExecutionPolicy Bypass -File \"" + Path.Combine(install, "register-autostart.ps1") + "\" -InstallRoot \"" + installRoot + "\"",
                install);
            await WaitForSiteAsync(TimeSpan.FromMinutes(5));
            AppendLog("== Done =="); await RefreshStatusAsync(); SetBusy(false);
        }

        void ShowCredentials()
        {
            try
            {
                if (!File.Exists(_credsFile)) { AppendLog("credentials.txt not found"); return; }
                MessageBox.Show(File.ReadAllText(_credsFile), "BasaPOS Credentials",
                    MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            catch (Exception ex) { AppendLog("Could not read credentials: " + ex.Message); }
        }
    }
}
```

- [ ] **Step 2: Verify + commit**

Local verification is structural only (cannot compile WinForms on Linux):
```bash
grep -n 'OnRepairAsync\|ShowCredentials\|appliance-status.txt\|settings.txt' package/launcher/Program.cs | head
! grep -n 'frappe-bench' package/launcher/Program.cs
git add package/launcher/Program.cs
git commit -m "feat(launcher): config-driven control panel with repair + credentials surfacing"
```

---

### Task 7: Inno Setup script + payload assembler

**Files:**
- Create: `package/BasaPOS.iss`
- Create: `package/build.ps1`

Quoting note: `{app}` resolves to `%LOCALAPPDATA%\Programs\BasaPOS` (no spaces), so `[Run]`/`[UninstallRun]` parameter strings need NO inner double quotes.

> ISCC must be >= 6.3 for x64compatible; CI installs current Inno via chocolatey.

- [ ] **Step 1: Write `package/BasaPOS.iss`**

```ini
; BasaPOS one-click offline installer (native WSL2 appliance, no Docker)
#define MyAppName "BasaPOS"
#ifndef MyAppVersion
#define MyAppVersion "0.1.0"
#endif
#define MyAppExeName "BasaPOS.exe"

[Setup]
AppId={{8A2C9B4E-5D3F-4E7A-9C1B-4F6A2E1B5C3D}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher=BasaPOS
DefaultDirName={localappdata}\Programs\BasaPOS
DisableProgramGroupPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.19041
OutputBaseFilename=BasaPOS-Setup-{#MyAppVersion}
OutputDir=build\output
UninstallDisplayIcon={app}\BasaPOS.exe
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
RestartApplications=no
CloseApplications=yes

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "autostart"; Description: "Start BasaPOS when I sign in to Windows"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "build\payload\rootfs\basapos-rootfs.tar.gz"; DestDir: "{app}\rootfs"; Flags: ignoreversion nocompression
Source: "build\payload\wsl\wsl.msi"; DestDir: "{app}\wsl"; Flags: ignoreversion nocompression
Source: "build\payload\BasaPOS.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "build\payload\install\*"; DestDir: "{app}\payload\install"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "build\payload\app\*"; DestDir: "{app}\app"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon
Name: "{userstartup}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: autostart

[Run]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File {app}\payload\install\setup.ps1 -AppDir {app}"; StatusMsg: "Setting up appliance (several minutes)..."; Flags: runhidden waituntilterminated

[UninstallRun]
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File {app}\payload\install\remove-basapos.ps1"; Flags: runhidden; RunOnceId: "BasaPOSCleanup"

[Code]
function ReadStatus(): String;
var lines: TArrayOfString;
begin
  Result := '';
  if FileExists(ExpandConstant('{app}\setup-status.txt')) then
    if LoadStringsFromFile(ExpandConstant('{app}\setup-status.txt'), lines) then
      if GetArrayLength(lines) > 0 then Result := lines[0];
end;

function NeedRestart(): Boolean;
begin
  Result := Pos('NEEDS_REBOOT', ReadStatus()) > 0;
end;

function SetupSucceeded(): Boolean;
begin
  Result := Pos('SETUP_COMPLETE', ReadStatus()) > 0;
end;
```

- [ ] **Step 2: Write `package/build.ps1`** (param-driven assembler; zero machine paths)

```powershell
<#
  Assembles the installer payload and compiles BasaPOS-Setup.exe (Windows only).
  Usage from repo root:
    powershell -File package\build.ps1 [-RootfsTar path] [-WslMsi path] [-IsccPath path] [-Version x.y.z]
  Defaults:
    -RootfsTar appliance\dist\basapos-rootfs.tar.gz
    -WslMsi    package\wsl\wsl.msi   (download once, never commit)
    -IsccPath  discovered from standard install locations
#>
param(
  [string]$RootfsTar = '',
  [string]$WslMsi = '',
  [string]$IsccPath = '',
  [string]$Version = '0.1.0'
)
$ErrorActionPreference = 'Stop'
$Pkg = $PSScriptRoot
$Build = Join-Path $Pkg 'build'
$Payload = Join-Path $Build 'payload'

if (-not $RootfsTar) { $RootfsTar = Join-Path $Pkg '..\appliance\dist\basapos-rootfs.tar.gz' }
if (-not $WslMsi) { $WslMsi = Join-Path $Pkg 'wsl\wsl.msi' }
foreach ($req in @($RootfsTar, $WslMsi)) {
  if (-not (Test-Path $req)) { throw "required input missing: $req" }
}

Write-Host '== 1/4 publishing launcher =='
$pub = Join-Path $Build 'launcher-publish'
& dotnet publish (Join-Path $Pkg 'launcher\BasaPOS.csproj') -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:Version=$Version -o $pub
if ($LASTEXITCODE -ne 0) { throw 'launcher publish failed' }

Write-Host '== 2/4 staging payload =='
Remove-Item $Payload -Recurse -Force -ErrorAction SilentlyContinue
foreach ($d in @('rootfs','wsl','install','app')) {
  New-Item -ItemType Directory -Force -Path (Join-Path $Payload $d) | Out-Null
}
Copy-Item (Join-Path $pub 'BasaPOS.exe') (Join-Path $Payload 'BasaPOS.exe') -Force
Copy-Item $RootfsTar (Join-Path $Payload 'rootfs\basapos-rootfs.tar.gz') -Force
Copy-Item $WslMsi (Join-Path $Payload 'wsl\wsl.msi') -Force
Copy-Item (Join-Path $Pkg 'payload\install\*') (Join-Path $Payload 'install') -Recurse -Force
Remove-Item (Join-Path $Payload 'install\lib\.gitkeep') -Force -ErrorAction SilentlyContinue
Copy-Item (Join-Path $Pkg 'payload\app\*') (Join-Path $Payload 'app') -Recurse -Force
Copy-Item (Join-Path $Pkg 'payload\app\settings.template.txt') (Join-Path $Payload 'app\settings.txt') -Force

Write-Host '== 3/4 locating ISCC =='
if (-not $IsccPath) {
  $candidates = @(
    Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe',
    Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe'
  )
  $cmd = Get-Command iscc.exe -ErrorAction SilentlyContinue
  if ($cmd) { $candidates += $cmd.Source }
  foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { $IsccPath = $c; break } }
}
if (-not ($IsccPath -and (Test-Path $IsccPath))) { throw 'ISCC.exe not found; pass -IsccPath' }

Write-Host '== 4/4 compiling installer =='
Push-Location $Pkg
try {
  & $IsccPath "/DMyAppVersion=$Version" (Join-Path $Pkg 'BasaPOS.iss')
  if ($LASTEXITCODE -ne 0) { throw "ISCC failed (exit $LASTEXITCODE)" }
} finally { Pop-Location }

$out = Join-Path $Build ('output\BasaPOS-Setup-' + $Version + '.exe')
if (-not (Test-Path $out)) { throw "expected output not found: $out" }
Write-Host ("Done. Installer: {0} ({1:N2} GB)" -f $out, ((Get-Item $out).Length / 1GB))
```

Note on `/DMyAppVersion=$Version`: PowerShell expands `$Version` before passing; Inno's `#define MyAppVersion` guard at the top of the .iss respects the /D override.

- [ ] **Step 3: Verify + commit**

Local (Linux): structural checks only —
```bash
grep -c 'Source:' package/BasaPOS.iss          # expect 5
grep -n 'C:\\Users\\' package/build.ps1 package/BasaPOS.iss && echo LEAK || echo OK
git add package/BasaPOS.iss package/build.ps1
git commit -m "feat(package): de-hardcoded inno script and payload assembler"
```

---

### Task 8: Workflows — lint gate + windows release build

**Files:**
- Create: `.github/workflows/installer-lint.yml`
- Create: `.github/workflows/windows-release.yml`

- [ ] **Step 1: `installer-lint.yml`** — pwsh syntax gate for every payload script (runs on ubuntu; pwsh preinstalled).

```yaml
name: installer-lint

on:
  push:
    branches: [master, main]
    paths: ["package/**", ".github/workflows/installer-lint.yml"]
  pull_request:
    paths: ["package/**", ".github/workflows/installer-lint.yml"]

jobs:
  pwsh-parse:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Parse all payload scripts
        run: |
          set -e
          fail=0
          for f in $(find package -name '*.ps1' -type f); do
            echo "parsing $f"
            if ! pwsh -NoProfile -Command "\$null = [scriptblock]::Create((Get-Content -Raw '$f')); Write-Host '  OK'"; then
              fail=1
            fi
          done
          exit $fail
```

- [ ] **Step 2: `windows-release.yml`** — builds Setup.exe on every push touching package/** (artifact) AND publishes a GitHub Release on version tags.

```yaml
name: windows-release

on:
  push:
    branches: [master, main]
    paths: ["package/**", "appliance/**", "apps.json"]
    tags: ["v*"]
  pull_request:
    paths: ["package/**"]
  workflow_dispatch:

permissions:
  contents: write

jobs:
  rootfs:
    runs-on: ubuntu-latest
    timeout-minutes: 120
    steps:
      - uses: actions/checkout@v4
      - name: Build appliance artifact
        run: bash appliance/build.sh
      - uses: actions/upload-artifact@v4
        with:
          name: basapos-rootfs
          path: appliance/dist/basapos-rootfs.tar.gz

  installer:
    needs: rootfs
    runs-on: windows-latest
    timeout-minutes: 60
    steps:
      - uses: actions/checkout@v4

      - uses: actions/download-artifact@v4
        with:
          name: basapos-rootfs
          path: appliance/dist

      - name: Stage WSL MSI (pinned)
        shell: pwsh
        run: |
          New-Item -ItemType Directory -Force -Path package/wsl | Out-Null
          $url = 'https://github.com/microsoft/WSL/releases/download/2.7.11/wsl.2.7.11.0.x64.msi'
          Invoke-WebRequest -Uri $url -OutFile package/wsl/wsl.msi

      - name: Assemble + compile installer
        shell: pwsh
        run: |
          $tag = '${{ github.ref_name }}' -replace '^v',''
          if ($tag -match '^\d') { $v = $tag } else { $v = '0.1.0' }
          powershell -NoProfile -ExecutionPolicy Bypass -File package/build.ps1 -Version $v `
            -RootfsTar appliance/dist/basapos-rootfs.tar.gz

      - name: Checksum
        shell: pwsh
        run: |
          Get-ChildItem package/build/output/*.exe | ForEach-Object {
            $h = (Get-FileHash $_.FullName -Algorithm SHA256).Hash
            "$h  $($_.Name)" | Out-File (Join-Path $_.DirectoryName 'SHA256SUMS') -Encoding ascii
            Get-Content (Join-Path $_.DirectoryName 'SHA256SUMS')
          }

      - uses: actions/upload-artifact@v4
        with:
          name: BasaPOS-Setup
          path: package/build/output/

      - name: Publish release (tags only)
        if: startsWith(github.ref, 'refs/tags/v')
        shell: pwsh
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          gh release create "${{ github.ref_name }}" package/build/output/* --title "${{ github.ref_name }}" --notes "BasaPOS offline installer. Verify SHA256SUMS before running."

  e2e:
    needs: rootfs
    runs-on: windows-latest
    timeout-minutes: 45
    steps:
      - uses: actions/checkout@v4
      - uses: actions/download-artifact@v4
        with:
          name: basapos-rootfs
          path: appliance/dist
      - name: WSL2 import + boot + health E2E
        shell: pwsh
        run: powershell -NoProfile -ExecutionPolicy Bypass -File package/e2e/e2e-import-boot.ps1 -RootfsTar appliance/dist/basapos-rootfs.tar.gz
```

- [ ] **Step 3: Verify + commit**

```bash
python3 -c "import yaml;
[yaml.safe_load(open(f)) for f in ['.github/workflows/installer-lint.yml','.github/workflows/windows-release.yml']]; print('YAML_OK')"
git add .github/workflows/installer-lint.yml .github/workflows/windows-release.yml
git commit -m "ci: pwsh parse gate, windows release build, WSL2 e2e job"
```

---

### Task 9: E2E script — real WSL2 import/boot/health on the windows runner

**Files:**
- Create: `package/e2e/e2e-import-boot.ps1`

- [ ] **Step 1: Write `package/e2e/e2e-import-boot.ps1`**

```powershell
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

Write-Host '== import rootfs =='
$distroDir = Join-Path $env:RUNNER_TEMP 'basapos-distro'
New-Item -ItemType Directory -Force -Path $distroDir | Out-Null
wsl --import $Distro $distroDir $RootfsTar
Check 'wsl --import exit 0' ($LASTEXITCODE -eq 0)

Write-Host '== boot (systemd starts all units) =='
wsl -d $Distro -u root --exec /bin/true
Check 'distro boots' ($LASTEXITCODE -eq 0)

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
```

Note: `--install --no-distribution` enables WSL from scratch on runners lacking it; `$env:WSL_UTF8='1'` sidesteps UTF-16 output mangling (cleaner than byte-decoding).

- [ ] **Step 2: Verify + commit**

```bash
grep -c 'Check ' package/e2e/e2e-import-boot.ps1   # expect >= 4
git add package/e2e/e2e-import-boot.ps1
git commit -m "test(e2e): real WSL2 import/boot/health validation script"
```

---

### Task 10: Operator docs (zero-support ops)

**Files:**
- Create: `docs/ops/usb-update.md`, `docs/ops/lan-mode.md`, `docs/ops/troubleshooting.md`

- [ ] **Step 1: Write the three docs**

`usb-update.md`:
```markdown
# Updating a shop machine (USB workflow)

1. On any online machine: download `BasaPOS-Setup-x.y.z.exe` + `SHA256SUMS`
   from the release page. Verify the hash.
2. Copy the Setup exe to a USB stick.
3. At the shop: close BasaPOS (the appliance keeps running), run the new Setup.
4. The installer detects the existing install and automatically:
   backs up data -> swaps the appliance -> restores data. Do NOT uninstall first.
5. When finished, open https://basapos.local and check the till works.
Time: ~10 minutes. No internet needed at the shop.
```

`lan-mode.md`:
```markdown
# LAN mode (terminals connecting over the shop network)

On the server PC, edit `%LOCALAPPDATA%\Programs\BasaPOS\app\settings.txt`:
    LAN_MODE=true
Restart the PC (or re-run Repair in the launcher).
Windows Firewall prompt: allow on Private networks only.
On each terminal: add `<server-ip> basapos.local` to
`C:\Windows\System32\drivers\etc\hosts` (needs admin), then browse
https://basapos.local and accept the certificate warning once.
```

`troubleshooting.md`:
```markdown
# Troubleshooting

| Symptom | Where to look | Fix |
|---|---|---|
| Launcher says Appliance missing | %LOCALAPPDATA%\Programs\BasaPOS\data\distro missing ext4.vhdx | Press Repair |
| Stuck on Starting... | logs\autostart.log, appliance-status.txt | ERROR_HEALTH after boot attempts: reboot PC once; if persistent run verify.ps1 |
| Site unreachable from terminal | server firewall / hosts entry on terminal | see lan-mode.md |
| Forgot admin password | config\credentials.txt (Password button in launcher) | shown in app |
| Backup failed | run scripts\verify.ps1 output | disk full is most common; free space on C: |
Logs live in %LOCALAPPDATA%\Programs\BasaPOS\logs\.
```

- [ ] **Step 2: Commit**

```bash
git add docs/ops
git commit -m "docs(ops): USB update, LAN mode, troubleshooting guides"
```

---

## Out of scope (deliberate)

| Item | Why |
|---|---|
| True SYSTEM pre-login start | WSL per-user registration platform limit |
| Layered update payloads | revisit when USB updates prove painful |
| Code-signed installer | EV cert procurement is a business step; document as follow-up |
| S4U behavior verification on real shop hardware | manual checklist item (below) |

## Manual checklist (cannot be automated anywhere)

After first real-machine install: reboot without login → confirm site up;
delete Setup.exe → everything still works; upgrade drill v(n−1)→v(n);
uninstall leaves no hosts entry/task/VHD.

## Self-review notes (filled by controller before execution)

- Spec §5 install flow ↔ setup.ps1 phases mapped 1:1
- Spec §7 autostart: S4U + logon-fallback flag present in register-autostart.ps1
- Spec §8 hardening: random pw + ACL, no baked secrets (rootfs has throwaway pw reset on fresh installs), no telemetry anywhere
- Spec §9 LAN_MODE behind settings flag; portproxy refreshed per boot
- Upgrade path preserves credentials.txt (only fresh installs generate)
