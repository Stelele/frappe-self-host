#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

cd "$REPO_DIR/frappe_docker"

echo "Building basapos Frappe v16 image with apps from ../apps.json..."

docker build \
  --build-arg=FRAPPE_PATH=https://github.com/frappe/frappe \
  --build-arg=FRAPPE_BRANCH=version-16 \
  --build-arg=CACHE_BUST="$(date +%s)" \
  --secret=id=apps_json,src=../apps.json \
  --tag=basapos:16 \
  --file=images/layered/Containerfile .

echo "Build complete: basapos:16"
