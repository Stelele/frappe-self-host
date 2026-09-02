param([string]$SetupExe)
$ErrorActionPreference = 'Stop'
$env:WSL_UTF8 = '1'
Write-Host "=== drill: uninstall ==="
$p = Start-Process -FilePath $SetupExe -ArgumentList '--uninstall','--unattended' -Wait -PassThru -NoNewWindow
if ($p.ExitCode -ne 0) {
    Get-Content 'C:\ProgramData\BasaPOS\install.log' -ErrorAction SilentlyContinue | Select-Object -Last 40
    throw "uninstall exited $($p.ExitCode)"
}
Start-Sleep -Seconds 5
if ((wsl --list --quiet | Out-String) -match 'BasaPOS') { throw 'distro still registered' }
if ((Get-Content C:\Windows\System32\drivers\etc\hosts -Raw) -match '127\.0\.0\.1\s+basapos\.local') { throw 'hosts entry left' }
if (Get-ScheduledTask -TaskName 'BasaPOS-Appliance' -ErrorAction SilentlyContinue) { throw 'autostart task left' }
if (Test-Path C:\ProgramData\BasaPOS\boot.cmd) { throw 'boot.cmd left' }
if (Test-Path C:\BasaPOS\distro) { throw 'distro dir left' }
if (Test-Path C:\BasaPOS\config) { throw 'config dir left' }
$leftover = Get-ChildItem C:\BasaPOS -ErrorAction SilentlyContinue | Where-Object Name -ne 'backups'
if ($leftover) { throw "leftovers in C:\BasaPOS: $($leftover.Name -join ', ')" }
Write-Host 'DRILL UNINSTALL PASS'
