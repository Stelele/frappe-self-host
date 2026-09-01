param([string]$SetupExe)
$ErrorActionPreference = 'Stop'
Write-Host "=== drill: uninstall ==="
& $SetupExe --uninstall --unattended
if ($LASTEXITCODE -ne 0) {
    Get-Content "$env:TEMP\basapos-setup.log" -ErrorAction SilentlyContinue | Select-Object -Last 40
    throw "uninstall exited $LASTEXITCODE"
}
Start-Sleep -Seconds 5
if ((wsl --list --quiet | Out-String) -match 'BasaPOS') { throw 'distro still registered' }
if ((Get-Content C:\Windows\System32\drivers\etc\hosts -Raw) -match '127\.0\.0\.1\s+basapos\.local') { throw 'hosts entry left' }
schtasks /query /tn BasaPOS-Appliance *> $null
if ($LASTEXITCODE -eq 0) { throw 'autostart task left' }
if (Test-Path C:\ProgramData\BasaPOS\boot.cmd) { throw 'boot.cmd left' }
if (Test-Path C:\BasaPOS\distro) { throw 'distro dir left' }
if (Test-Path C:\BasaPOS\config) { throw 'config dir left' }
$leftover = Get-ChildItem C:\BasaPOS -ErrorAction SilentlyContinue | Where-Object Name -ne 'backups'
if ($leftover) { throw "leftovers in C:\BasaPOS: $($leftover.Name -join ', ')" }
Write-Host 'DRILL UNINSTALL PASS'
