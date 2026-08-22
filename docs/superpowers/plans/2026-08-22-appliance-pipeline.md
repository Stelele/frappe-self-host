# Appliance Pipeline Implementation Plan (M1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reproducible CI-built WSL appliance rootfs (`basapos-rootfs.tar.gz`) produced entirely from this repo — killing the prototype's black-box tarball.

**Architecture:** A staged Docker build (Ubuntu 22.04 → runtime deps → bench + site → systemd wiring → WSL hygiene) whose final container filesystem is `docker export`ed to a gzipped tarball, validated by structural assertions, and published as a CI artifact.

**Tech Stack:** Docker, Ubuntu 22.04 (jammy), Frappe version-16 via `apps.json`, MariaDB, Redis, nginx, systemd-in-WSL, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-08-22-wsl-native-windows-installer-design.md` §4 (Appliance Pipeline), milestone M1.

**Verification environment:** local Linux + Docker (all tasks); CI mirrors the same steps.

---

## File Structure

```
appliance/
├── Containerfile              # staged image build (context = repo root!)
├── provision.sh               # build-time provisioning (runs inside container)
├── validate.sh                # structural assertions on exported tarball
├── build.sh                   # orchestrates build → export → validate
├── mariadb/50-basapos.cnf     # frappe-required MariaDB settings
└── overlay/
    ├── etc/wsl.conf           # enables systemd, pins hostname, static hosts
    ├── etc/hosts              # shipped because generateHosts=false
    └── etc/nginx/sites-available/basapos.conf
.github/workflows/appliance.yml  # CI: build → smoke → export → validate → artifact
.gitignore                       # + appliance/dist/
```

**Context convention:** every `docker build` uses the **repo root** as context with `-f appliance/Containerfile`, so `apps.json` is visible to the build.

**Naming conventions:** image `basapos-appliance:16` · artifact `appliance/dist/basapos-rootfs.tar.gz` · distro name (used later by Plan B) `BasaPOS` · domain `basapos.local`.

**Deliberate choices locked here:** Ubuntu 22.04 (official `wkhtmltox` jammy deb exists; Python 3.10 satisfies v16) · single Redis instance on 6379 serving cache+queue+socketio · systemd units hand-enabled via `multi-user.target.wants` symlinks (no systemd running during docker build) · `generateHosts=false` so our shipped `/etc/hosts` (with `basapos.local`) survives boots · build-time throwaway admin password, reset at install time by Plan B · MariaDB root gets native-password auth with a documented localhost-only credential so both `bench new-site` and future backup-restores work deterministically.

---

### Task 1: Scaffold appliance tree + WSL overlay files

**Files:**
- Create: `appliance/overlay/etc/wsl.conf`
- Create: `appliance/overlay/etc/hosts`
- Create: `appliance/mariadb/50-basapos.cnf`
- Modify: `.gitignore`

- [ ] **Step 1: Create `appliance/overlay/etc/wsl.conf`**

```ini
[boot]
systemd=true

[network]
hostname=basapos
generateHosts=false

[user]
default=frappe
```

- [ ] **Step 2: Create `appliance/overlay/etc/hosts`**

Shipped verbatim because `generateHosts=false` stops WSL regenerating it.

```
127.0.0.1	localhost
127.0.1.1	basapos
127.0.0.1	basapos.local

# The following lines are desirable for IPv6 capability
::1     ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
```

- [ ] **Step 3: Create `appliance/mariadb/50-basapos.cnf`**

Frappe's required MariaDB settings (from official native-install docs).

```ini
[client]
default-character-set = utf8mb4

[mysqld]
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

innodb_file_format = Barracuda
innodb_file_per_table = 1
innodb_large_prefix = ON
innodb_buffer_pool_size = 512M
innodb_log_file_size = 128M

