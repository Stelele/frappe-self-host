#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

ENV_FILE="$REPO_DIR/.env"
COMPOSE_DIR="$REPO_DIR/frappe_docker"

if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: .env file not found at $ENV_FILE"
  echo "Copy .env.example to .env and fill in your values."
  exit 1
fi

echo "Generating compose configuration..."
cd "$COMPOSE_DIR"

docker compose --env-file "$ENV_FILE" \
  -f compose.yaml \
  -f overrides/compose.mariadb.yaml \
  -f overrides/compose.redis.yaml \
  -f overrides/compose.proxy.yaml \
  -f overrides/compose.https.yaml \
  config > "$REPO_DIR/compose.custom.yaml"

echo "Starting all services..."
docker compose --env-file "$ENV_FILE" -f "$REPO_DIR/compose.custom.yaml" up -d

echo "Deploy complete. Run scripts/create-site.sh to create your first site."
