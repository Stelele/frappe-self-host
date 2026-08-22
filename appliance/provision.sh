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

install_bench_cli
create_user
init_bench_and_apps
echo "[provision] TASK4 COMPLETE"
