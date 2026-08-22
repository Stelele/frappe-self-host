#!/usr/bin/env bash
set -euo pipefail
log() { echo "[provision] $*"; }

install_bench_cli() {
  log "installing frappe-bench"
  pip3 install --no-cache-dir "frappe-bench==5.31.0"
  if [ "$(command -v bench)" != "/usr/local/bin/bench" ]; then
    ln -sf "$(command -v bench)" /usr/local/bin/bench
  fi
  chmod o+r /usr/local/bin/bench
}

create_user() {
  log "creating unprivileged frappe user"
  id -u frappe >/dev/null 2>&1 || useradd -ms /bin/bash frappe
}

init_bench_and_apps() {
  log "bench init (frappe version-16)"
  sudo -u frappe bash -lc '
    set -e
    cd "$HOME"
    bench init --frappe-branch version-16 --python /usr/local/bin/python3.14 --verbose bench
    cd bench
    for row in $(jq -c ".[]" /tmp/apps.json); do
      url=$(jq -r ".url" <<<"$row"); branch=$(jq -r ".branch" <<<"$row")
      name=$(basename "$url" .git)
      echo "[provision] get-app $name@$branch"
      bench get-app "$url" --branch "$branch"
    done
  '
}

MARIADB_ROOT_PW="BasaPOS-root-2026"   # localhost-only; documented in spec §8

bootstrap_mariadb() {
  log "initializing + starting mariadb"
  mkdir -p /run/mysqld && chown mysql:mysql /run/mysqld
  mariadb-install-db --user=mysql --datadir=/var/lib/mysql >/dev/null 2>&1 || true
  ( mysqld_safe --skip-syslog >/var/log/mysqld-provision.log 2>&1 & )
  for i in $(seq 1 60); do
    mariadb-admin ping >/dev/null 2>&1 && break
    sleep 2
  done
  mariadb-admin ping || { echo "mariadb did not start"; tail -30 /var/log/mysqld-provision.log >&2; exit 1; }
  mariadb -e "SET PASSWORD FOR 'root'@'localhost' = PASSWORD('${MARIADB_ROOT_PW}');
              FLUSH PRIVILEGES;"
  log "mariadb ready (root pw set, native auth)"
}

bootstrap_redis() {
  log "starting redis"
  redis-server --daemonize yes --save '' --appendonly no
  redis-cli ping | grep -q PONG
}

SITE="basapos.local"
BUILD_ADMIN_PW="reset-at-install-time"   # throwaway; Plan B resets on install

create_site() {
  log "creating site ${SITE}"
  sudo -u frappe bash -lc "
    set -e
    cd \$HOME/bench
    # global config BEFORE new-site: bench init seeds dev-default redis ports
    # (queue @11000 etc.) which erpnext's install hits; repoint to 6379 first.
    bench set-config -g db_host 127.0.0.1
    bench set-config -g redis_cache redis://127.0.0.1:6379
    bench set-config -g redis_queue redis://127.0.0.1:6379
    bench set-config -g redis_socketio redis://127.0.0.1:6379
    bench set-config -g socketio_port 9000
    bench new-site ${SITE} \
      --mariadb-root-password '${MARIADB_ROOT_PW}' \
      --admin-password '${BUILD_ADMIN_PW}' \
      --install-app erpnext
    # custom apps (everything cloned beyond frappe/erpnext).
    # Clone dirs ARE the internal app names (verified in Task 4):
    #   awesome_dashboard_scripts -> awesome_dashboard
    #   awesome-butchery          -> awesome_butchery
    #   erpnext-point-of-sale-expenses -> pos_expenses
    for d in \$(ls /home/frappe/bench/apps | grep -vE '^(frappe|erpnext)\$'); do
      echo \"[provision] install-app \$d\"
      bench --site ${SITE} install-app \"\$d\"
    done
    bench use ${SITE}
    # bench 5.31 stores the selection as "default_site" in common_site_config.json
    # instead of currentsite.txt; keep the legacy file too for older tooling.
    echo "${SITE}" > \$HOME/bench/sites/currentsite.txt
    bench set-config -gp maintenance_mode 0
    bench set-config -gp pause_scheduler 0
  "
}

wire_nginx() {
  log "wiring nginx site"
  rm -f /etc/nginx/sites-enabled/default
  rm -f /etc/nginx/sites-available/.gitkeep
  mkdir -p /etc/nginx/ssl
  ln -sf /etc/nginx/sites-available/basapos.conf /etc/nginx/sites-enabled/basapos.conf
  # Build-time THROWAWAY cert (CN=build-time-placeholder) so `nginx -t` passes;
  # the real per-machine cert (unique CN) is generated at WSL boot by the
  # basapos-firstboot unit (Task 7), whose ConditionPathExists logic checks a
  # marker/CN — Task 7's hygiene step REMOVES this placeholder so firstboot
  # regenerates it.
  openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout /etc/nginx/ssl/basapos.key -out /etc/nginx/ssl/basapos.crt \
    -subj "/CN=build-time-placeholder" >/dev/null 2>&1
  nginx -t
}

shutdown_dbs() {
  log "graceful db shutdown"
  mariadb-admin shutdown || true
  redis-cli shutdown nosave || true
  sleep 2
  pgrep -x mysqld && { echo "mysqld still alive"; exit 1; } || true
}

install_bench_cli
create_user
init_bench_and_apps
bootstrap_mariadb
bootstrap_redis
create_site
wire_nginx
shutdown_dbs
echo "[provision] TASK6 COMPLETE"
