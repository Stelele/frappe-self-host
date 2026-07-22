# Frappe Docker Deployment

One-command deploy template for Frappe/ERPNext v16 with custom apps on a single server.

## Prerequisites

- Docker Engine 23.0+ with BuildKit
- Docker Compose v2
- A domain pointing to your server (for SSL)

## Quick Start

```bash
# 1. Edit your custom apps
vim apps.json

# 2. Configure environment
cp .env.example .env
vim .env

# 3. Build the Docker image
./scripts/build.sh

# 4. Deploy
./scripts/deploy.sh

# 5. Create your first site
./scripts/create-site.sh erpnext.example.com
```

## Windows

Open PowerShell as Administrator and run the `.ps1` equivalents:

```powershell
.\scripts\build.ps1
.\scripts\deploy.ps1
.\scripts\create-site.ps1 erpnext.example.com
```

## Backup

```bash
# Manual backup
./scripts/backup.sh

# Automated (Linux) — every 6 hours
./scripts/setup-cron.sh
```

## Updating Apps

1. Update URLs/branches in `apps.json`
2. Run `./scripts/build.sh`
3. Run `./scripts/deploy.sh` (migrator runs automatically)

## Custom App Installation

After site creation, install additional apps:

```bash
docker compose -f compose.custom.yaml exec backend \
  bench --site erpnext.example.com install-app my_custom_app
```

## Directory Layout

```
frappe-deploy/
├── frappe_docker/       # Git submodule
├── apps.json            # Custom app definitions
├── .env                 # Secrets and config
├── compose.custom.yaml  # Generated compose file
├── scripts/
│   ├── build.sh/ps1     # Build Docker image
│   ├── deploy.sh/ps1    # Deploy stack
│   ├── create-site.sh/ps1  # Create a new site
│   ├── backup.sh/ps1    # Backup all sites
│   ├── restore.sh       # Restore from backup
│   └── setup-cron.sh    # Install backup cron job
├── backups/             # Backup destination
└── .github/workflows/   # CI/CD (optional)
```
