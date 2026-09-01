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
  local deadline=$(( $(date +%s) + $3 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    docker exec "$1" test -f "/var/lib/basapos/firstboot/$2" 2>/dev/null && return 0
    if [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" != "true" ]; then
      echo "FAIL: container died while waiting for sentinel $2"
      return 1
    fi
    sleep 5
  done
  return 1
}

wait_done() {  # $1=cid — done sentinel AND a real 200 from the site
  wait_sentinel "$1" done 2400 || {
    echo "FAIL: never converged after power-cut at $KILLED_AT"
    docker exec "$1" tail -50 /var/log/basapos-firstboot.log 2>/dev/null || true
    return 1; }
  local code=""
  for _ in $(seq 1 60); do
    code="$(docker exec "$1" curl -sk -o /dev/null -w '%{http_code}' \
      --resolve basapos.local:443:127.0.0.1 \
      https://basapos.local/api/method/ping 2>/dev/null || true)"
    [ "$code" = "200" ] && return 0
    sleep 5
  done
  echo "FAIL: done sentinel set but site unhealthy (last http code='$code', power-cut at $KILLED_AT)"
  docker exec "$1" docker ps --format '{{.Names}} {{.Status}}' 2>/dev/null || true
  return 1
}

KILLED_AT=""
ITERATIONS=("(boot)" loaded env stack site cert booted done)
for P in "${ITERATIONS[@]}"; do
  echo "=== drill: power-cut during/after: $P ==="
  T0=$(date +%s)
  CID=$(docker run -d --privileged -v "$CREDS:/mnt/c/BasaPOS" "$IMG" /sbin/init)
  cleanup() { docker rm -f "$CID" >/dev/null 2>&1 || true; }
  trap cleanup EXIT

  if [ "$P" = "(boot)" ]; then
    # kill mid docker-load (the longest, most fragile phase) before ANY sentinel
    DELAY=$(( RANDOM % 120 + 30 ))
  else
    wait_sentinel "$CID" "$P" 2700 || {
      echo "FAIL: sentinel $P never appeared"
      docker exec "$CID" systemctl status basapos-firstboot.service --no-pager 2>&1 | tail -20 || true
      exit 1; }
    # land mid-flight in the NEXT phase, not at the clean boundary
    DELAY=$(( RANDOM % 150 + 30 ))
  fi
  echo "  killing container in ${DELAY}s (power-cut simulation)"
  KILLED_AT="$P"
  sleep "$DELAY"
  docker restart -t 0 "$CID" >/dev/null

  # container rebooted: systemd auto-starts basapos-firstboot.service again;
  # sentinels skip completed phases — convergence must reach done + HTTP 200
  wait_done "$CID"
  echo "OK: converged after power-cut at $P ($(($(date +%s) - T0))s)"
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
