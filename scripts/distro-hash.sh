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

{
  printf 'distro-hash-v1\n'
  # tracked files only (ignores shop/build noise); canonical byte hashes
  git ls-files -z -- "${inputs[@]}" | sort -z | xargs -0 -I{} sha256sum "{}"
  # submodule pin is part of the hash even though ls-files only lists the dir
  git ls-tree HEAD frappe_docker --format='%(objectname)'
} | sha256sum | cut -d' ' -f1