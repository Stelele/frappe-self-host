param()
# Boot wrapper: scheduled-task ACTION. Boots distro, polls health, stamps status.
# Status states the launcher reads: STARTING / RUNNING / ERROR_WAKE / ERROR_HEALTH
$ErrorActionPreference = "Continue"
$LF = [char]10

# --- Resolve install root ---
# Priority: (1) hint file written by setup.ps1, (2) $PSScriptRoot, (3) LOCALAPPDATA fallback
$InstallRoot = $null
$hintFile = Join-Path $env:ProgramData "BasaPOS\install-root.txt"
if (Test-Path $hintFile) {
  $InstallRoot = (Get-Content $hintFile -ErrorAction SilentlyContinue | Select-Object -First 1).Trim()
}
if (-not $InstallRoot -or -not (Test-Path $InstallRoot)) {
  $ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
  if ($ScriptDir) { $InstallRoot = Split-Path -Parent (Split-Path -Parent $ScriptDir) }
}
if (-not $InstallRoot -or -not (Test-Path $InstallRoot)) {
  $InstallRoot = Join-Path $env:LOCALAPPDATA "Programs\BasaPOS"
}

$StatusFile = Join-Path $InstallRoot "appliance-status.txt"
$SettingsFile = Join-Path $InstallRoot "app\settings.txt"
$env:BASA_LOG_FILE = Join-Path $InstallRoot "logs\autostart.log"
$env:BASA_DEBUG_FILE = Join-Path $InstallRoot "setup-debug.txt"

# Write status IMMEDIATELY to a known file so the drill can see we ran
try {
  "STARTING" | Out-File -FilePath $StatusFile -Encoding ascii -Force
} catch {}

# Also append to setup-debug.txt as a breadcrumb
try {
  $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  [System.IO.File]::AppendAllText($env:BASA_DEBUG_FILE, $ts + " BOOT-WRAPPER ENTERED (InstallRoot=" + $InstallRoot + ")" + $LF)
} catch {}

# Load common helpers
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$commonPath = Join-Path $ScriptDir "common.ps1"
if (Test-Path $commonPath) {
  . $commonPath
} else {
  try {
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    [System.IO.File]::AppendAllText($env:BASA_DEBUG_FILE, $ts + " BOOT-WRAPPER: common.ps1 not found at " + $commonPath + $LF)
  } catch {}
  Set-Content -Path $StatusFile -Value "ERROR_WAKE" -Encoding ascii
  exit 1
}

function Set-Status([string]$s) { Set-Content -Path $StatusFile -Value $s -Encoding ascii }

Write-BasaLog "boot-wrapper: waking distro $script:Distro"

# Boot attempt - try without -u root first (root user session may fail in S4U context)
$woke = $false
for ($i = 1; $i -le 3; $i++) {
  & wsl.exe -d $script:Distro --exec /bin/true 2>$null | Out-Null
  if ($LASTEXITCODE -eq 0) { $woke = $true; break }
  & wsl.exe -d $script:Distro -u root --exec /bin/true 2>$null | Out-Null
  if ($LASTEXITCODE -eq 0) { $woke = $true; break }
  Write-BasaLog "wake attempt $i failed; retrying in 15s"
  Start-Sleep -Seconds 15
}
if (-not $woke) { Set-Status "ERROR_WAKE"; exit 1 }

$url = Get-SiteUrl -SettingsFile $SettingsFile
Write-BasaLog "polling $url/api/method/ping"

$restarted = $false
$deadline = (Get-Date).AddMinutes(8)
while ((Get-Date) -lt $deadline) {
  if (Test-SiteOnline -Url $url) {
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
  if (-not $restarted -and ((Get-Date) -gt $deadline.AddMinutes(-7))) {
    Write-BasaLog "site not responding after 60s - restarting bench services"
    & wsl.exe -d $script:Distro -u root -- bash -c "systemctl restart basapos-gunicorn basapos-socketio basapos-worker-short basapos-worker-long basapos-scheduler 2>&1" 2>$null | Out-Null
    $restarted = $true
    Start-Sleep -Seconds 10
  }
  Start-Sleep -Seconds 10
}
Set-Status "ERROR_HEALTH"
exit 1
