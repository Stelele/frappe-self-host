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

# Ensure PULL_POLICY is set (use local image, not pull from registry)
if ! grep -q '^PULL_POLICY=' "$ENV_FILE" 2>/dev/null; then
  echo "PULL_POLICY=missing" >> "$ENV_FILE"
fi

# Read OFFLINE flag
OFFLINE=""
if grep -q '^OFFLINE=true' "$ENV_FILE" 2>/dev/null; then
  OFFLINE=true
fi

# Derive SITES_RULE from DOMAIN shorthand
SITES_RULE=""
if grep -q '^SITES_RULE=' "$ENV_FILE" 2>/dev/null; then
  SITES_RULE=$(grep '^SITES_RULE=' "$ENV_FILE" | head -1 | cut -d= -f2-)
elif grep -q '^DOMAIN=' "$ENV_FILE" 2>/dev/null; then
  DOMAIN=$(grep '^DOMAIN=' "$ENV_FILE" | cut -d= -f2)
  SITES_RULE="Host(\`$DOMAIN\`)"
fi

if [ -z "$SITES_RULE" ]; then
  echo "ERROR: Set DOMAIN or SITES_RULE in .env"
  exit 1
fi

export SITES_RULE

echo "Generating compose configuration..."
cd "$COMPOSE_DIR"

COMPOSE_FILES="-f compose.yaml -f overrides/compose.mariadb.yaml -f overrides/compose.redis.yaml -f overrides/compose.proxy.yaml"

if [ "$OFFLINE" = true ]; then
  echo "Mode: OFFLINE — HTTP only (no SSL)"
  # Auto-add .local domain to /etc/hosts for offline access
  DOMAIN=$(grep '^DOMAIN=' "$ENV_FILE" | cut -d= -f2)
  if echo "$DOMAIN" | grep -q '\.local$' 2>/dev/null; then
    if ! grep -qi "127.0.0.1.*$DOMAIN" /etc/hosts 2>/dev/null; then
      echo "Adding $DOMAIN to /etc/hosts (requires sudo)..."
      sudo tee -a /etc/hosts > /dev/null <<< "127.0.0.1 $DOMAIN" 2>/dev/null && echo "  Added $DOMAIN to /etc/hosts" || echo "  Could not add to /etc/hosts — run: sudo tee -a /etc/hosts <<< \"127.0.0.1 $DOMAIN\""
    fi
  fi
else
  echo "Mode: ONLINE — HTTPS with Let's Encrypt"
  COMPOSE_FILES="$COMPOSE_FILES -f overrides/compose.https.yaml"
fi

# shellcheck disable=SC2086
docker compose --env-file "$ENV_FILE" $COMPOSE_FILES config > "$REPO_DIR/compose.custom.yaml"

echo "Starting all services..."
docker compose --env-file "$ENV_FILE" -f "$REPO_DIR/compose.custom.yaml" up -d

# On first deploy, DB needs time to init before configurator can run.
# Ensure all Frappe services come up even if configurator's initial attempt timed out.
echo "Waiting for DB health check, then ensuring all services start..."
sleep 15
docker compose -f "$REPO_DIR/compose.custom.yaml" start configurator 2>/dev/null || true
sleep 10
docker compose -f "$REPO_DIR/compose.custom.yaml" start backend frontend websocket queue-short queue-long scheduler 2>/dev/null || true

echo "Deploy complete."
echo "Next: scripts/create-site.sh <your-domain>
Or:  scripts/verify.sh"
