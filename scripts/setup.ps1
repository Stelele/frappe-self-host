#!/usr/bin/env pwsh
param(
  [ValidateSet("docker", "check")]
  [string]$Command = "docker"
)

docker context use default 2>$null

Write-Host "=== Frappe Docker: Prerequisites Setup ==="
Write-Host ""

function Install-Docker {
  Write-Host ">>> Installing Docker Desktop for Windows..."

  $existing = Get-Command docker -ErrorAction SilentlyContinue
  if ($existing) {
    $version = docker --version
    Write-Host "Docker already installed ($version)"
    return
  }

  Write-Host "Downloading Docker Desktop installer..."
  $installer = "$env:TEMP\DockerDesktopInstaller.exe"
  Invoke-WebRequest -Uri "https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe" -OutFile $installer

  Write-Host "Running installer (requires admin)..."
  Start-Process -Wait -FilePath $installer -ArgumentList "install --quiet"

  Remove-Item $installer -Force

  Write-Host "Docker Desktop installed. Reboot may be required."
}

function Check-DockerVersion {
  Write-Host ">>> Checking Docker version..."

  try {
    $version = docker version --format '{{.Server.Version}}'
    $major = $version.Split('.')[0] -as [int]
    if ($major -ge 23) {
      Write-Host "Docker $version — meets the v23.0+ requirement."
    } else {
      Write-Host "Docker $version — too old. Upgrade to v23.0+ for BuildKit support."
    }
  } catch {
    Write-Host "Docker not found or not running."
  }
}

function Check-BuildKit {
  Write-Host ">>> Checking BuildKit (Docker Buildx)..."
  try {
    $bx = docker buildx version
    Write-Host "Buildx available: $bx"
  } catch {
    Write-Host "Buildx not found. Install Docker 23.0+ or enable BuildKit."
  }
}

switch ($Command) {
  "docker" {
    Install-Docker
  }
  "check" {
    Check-DockerVersion
    Check-BuildKit
  }
}

Write-Host ""
Write-Host "=== Done ==="
