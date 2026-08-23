# Registers BasaPOS-Appliance scheduled task (S4U, system startup, installing user).
# Use -LogonFallback on systems where S4U AtStartup is unavailable/restricted.
param(
  [Parameter(Mandatory=$true)][string]$InstallRoot,
  [switch]$LogonFallback
)
$ErrorActionPreference = "Stop"
$TaskName = "BasaPOS-Appliance"
$wrapper = Join-Path $InstallRoot "payload\install\boot-wrapper.ps1"
$arg = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$wrapper`""

$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $arg
if ($LogonFallback) {
  $trigger = New-ScheduledTaskTrigger -AtLogOn
} else {
  $trigger = New-ScheduledTaskTrigger -AtStartup
  $trigger.Delay = "PT30S"
}
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
  -LogonType S4U -RunLevel Highest

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
  -Principal $principal -Force | Out-Null
Write-Host "Registered $TaskName (logon type: $(if($LogonFallback){'AtLogOn'}else{'S4U AtStartup'}))"
