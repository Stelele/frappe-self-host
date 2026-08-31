#!/usr/bin/env bash
# Generate the final compose file from the shared frappe_docker chain.
# Usage: gen-compose.sh <out-dir> [--rewrite FROM=TO]
#   <out-dir>  receives compose.final.yaml. The dir MUST have a certs/ sibling
#              (../certs is baked into the config by the selfsigned override).
#   --rewrite  sed the generated file, replacing absolute path prefix FROM with
#              TO (used to map CI staging paths onto in-distro /opt/basapos).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$REPO_DIR/.env"
COMPOSE_DIR="$REPO_DIR/frappe_docker"

OUT_DIR=""
REWRITE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --rewrite) REWRITE="$2"; shift 2 ;;
    *) OUT_DIR="$1"; shift ;;
  esac
done
[ -n "$OUT_DIR" ] || { echo "usage: $0 <out-dir> [--rewrite FROM=TO]"; exit 1; }
[ -f "$ENV_FILE" ] || { echo "ERROR: .env not found at $ENV_FILE"; exit 1; }

OFFLINE=""
grep -q '^OFFLINE=true' "$ENV_FILE" && OFFLINE=true

SITES_RULE=""
# keep in sync with deploy.sh
if grep -q '^SITES_RULE=' "$ENV_FILE" 2>/dev/null; then
  SITES_RULE=$(grep '^SITES_RULE=' "$ENV_FILE" | head -1 | cut -d= -f2-)
elif grep -q '^DOMAIN=' "$ENV_FILE" 2>/dev/null; then
  DOMAIN=$(grep '^DOMAIN=' "$ENV_FILE" | cut -d= -f2)
  SITES_RULE="Host(\`$DOMAIN\`)"
fi
[ -n "$SITES_RULE" ] || { echo "ERROR: set DOMAIN or SITES_RULE in .env"; exit 1; }
export SITES_RULE

COMPOSE_FILES="-f compose.yaml -f overrides/compose.mariadb.yaml -f overrides/compose.redis.yaml -f overrides/compose.proxy.yaml"
if [ "$OFFLINE" = true ]; then
  COMPOSE_FILES="$COMPOSE_FILES -f ../overrides/compose.selfsigned.yaml"
else
  COMPOSE_FILES="$COMPOSE_FILES -f overrides/compose.https.yaml"
fi

# canonicalize OUT_DIR before we cd (relative paths would straddle two CWDs)
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
TMP_OUT="$OUT_DIR/.compose.final.yaml.tmp"
trap 'rm -f "$TMP_OUT"' EXIT
cd "$COMPOSE_DIR"
# --project-directory "$OUT_DIR" rebinds relative bind sources (../certs),
# the baked project name, AND all volume/network names to OUT_DIR's basename:
#   Linux   (OUT=frappe_docker)          → $REPO_DIR/certs (unchanged)
#   staging (OUT=…/opt/basapos/compose)  → certs sibling, later sed→ /opt/basapos
# shellcheck disable=SC2086
docker compose --project-directory "$OUT_DIR" --env-file "$ENV_FILE" $COMPOSE_FILES config > "$TMP_OUT"
mv "$TMP_OUT" "$OUT_DIR/compose.final.yaml"

if [ -n "$REWRITE" ]; then
  FROM="${REWRITE%%=*}"; TO="${REWRITE#*=}"
  case "$REWRITE" in *=*) ;; *) echo "ERROR: --rewrite expects FROM=TO (got: $REWRITE)"; exit 1 ;; esac
  [ -n "$FROM" ] || { echo "ERROR: --rewrite FROM must be non-empty"; exit 1; }
  sed -i "s|$FROM|$TO|g" "$OUT_DIR/compose.final.yaml"
fi
echo "wrote $OUT_DIR/compose.final.yaml"
