#!/usr/bin/env bash
# Kill-at-every-phase convergence drill for the v3 firstboot.
# For each phase sentinel: FRESH privileged container → systemd runs
# basapos-firstboot.service → wait for sentinel N → SIGKILL the service
# (simulated power cut) → restart the service → must converge to `done`
# and serve /api/method/ping. Exercises the real unit wiring.
set -euo pipefail
IMG="${1:?usage: test-firstboot.sh <basapos-distro image>}"
PHASES=(loaded env stack site cert booted done)
CREDS="$(mktemp -d)"
mkdir -p "$CREDS/config" "$CREDS/logs" "$CREDS/backups"
printf 'InstallPassword123!\n' > "$CREDS/config/install-password.txt"
: > "$CREDS/config/credentials.txt"

wait_sentinel() {  # $1=cid $2=sentinel $3=max-seconds
  for _ in $(seq 1 $(( $3 / 5 ))); do
    docker exec "$1" test -f "/var/lib/basapos/firstboot/$2" 2>/dev/null && return 0
    sleep 5
  done
  return 1
}

wait_done() {  # $1=cid — wait for completion + healthy ping
  wait_sentinel "$1" done 2400 || { echo "FAIL: never converged after kill at $KILLED_AT"; docker exec "$1" tail -50 /var/log/basapos-firstboot.log 2>/dev/null || true; return 1; }
  for _ in $(seq 1 60); do
    docker exec "$1" curl -sk -o /dev/null https://localhost/api/method/ping 2>/dev/null && return 0
    sleep 5
  done
  echo "FAIL: done sentinel set but site unhealthy (kill at $KILLED_AT)"
  docker exec "$1" docker ps --format '{{.Names}} {{.Status}}' 2>/dev/null || true
  return 1
}

KILLED_AT=""
for P in "${PHASES[@]}"; do
  echo "=== drill: kill after sentinel: $P ==="
  CID=$(docker run -d --privileged -v "$CREDS:/mnt/c/BasaPOS" "$IMG" /sbin/init)
  cleanup() { docker rm -f "$CID" >/dev/null 2>&1 || true; }
  trap cleanup EXIT

  # wait for docker.service to settle, then for the phase sentinel.
  # firstboot phases can take a while (docker load of ~5GB inside the VM).
  wait_sentinel "$CID" "$P" 2700 \
    || { echo "FAIL: sentinel $P never appeared"; docker exec "$CID" systemctl status basapos-firstboot.service --no-pager 2>&1 | tail -20 || true; exit 1; }

  echo "  sentinel $P up — SIGKILL firstboot (power-cut simulation)"
  docker exec "$CID" systemctl kill -s SIGKILL basapos-firstboot.service 2>/dev/null || true
  docker exec "$CID" systemctl stop basapos-firstboot.service 2>/dev/null || true
  sleep 3
  KILLED_AT="$P"

  echo "  restarting service — must converge"
  docker exec "$CID" systemctl start basapos-firstboot.service
  wait_done "$CID"

  echo "OK: converged after kill at $P"
  cleanup
  trap - EXIT
done

echo "=== backup service smoke ==="
CID=$(docker run -d --privileged -v "$CREDS:/mnt/c/BasaPOS" "$IMG" /sbin/init)
trap 'docker rm -f "$CID" >/dev/null 2>&1 || true' EXIT
wait_done "$CID"
docker exec "$CID" systemctl start basapos-backup.service
sleep 20
ls "$CREDS"/backups/20*/ >/dev/null 2>&1 \
  && echo "OK: backup landed in /mnt/c target" \
  || { echo "FAIL: no backup dir in /mnt/c after service run"; docker exec "$CID" journalctl -u basapos-backup.service --no-pager 2>&1 | tail -30; exit 1; }
docker rm -f "$CID" >/dev/null
trap - EXIT

rm -rf "$CREDS"
echo "FIRSTBOOT DRILL PASS"
