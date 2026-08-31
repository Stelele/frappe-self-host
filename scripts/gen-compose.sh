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

mkdir -p "$OUT_DIR"
cd "$COMPOSE_DIR"
# --project-directory "$OUT_DIR" makes ../certs resolve relative to the OUTPUT
# dir: Linux (OUT=frappe_docker) → $REPO_DIR/certs (unchanged); distro staging
# (OUT=…/opt/basapos/compose) → certs sibling baked for /opt/basapos rewrite.
# shellcheck disable=SC2086
docker compose --project-directory "$OUT_DIR" --env-file "$ENV_FILE" $COMPOSE_FILES config > "$OUT_DIR/compose.final.yaml"

if [ -n "$REWRITE" ]; then
  FROM="${REWRITE%%=*}"; TO="${REWRITE#*=}"
  sed -i "s|$FROM|$TO|g" "$OUT_DIR/compose.final.yaml"
fi
echo "wrote $OUT_DIR/compose.final.yaml"
