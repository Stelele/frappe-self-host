#!/usr/bin/env bash
# v3 pipeline: ONE image build → save 4 stack images → distro build →
# export → gzip → split → SHA256SUMS. Disk-budgeted for CI runners.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

IMAGE_TAG=basapos:16
DISTRO_TAG=basapos-distro:16
OUT_DIR=appliance/dist
PART_SIZE=1900m
# stage on the artifact disk by default (/tmp may be a small tmpfs on CI);
# override with BASAPOS_STAGE_DIR for exotic runners
STAGE="${BASAPOS_STAGE_DIR:-$OUT_DIR.stage}"
rm -rf "$STAGE"; mkdir -p "$STAGE"
mkdir -p "$OUT_DIR"

echo "== 1/6 build frappe image (ONE build — parity by construction) =="
CACHE_BUST="$(sha256sum apps.json | cut -d' ' -f1)"
docker build \
  --build-arg=FRAPPE_PATH=https://github.com/frappe/frappe \
  --build-arg=FRAPPE_BRANCH=version-16 \
  --build-arg=CACHE_BUST="$CACHE_BUST" \
  --secret=id=apps_json,src=apps.json \
  --tag="$IMAGE_TAG" \
  --file=frappe_docker/images/layered/Containerfile frappe_docker

echo "== 2/6 save images.tar (4 pinned stack images) =="
docker pull -q mariadb:11.8
docker pull -q redis:8.6-alpine
docker pull -q traefik:v3.6
docker save "$IMAGE_TAG" mariadb:11.8 redis:8.6-alpine traefik:v3.6 \
  -o "$STAGE/images.tar"
docker image inspect "$IMAGE_TAG" --format '{{.Id}}' > "$STAGE/image-digest.txt"

echo "== 3/6 generate compose bundle (same scripts as Linux) =="
mkdir -p "$STAGE/opt/basapos/compose" "$STAGE/opt/basapos/certs"
ENV_HAD_ONE=0
[ -f .env ] && { cp .env "$STAGE/user-env.bak"; ENV_HAD_ONE=1; }
restore_env() {
  if [ "$ENV_HAD_ONE" = 1 ]; then mv -f "$STAGE/user-env.bak" .env
  else rm -f .env; fi
}
trap 'restore_env; rm -rf "$STAGE"; rm -rf "$ROOT/appliance/.payload"' EXIT
sed -e 's|^DB_PASSWORD=.*|DB_PASSWORD=__GENERATED_AT_FIRSTBOOT__|' \
    -e 's|^ADMIN_PASSWORD=.*|ADMIN_PASSWORD=install-time|' .env.example > .env
bash scripts/gen-compose.sh "$STAGE/opt/basapos/compose" --rewrite "$STAGE=" >/dev/null
cp "$STAGE/opt/basapos/compose/compose.final.yaml" "$STAGE/compose-parity.yaml"

echo "== 4/6 build distro image (payload staged into context) =="
mkdir -p appliance/.payload/opt/basapos
cp "$STAGE/images.tar" appliance/.payload/opt/basapos/images.tar
cp -r "$STAGE/opt/basapos/compose" appliance/.payload/opt/basapos/compose
cp "$STAGE/image-digest.txt" appliance/.payload/opt/basapos/image-digest.txt
cp "$STAGE/compose-parity.yaml" appliance/.payload/compose-parity.yaml
docker build -f appliance/Containerfile -t "$DISTRO_TAG" .
rm -rf appliance/.payload
docker builder prune -f >/dev/null 2>&1 || true

echo "== 5/6 export + gzip =="
CID=$(docker create "$DISTRO_TAG")
docker export "$CID" | gzip -6 > "$OUT_DIR/basapos-distro.tar.gz.tmp"
docker rm "$CID" >/dev/null

echo "== 6/6 validate → split → checksums =="
bash appliance/validate.sh "$OUT_DIR/basapos-distro.tar.gz.tmp"
mv "$OUT_DIR/basapos-distro.tar.gz.tmp" "$OUT_DIR/basapos-distro.tar.gz"
cd "$OUT_DIR"
rm -f basapos-distro.tar.part-* SHA256SUMS
split -b "$PART_SIZE" -d basapos-distro.tar.gz basapos-distro.tar.part-
sha256sum basapos-distro.tar.gz basapos-distro.tar.part-* > SHA256SUMS
ls -lh
