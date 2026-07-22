# Frappe Docker Deployment

One-command deploy template for Frappe/ERPNext v16 with custom apps on a single server.

## Quick Start

```bash
# 1. Edit your custom apps
vim apps.json

# 2. Set your domain (that's it — everything else has defaults)
cp .env.example .env
echo "DOMAIN=erpnext.example.com" >> .env
echo "LETSENCRYPT_EMAIL=you@example.com" >> .env

# 3. Full pipeline: setup → build → deploy → verify
./scripts/deploy-all.sh

# 4. Create your first site
./scripts/create-site.sh erpnext.example.com
```

Windows (PowerShell Admin):
```powershell
.\scripts\deploy-all.ps1
.\scripts\create-site.ps1 erpnext.example.com
```

## Individual Steps

| Step | Linux | Windows |
|------|-------|---------|
| Install Docker | `./scripts/setup.sh` | `.\scripts\setup.ps1` |
| Build image | `./scripts/build.sh` | `.\scripts\build.ps1` |
| Deploy stack | `./scripts/deploy.sh` | `.\scripts\deploy.ps1` |
| Create site | `./scripts/create-site.sh site.com` | `.\scripts\create-site.ps1 site.com` |
| Verify health | `./scripts/verify.sh` | `.\scripts\verify.ps1` |

## .env Options

```
DOMAIN=erpnext.example.com       # Shorthand (simpler)
SITES_RULE=Host(`erpnext.example.com`)  # Full Traefik syntax (preferred for multi-domain)
LETSENCRYPT_EMAIL=you@example.com # For auto-SSL
DB_PASSWORD=<random>              # Auto-generated if empty
```

## Containers Survive Reboots

All services have `restart: unless-stopped` — containers restart automatically after machine reboot. No extra config needed.

## Traefik

Traefik runs embedded in the stack — no separate setup, no dashboard to configure. It reads the `SITES_RULE` env var and auto-proxies traffic with Let's Encrypt SSL. That's it.

## Backup

```bash
./scripts/backup.sh              # Manual backup
./scripts/setup-cron.sh          # Automatic every 6 hours
```

## Updating Apps

```bash
vim apps.json                    # Change URLs/branches
./scripts/build.sh               # Rebuild image
./scripts/deploy.sh              # Redeploy (auto-migrates)
```

## Directory Layout

```
frappe-deploy/
├── frappe_docker/       # Git submodule
├── apps.json            # Custom app definitions
├── .env                 # Your config
├── compose.custom.yaml  # Generated compose file
├── scripts/
│   ├── setup.sh/ps1     # Install prerequisites
│   ├── deploy-all.sh/ps1  # Full pipeline
│   ├── build.sh/ps1     # Build Docker image
│   ├── deploy.sh/ps1    # Deploy stack
│   ├── verify.sh/ps1    # Health check
│   ├── create-site.sh/ps1  # Create a new site
│   ├── backup.sh/ps1    # Backup all sites
│   ├── restore.sh       # Restore from backup
│   └── setup-cron.sh    # Install backup cron
├── backups/
└── .github/workflows/
```
