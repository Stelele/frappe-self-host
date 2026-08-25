param()
# Boot wrapper: scheduled-task ACTION. Boots distro, polls health, stamps status.
# Status states the launcher reads: STARTING / RUNNING / ERROR_WAKE / ERROR_HEALTH
$ErrorActionPreference = "Continue"
$InstallRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)   # {app}
$StatusFile = Join-Path $InstallRoot "appliance-status.txt"
$SettingsFile = Join-Path $InstallRoot "app\settings.txt"
$env:BASA_LOG_FILE = Join-Path $InstallRoot "logs\autostart.log"
$env:BASA_DEBUG_FILE = Join-Path $InstallRoot "setup-debug.txt"
New-Item -ItemType Directory -Force -Path (Join-Path $InstallRoot "logs") | Out-Null
. (Join-Path $PSScriptRoot "common.ps1")

function Set-Status([string]$s) { Set-Content -Path $StatusFile -Value $s -Encoding ascii }

Set-Status "STARTING"
Write-BasaLog "boot-wrapper: waking distro $script:Distro"

# Boot attempt with up to 3 retries (covers VM cold starts / slow disks)
$woke = $false
for ($i = 1; $i -le 3; $i++) {
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
  # After 60s without a response, try restarting bench services once
  if (-not $restarted -and ((Get-Date) -gt $deadline.AddMinutes(-7))) {
    Write-BasaLog "site not responding after 60s — restarting bench services"
    & wsl.exe -d $script:Distro -u root -- bash -c "systemctl restart basapos-gunicorn basapos-socketio basapos-worker-short basapos-worker-long basapos-scheduler 2>&1" 2>$null | Out-Null
    $restarted = $true
    Start-Sleep -Seconds 10
  }
  Start-Sleep -Seconds 10
}
Set-Status "ERROR_HEALTH"
exit 1
