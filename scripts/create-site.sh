#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$REPO_DIR/.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: .env file not found at $ENV_FILE"
  exit 1
fi

source "$ENV_FILE"

SITE_NAME="${1:-}"
if [ -z "$SITE_NAME" ]; then
  echo "Usage: $0 <site-name>"
  echo ""
  echo "Examples:"
  echo "  $0 basapos.local          # offline (.local /etc/hosts)"
  echo "  $0 erpnext.example.com    # online (real domain)"
  exit 1
fi

echo "Creating site $SITE_NAME..."

docker compose -f "$REPO_DIR/compose.custom.yaml" exec backend \
  bench new-site \
    --mariadb-user-host-login-scope=% \
    --db-root-password "$DB_PASSWORD" \
    --install-app erpnext \
    --admin-password "${ADMIN_PASSWORD:-admin}" \
    "$SITE_NAME"

echo ""
echo "Install additional apps if needed:"
echo "  docker compose -f compose.custom.yaml exec backend bench --site $SITE_NAME install-app <app-name>"
