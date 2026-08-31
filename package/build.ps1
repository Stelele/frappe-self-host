<#
  Assembles the installer payload and compiles BasaPOS-Setup.exe (Windows only).
  Usage from repo root:
    powershell -File package\build.ps1 [-RootfsTar path] [-WslMsi path] [-IsccPath path] [-Version x.y.z]
  Defaults:
    -RootfsTar appliance\dist\basapos-rootfs.tar.gz
    -WslMsi    package\wsl\wsl.msi   (download once, never commit)
    -IsccPath  discovered from standard install locations
#>
param(
  [string]$RootfsTar = '',
  [string]$WslMsi = '',
  [string]$IsccPath = '',
  [string]$Version = '0.1.0'
)
$ErrorActionPreference = 'Stop'
$Pkg = $PSScriptRoot
$Build = Join-Path $Pkg 'build'
$Payload = Join-Path $Build 'payload'

if (-not $RootfsTar) { $RootfsTar = Join-Path $Pkg '..\appliance\dist\basapos-rootfs.tar.gz' }
if (-not $WslMsi) { $WslMsi = Join-Path $Pkg 'wsl\wsl.msi' }
foreach ($req in @($RootfsTar, $WslMsi)) {
  if (-not (Test-Path $req)) { throw "required input missing: $req" }
}

Write-Host '== 1/4 publishing launcher =='
$pub = Join-Path $Build 'launcher-publish'
& dotnet publish (Join-Path $Pkg 'launcher\BasaPOS.csproj') -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:Version=$Version -o $pub
if ($LASTEXITCODE -ne 0) { throw 'launcher publish failed' }

Write-Host '== 2/4 staging payload =='
Remove-Item $Payload -Recurse -Force -ErrorAction SilentlyContinue
foreach ($d in @('rootfs','wsl','install','app')) {
  New-Item -ItemType Directory -Force -Path (Join-Path $Payload $d) | Out-Null
}
Copy-Item (Join-Path $pub 'BasaPOS.exe') (Join-Path $Payload 'BasaPOS.exe') -Force
Copy-Item $RootfsTar (Join-Path $Payload 'rootfs\basapos-rootfs.tar.gz') -Force
Copy-Item $WslMsi (Join-Path $Payload 'wsl\wsl.msi') -Force
Copy-Item (Join-Path $Pkg 'payload\install\*') (Join-Path $Payload 'install') -Recurse -Force
Remove-Item (Join-Path $Payload 'install\lib\.gitkeep') -Force -ErrorAction SilentlyContinue
Copy-Item (Join-Path $Pkg 'payload\app\*') (Join-Path $Payload 'app') -Recurse -Force
Copy-Item (Join-Path $Pkg 'payload\app\settings.template.txt') (Join-Path $Payload 'app\settings.txt') -Force

Write-Host '== 3/4 locating ISCC =='
if (-not $IsccPath) {
  $candidates = @(
    (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
    (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe')
  )
  $cmd = Get-Command iscc.exe -ErrorAction SilentlyContinue
  if ($cmd) { $candidates += $cmd.Source }
  foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { $IsccPath = $c; break } }
}
if (-not ($IsccPath -and (Test-Path $IsccPath))) { throw 'ISCC.exe not found; pass -IsccPath' }

Write-Host '== 4/4 compiling installer =='
Push-Location $Pkg
try {
  & $IsccPath "/DMyAppVersion=$Version" (Join-Path $Pkg 'BasaPOS.iss')
  if ($LASTEXITCODE -ne 0) { throw "ISCC failed (exit $LASTEXITCODE)" }
} finally { Pop-Location }

$out = Join-Path $Build ('output\BasaPOS-Setup-' + $Version + '.exe')
if (-not (Test-Path $out)) { throw "expected output not found: $out" }
$size = (Get-Item $out).Length
# GitHub release assets have a hard 2 GiB (2147483648 byte) limit. Fail at
# BUILD time (not release time) if we'd exceed it.
if ($size -ge 2147483648) {
  throw ("Installer is {0:N2} GiB — exceeds GitHub's 2 GiB release-asset limit. " -f ($size / 1GB) +
         "Shrink the rootfs (gzip -9, clear build caches in provision.sh hygiene).")
}
Write-Host ("Done. Installer: {0} ({1:N2} GB)" -f $out, ($size / 1GB))
