#!/usr/bin/env bash
set -euo pipefail
docker context use default 2>/dev/null || true

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

# Read installed apps from the image's apps.txt (excludes frappe, includes erpnext and custom apps)
INSTALL_APPS_LIST=$(docker compose -f "$REPO_DIR/compose.custom.yaml" exec backend \
  cat /home/frappe/frappe-bench/sites/apps.txt 2>/dev/null \
  | grep -v '^frappe$' \
  | tr '\n' ' ')
INSTALL_APPS_LIST="${INSTALL_APPS_LIST%% }"
if [ -z "$INSTALL_APPS_LIST" ]; then
  echo "ERROR: Could not read apps.txt from backend container"
  exit 1
fi

# Build repeated --install-app flags
INSTALL_APP_FLAGS=""
for app in $INSTALL_APPS_LIST; do
  INSTALL_APP_FLAGS="$INSTALL_APP_FLAGS --install-app $app"
done

echo "Creating site $SITE_NAME with apps: $INSTALL_APPS_LIST..."

docker compose -f "$REPO_DIR/compose.custom.yaml" exec backend \
  bench new-site \
    --mariadb-user-host-login-scope=% \
    --db-root-password "$DB_PASSWORD" \
    $INSTALL_APP_FLAGS \
    --admin-password "${ADMIN_PASSWORD:-admin}" \
    "$SITE_NAME"

echo ""
echo "Running patches and migrations..."
docker compose -f "$REPO_DIR/compose.custom.yaml" exec backend \
  bench --site "$SITE_NAME" migrate

echo ""
echo "Building frontend assets..."
docker compose -f "$REPO_DIR/compose.custom.yaml" exec backend \
  bench --site "$SITE_NAME" build

echo ""
echo "Syncing assets to frontend..."
docker compose -f "$REPO_DIR/compose.custom.yaml" exec backend \
  tar -chf - --exclude='node_modules' -C /home/frappe/frappe-bench assets \
  | docker compose -f "$REPO_DIR/compose.custom.yaml" exec -T frontend \
  tar -xf - -C /home/frappe/frappe-bench
