param([string]$PartsDir, [string]$OutFile)
$ErrorActionPreference = 'Stop'
# stitch multi-part distro tarball + verify against SHA256SUMS (GUI equivalent
# of PartStitcher — used by CI drills)
$sums = @{}
Get-Content (Join-Path $PartsDir 'SHA256SUMS') | ForEach-Object {
    $b = $_ -split '\s+', 2
    if ($b.Count -eq 2) { $sums[$b[1].Trim().TrimStart('*')] = $b[0].ToLower() }
}
if (-not $sums.ContainsKey('basapos-distro.tar.gz')) { throw 'SHA256SUMS missing basapos-distro.tar.gz entry' }

$parts = Get-ChildItem $PartsDir -Filter 'basapos-distro.tar.part-*' | Sort-Object Name
if ($parts.Count -eq 0) { throw "no parts found in $PartsDir" }

$outPath = Join-Path (Get-Location) $OutFile
$out = [IO.File]::Create($outPath)
try {
    foreach ($p in $parts) {
        $in = [IO.File]::OpenRead($p.FullName)
        $in.CopyTo($out)
        $in.Close()
    }
} finally { $out.Close() }

$hash = (Get-FileHash $outPath -Algorithm SHA256).Hash.ToLower()
if ($hash -ne $sums['basapos-distro.tar.gz']) {
    throw "stitch hash mismatch: expected $($sums['basapos-distro.tar.gz']), got $hash"
}
Write-Host "STITCH_OK $outPath ($hash)"
