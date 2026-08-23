# Full uninstall cleanup for BasaPOS appliance. Wired into Inno Setup [UninstallRun].
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
