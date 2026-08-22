#!/usr/bin/env bash
# Structural assertions on the exported appliance rootfs tarball.
# Usage: validate.sh <path/to/rootfs.tar.gz>
set -euo pipefail

TAR="${1:?usage: validate.sh <rootfs.tar.gz>}"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok:   $*"; }

[[ -f "$TAR" ]] || fail "tarball not found: $TAR"

has() { tar -tzf "$TAR" "$1" >/dev/null 2>&1; }

# --- required filesystem members -------------------------------------------
for m in \
  ./etc/wsl.conf \
  ./lib/systemd/systemd \
  ./home/frappe/bench/sites/basapos.local/site_config.json \
  ./home/frappe/bench/sites/basapos.local/private/backups \
  ./home/frappe/bench/env/bin/gunicorn \
  ./home/frappe/bench/apps/frappe \
  ./home/frappe/bench/apps/erpnext \
  ./etc/nginx/sites-available/basapos.conf \
  ./etc/nginx/sites-enabled/basapos.conf \
  ./usr/local/bin/bench \
  ; do
  has "$m" || fail "missing member: $m"
done
pass "all required members present"

# --- systemd enablement symlinks --------------------------------------------
for u in basapos-gunicorn basapos-socketio basapos-worker-short \
         basapos-worker-long basapos-scheduler basapos-firstboot mariadb redis-server; do
  has "./etc/systemd/system/multi-user.target.wants/${u}.service" \
    || fail "unit not enabled: ${u}.service"
done
pass "all units enabled"

# --- wsl.conf content ---------------------------------------------------------
wslconf=$(tar -xzOf "$TAR" ./etc/wsl.conf)
grep -q '^systemd=true' <<<"$wslconf" || fail "wsl.conf missing systemd=true"
grep -q '^generateHosts=false' <<<"$wslconf" || fail "wsl.conf missing generateHosts=false"
pass "wsl.conf correct"

# --- hosts carries the domain --------------------------------------------------
hosts=$(tar -xzOf "$TAR" ./etc/hosts)
grep -q '127.0.0.1[[:space:]]\+basapos.local' <<<"$hosts" || fail "hosts missing basapos.local"
pass "hosts entry present"

# --- machine-id must be BLANK (WSL regenerates on import) ----------------------
midsize=$(tar -xzOf "$TAR" ./etc/machine-id | wc -c)
[[ "$midsize" -eq 0 ]] || fail "machine-id not blank (${midsize} bytes)"
pass "machine-id blank"

# --- nginx conf sanity ----------------------------------------------------------
ngx=$(tar -xzOf "$TAR" ./etc/nginx/sites-available/basapos.conf)
grep -q 'listen 443 ssl' <<<"$ngx" || fail "nginx missing 443 ssl listener"
grep -q 'server_name basapos.local' <<<"$ngx" || fail "nginx missing server_name"
pass "nginx conf sane"

echo ""
echo "ALL VALIDATIONS PASSED: $TAR"
