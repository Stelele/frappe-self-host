#!/usr/bin/env bash
set -euo pipefail
docker context use default 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$REPO_DIR/.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: .env file not found"
  exit 1
fi

source "$ENV_FILE"

if [ -z "${DOMAIN:-}" ]; then
  echo "ERROR: DOMAIN not set in .env"
  exit 1
fi

CERTS_DIR="$REPO_DIR/certs"
CERT_FILE="$CERTS_DIR/cert.pem"
KEY_FILE="$CERTS_DIR/key.pem"
DYNAMIC_FILE="$CERTS_DIR/dynamic.yml"

mkdir -p "$CERTS_DIR"

if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
  echo "Certificate already exists for $DOMAIN"
else
  if command -v mkcert &>/dev/null; then
    echo "Generating locally-trusted certificate using mkcert..."
    mkcert -install 2>&1 | tail -1
    mkcert -cert-file "$CERT_FILE" -key-file "$KEY_FILE" "$DOMAIN" 2>&1 | tail -1
  else
    echo "mkcert not found — generating self-signed certificate (browser will show warning)..."
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
      -keyout "$KEY_FILE" \
      -out "$CERT_FILE" \
      -subj "/CN=$DOMAIN" \
      -addext "subjectAltName=DNS:$DOMAIN" 2>/dev/null
  fi
  echo "  cert: $CERT_FILE"
  echo "  key:  $KEY_FILE"
fi

cat > "$DYNAMIC_FILE" <<EOF
tls:
  certificates:
    - certFile: /certs/cert.pem
      keyFile: /certs/key.pem
EOF

echo "  dynamic: $DYNAMIC_FILE"
