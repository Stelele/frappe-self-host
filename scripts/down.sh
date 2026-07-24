#!/usr/bin/env bash
set -euo pipefail
docker context use default 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
COMPOSE_FILE="$REPO_DIR/compose.custom.yaml"

if [ ! -f "$COMPOSE_FILE" ]; then
  echo "No compose.custom.yaml found — nothing to tear down."
  exit 0
fi

echo "Stopping and removing all containers, volumes, and networks..."
docker compose -f "$COMPOSE_FILE" down -v

echo "Done."
