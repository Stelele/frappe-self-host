#!/usr/bin/env bash
# distro-hash.sh — content-addressed hash over every v3 distro build input.
#
# CI uses it as the GHCR cache key: the distro is pushed to
# ghcr.io/<owner>/<repo>/basapos-distro:sha256-<DISTRO_SHA> and pulls of that
# exact tag skip the ~5min Docker rebuild + firstboot smoke entirely.
#
# Keep this list in sync with build.sh / gen-compose.sh inputs:
#   apps.json (frappe image), .env.example, appliance/**, gen-compose.sh,
#   overrides/** (compose.selfsigned.yaml), and the frappe_docker SUBMODULE SHA.
# compose.custom.yaml is a deploy artifact, NOT a build input — excluded.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

inputs=(apps.json .env.example appliance scripts/gen-compose.sh overrides)

# submodule pin is part of the hash even though ls-files only lists the dir;
# fail loudly if the gitlink is missing so it can't silently drop out of the key
sub="$(git ls-tree HEAD frappe_docker --format='%(objectname)')"
[ -n "$sub" ] || { echo "distro-hash: frappe_docker submodule pin not found" >&2; exit 1; }

{
  printf 'distro-hash-v1\n'
  # tracked files only (ignores shop/build noise); canonical byte hashes.
  # LC_ALL=C pins sort collation so the ordering (and thus the digest) is
  # identical on any runner locale.
  git ls-files -z -- "${inputs[@]}" | LC_ALL=C sort -z | xargs -0 sha256sum
  printf '%s\n' "$sub"
} | sha256sum | cut -d' ' -f1