#!/usr/bin/env bash
# Fetch a BasaPOS release and assemble a USB-ready folder in one shot.
# Requires: gh (authenticated) + sha256sum (coreutils).
#
# Usage: scripts/fetch-release.sh <tag>     e.g. scripts/fetch-release.sh v3.0.0-rc1
#
# Produces: release/<tag>/BasaPOS-Setup.exe
#           release/<tag>/payload/{basapos-distro.tar.part-*, SHA256SUMS, wsl.msi}
# which is exactly what the installer expects — copy the whole folder to USB.
set -euo pipefail

TAG="${1:?usage: fetch-release.sh <tag>}"
DEST="release/$TAG"
PAYLOAD="$DEST/payload"

mkdir -p "$PAYLOAD"

echo "== downloading $TAG assets (gh release download) =="
gh release download "$TAG" --dir "$DEST" --clobber

echo "== assembling USB layout =="
# installer expects BasaPOS-Setup.exe at the root and the payload bits in payload/
mv "$DEST"/basapos-distro.tar.part-* "$PAYLOAD"/ 2>/dev/null || true
mv "$DEST/SHA256SUMS" "$PAYLOAD/" 2>/dev/null || true
mv "$DEST/wsl.msi" "$PAYLOAD/" 2>/dev/null || true

[ -f "$DEST/BasaPOS-Setup.exe" ] || { echo "ERROR: BasaPOS-Setup.exe missing — wrong tag?"; exit 1; }

echo "== verifying payload parts =="
(cd "$PAYLOAD" && grep 'basapos-distro.tar.part-' SHA256SUMS | sha256sum -c -)

echo
echo "== ready =="
echo "  $DEST/"
echo "    BasaPOS-Setup.exe"
echo "    payload/  (basapos-distro.tar.part-* + SHA256SUMS + wsl.msi)"
echo
echo "Copy the whole $DEST folder (exe + payload/) to a USB stick."
echo "The installer re-verifies the stitched tarball against SHA256SUMS before importing."
