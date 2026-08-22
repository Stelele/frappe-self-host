#!/usr/bin/env bash
# Build → smoke → export → validate the BasaPOS WSL appliance rootfs.
# Usage: bash appliance/build.sh            (run from anywhere; self-locates repo root)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
IMAGE=basapos-appliance:16
OUT=appliance/dist/basapos-rootfs.tar.gz

echo "== build image =="
docker build -f appliance/Containerfile -t "$IMAGE" .

echo "== in-image smoke =="
# NOTE: /etc/hosts|hostname|resolv.conf are docker-shadowed at runtime — do NOT
# assert them here; validate.sh checks them at tar level instead.
smoke_out="$(docker run --rm "$IMAGE" bash -c '
  test -x /home/frappe/bench/env/bin/gunicorn || { echo "FAIL: gunicorn binary missing"; exit 1; }
  test -L /etc/systemd/system/multi-user.target.wants/basapos-gunicorn.service || { echo "FAIL: gunicorn want-link"; exit 1; }
  test -e /lib/systemd/systemd || { echo "FAIL: systemd init binary missing"; exit 1; }
  [[ ! -s /etc/nginx/ssl/basapos.crt ]] || { echo "FAIL: TLS cert baked into image"; exit 1; }
  [[ $(wc -c </etc/machine-id) -eq 0 ]] || { echo "FAIL: machine-id not blank"; exit 1; }
  test ! -e /opt/provision.sh || { echo "FAIL: provision traces present"; exit 1; }
  echo SMOKE_OK')" || { echo "$smoke_out" >&2; echo "FAIL: smoke failed" >&2; exit 1; }
grep -q '^SMOKE_OK$' <<<"$smoke_out"

echo "== stamp shadowed files into container =="
CID=$(docker create "$IMAGE")
STAMP="$(mktemp -d)"
trap 'docker rm "$CID" >/dev/null 2>&1 || true; rm -rf "$STAMP"' EXIT
cp appliance/overlay/etc/hosts "$STAMP/hosts"
printf 'basapos\n' > "$STAMP/hostname"
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "$STAMP/resolv.conf"
docker cp "$STAMP/hosts"      "$CID:/etc/hosts"
docker cp "$STAMP/hostname"   "$CID:/etc/hostname"
docker cp "$STAMP/resolv.conf" "$CID:/etc/resolv.conf"
rm -rf "$STAMP"

echo "== export rootfs =="
mkdir -p "$(dirname "$OUT")"
# export to a temp name and only move into place after validation passes,
# so dist/ never holds a rejected or truncated artifact
docker export "$CID" | gzip -1 > "$OUT.tmp"

echo "== validate =="
bash appliance/validate.sh "$OUT.tmp"
mv "$OUT.tmp" "$OUT"

ls -lh "$OUT"
