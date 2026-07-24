#!/usr/bin/env bash
set -euo pipefail
docker context use default 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
BACKUP_DIR="$REPO_DIR/backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

mkdir -p "$BACKUP_DIR"

echo "Backing up all sites..."
docker compose -f "$REPO_DIR/compose.custom.yaml" exec backend \
  bench --site all backup --with-files --backup-path "/home/frappe/frappe-bench/backups/$TIMESTAMP"

echo "Copying backup files to host..."
docker compose -f "$REPO_DIR/compose.custom.yaml" cp \
  "backend:/home/frappe/frappe-bench/backups/$TIMESTAMP" "$BACKUP_DIR/$TIMESTAMP"

echo "Backup saved to $BACKUP_DIR/$TIMESTAMP"
