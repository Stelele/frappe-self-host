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
  mariadb-admin ping || { echo "mariadb did not start"; exit 1; }
  mariadb -e "SET PASSWORD FOR 'root'@'localhost' = PASSWORD('${MARIADB_ROOT_PW}');
              FLUSH PRIVILEGES;"
  log "mariadb ready (root pw set, native auth)"
}

bootstrap_redis() {
  log "starting redis"
  redis-server --daemonize yes --save '' --appendonly no
  redis-cli ping | grep -q PONG
}

install_bench_cli
create_user
init_bench_and_apps
bootstrap_mariadb
bootstrap_redis
echo "[provision] TASK5 COMPLETE"
