#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
COMPOSE_FILE="$REPO_DIR/compose.custom.yaml"

PASS=0
FAIL=0

pass()  { PASS=$((PASS + 1)); echo "  [PASS] $1"; }
fail()  { FAIL=$((FAIL + 1)); echo "  [FAIL] $1"; }

echo ""
echo "=== Frappe Deploy: Verification ==="
echo ""

# 1. Docker installed and running
echo "--- Docker ---"
if docker info &>/dev/null; then
  pass "Docker is running ($(docker --version))"
else
  fail "Docker is not running"
fi

if docker buildx version &>/dev/null; then
  pass "BuildKit available"
else
  fail "BuildKit not available"
fi

# 2. Docker image exists
echo "--- Image ---"
if docker image inspect BasaPOS:16 &>/dev/null; then
  pass "BasaPOS image BasaPOS:16 exists"
  IMAGE_SIZE=$(docker image inspect BasaPOS:16 --format='{{.Size}}' | awk '{printf "%.1f MB", $1/1024/1024}')
  echo "       Size: $IMAGE_SIZE"
else
  fail "BasaPOS image BasaPOS:16 not found (run scripts/build.sh)"
fi

# 3. Compose file exists
echo "--- Configuration ---"
if [ -f "$COMPOSE_FILE" ]; then
  pass "compose.custom.yaml exists"
else
  fail "compose.custom.yaml not found (run scripts/deploy.sh)"
fi

# 4. Containers running
echo "--- Services ---"
if [ ! -f "$COMPOSE_FILE" ]; then
  fail "Cannot check services without compose.custom.yaml"
else
  for service in backend frontend websocket queue-short queue-long scheduler; do
    STATUS=$(docker compose -f "$COMPOSE_FILE" ps --status running --format '{{.Name}}' 2>/dev/null | grep -c "$service" || true)
    if [ "$STATUS" -ge 1 ]; then
      pass "Container '$service' is running"
    else
      fail "Container '$service' is not running"
    fi
  done

  # Check DB service (may be named mariadb-database)
  DB_STATUS=$(docker compose -f "$COMPOSE_FILE" ps --status running --format '{{.Name}}' 2>/dev/null | grep -c mariadb || true)
  if [ "$DB_STATUS" -ge 1 ]; then
    pass "Database (MariaDB) is running"
  else
    fail "Database (MariaDB) is not running"
  fi
fi

# 5. Summarize
echo "--- Summary ---"
TOTAL=$((PASS + FAIL))
echo "  $PASS / $TOTAL checks passed"
if [ "$FAIL" -gt 0 ]; then
  echo "  $FAIL checks failed — review issues above."
  exit 1
fi
echo "  All systems operational."
