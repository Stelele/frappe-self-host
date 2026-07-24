#!/usr/bin/env bash
set -euo pipefail
docker context use default 2>/dev/null || true

echo "=== Frappe Docker: Prerequisites Setup ==="
echo ""

detect_distro() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    echo "$ID"
  else
    echo "unknown"
  fi
}

install_docker() {
  echo ">>> Installing Docker Engine..."

  if command -v docker &>/dev/null; then
    echo "Docker already installed ($(docker --version))"
    return
  fi

  curl -fsSL https://get.docker.com | bash

  sudo usermod -aG docker "$USER"

  echo "Docker installed. You'll need to log out and back in for group changes to take effect."
}

install_docker_compose() {
  echo ">>> Checking Docker Compose..."

  if docker compose version &>/dev/null; then
    echo "Docker Compose already installed ($(docker compose version))"
    return
  fi

  echo "Docker Compose v2 is included with Docker Engine 23.0+."
  echo "If you're on an older version, upgrade Docker:"
  echo "  curl -fsSL https://get.docker.com | bash"
}

check_docker_version() {
  echo ">>> Checking Docker version..."

  if ! command -v docker &>/dev/null; then
    echo "Docker not found. Run the install step above."
    return
  fi

  DOCKER_VERSION=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "0")
  MAJOR=$(echo "$DOCKER_VERSION" | cut -d. -f1)

  if [ "$MAJOR" -ge 23 ]; then
    echo "Docker $DOCKER_VERSION — meets the v23.0+ requirement."
  else
    echo "Docker $DOCKER_VERSION — too old. Upgrade to v23.0+ for BuildKit support."
  fi
}

check_buildkit() {
  echo ">>> Checking BuildKit (Docker Buildx)..."

  if docker buildx version &>/dev/null; then
    echo "Buildx available: $(docker buildx version)"
  else
    echo "Buildx not found. Install Docker 23.0+ or enable BuildKit."
  fi
}

echo "Detected OS: $(detect_distro)"
echo ""

case "${1:-all}" in
  docker|all)
    install_docker
    install_docker_compose
    ;;
  check|verify)
    check_docker_version
    check_buildkit
    ;;
  *)
    echo "Usage: $0 {docker|check}"
    echo "  $0          — install Docker + Compose"
    echo "  $0 check    — verify prerequisites"
    exit 1
    ;;
esac

echo ""
echo "=== Done ==="
