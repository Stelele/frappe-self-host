#!/usr/bin/env bash
# Structural assertions on the exported appliance rootfs tarball.
# Usage: validate.sh <path/to/rootfs.tar.gz>
set -euo pipefail

TAR="${1:?usage: validate.sh <rootfs.tar.gz>}"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok:   $*"; }

[[ -f "$TAR" ]] || fail "tarball not found: $TAR"

# docker export emits members WITHOUT the leading "./"; normalize queries.
# List members once — scanning the gzipped rootfs per-query is far too slow.
MEMBERS="$(mktemp)"
trap 'rm -f "$MEMBERS"' EXIT
tar -tzf "$TAR" > "$MEMBERS"
has() {
  local p="${1#./}"
  # directories are listed by tar with a trailing slash; also accept "./"-prefixed
  # archives (GNU-tar-produced rootfs) for producer independence
  grep -qxF -- "$p" "$MEMBERS" || grep -qxF -- "$p/" "$MEMBERS" \
    || grep -qxF -- "./$p" "$MEMBERS"
}

# --- required filesystem members -------------------------------------------
for m in \
  ./etc/wsl.conf \
  ./usr/lib/systemd/systemd \
  ./etc/hosts \
  ./etc/machine-id \
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
         basapos-worker-long basapos-scheduler basapos-firstboot mariadb redis-server nginx; do
  has "./etc/systemd/system/multi-user.target.wants/${u}.service" \
    || fail "unit not enabled: ${u}.service"
done
pass "all units enabled"

# --- enabled units' target bodies must exist in the rootfs -------------------
for m in \
  ./etc/systemd/system/basapos-gunicorn.service \
  ./etc/systemd/system/basapos-socketio.service \
  ./etc/systemd/system/basapos-worker-short.service \
  ./etc/systemd/system/basapos-worker-long.service \
  ./etc/systemd/system/basapos-scheduler.service \
  ./etc/systemd/system/basapos-firstboot.service \
  ./usr/lib/systemd/system/mariadb.service \
  ./usr/lib/systemd/system/redis-server.service \
  ./usr/lib/systemd/system/nginx.service \
  ./home/frappe/bench/apps/frappe/socketio.js \
  ; do
  has "$m" || fail "missing unit/socketio member: $m"
done
pass "all unit targets present"

# --- wsl.conf content ---------------------------------------------------------
wslconf=$(tar -xzOf "$TAR" etc/wsl.conf)
grep -q '^systemd=true' <<<"$wslconf" || fail "wsl.conf missing systemd=true"
grep -q '^generateHosts=false' <<<"$wslconf" || fail "wsl.conf missing generateHosts=false"
pass "wsl.conf correct"

# --- hostname stamped ----------------------------------------------------------
hn=$(tar -xzOf "$TAR" etc/hostname)
grep -qx 'basapos' <<<"$hn" || fail "hostname not stamped (got: $hn)"
pass "hostname stamped"

# --- hosts carries the domain --------------------------------------------------
hosts=$(tar -xzOf "$TAR" etc/hosts)
grep -q '127.0.0.1[[:space:]]\+basapos.local' <<<"$hosts" || fail "hosts missing basapos.local"
pass "hosts entry present"

# --- machine-id must be BLANK (WSL regenerates on import) ----------------------
midsize=$(tar -xzOf "$TAR" etc/machine-id | wc -c)
[[ "$midsize" -eq 0 ]] || fail "machine-id not blank (${midsize} bytes)"
pass "machine-id blank"

# --- nginx conf sanity ----------------------------------------------------------
ngx=$(tar -xzOf "$TAR" etc/nginx/sites-available/basapos.conf)
grep -q '^[[:space:]]*listen 443 ssl' <<<"$ngx" || fail "nginx missing 443 ssl listener"
grep -q 'server_name basapos.local' <<<"$ngx" || fail "nginx missing server_name"
pass "nginx conf sane"

# --- /home/frappe must be traverseable by nginx's www-data ---------------------
# nginx serves /assets/* directly via try_files; the worker (www-data) needs the
# x bit ("other") on /home/frappe or every asset 404s and the page renders
# unstyled. Capture perms in one pass (tar -tv is expensive on a 1.9GB gzip).
VERBOSE="$(mktemp)"; trap 'rm -f "$MEMBERS" "$VERBOSE"' EXIT
tar -tvzf "$TAR" > "$VERBOSE" 2>/dev/null
homepriv=$(awk '$6 == "home/frappe/" || $6 == "home/frappe" {print $1; exit}' "$VERBOSE")
[[ "$homepriv" =~ ^d[rwx-]{3}[rwx-]{3}[rwx-]{3}$ ]] || fail "could not determine /home/frappe mode from tar listing"
# last char is the "other" execute bit
[[ "${homepriv:9}" == "x" || "${homepriv:9}" == "t" || "${homepriv:9}" == "s" ]] \
  || fail "/home/frappe is not other-traverseable (mode $homepriv) -- nginx/www-data cannot serve /assets; run: chmod 0751 /home/frappe in create_user()"
pass "/home/frappe mode $homepriv is www-data-traverseable"

# --- sites/assets/<app> must be symlinks into apps' public dirs ----------------
for app in frappe erpnext; do
  grep -q "^lrwxrwxrwx.*sites/assets/${app} -> .*apps/${app}/${app}/public$" "$VERBOSE" \
    || fail "sites/assets/${app} is not a symlink to apps/${app}/${app}/public -- bench build did not wire assets"
done
pass "sites/assets/{frappe,erpnext} symlinks present"

# --- built CSS bundles must exist (unstyled-page guard) ------------------------
bundle=$(awk '/apps\/frappe\/frappe\/public\/dist\/css\/[^ ]*\.css$/ {print $NF; exit}' "$VERBOSE")
[[ -n "$bundle" ]] || fail "no built CSS bundle under apps/frappe/frappe/public/dist/css -- bench build output missing"
pass "built frappe CSS bundle present: ${bundle##* }"

echo ""
echo "ALL VALIDATIONS PASSED: $TAR"
