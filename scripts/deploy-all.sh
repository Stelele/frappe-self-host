#!/usr/bin/env bash
set -euo pipefail
docker context use default 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ""
echo "=== BasaPOS Frappe Deploy: Full Pipeline ==="
echo ""

echo ">>> Step 1: Prerequisites"
bash "$SCRIPT_DIR/setup.sh"

echo ""
echo ">>> Step 2: Build Docker image"
bash "$SCRIPT_DIR/build.sh"

echo ""
echo ">>> Step 3: Deploy stack"
bash "$SCRIPT_DIR/deploy.sh"

echo ""
echo ">>> Step 4: Verify"
bash "$SCRIPT_DIR/verify.sh"

SITE_NAME="${1:-basapos.local}"

echo ""
echo ">>> Step 5: Create site ($SITE_NAME)"
bash "$SCRIPT_DIR/create-site.sh" "$SITE_NAME"

echo ""
echo "=== All done! ==="
