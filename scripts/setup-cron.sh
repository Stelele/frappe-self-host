#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_SCRIPT="$SCRIPT_DIR/backup.sh"
CRON_SCHEDULE="0 */6 * * *"

echo "Adding backup cron job (every 6 hours)..."
(crontab -l 2>/dev/null | grep -v "$BACKUP_SCRIPT"; echo "$CRON_SCHEDULE $BACKUP_SCRIPT >> $SCRIPT_DIR/../backups/cron.log 2>&1") | crontab -

echo "Cron job installed."
crontab -l | grep "$BACKUP_SCRIPT"
