<#
  Drill phase 3/3: silent uninstall.
  Requires an install to exist on the SAME runner (from drill-install.ps1,
  optionally aged by drill-upgrade.ps1). Runs as its own CI step so failures
  attribute to UNINSTALL.
  Usage: drill-uninstall.ps1
#>
. (Join-Path $PSScriptRoot 'drill-common.ps1')
trap { Copy-CiLogs; Write-Host "DRILL DIED: $_"; exit 1 }

# Snapshot appliance logs BEFORE the uninstaller deletes {app}\logs -- if the
# drill dies anywhere in this phase, the artifacts still tell the story.
Copy-CiLogs
Write-Host '== 4. silent uninstall =='
$oldEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& taskkill /F /IM wsl.exe /T 2>$null
$ErrorActionPreference = $oldEap
Start-Sleep -Seconds 5
$unins = Get-ChildItem $AppDir -Filter 'unins*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
Check 'uninstaller present' ($null -ne $unins)
if ($unins) {
  # Bounded wait (drill-failure-catalog D2): the uninstaller runs
  # remove-basapos.ps1 -> wsl --unregister, which is known to hang on CI
  # runners. Kill + reap after 10 min instead of blocking forever.
  $p3 = Start-Process -FilePath $unins.FullName -ArgumentList '/SILENT','/SUPPRESSMSGBOXES',"/LOG=$env:RUNNER_TEMP\inno-uninstall.log" -PassThru
  $uninsKilled = -not $p3.WaitForExit(600000)
  if ($uninsKilled) {
    Write-Host '  [TIMEOUT] uninstaller did not exit in 10 min - killing'
    $p3 | Stop-Process -Force -ErrorAction SilentlyContinue
    $null = $p3.WaitForExit()
  }
  Start-Sleep -Seconds 5
}
$taskAfter = $null
$oldEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$taskAfter = (schtasks /query /tn BasaPOS-Appliance 2>&1) -join ''
$ErrorActionPreference = $oldEap
Check 'autostart task removed' (-not ("$taskAfter" -match 'BasaPOS-Appliance'))
Check 'hosts entry removed' (-not (Select-String -Path $HostsFile -Pattern 'basapos\.local' -Quiet))
Check 'VHD removed' (-not (Test-Path "$AppDir\data\distro\ext4.vhdx"))

Exit-Drill 'UNINSTALL'
