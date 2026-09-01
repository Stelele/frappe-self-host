param([string]$SetupExe, [string]$PayloadDir)
$ErrorActionPreference = 'Stop'
Write-Host "=== drill: install ($SetupExe, payload $PayloadDir) ==="
& $SetupExe --install --unattended --payload $PayloadDir
if ($LASTEXITCODE -ne 0) {
    Get-Content "$env:TEMP\basapos-setup.log" -ErrorAction SilentlyContinue | Select-Object -Last 40
    throw "setup exited $LASTEXITCODE"
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
$log = Get-Content "$env:TEMP\basapos-setup.log" -Raw
if ($log -notmatch 'DONE password=') { throw 'no DONE marker in setup log' }
Write-Host 'DRILL INSTALL PASS'
