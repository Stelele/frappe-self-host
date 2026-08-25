# Registers BasaPOS-Appliance scheduled task (Interactive, system startup, installing user).
# Interactive logon preserves the user's profile and environment — required for
# WSL access and file I/O in the boot-wrapper. S4U strips the profile and breaks both.
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
  -LogonType Interactive -RunLevel Highest

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
  -Principal $principal -Force | Out-Null
Write-Host "Registered $TaskName (logon type: $(if($LogonFallback){'AtLogOn'}else{'Interactive AtStartup'}))"
