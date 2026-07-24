#!/usr/bin/env bash
set -euo pipefail
docker context use default 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
BACKUP_FILE="${1:-}"

if [ -z "$BACKUP_FILE" ]; then
  echo "Usage: $0 <path-to-backup-file.sql>"
  echo "Backups are stored in $REPO_DIR/backups/"
  exit 1
fi

source "$REPO_DIR/.env"

BACKUP_FILENAME=$(basename "$BACKUP_FILE")
SITE_NAME="${BACKUP_FILENAME%%-*}"
PRIVATE_FILE="${BACKUP_FILE%.sql}-files.tar"
COMPOSE_FILE="$REPO_DIR/compose.custom.yaml"

echo "Restoring site $SITE_NAME from $BACKUP_FILE..."

docker compose -f "$COMPOSE_FILE" cp "$BACKUP_FILE" "backend:/tmp/$BACKUP_FILENAME"

docker compose -f "$COMPOSE_FILE" exec backend \
  bench --site "$SITE_NAME" restore "/tmp/$BACKUP_FILENAME" --db-root-password "$DB_PASSWORD"

if [ -f "$PRIVATE_FILE" ]; then
  echo "Restoring private files..."
  docker compose -f "$COMPOSE_FILE" cp "$PRIVATE_FILE" "backend:/tmp/$(basename $PRIVATE_FILE)"
  docker compose -f "$COMPOSE_FILE" exec backend \
    tar -xf "/tmp/$(basename $PRIVATE_FILE)" -C "/home/frappe/frappe-bench/sites/"
fi

echo "Restore complete."
