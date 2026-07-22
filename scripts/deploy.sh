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

# Allow shorthand DOMAIN=example.com if user doesn't want to write SITES_RULE syntax
SITES_RULE=""
if grep -q '^SITES_RULE=' "$ENV_FILE" 2>/dev/null; then
  SITES_RULE=$(grep '^SITES_RULE=' "$ENV_FILE" | head -1 | cut -d= -f2-)
elif grep -q '^DOMAIN=' "$ENV_FILE" 2>/dev/null; then
  DOMAIN=$(grep '^DOMAIN=' "$ENV_FILE" | cut -d= -f2)
  SITES_RULE="Host(\`$DOMAIN\`)"
fi

if [ -z "$SITES_RULE" ]; then
  echo "ERROR: Set SITES_RULE or DOMAIN in .env"
  echo "  SITES_RULE=Host(\`erpnext.example.com\`)"
  echo "  # or just:"
  echo "  DOMAIN=erpnext.example.com"
  exit 1
fi

export SITES_RULE

echo "Generating compose configuration..."
cd "$COMPOSE_DIR"

docker compose --env-file "$ENV_FILE" \
  -f compose.yaml \
  -f overrides/compose.mariadb.yaml \
  -f overrides/compose.redis.yaml \
  -f overrides/compose.proxy.yaml \
  -f overrides/compose.https.yaml \
  config > "$REPO_DIR/compose.custom.yaml"

echo "Starting all services (restart: unless-stopped is the default)..."
docker compose --env-file "$ENV_FILE" -f "$REPO_DIR/compose.custom.yaml" up -d

echo "Deploy complete."
echo "Next: scripts/create-site.sh <your-domain.com>
Or:  scripts/verify.sh"
