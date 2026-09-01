param([string]$SetupExe, [string]$PayloadDir)
$ErrorActionPreference = 'Stop'
Write-Host '=== drill: reinstall (uninstall -> install) ==='
& $SetupExe --install --unattended --payload $PayloadDir
if ($LASTEXITCODE -ne 0) { throw "install #1 failed ($LASTEXITCODE)" }
& $SetupExe --uninstall --unattended
if ($LASTEXITCODE -ne 0) { throw "uninstall failed ($LASTEXITCODE)" }
& $SetupExe --install --unattended --payload $PayloadDir
if ($LASTEXITCODE -ne 0) { throw "install #2 failed ($LASTEXITCODE)" }
if (-not ((wsl --list --quiet | Out-String) -match 'BasaPOS')) { throw 'distro missing after reinstall' }
Write-Host 'DRILL REINSTALL PASS'
