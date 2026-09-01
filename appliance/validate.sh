#!/usr/bin/env bash
# Tar-level structural asserts for the v3 distro.
set -euo pipefail
TAR="${1:?usage: validate.sh <distro.tar.gz>}"

LIST="$(gzip -dc "$TAR" | tar -tf -)"
# docker export lists members WITHOUT a leading "/" (e.g. etc/wsl.conf),
# so normalize each required path by stripping its leading slash before match.
has() { local q="${1#/}"; grep -Fxq "$q" <<<"$LIST"; }

for f in \
  /etc/wsl.conf \
  /usr/lib/systemd/systemd \
  /etc/systemd/system/basapos-firstboot.service \
  /etc/systemd/system/basapos-backup.timer \
  /usr/local/sbin/basapos-firstboot \
  /usr/local/sbin/basapos-backup \
  /opt/basapos/images.tar \
  /opt/basapos/compose/compose.final.yaml \
  /opt/basapos/compose/.env.template \
  /opt/basapos/certs/ \
  /opt/basapos/compose-parity.yaml ; do
  has "$f" || { echo "VALIDATE FAIL: missing $f"; exit 1; }
done

# docker export members have no leading "/"; strip it for tar -xOf lookups.
X() { gzip -dc "$TAR" | tar -xOf - "${1#/}"; }

echo "== extract shipped metadata (single pass) =="
TMPV="$(mktemp -d)"
trap 'rm -rf "$TMPV"' EXIT
gzip -dc "$TAR" | tar -xf - -C "$TMPV" \
  opt/basapos/image-digest.txt opt/basapos/compose-parity.yaml opt/basapos/compose/compose.final.yaml

echo "== image digest (recorded at build) =="
cat "$TMPV/opt/basapos/image-digest.txt"

echo "== compose parity (staged == shipped) =="
A=$(sha256sum < "$TMPV/opt/basapos/compose-parity.yaml" | cut -d' ' -f1)
B=$(sha256sum < "$TMPV/opt/basapos/compose/compose.final.yaml" | cut -d' ' -f1)
echo "parity:   $A"
echo "shipped:  $B"
[ "$A" = "$B" ] || { echo "VALIDATE FAIL: compose drift (parity != shipped)"; exit 1; }

echo "== certs bind-path guard (anchored — catches rewrite failures) =="
grep -q '        source: /opt/basapos/certs' "$TMPV/opt/basapos/compose/compose.final.yaml" \
  || { echo "VALIDATE FAIL: certs bind source not exactly /opt/basapos/certs (rewrite broken?)"; exit 1; }
grep -q '\.stage' "$TMPV/opt/basapos/compose/compose.final.yaml" \
  && { echo "VALIDATE FAIL: staging path leaked into shipped compose"; exit 1; } || true

echo "== offline pull policy =="
grep -q 'pull_policy: never' "$TMPV/opt/basapos/compose/compose.final.yaml" \
  || { echo "VALIDATE FAIL: pull_policy not pinned to never"; exit 1; }

echo "== size report =="
ls -lh "$TAR"
echo "VALIDATE OK"