bind-address = 127.0.0.1
```

- [ ] **Step 4: Append to `.gitignore`**

```gitignore
appliance/dist/
```

- [ ] **Step 5: Verify tree**

Run: `find appliance -type f | sort && tail -3 .gitignore`
Expected: the four new paths listed; `.gitignore` ends with `appliance/dist/`.

- [ ] **Step 6: Commit**

```bash
git add appliance .gitignore
git commit -m "feat(appliance): scaffold WSL appliance tree with wsl.conf, hosts, mariadb config"
```

---

### Task 2: Validation harness first (the failing test)

The tarball doesn't exist yet — this task's script must FAIL now and PASS after Task 8.

**Files:**
- Create: `appliance/validate.sh`

- [ ] **Step 1: Write `appliance/validate.sh`**

```bash
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
```

- [ ] **Step 2: Make executable and run against nonexistent tarball**

Run: `chmod +x appliance/validate.sh && bash appliance/validate.sh appliance/dist/basapos-rootfs.tar.gz; echo "exit=$?"`
Expected: `FAIL: tarball not found:` … `exit=1`

- [ ] **Step 3: Commit**

```bash
git add appliance/validate.sh
git commit -m "test(appliance): tarball structural validation harness"
```

---

### Task 3: Containerfile — base stage (deps, node, wkhtmltopdf, configs)

**Files:**
- Create: `appliance/Containerfile`

- [ ] **Step 1: Resolve and pin the base image digest**

Run: `docker pull ubuntu:22.04 && docker inspect --format '{{index .RepoDigests 0}}' ubuntu:22.04`
Expected output like: `ubuntu@sha256:abc123…` — record it; you'll paste it into Step 2.

- [ ] **Step 2: Write `appliance/Containerfile`**

Replace `ubuntu@sha256:REPLACE_ME` with the digest from Step 1.

```dockerfile
# BasaPOS WSL appliance — built from repo root:
#   docker build -f appliance/Containerfile -t basapos-appliance:16 .
FROM ubuntu@sha256:REPLACE_ME

ENV DEBIAN_FRONTEND=noninteractive \
    LC_ALL=C.UTF-8 \
    LANG=C.UTF-8

