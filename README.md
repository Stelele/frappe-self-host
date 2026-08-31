# BasaPOS Frappe Docker Deployment

Offline-first deploy template for Frappe/ERPNext v16 with custom apps on a single server.

## Quick Start (Offline)

```bash
# 1. Edit your custom apps
vim apps.json

# 2. Configure (everything uses defaults, just set your local domain)
cp .env.example .env
# Default: OFFLINE=true, DOMAIN=basapos.local

# 3. Add to your /etc/hosts (for LAN access)
echo "192.168.1.100 basapos.local" >> /etc/hosts

# 4. Full pipeline
./scripts/deploy-all.sh

# 5. Create site
./scripts/create-site.sh basapos.local
```

Windows: run the GUI installer — see `docs/superpowers/specs/2026-08-31-wsl-docker-parity-installer-design.md` (v3, in development). The old PowerShell/Docker-Desktop flow and the v2 WSL installer are removed.

## Mode: OFFLINE vs ONLINE

| Mode | Config | SSL | Domain Example |
|------|--------|-----|----------------|
| Offline | `OFFLINE=true` | None (HTTP) | `basapos.local` via /etc/hosts |
| Online | `OFFLINE=false` | Let's Encrypt | `erpnext.example.com` (real DNS) |

Set `OFFLINE=true` in `.env` and the deploy script skips Let's Encrypt setup automatically.

## How to Access Offline

Add this line to every client machine's `/etc/hosts` (Linux/macOS) or `C:\Windows\System32\drivers\etc\hosts`:

```
192.168.1.100  basapos.local
```

Then visit `http://basapos.local` in a browser.

## Individual Steps

| Step | Linux |
|------|-------|
| Install Docker | `./scripts/setup.sh` |
| Build image | `./scripts/build.sh` |
| Deploy stack | `./scripts/deploy.sh` |
| Create site | `./scripts/create-site.sh site` |
| Verify health | `./scripts/verify.sh` |
| Tear down | `./scripts/down.sh` |

## Containers Survive Reboots

All services have `restart: unless-stopped` — they come back automatically after a machine restart.

## Traefik

Traefik runs embedded in the stack. In offline mode it routes HTTP traffic based on the hostname. No configuration needed.

## Backup

```bash
./scripts/backup.sh              # Manual backup
./scripts/setup-cron.sh          # Automatic every 6 hours
```

## Updating Apps

```bash
vim apps.json
./scripts/build.sh
./scripts/deploy.sh
```

## Directory Layout

```
frappe-deploy/
├── frappe_docker/       # Git submodule
├── apps.json            # Custom app definitions
├── .env                 # Your config
├── compose.custom.yaml  # Generated compose file
├── scripts/
│   ├── setup.sh     # Install prerequisites
│   ├── deploy-all.sh  # Full pipeline
│   ├── build.sh     # Build Docker image
│   ├── deploy.sh    # Deploy stack
│   ├── verify.sh    # Health check
│   ├── create-site.sh  # Create a new site
│   ├── backup.sh    # Backup all sites
│   ├── restore.sh   # Restore from backup
│   └── setup-cron.sh    # Install backup cron
├── backups/
└── .github/workflows/
```

