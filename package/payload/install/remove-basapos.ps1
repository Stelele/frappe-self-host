param(
  [string]$Distro = "BasaPOS",
  [string]$AppDir = "$env:LOCALAPPDATA\Programs\BasaPOS"
)
# Full uninstall cleanup for BasaPOS appliance. Wired into Inno Setup [UninstallRun].
$ErrorActionPreference = "Continue"

Unregister-ScheduledTask -TaskName "BasaPOS-Appliance" -Confirm:$false -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName "BasaPOS-Setup-Resume" -Confirm:$false -ErrorAction SilentlyContinue

# Remove the appliance's self-signed cert from the machine trust store.
# Inlined deliberately (no dot-sourcing common.ps1: it may already be gone in
# a partial uninstall). Thumbprint path must match Ensure-TrustedCert in
# common.ps1: <InstallRoot>\config\tls\cert-thumbprint.txt
# Uses .NET X509Store, not the Cert: drive (which is not mounted in this
# context - "Cannot find drive. A drive with the name 'Cert' does not exist").
$thumbFile = Join-Path $AppDir "config\tls\cert-thumbprint.txt"
if (Test-Path $thumbFile) {
  $thumb = (Get-Content $thumbFile -First 1 -ErrorAction SilentlyContinue)
  if ($thumb) {
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root', 'LocalMachine')
    $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
    try {
      foreach ($c in $store.Certificates) {
        if ($c.Thumbprint -eq $thumb.Trim()) { $store.Remove($c); Write-Host "Removed trusted cert $($thumb.Trim())"; break }
      }
    } finally { $store.Close() }
  }
}

& wsl.exe --unregister $Distro 2>$null

$hosts = "$env:SystemRoot\System32\drivers\etc\hosts"
if (Test-Path $hosts) {
  $content = Get-Content $hosts | Where-Object { $_ -notmatch 'basapos\.local' }
  Set-Content -Path $hosts -Value $content
}
Write-Host "BasaPOS appliance removed."
