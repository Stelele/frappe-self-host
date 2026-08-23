param([string]$Distro = "BasaPOS")
Write-Host "Stopping the BasaPOS appliance (data preserved)..."
& wsl.exe --terminate $Distro 2>$null
if ($LASTEXITCODE -eq 0) { Write-Host "Done." } else { Write-Host "The appliance is already stopped." }
