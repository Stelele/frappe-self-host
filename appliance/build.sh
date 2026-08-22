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
docker run --rm "$IMAGE" bash -c '
  test -x /home/frappe/bench/env/bin/gunicorn &&
  test -L /etc/systemd/system/multi-user.target.wants/basapos-gunicorn.service &&
  test -e /lib/systemd/systemd &&
  [[ ! -s /etc/nginx/ssl/basapos.crt ]] &&
  [[ $(wc -c </etc/machine-id) -eq 0 ]] &&
  test ! -e /opt/provision.sh &&
  echo SMOKE_OK' | grep -q SMOKE_OK

echo "== stamp shadowed files into container =="
CID=$(docker create "$IMAGE")
trap 'docker rm "$CID" >/dev/null 2>&1 || true' EXIT
STAMP="$(mktemp -d)"
cp appliance/overlay/etc/hosts "$STAMP/hosts"
printf 'basapos\n' > "$STAMP/hostname"
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "$STAMP/resolv.conf"
docker cp "$STAMP/hosts"      "$CID:/etc/hosts"
docker cp "$STAMP/hostname"   "$CID:/etc/hostname"
docker cp "$STAMP/resolv.conf" "$CID:/etc/resolv.conf"
rm -rf "$STAMP"

echo "== export rootfs =="
mkdir -p "$(dirname "$OUT")"
docker export "$CID" | gzip -1 > "$OUT"

echo "== validate =="
bash appliance/validate.sh "$OUT"

ls -lh "$OUT"
