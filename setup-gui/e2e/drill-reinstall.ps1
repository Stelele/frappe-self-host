param([string]$SetupExe, [string]$PayloadDir)
$ErrorActionPreference = 'Stop'
$env:WSL_UTF8 = '1'
Write-Host '=== drill: reinstall (uninstall -> install) ==='
$p1 = Start-Process -FilePath $SetupExe -ArgumentList '--install','--unattended','--payload',$PayloadDir -Wait -PassThru -NoNewWindow
if ($p1.ExitCode -ne 0) { throw "install #1 failed ($($p1.ExitCode))" }
$p2 = Start-Process -FilePath $SetupExe -ArgumentList '--uninstall','--unattended' -Wait -PassThru -NoNewWindow
if ($p2.ExitCode -ne 0) { throw "uninstall failed ($($p2.ExitCode))" }
$p3 = Start-Process -FilePath $SetupExe -ArgumentList '--install','--unattended','--payload',$PayloadDir -Wait -PassThru -NoNewWindow
if ($p3.ExitCode -ne 0) { throw "install #2 failed ($($p3.ExitCode))" }
if (-not ((wsl --list --quiet | Out-String) -match 'BasaPOS')) { throw 'distro missing after reinstall' }
$keepers = @(Get-Process -Name 'BasaPOS.Keeper' -ErrorAction SilentlyContinue)
if ($keepers.Count -ne 1) { throw "expected exactly 1 keeper after reinstall, found $($keepers.Count)" }
$kt = Get-ScheduledTask -TaskName 'BasaPOS-Keeper'
if ($kt.Triggers.Count -ne 2) { throw 'keeper task lost a trigger on reinstall' }
if ($kt.State -ne 'Running' -and $kt.State -ne 'Ready') { throw "unexpected keeper task state $($kt.State)" }
Write-Host 'DRILL REINSTALL PASS'
