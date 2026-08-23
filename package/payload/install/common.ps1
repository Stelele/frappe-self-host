# Shared helpers for BasaPOS install payload. Dot-source me.
# PS 5.1-compatible. No profile dependencies.

$script:Distro = "BasaPOS"
$script:Domain = "basapos.local"
$script:BenchPath = "/home/frappe/bench"

function Write-BasaLog {
  param([string]$Message)
  $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
  # When BASA_LOG_FILE is set we're running headless (Inno/scheduled task):
  # console output would fill an unread hidden-console buffer and deadlock
  # long operations - file-only. Interactive runs have no log file set.
  if ($env:BASA_LOG_FILE) {
    Add-Content -Path $env:BASA_LOG_FILE -Value $line -Encoding ascii
  } else {
    Write-Host $line
  }
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
