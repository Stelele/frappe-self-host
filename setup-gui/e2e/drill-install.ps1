param([string]$SetupExe, [string]$PayloadDir)
$ErrorActionPreference = 'Stop'
Write-Host "=== drill: install ($SetupExe, payload $PayloadDir) ==="
# WinExe (GUI subsystem) processes return immediately from the call operator —
# must Start-Process -Wait or the drill races the installer
$p = Start-Process -FilePath $SetupExe -ArgumentList '--install','--unattended','--payload',$PayloadDir -Wait -PassThru -NoNewWindow
if ($p.ExitCode -ne 0) {
    Get-Content 'C:\BasaPOS\logs\install.log' -ErrorAction SilentlyContinue | Select-Object -Last 40
    throw "setup exited $($p.ExitCode)"
}
# assertions
if (-not ((wsl --list --quiet | Out-String) -match 'BasaPOS')) { throw 'distro missing' }
if (-not ((Get-Content C:\Windows\System32\drivers\etc\hosts -Raw) -match 'basapos\.local')) { throw 'hosts entry missing' }
if (-not (Test-Path C:\BasaPOS\config\credentials.txt)) { throw 'credentials missing' }
if (-not (Test-Path C:\BasaPOS\config\basapos.crt))     { throw 'cert not exported' }
if (-not (Test-Path C:\BasaPOS\config\version.txt))     { throw 'version.txt missing' }
schtasks /query /tn BasaPOS-Appliance *> $null
if ($LASTEXITCODE -ne 0) { throw 'autostart task missing' }
if (-not (Test-Path C:\ProgramData\BasaPOS\boot.cmd))   { throw 'boot.cmd missing' }
$logFile = 'C:\BasaPOS\logs\install.log'
$log = Get-Content $logFile -Raw -ErrorAction SilentlyContinue
if ($log -notmatch 'DONE password=') { throw 'no DONE marker in setup log' }
Write-Host 'DRILL INSTALL PASS'
