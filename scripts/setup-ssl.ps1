#!/usr/bin/env pwsh
param()

docker context use default 2>$null

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoDir = Split-Path -Parent $ScriptDir
$EnvFile = "$RepoDir/.env"

if (-not (Test-Path $EnvFile)) {
  Write-Error ".env file not found"
  exit 1
}

$envVars = @{}
Get-Content $EnvFile | ForEach-Object {
  if ($_ -match '^([^#=]+)=(.*)$') {
    $envVars[$matches[1].Trim()] = $matches[2].Trim()
  }
}

$domain = $envVars['DOMAIN']
if (-not $domain) {
  Write-Error "DOMAIN not set in .env"
  exit 1
}

$certsDir = "$RepoDir/certs"
$certFile = "$certsDir/cert.pem"
$keyFile = "$certsDir/key.pem"
$dynamicFile = "$certsDir/dynamic.yml"

New-Item -ItemType Directory -Force -Path $certsDir | Out-Null

if ((Test-Path $certFile) -and (Test-Path $keyFile)) {
  Write-Host "Certificate already exists for $domain"
} else {
  $mkcert = Get-Command mkcert -ErrorAction SilentlyContinue
  if ($mkcert) {
    Write-Host "Generating locally-trusted certificate using mkcert..."
    & mkcert -install 2>&1 | Select-Object -Last 1
    & mkcert -cert-file $certFile -key-file $keyFile $domain 2>&1 | Select-Object -Last 1
  } else {
    Write-Host "mkcert not found — generating self-signed certificate (browser will show warning)..."
    $openssl = Get-Command openssl -ErrorAction SilentlyContinue
    if ($openssl) {
      & $openssl.Source req -x509 -nodes -days 3650 -newkey rsa:2048 `
        -keyout $keyFile -out $certFile `
        -subj "/CN=$domain" `
        -addext "subjectAltName=DNS:$domain" 2>$null
    } else {
      # Fallback using .NET cert generation
      $cert = New-SelfSignedCertificate -DnsName $domain -CertStoreLocation Cert:\CurrentUser\My -NotAfter (Get-Date).AddDays(3650)
      $certPath = "Cert:\CurrentUser\My\$($cert.Thumbprint)"
      Export-Certificate -Cert $certPath -FilePath $certFile -Type CERT 2>$null
      $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
      $keyBytes = $rsa.ExportPkcs8PrivateKey()
      [System.IO.File]::WriteAllBytes($keyFile, $keyBytes)
      Remove-Item $certPath
    }
  }
  Write-Host "  cert: $certFile"
  Write-Host "  key:  $keyFile"
}

@"
tls:
  certificates:
    - certFile: /certs/cert.pem
      keyFile: /certs/key.pem
"@ | Out-File -FilePath $dynamicFile -Encoding utf8

Write-Host "  dynamic: $dynamicFile"
