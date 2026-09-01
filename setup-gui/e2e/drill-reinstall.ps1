param([string]$SetupExe, [string]$PayloadDir)
$ErrorActionPreference = 'Stop'
Write-Host '=== drill: reinstall (uninstall -> install) ==='
$p1 = Start-Process -FilePath $SetupExe -ArgumentList '--install','--unattended','--payload',$PayloadDir -Wait -PassThru -NoNewWindow
if ($p1.ExitCode -ne 0) { throw "install #1 failed ($($p1.ExitCode))" }
$p2 = Start-Process -FilePath $SetupExe -ArgumentList '--uninstall','--unattended' -Wait -PassThru -NoNewWindow
if ($p2.ExitCode -ne 0) { throw "uninstall failed ($($p2.ExitCode))" }
$p3 = Start-Process -FilePath $SetupExe -ArgumentList '--install','--unattended','--payload',$PayloadDir -Wait -PassThru -NoNewWindow
if ($p3.ExitCode -ne 0) { throw "install #2 failed ($($p3.ExitCode))" }
if (-not ((wsl --list --quiet | Out-String) -match 'BasaPOS')) { throw 'distro missing after reinstall' }
Write-Host 'DRILL REINSTALL PASS'
