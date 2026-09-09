#!/usr/bin/env bash
# smoke-firstboot.sh — firstboot convergence smoke on a LINUX runner.
#
# Boots the freshly-built distro IMAGE directly (no Windows/WSL required):
# the image is the same rootfs the installer imports, minus WSL specifics.
# Asserts the real firstboot converges, then KILLS the container mid-'stack'
# phase (SIGKILL == a WSL power-cut), reboots the same container (its
# filesystem persists exactly like a WSL VM after `wsl --shutdown`), and
# requires reconvergence to `done` + an HTTP 200 over TLS.
#
# This is the replacement for the old 8-phase Windows kill-drill fleet: one
# representative mid-phase kill exercises the same sentinel/resume machinery.
#
# Usage: smoke-firstboot.sh <distro-image-tag>
#   HTTPS_PUBLISH_PORT  host port to publish the VM's 443 on (default 8443)
#
# Storage-driver note: firstboot runs its OWN dockerd inside this container
# ("docker in docker"). overlay2-in-overlay2 whiteout unpack has historically
# failed on CI runners (commit 9fb7204). Try overlay2 first; on whiteout
# failure, restart the container with an inner vfs daemon.json (vfs copies
# layers — no whiteouts — and still exercises every other phase + the resume
# path). The production overlay2 install path stays covered by the Windows
# drill lane.
set -euo pipefail

IMG="${1:?usage: smoke-firstboot.sh <distro-image-tag>}"
HTTPS_PORT="${HTTPS_PUBLISH_PORT:-8443}"
DOMAIN=basapos.local
CONTAINER=basapos-smoke
FIELD=/var/lib/basapos/firstboot
DONE="$FIELD/done"
LOG=/var/log/basapos-firstboot.log
LOGIN="start db + cache tiers"
# arbitrary, but MUST be < the distro job timeout and > worst-case cold firstboot
MAX_FIRST="${SMOKE_MAX_FIRST:-420}"   # boot → phase-log line appears
MAX_RESUME="${SMOKE_MAX_RESUME:-420}" # resume → done sentinel

MNT="$(mktemp -d)"
trap 'docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; rm -rf "$MNT"' EXIT
# the container sees this dir at /mnt/c, so == the C: root of a field box:
# /mnt/c/BasaPOS/config|logs|backups
mkdir -p "$MNT/BasaPOS/config" "$MNT/BasaPOS/logs" "$MNT/BasaPOS/backups"
printf 'InstallPassword123!' > "$MNT/BasaPOS/config/install-password.txt"
: > "$MNT/BasaPOS/config/credentials.txt"

fail() { echo "SMOKE FAIL: $*" >&2; exit 1; }

boot_container() { # boot_container <storage-driver|"">
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  local vol=""
  if [ -n "${1:-}" ]; then
    printf '{"storage-driver":"%s"}\n' "$1" > "$MNT/daemon.json"
    vol="-v $MNT/daemon.json:/etc/docker/daemon.json:ro"
  fi
  # shellcheck disable=SC2086
  docker run -d --name "$CONTAINER" --privileged --cgroupns=host \
    -e container=docker -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    -v "$MNT:/mnt/c" -p "$HTTPS_PORT:443" $vol \
    "$IMG" /sbin/init >/dev/null
}

