param([string]$DistroTar)
$ErrorActionPreference = 'Stop'
# Firstboot convergence drill on REAL WSL2 (the production runtime): import the
# distro, let systemd auto-run firstboot, kill the whole VM mid-flight via
# `wsl --shutdown` (a truer power-cut than any container kill), reboot, and
# require convergence to `done` + an HTTP 200. Runs once per phase.
$phases = @('(boot)', 'loaded', 'env', 'stack', 'site', 'cert', 'booted', 'done')
$tar = (Resolve-Path $DistroTar).Path

function Wait-Sentinel([string]$phase, [int]$maxSec) {
    $deadline = (Get-Date).AddSeconds($maxSec)
    while ((Get-Date) -lt $deadline) {
        wsl -d BasaPOS -- test -f "/var/lib/basapos/firstboot/$phase" 2>$null
        if ($LASTEXITCODE -eq 0) { return $true }
        Start-Sleep -Seconds 5
    }
    return $false
}

function Wait-Healthy([int]$maxSec) {
    $deadline = (Get-Date).AddSeconds($maxSec)
    while ((Get-Date) -lt $deadline) {
        $code = (wsl -d BasaPOS -- curl -sk -o /dev/null -w '%{http_code}' --resolve basapos.local:443:127.0.0.1 https://basapos.local/api/method/ping 2>$null)
        if ("$code".Trim() -eq '200') { return $true }
        Start-Sleep -Seconds 5
    }
    return $false
}

foreach ($p in $phases) {
    Write-Host "=== drill: power-cut during/after: $p ==="
    $t0 = Get-Date

    wsl --unregister BasaPOS 2>$null | Out-Null
    $dir = 'C:\basapos-drill\instance'
    if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    foreach ($d in @('C:\BasaPOS\config', 'C:\BasaPOS\logs', 'C:\BasaPOS\backups')) {
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        Get-ChildItem $d -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
    Set-Content -Path 'C:\BasaPOS\config\install-password.txt' -Value 'InstallPassword123!' -NoNewline
    Set-Content -Path 'C:\BasaPOS\config\credentials.txt' -Value ''

    wsl --import BasaPOS $dir $tar --version 2
    if ($LASTEXITCODE -ne 0) { throw 'wsl --import failed' }
    wsl -d BasaPOS --exec /bin/true   # boot: systemd auto-starts firstboot

    if ($p -ne '(boot)') {
        if (-not (Wait-Sentinel $p 2700)) {
            wsl -d BasaPOS -- tail -50 /var/log/basapos-firstboot.log 2>$null
            throw "sentinel $p never appeared"
        }
        $delay = Get-Random -Minimum 30 -Maximum 180
    } else {
        $delay = Get-Random -Minimum 30 -Maximum 150
    }
    Write-Host "  power-cut in ${delay}s"
    Start-Sleep -Seconds $delay
    wsl --shutdown        # true power cut: VM + dockerd + containers die
    Start-Sleep -Seconds 5
    wsl -d BasaPOS --exec /bin/true   # reboot; sentinels skip completed phases

    if (-not (Wait-Sentinel 'done' 2400)) {
        wsl -d BasaPOS -- tail -60 /var/log/basapos-firstboot.log 2>$null
        throw "never converged after power-cut at $p"
    }
    if (-not (Wait-Healthy 300)) {
        wsl -d BasaPOS -- sh -c 'docker ps --format "{{.Names}} {{.Status}}"' 2>$null
        throw "done sentinel set but site unhealthy after power-cut at $p"
    }
    Write-Host ("OK: converged after power-cut at {0} ({1:n0}s)" -f $p, ((Get-Date) - $t0).TotalSeconds)
}

# backup timer smoke
wsl -d BasaPOS -u root -- systemctl start basapos-backup.service
Start-Sleep -Seconds 60
if (-not (Get-ChildItem 'C:\BasaPOS\backups' -Filter '20*' -ErrorAction SilentlyContinue)) {
    wsl -d BasaPOS -- sh -c 'journalctl -u basapos-backup.service --no-pager | tail -30' 2>$null
    throw 'backup did not land in C:\BasaPOS\backups'
}

wsl --unregister BasaPOS 2>$null | Out-Null
Remove-Item 'C:\basapos-drill' -Recurse -Force -ErrorAction SilentlyContinue
Write-Host 'FIRSTBOOT DRILL PASS (real WSL2)'