# ---- system packages --------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl wget git gnupg lsb-release sudo jq \
      build-essential pkg-config \
      python3.10 python3.10-dev python3-pip python3.10-venv \
      libpython3.10-dev libffi-dev libssl-dev libmariadb-dev \
      mariadb-server mariadb-client \
      redis-server \
      nginx \
      fontconfig libxrender1 libxext6 xfonts-75dpi xfonts-base \
      openssl cron file \
    && rm -rf /var/lib/apt/lists/*

# ---- Node 20 -----------------------------------------------------------------
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && npm install --global yarn@1.22.19 \
    && rm -rf /var/lib/apt/lists/*

# ---- patched wkhtmltopdf (official jammy build) ------------------------------
RUN curl -fsSL -o /tmp/wkhtmltox.deb \
      https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-2/wkhtmltox_0.12.6.1-2.jammy_amd64.deb \
    && dpkg -i /tmp/wkhtmltox.deb 2>/dev/null || apt-get -f install -y \
    && rm -f /tmp/wkhtmltox.deb

# ---- frappe-required MariaDB tuning ------------------------------------------
COPY appliance/mariadb/50-basapos.cnf /etc/mysql/mariadb.conf.d/50-basapos.cnf

# ---- overlay (wsl.conf, hosts, nginx site) -----------------------------------
COPY appliance/overlay/ /

# ---- provisioning payload -----------------------------------------------------
COPY appliance/provision.sh /opt/provision.sh
COPY apps.json /tmp/apps.json
RUN chmod +x /opt/provision.sh

# ---- provision -----------------------------------------------------------------
RUN bash /opt/provision.sh

CMD ["/bin/bash"]
```

Note: `nginx` ships with a default site that would clash; `provision.sh` (Task 6) removes it.

- [ ] **Step 3: Create stub provision so the build completes**

Create `appliance/provision.sh` containing only:

```bash
#!/usr/bin/env bash
set -euo pipefail
echo "[provision] stub — filled in Tasks 4-7"
```

- [ ] **Step 4: Build (expect success)**

Run (repo root): `docker build -f appliance/Containerfile -t basapos-appliance:16 . 2>&1 | tail -5`
Expected: ends with `DONE` / writes image `basapos-appliance:16`. First run downloads ~400 MB of packages — slow is normal.

- [ ] **Step 5: Spot-check installed pieces**

Run: `docker run --rm basapos-appliance:16 bash -c 'node -v && python3 --version && wkhtmltopdf --version | head -1 && ls /etc/mysql/mariadb.conf.d/50-basapos.cnf /etc/wsl.conf'`
Expected: `v20.x`, `Python 3.10.x`, `wkhtmltopdf 0.12.6 (with patched qt)`, both listed files.

- [ ] **Step 6: Commit**

```bash
git add appliance/Containerfile appliance/provision.sh
git commit -m "feat(appliance): pinned base image stage with frappe v16 runtime deps"
```

---

### Task 4: Provision — user, bench, apps from apps.json

Append functions to `appliance/provision.sh` and call them. Everything below replaces the stub body progressively — final call order comes in Task 7.

- [ ] **Step 1: Append user + bench install to `appliance/provision.sh`**

```bash
log() { echo "[provision] $*"; }

install_bench_cli() {
  log "installing frappe-bench"
  pip3 install --no-cache-dir "frappe-bench==$(pip3 index versions frappe-bench 2>/dev/null \
    | head -1 | grep -oP '(?<=\()5\.[0-9.]+(?=\))' || echo 5.25.1)"
  # NOTE: executor — run `pip3 index versions frappe-bench` once, pin the latest
  # 5.x.y EXACTLY in the line above, removing the dynamic fallback.
  ln -sf "$(command -v bench)" /usr/local/bin/bench
  chmod o+r /usr/local/bin/bench
}

create_user() {
  log "creating unprivileged frappe user"
  id -u frappe >/dev/null 2>&1 || useradd -ms /bin/bash frappe
}
```

Also append the temporary driver at the bottom:

```bash
install_bench_cli
create_user
echo "[provision] TASK4 COMPLETE"
```

- [ ] **Step 2: Pin bench version concretely**

Run: `docker run --rm basapos-appliance:16 pip3 index versions frappe-bench | head -3`
Take the newest `5.x.y`, edit `provision.sh` to `pip3 install --no-cache-dir "frappe-bench==5.x.y"` (drop the dynamic expression).

- [ ] **Step 3: Append app install function**

```bash
init_bench_and_apps() {
  log "bench init (frappe version-16)"
  sudo -u frappe bash -lc '
    set -e
    cd "$HOME"
    bench init --frappe-branch version-16 --verbose bench
    cd bench
    for row in $(jq -c ".[]" /tmp/apps.json); do
      url=$(jq -r ".url" <<<"$row"); branch=$(jq -r ".branch" <<<"$row")
      name=$(basename "$url" .git)
      echo "[provision] get-app $name@$branch"
      bench get-app "$url" --branch "$branch"
    done
  '
}
```

Add `init_bench_and_apps` to the driver block (after `create_user`). Replace `TASK4 COMPLETE` line when done.

- [ ] **Step 4: Rebuild and verify apps landed**

Run (repo root): `docker build -f appliance/Containerfile -t basapos-appliance:16 . 2>&1 | tail -3 && docker run --rm basapos-appliance:16 ls /home/frappe/bench/apps`
Expected: `erpnext  frappe` plus your three custom apps (`awesome_dashboard_scripts`, `awesome-butchery`, `erpnext-point-of-sale-expenses`). Long build (~10–25 min) — normal.

- [ ] **Step 5: Commit**

```bash
git add appliance/provision.sh
git commit -m "feat(appliance): bench init + apps.json-driven get-app provisioning"
```

---

### Task 5: Provision — databases up at build time

- [ ] **Step 1: Append DB bootstrap to `appliance/provision.sh`**

```bash
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
```

Driver additions (after `init_bench_and_apps`): `bootstrap_mariadb`, `bootstrap_redis`.

Why start them now: `bench new-site` (Task 6) needs live MariaDB+Redis inside the container. They are NOT left running in the image — the export captures a stopped filesystem; WSL+systemd starts them at boot via the enabled units.

- [ ] **Step 2: Rebuild, expect DB stages green**

Run: `docker build -f appliance/Containerfile -t basapos-appliance:16 . 2>&1 | grep -E '\[provision\]|ERROR'`
Expected: `[provision] mariadb ready …` then `[provision] starting redis` and build success.

- [ ] **Step 3: Commit**

```bash
git add appliance/provision.sh
git commit -m "feat(appliance): build-time mariadb/redis bootstrap for site creation"
```

---

### Task 6: Provision — site, production config, nginx

- [ ] **Step 1: Append site creation to `appliance/provision.sh`**

```bash
SITE="basapos.local"
BUILD_ADMIN_PW="reset-at-install-time"   # throwaway; Plan B resets on install

create_site() {
  log "creating site ${SITE}"
  sudo -u frappe bash -lc "
    set -e
    cd \$HOME/bench
    bench new-site ${SITE} \
      --mariadb-root-password '${MARIADB_ROOT_PW}' \
      --admin-password '${BUILD_ADMIN_PW}' \
      --install-app erpnext
    # custom apps (everything in apps.json beyond erpnext/frappe)
    for name in \$(jq -r '.[].url' /tmp/apps.json | xargs -n1 basename | sed 's/\.git\$//' | grep -vE '^(frappe|erpnext)\$'); do
      echo \"[provision] install-app \$name\"
      bench --site ${SITE} install-app \"\$name\"
    done
    bench use ${SITE}
    bench set-config -g db_host 127.0.0.1
    bench set-config -g redis_cache redis://127.0.0.1:6379
    bench set-config -g redis_queue redis://127.0.0.1:6379
    bench set-config -g redis_socketio redis://127.0.0.1:6379
    bench set-config -g socketio_port 9000
    bench set-config -gp maintenance_mode 0
    bench set-config -gp pause_scheduler 0
  "
}
```

- [ ] **Step 2: Append nginx site wiring**

```bash
wire_nginx() {
  log "wiring nginx site"
  rm -f /etc/nginx/sites-enabled/default
  mkdir -p /etc/nginx/ssl
  # cert generated per-machine at first boot (unique CN) — see basapos-firstboot
  chown frappe:frappe /home/frappe/bench
  nginx -t
}
```

Create **`appliance/overlay/etc/nginx/sites-available/basapos.conf`**:

```nginx
upstream basapos-gunicorn-server {
    server 127.0.0.1:8000 fail_timeout=0;
}
upstream basapos-socketio-server {
    server 127.0.0.1:9000 fail_timeout=0;
}

server {
    listen 80;
    server_name basapos.local;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name basapos.local;

    ssl_certificate     /etc/nginx/ssl/basapos.crt;
    ssl_certificate_key /etc/nginx/ssl/basapos.key;
    ssl_protocols TLSv1.2 TLSv1.3;

    root /home/frappe/bench/sites;

    location /assets {
        try_files $uri =404;
        add_header Cache-Control "max-age=31536000";
    }
    location ~ ^/protected/ {
        internal;
        try_files /$uri =404;
    }
    location /socket.io {
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header X-Frappe-Site-name basapos.local;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header Host $host;
        proxy_pass http://basapos-socketio-server;
    }
    location / {
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Frappe-Site-Name basapos.local;
        proxy_set_header Host $host;
        proxy_pass http://basapos-gunicorn-server;
    }
}
```

And enable symlink inside `wire_nginx()`:

```bash
  ln -sf /etc/nginx/sites-available/basapos.conf /etc/nginx/sites-enabled/basapos.conf
```

Driver addition: `create_site`, then `wire_nginx`.

- [ ] **Step 3: Rebuild — expect site created**

Run: `docker build -f appliance/Containerfile -t basapos-appliance:16 . 2>&1 | grep -E '\[provision\]|ERROR|FAILED'`
Expected: `[provision] creating site basapos.local`, per-app install lines, `nginx: configuration file … test is successful`, success exit.

- [ ] **Step 4: Commit**

```bash
git add appliance/provision.sh appliance/overlay/etc/nginx/sites-available/basapos.conf
git commit -m "feat(appliance): site creation, common config, nginx production wiring"
```

---

### Task 7: Systemd units + firstboot + hygiene + final call order

**Files:**
- Create: `appliance/overlay/etc/systemd/system/basapos-gunicorn.service`
- Create: `appliance/overlay/etc/systemd/system/basapos-socketio.service`
- Create: `appliance/overlay/etc/systemd/system/basapos-worker-short.service`
- Create: `appliance/overlay/etc/systemd/system/basapos-worker-long.service`
- Create: `appliance/overlay/etc/systemd/system/basapos-scheduler.service`
- Create: `appliance/overlay/etc/systemd/system/basapos-firstboot.service`
- Modify: `appliance/provision.sh` (enable_units, hygiene, driver order)

- [ ] **Step 1: App/service units** (shared pattern; `After=` chains on mariadb/redis/network)

`basapos-gunicorn.service`:

```ini
[Unit]
Description=BasaPOS gunicorn (frappe web)
After=network.target mariadb.service redis-server.service basapos-firstboot.service
Wants=mariadb.service redis-server.service

[Service]
User=frappe
WorkingDirectory=/home/frappe/bench/sites
ExecStart=/home/frappe/bench/env/bin/gunicorn \
  --chdir=/home/frappe/bench/sites \
  --bind=127.0.0.1:8000 \
  --threads=4 --workers=3 --timeout=120 \
  frappe.app:application --preload
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

`basapos-socketio.service`: same header/footer; body:

```ini
ExecStart=/usr/bin/node /home/frappe/bench/apps/frappe/socketio.js
Environment=NODE_ENV=production
```

`basapos-worker-short.service` / `basapos-worker-long.service`: same header/footer; bodies respectively:

```ini
ExecStart=/home/frappe/bench/env/bin/python -m frappe.utils.bench_helper frappe worker --queue short,default
```

```ini
ExecStart=/home/frappe/bench/env/bin/python -m frappe.utils.bench_helper frappe worker --queue long,default,low
```

`basapos-scheduler.service`:

```ini
ExecStart=/home/frappe/bench/env/bin/python -m frappe.utils.bench_helper frappe schedule
```

All five: `Restart=always`, `RestartSec=5`, `User=frappe`, `WantedBy=multi-user.target`.

- [ ] **Step 2: Firstboot unit (per-machine TLS cert)**

`basapos-firstboot.service`:

```ini
[Unit]
Description=BasaPOS first-boot (TLS cert generation)
Before=nginx.service
ConditionPathExists=!/etc/nginx/ssl/basapos.crt

[Service]
Type=oneshot
ExecStart=/usr/bin/openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
  -keyout /etc/nginx/ssl/basapos.key -out /etc/nginx/ssl/basapos.crt \
  -subj "/CN=basapos.local" \
  -addext "subjectAltName=DNS:basapos.local,DNS:localhost,IP:127.0.0.1"

[Install]
WantedBy=multi-user.target
```

(`ConditionPathExists=!…` keeps it idempotent — regenerates only when cert absent.)

- [ ] **Step 3: Enablement + hygiene in `appliance/provision.sh`**

```bash
enable_units() {
  log "enabling systemd units (offline symlink method)"
  local wants=/etc/systemd/system/multi-user.target.wants
  mkdir -p "$wants"
  local units=(basapos-gunicorn basapos-socketio basapos-worker-short \
               basapos-worker-long basapos-scheduler basapos-firstboot \
               mariadb redis-server)
  for u in "${units[@]}"; do
    ln -sf "/etc/systemd/system/${u}.service" "${wants}/${u}.service"
  done
}

hygiene() {
  log "WSL hygiene: ids, caches, logs"
  truncate -s 0 /etc/machine-id          # WSL regenerates on import
  : > /var/lib/dbus/machine-id || true
  echo basapos > /etc/hostname
  apt-get clean
  rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
  find /var/log -type f -name '*.log' -exec truncate -s 0 {} \; 2>/dev/null || true
  rm -f /var/log/mysqld-provision.log /opt/provision.sh  # provision traces gone
}
```

- [ ] **Step 4: Final driver block** (replaces all partial drivers):

```bash
install_bench_cli
create_user
init_bench_and_apps
bootstrap_mariadb
bootstrap_redis
create_site
wire_nginx
enable_units
hygiene
echo "[provision] APPLIANCE READY"
```

- [ ] **Step 5: Full rebuild**

Run: `docker build -f appliance/Containerfile -t basapos-appliance:16 . && echo BUILD_OK`
Expected: `BUILD_OK`.

- [ ] **Step 6: In-image smoke assertions**

Run:
```bash
docker run --rm basapos-appliance:16 bash -c '
  test -x /home/frappe/bench/env/bin/gunicorn &&
  test -L /etc/systemd/system/multi-user.target.wants/basapos-gunicorn.service &&
  [[ ! -s /etc/nginx/ssl/basapos.crt ]] &&
  [[ $(wc -c </etc/machine-id) -eq 0 ]] &&
  grep -q basapos.local /etc/hosts &&
  echo SMOKE_OK'
```
Expected: `SMOKE_OK`.

- [ ] **Step 7: Commit**

```bash
git add appliance/overlay/etc/systemd/system appliance/provision.sh
git commit -m "feat(appliance): systemd units, firstboot TLS, hygiene, final pipeline order"
```

---

### Task 8: Export + validate green

**Files:**
- Create: `appliance/build.sh`

- [ ] **Step 1: Write `appliance/build.sh`**

```bash
#!/usr/bin/env bash
# Build → export → validate the BasaPOS WSL appliance rootfs.
# Usage: bash appliance/build.sh            (run from anywhere; self-locates repo root)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
IMAGE=basapos-appliance:16
OUT=appliance/dist/basapos-rootfs.tar.gz

echo "== build image =="
docker build -f appliance/Containerfile -t "$IMAGE" .

echo "== in-image smoke =="
docker run --rm "$IMAGE" bash -c '
  test -x /home/frappe/bench/env/bin/gunicorn &&
  test -L /etc/systemd/system/multi-user.target.wants/basapos-gunicorn.service &&
  [[ ! -s /etc/nginx/ssl/basapos.crt ]] &&
  [[ $(wc -c </etc/machine-id) -eq 0 ]] &&
  grep -q basapos.local /etc/hosts && echo SMOKE_OK' | grep -q SMOKE_OK

echo "== export rootfs =="
mkdir -p "$(dirname "$OUT")"
CID=$(docker create "$IMAGE")
trap 'docker rm "$CID" >/dev/null 2>&1 || true' EXIT
docker export "$CID" | gzip -1 > "$OUT"

echo "== validate =="
bash appliance/validate.sh "$OUT"

ls -lh "$OUT"
```

- [ ] **Step 2: Run the full pipeline**

Run: `chmod +x appliance/build.sh && bash appliance/build.sh`
Expected: `ALL VALIDATIONS PASSED` and a size print (~1–2 GB). If validate flags anything, fix the offending task above and rerun — do NOT weaken assertions.

- [ ] **Step 3: Commit**

```bash
git add appliance/build.sh
git commit -m "feat(appliance): one-command build/export/validate pipeline"
```

---

### Task 9: CI workflow

**Files:**
- Create: `.github/workflows/appliance.yml`

- [ ] **Step 1: Write `.github/workflows/appliance.yml`**

```yaml
name: appliance

on:
  push:
    branches: [main]
    paths: ["appliance/**", "apps.json", ".github/workflows/appliance.yml"]
  pull_request:
    paths: ["appliance/**", "apps.json", ".github/workflows/appliance.yml"]
  workflow_dispatch:

jobs:
  build:
    runs-on: ubuntu-latest
    timeout-minutes: 90
    steps:
      - uses: actions/checkout@v4

      - uses: docker/setup-buildx-action@v3

      - name: Build appliance image (GHA layer cache)
        uses: docker/build-push-action@v6
        with:
          context: .
          file: appliance/Containerfile
          tags: basapos-appliance:16
          load: true
          cache-from: type=gha
          cache-to: type=gha,mode=max

      - name: Smoke
        run: |
          docker run --rm basapos-appliance:16 bash -c '
            test -x /home/frappe/bench/env/bin/gunicorn &&
            test -L /etc/systemd/system/multi-user.target.wants/basapos-gunicorn.service &&
            [[ $(wc -c </etc/machine-id) -eq 0 ]] && echo SMOKE_OK' | grep -q SMOKE_OK

      - name: Export rootfs
        run: |
          mkdir -p appliance/dist
          CID=$(docker create basapos-appliance:16)
          docker export "$CID" | gzip -1 > appliance/dist/basapos-rootfs.tar.gz
          docker rm "$CID" >/dev/null

      - name: Validate
        run: bash appliance/validate.sh appliance/dist/basapos-rootfs.tar.gz

      - name: Checksum + size report
        run: |
          cd appliance/dist
          sha256sum basapos-rootfs.tar.gz > SHA256SUMS
          cat SHA256SUMS && ls -lh basapos-rootfs.tar.gz

      - uses: actions/upload-artifact@v4
        with:
          name: basapos-rootfs
          path: appliance/dist/
```

- [ ] **Step 2: Local dry-check of workflow syntax**

Run: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/appliance.yml')); print('YAML_OK')"`
Expected: `YAML_OK`.

- [ ] **Step 3: Push branch, watch run green**

Run: `git push -u origin feat/appliance-pipeline` then open the Actions tab.
Expected: `appliance → build` job succeeds; artifact `basapos-rootfs` downloadable. (First uncached run ≈ 30–60 min; subsequent runs hit layer cache.)

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/appliance.yml
git commit -m "ci(appliance): build, smoke, export, validate, publish rootfs artifact"
```

---

### Task 10: Docs touch-up

- [ ] **Step 1: Append an "Appliance (Windows target)" section to `README.md`**

```markdown
## Appliance Rootfs (Windows target)

The Windows installer (see `docs/superpowers/specs/2026-08-22-wsl-native-windows-installer-design.md`)
consumes a WSL-importable rootfs built from `appliance/`:

    bash appliance/build.sh     # build → smoke → export → validate
    # → appliance/dist/basapos-rootfs.tar.gz

CI produces the same artifact on every push touching `appliance/**` or `apps.json`.
App changes: edit `apps.json` — shared source of truth with the Docker flow.
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: appliance rootfs build instructions"
```

---

## Out of scope (deliberately)

| Item | Lands in |
|---|---|
| Setup.exe, launcher changes, setup.ps1 de-hardcoding | Plan B |
| Autostart scheduled task + boot wrapper | Plan B |
| Upgrade drill (backup→swap→restore) | Plan B |
| Runtime boot E2E (WSL import + health probe in GH Windows runner) | Plan B |
| LAN_MODE plumbing | Plan B (flag off) |

## Risks / known unknowns

- **socketio entrypoint path** may differ on v16 (`apps/frappe/socketio.js` vs bundled node server). Verified implicitly by Task 9's CI boot? No — first *runtime* boot happens in Plan B's E2E; if the unit fails there, fix path in Task 7's unit and rebuild.
- **Custom app install failures** surface at Task 6 build (get-app/install-app) — fix `apps.json` branches, not the appliance.
- **Tarball size**: `gzip -1` trades size for speed; if >2 GB becomes a problem, switch to `zstd` later.
