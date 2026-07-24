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

# Extract all app names from apps.json (excluding frappe itself)
INSTALL_APPS="erpnext"
if [ -f "$REPO_DIR/apps.json" ]; then
  ALL_APPS=$(python3 -c "
import json
with open('$REPO_DIR/apps.json') as f:
    apps = json.load(f)
names = [a['url'].split('/')[-1] for a in apps if a['url'].split('/')[-1] not in ('frappe', 'erpnext')]
print(' '.join(names))
" 2>/dev/null) || ALL_APPS=""
  if [ -n "$ALL_APPS" ]; then
    INSTALL_APPS="$INSTALL_APPS $ALL_APPS"
  fi
fi

echo "Creating site $SITE_NAME with apps: $INSTALL_APPS..."

docker compose -f "$REPO_DIR/compose.custom.yaml" exec backend \
  bench new-site \
    --mariadb-user-host-login-scope=% \
    --db-root-password "$DB_PASSWORD" \
    --install-app $INSTALL_APPS \
    --admin-password "${ADMIN_PASSWORD:-admin}" \
    "$SITE_NAME"
