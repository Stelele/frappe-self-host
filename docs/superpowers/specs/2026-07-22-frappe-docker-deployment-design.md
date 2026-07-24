# Frappe Docker Production Deployment (Single-Server)

Date: 2026-07-22
Status: Draft

## Overview

A reproducible git-repo template for self-hosting Frappe/ERPNext v16 with custom apps in Docker on a single x86_64 server (Linux or Windows). The goal is one-command deploy that you don't think about.

## Architecture

A standard frappe_docker production stack:

- **Shared MariaDB** — single database container for all sites
- **Shared Redis** — cache + queue instances
- **Traefik** — reverse proxy with automatic Let's Encrypt SSL (one ingress, port 80/443)
- **Frappe Bench (per project)** — backend (gunicorn), frontend (nginx), websocket (Socket.IO), RQ queue workers (short/long), scheduler
- **Migrator** — runs `bench migrate` on deploy automatically
- **Cron backup** — `bench --site all backup --with-files` every 6 hours

## Repository Structure

```
frappe-deploy/
├── frappe_docker/              # git submodule (frappe/frappe_docker)
├── apps.json                   # custom app definitions (URL + branch)
├── .env                        # secrets (DB_PASSWORD, DOMAINS, etc.)
├── .env.example                # template with placeholders
├── scripts/
│   ├── build.sh                # docker build with apps.json secret
│   ├── build.ps1               # PowerShell equivalent
│   ├── deploy.sh               # generate compose + docker compose up
│   ├── deploy.ps1              # PowerShell equivalent
│   ├── create-site.sh          # bench new-site command
│   ├── create-site.ps1         # PowerShell equivalent
│   ├── backup.sh               # backup all sites
│   ├── backup.ps1              # PowerShell equivalent
│   └── restore.sh              # restore from backup
└── .github/workflows/
    └── deploy.yml              # optional CI/CD
```

## Build Flow

`build.sh` runs inside the `frappe_docker/` submodule:

```bash
docker build \
  --build-arg=FRAPPE_PATH=https://github.com/frappe/frappe \
  --build-arg=FRAPPE_BRANCH=version-16 \
  --secret=id=apps_json,src=../apps.json \
  --tag=basapos:16 \
  --file=images/layered/Containerfile .
```

The `apps.json` is passed as a BuildKit secret — never baked into image layers. Custom apps are built immutably into the image (the Docker way).

## Deploy Flow

`deploy.sh` runs:

1. Generate final compose from frappe_docker's base + overrides:
   ```
   docker compose --env-file ../.env \
     -f compose.yaml \
     -f overrides/compose.mariadb.yaml \
     -f overrides/compose.redis.yaml \
     -f overrides/compose.proxy.yaml \
     -f overrides/compose.https.yaml \
     config > compose.custom.yaml
   ```
2. Start everything:
   ```
   docker compose -f compose.custom.yaml up -d
   ```

Traefik handles auto-SSL via Let's Encrypt for all configured domains.

## Site Creation

```bash
docker compose exec backend bench new-site \
  --mariadb-user-host-login-scope=% \
  --db-root-password $DB_PASSWORD \
  --install-app erpnext \
  --install-app my_custom_app \
  --admin-password $ADMIN_PASSWORD \
  example.com
```

## Backup Strategy

A containerized job running `bench --site all backup --with-files` on a cron schedule (every 6 hours). Optionally integrated with restic for offsite snapshots.

## Container Immutability

All app code is baked into the image at build time. To update apps: rebuild the image, redeploy, and the migrator runs `bench migrate`. No live patching, no code drift.

## Scripts (Dual Shell/PowerShell)

Each script has a `.sh` (Linux) and `.ps1` (Windows) variant doing the same thing — `docker compose` commands are identical on both platforms via Docker Desktop.

## References

- https://github.com/frappe/frappe_docker
- https://frappe.github.io/frappe_docker/
- Build docs: https://frappe.github.io/frappe_docker/02-setup/02-build-setup.html
- Production docs: https://frappe.github.io/frappe_docker/03-production/01-tls-ssl-setup.html
- Automated builds: https://frappe.github.io/frappe_docker/03-production/06-automated-builds-and-deployment.html