wait_systemd() {
  local deadline=$(( $(date +%s) + 90 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    docker exec "$CONTAINER" bash -c 'test -d /run/systemd/system' >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

wait_phase3() { # wait until firstboot's stack phase TEXT appears (stack starting)
  local deadline=$(( $(date +%s) + MAX_FIRST ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    docker exec "$CONTAINER" grep -qF "$LOGIN" "$LOG" 2>/dev/null && return 0
    sleep 2
  done
  return 1
}

wait_done() {
  local deadline=$(( $(date +%s) + MAX_RESUME ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    docker exec "$CONTAINER" test -f "$DONE" >/dev/null 2>&1 && return 0
    sleep 5
  done
  return 1
}

healthy() {
  local code
  code=$(curl -sk --resolve "$DOMAIN:$HTTPS_PORT:127.0.0.1" \
    -o /dev/null -w '%{http_code}' \
    "https://$DOMAIN:$HTTPS_PORT/api/method/ping" 2>/dev/null || true)
  [ "$code" = "200" ]
}

wait_healthy() {
  local deadline=$(( $(date +%s) + 90 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    healthy && return 0
    sleep 5
  done
  return 1
}

show_tails() {
  # firstboot tee_log's the full command output (docker load, compose up, bench)
  # into WINLOG = /mnt/c/BasaPOS/logs/firstboot.log — host-visible at $MNT. This
  # is the AUTHORITATIVE sink; the in-VM $LOG tail can be empty/raced.
  echo "--- host-side firstboot.log tail (tee_log sink) ---" >&2
  tail -120 "$MNT/BasaPOS/logs/firstboot.log" >&2 2>/dev/null \
    || echo "  (not visible — WINLOG was never written)" >&2
  echo "--- in-VM firstboot log tail ---" >&2
  docker exec "$CONTAINER" tail -80 "$LOG" 2>/dev/null >&2 || true
  echo "--- systemd journal tail ---" >&2
  docker exec "$CONTAINER" journalctl -u basapos-firstboot --no-pager 2>/dev/null | tail -30 >&2 || true
  echo "--- host curl probe ---" >&2
  curl -sk --resolve "$DOMAIN:$HTTPS_PORT:127.0.0.1" -w "HTTP %{http_code}\n" \
    -o /dev/null "https://$DOMAIN:$HTTPS_PORT/api/method/ping" >&2 || true
  echo "--- docker ps -a (inner) ---" >&2
  docker exec "$CONTAINER" docker ps -a --format 'table {{.Names}}\t{{.Status}}' 2>/dev/null >&2 || true
  echo "--- inner docker info (storage) ---" >&2
  docker exec "$CONTAINER" docker info --format '{{json .Driver}}' 2>/dev/null >&2 || true
}

# run_smoke <storage-driver|""> → 0 pass, 1 fail (failures emit details)
run_smoke() {
  local driver="${1:-}" label="${1:-overlay2}"
  echo "== smoke: boot distro image ($IMG), inner storage=$label =="
  boot_container "$driver"
  if ! wait_systemd; then show_tails; echo "SMOKE $label FAIL: systemd never up"; return 1; fi
  if ! wait_phase3; then show_tails; echo "SMOKE $label FAIL: stack phase never started"; return 1; fi
  echo "  phase 3 ('stack') in progress — killing container (power-cut)"
  sleep 5
  docker kill "$CONTAINER" >/dev/null
  echo "  rebooting same container (fs persists == WSL reboot)"
  docker start "$CONTAINER" >/dev/null
  if ! wait_done; then show_tails; echo "SMOKE $label FAIL: never reconverged to done"; return 1; fi
  if ! wait_healthy; then show_tails; echo "SMOKE $label FAIL: done but site unhealthy"; return 1; fi
  echo "SMOKE $label PASS: converged after mid-stack kill; TLS 200 on :$HTTPS_PORT"
  return 0
}

# overlay2 default first. Retry with inner vfs ONLY when the failure looks like
# a layer-unpack (whiteout) failure OR the stack phase failing to start — the
# known nested-overlay failure modes (commit 9fb7204: nested overlayfs cannot
# unpack whiteouts). The "[3] tier start failed" journal line is how the
# swallowed docker compose error surfaces. Any other failure is a real bug and
# must fail the job fast rather than burn a second ~7min attempt.
SMOKE_DIAG="$MNT/smoke-diag.txt"
if ! run_smoke >"$SMOKE_DIAG" 2>&1; then
  if grep -Eq 'whiteout|failed to apply layer|failed to register layer|tier start failed' "$SMOKE_DIAG"; then
    echo "== overlay2 failed (layer-unpack or tier-start signature) — retrying with inner vfs =="
    rm -f "$SMOKE_DIAG"
    run_smoke vfs
  else
    cat "$SMOKE_DIAG" >&2
    fail "overlay2 smoke failed without a layer-unpack/tier-start signature (see above)"
  fi
fi