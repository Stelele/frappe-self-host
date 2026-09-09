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
# ("docker in docker"). The inner dockerd uses the vfs storage driver
# (daemon.json) DIRECTLY: nested overlay2 cannot unpack layers for the db
# stack tier on GH runners — proven empirically twice on this workflow (the
# mariadb/redis containers never start: firstboot crash-loops with
# "[3] tier start failed"). vfs copies layers (no whiteouts) and exercises
# every phase + the resume path. Production overlay2 is covered by the
# Windows drill lane, which runs the real WSL2 rootfs.
set -euo pipefail

IMG="${1:?usage: smoke-firstboot.sh <distro-image-tag>}"
HTTPS_PORT="${HTTPS_PUBLISH_PORT:-8443}"
DOMAIN=basapos.local
CONTAINER=basapos-smoke
FIELD=/var/lib/basapos/firstboot
STACK="$FIELD/stack"
DONE="$FIELD/done"
LOG=/var/log/basapos-firstboot.log
# arbitrary, but MUST be < the distro job timeout and > worst-case cold firstboot
MAX_FIRST="${SMOKE_MAX_FIRST:-420}"   # boot → stack sentinel marked
MAX_RESUME="${SMOKE_MAX_RESUME:-1500}" # resume → done sentinel (new-site +
  # full idempotent app install re-runs after a kill-landed-in-phase-4-pow-cut;
  # vfs layer copies make this the longest smoke segment)

MNT="$(mktemp -d)"
trap 'docker rm -f "$CONTAINER" >/dev/null 2>&1 || true; rm -rf "$MNT"' EXIT
# the container sees this dir at /mnt/c, so == the C: root of a field box:
# /mnt/c/BasaPOS/config|logs|backups
mkdir -p "$MNT/BasaPOS/config" "$MNT/BasaPOS/logs" "$MNT/BasaPOS/backups"
printf 'InstallPassword123!' > "$MNT/BasaPOS/config/install-password.txt"
: > "$MNT/BasaPOS/config/credentials.txt"

fail() { echo "SMOKE FAIL: $*" >&2; exit 1; }

boot_container() { # boot with inner dockerd pinned to the vfs storage driver
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  printf '{"storage-driver":"vfs"}\n' > "$MNT/daemon.json"
  docker run -d --name "$CONTAINER" --privileged --cgroupns=host \
    -e container=docker -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    -v "$MNT:/mnt/c" -v "$MNT/daemon.json:/etc/docker/daemon.json:ro" \
    -p "$HTTPS_PORT:443" \
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

wait_stack() { # wait until the stack sentinel is marked (db provisioned +
  # cache tiers started + configurator ran — NOT merely the phase-3 echo line:
  # killing a few seconds after 'dc up' begins hits mariadb mid-init, and on
  # resume its root@% grants were never created → new-site 1130)
  local deadline=$(( $(date +%s) + MAX_FIRST ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    docker exec "$CONTAINER" test -f "$STACK" >/dev/null 2>&1 && return 0
    sleep 5
  done
  return 1
}

wait_done() {
  local deadline=$(( $(date +%s) + MAX_RESUME ))
  local n=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    docker exec "$CONTAINER" test -f "$DONE" >/dev/null 2>&1 && return 0
    n=$((n+1))
    # heartbeat: surface progress (or a hang) in the runner log while waiting
    if [ $((n % 15)) -eq 0 ]; then
      echo "  still waiting for done ($(( $(date +%s) - deadline + MAX_RESUME ))s elapsed)" >&2
      tail -4 "$MNT/BasaPOS/logs/firstboot.log" >&2 2>/dev/null || true
    fi
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

# run_smoke → 0 pass, 1 fail (failures emit details). Inner dockerd is pinned
# to vfs (see header — nested overlay2 cannot start the stack tier on GH
# runners), and the kill happens only AFTER the stack sentinel is marked so
# the DB is fully provisioned when the 'reboot' resumes into new-site.
run_smoke() {
  echo "== smoke: boot distro image ($IMG), inner storage=vfs =="
  boot_container
  if ! wait_systemd; then show_tails; echo "SMOKE FAIL: systemd never up"; return 1; fi
  if ! wait_stack; then show_tails; echo "SMOKE FAIL: stack sentinel never marked"; return 1; fi
  echo "  stack deployed (db provisioned + configurator done) — killing container (power-cut)"
  docker kill "$CONTAINER" >/dev/null
  echo "  rebooting same container (fs persists == WSL reboot)"
  docker start "$CONTAINER" >/dev/null
  if ! wait_done; then show_tails; echo "SMOKE FAIL: never reconverged to done"; return 1; fi
  if ! wait_healthy; then show_tails; echo "SMOKE FAIL: done but site unhealthy"; return 1; fi
  echo "SMOKE PASS: converged after post-stack kill; TLS 200 on :$HTTPS_PORT"
  return 0
}

run_smoke || fail "vfs smoke failed (diagnostics above)"