param(
  [string]$Distro = "BasaPOS",
  [string]$AppDir = "$env:LOCALAPPDATA\Programs\BasaPOS"
)
# Full uninstall cleanup for BasaPOS appliance. Wired into Inno Setup [UninstallRun].
$ErrorActionPreference = "Continue"

Unregister-ScheduledTask -TaskName "BasaPOS-Appliance" -Confirm:$false -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName "BasaPOS-Setup-Resume" -Confirm:$false -ErrorAction SilentlyContinue

# Remove the appliance's self-signed cert from the machine trust store
# (tracked by thumbprint; see Ensure-TrustedCert in common.ps1).
$thumbFile = Join-Path $AppDir "config\tls\cert-thumbprint.txt"
if (Test-Path $thumbFile) {
  $thumb = (Get-Content $thumbFile -First 1 -ErrorAction SilentlyContinue)
  if ($thumb) {
    try { Remove-Item -Path "Cert:\LocalMachine\Root\$($thumb.Trim())" -ErrorAction Stop | Out-Null
          Write-Host "Removed trusted cert $($thumb.Trim())" } catch {}
  }
}

& wsl.exe --unregister $Distro 2>$null

$hosts = "$env:SystemRoot\System32\drivers\etc\hosts"
if (Test-Path $hosts) {
  $content = Get-Content $hosts | Where-Object { $_ -notmatch 'basapos\.local' }
  Set-Content -Path $hosts -Value $content
}
Write-Host "BasaPOS appliance removed."
