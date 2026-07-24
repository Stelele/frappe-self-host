# Frappe Docker Production Deployment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a reproducible Git repo template for self-hosting Frappe/ERPNext v16 with custom apps via Docker on a single x86_64 server (Linux + Windows support).

**Architecture:** A single git repo containing a frappe_docker submodule, custom app definitions (apps.json), env config, and dual-platform scripts (bash + PowerShell) for build, deploy, site creation, and backup. The Docker image is built immutably with custom apps baked in via BuildKit secrets.

**Tech Stack:** Docker, Docker Compose v2, Frappe v16, ERPNext v16, Traefik, MariaDB, Redis, Bash, PowerShell, GitHub Actions (optional CI/CD)

**Root directory:** `/home/gift/Documents/code-projects/frappe-offline`

---

### Task 1: Initialize Repo + frappe_docker Submodule

**Files:**
- Create: `.gitignore`
- Create: `.gitattributes`

- [ ] **Step 1: Write .gitignore**

```
# OS
.DS_Store
Thumbs.db

# Environment
.env
.env.local

# Docker
compose.custom.yaml

# IDE
.idea/
.vscode/
*.swp
*.swo
```

- [ ] **Step 2: Write .gitattributes**

```
* text=auto eol=lf
*.ps1 text eol=crlf
```

- [ ] **Step 3: Initialize git and add submodule**

Run: `cd /home/gift/Documents/code-projects/frappe-offline`
Run: `git init`
Run: `git submodule add https://github.com/frappe/frappe_docker.git`
Expected: frappe_docker/ directory populated with the repo.

- [ ] **Step 4: Initial commit**

Run:
```
git add .gitignore .gitattributes .gitmodules frappe_docker
git commit -m "chore: init repo with frappe_docker submodule"
```

---

### Task 2: Create apps.json

**Files:**
- Create: `apps.json`

- [ ] **Step 1: Write apps.json**

```json
[
  {
    "url": "https://github.com/frappe/erpnext",
    "branch": "version-16"
  },
  {
    "url": "https://github.com/frappe/hrms",
    "branch": "version-16"
  }
]
```

Note: User replaces these with their actual custom app repos.

- [ ] **Step 2: Commit**

Run: `git add apps.json && git commit -m "feat: add custom app definitions"`

---

### Task 3: Create .env.example and .env

**Files:**
- Create: `.env.example`
- Create: `.env`

- [ ] **Step 1: Write .env.example**

```bash
# Domains
DOMAINS=erpnext.example.com
SITES_RULE=Host(`erpnext.example.com`)

# Database
DB_PASSWORD=change_this_to_random_password
DB_HOST=mariadb-database
DB_PORT=3306

# Admin
ADMIN_PASSWORD=admin

# Let's Encrypt
LETSENCRYPT_EMAIL=admin@example.com
TRAEFIK_DOMAIN=traefik.example.com

# Docker image
CUSTOM_IMAGE=custom
CUSTOM_TAG=16
```

- [ ] **Step 2: Copy to .env with placeholder values**

Run: `cp .env.example .env`

- [ ] **Step 3: Add both to .gitignore (already done) and commit**

Run: `git add .env.example && git commit -m "chore: add env template"`

---

### Task 4: Create Build Scripts

**Files:**
- Create: `scripts/build.sh`
- Create: `scripts/build.ps1`

- [ ] **Step 1: Write build.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

cd "$REPO_DIR/frappe_docker"

echo "Building custom Frappe v16 image with apps from ../apps.json..."

docker build \
  --build-arg=FRAPPE_PATH=https://github.com/frappe/frappe \
  --build-arg=FRAPPE_BRANCH=version-16 \
  --build-arg=CACHE_BUST="$(date +%s)" \
  --secret=id=apps_json,src=../apps.json \
  --tag=basapos:16 \
  --file=images/layered/Containerfile .

echo "Build complete: basapos:16"
```

- [ ] **Step 2: Write build.ps1**

```powershell
#!/usr/bin/env pwsh
param()

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoDir = Split-Path -Parent $ScriptDir

Set-Location "$RepoDir/frappe_docker"

Write-Host "Building custom Frappe v16 image with apps from ../apps.json..."

docker build `
  --build-arg=FRAPPE_PATH=https://github.com/frappe/frappe `
  --build-arg=FRAPPE_BRANCH=version-16 `
  --build-arg=CACHE_BUST="$(Get-Date -Format o)" `
  --secret=id=apps_json,src=../apps.json `
  --tag=basapos:16 `
  --file=images/layered/Containerfile

Write-Host "Build complete: basapos:16"
```

- [ ] **Step 3: Make executable and commit**

Run:
```
chmod +x scripts/build.sh
git add scripts/build.sh scripts/build.ps1
git commit -m "feat: add build scripts (bash + PowerShell)"
```

---

### Task 5: Create Deploy Scripts

**Files:**
- Create: `scripts/deploy.sh`
- Create: `scripts/deploy.ps1`

- [ ] **Step 1: Write deploy.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

ENV_FILE="$REPO_DIR/.env"
COMPOSE_DIR="$REPO_DIR/frappe_docker"

if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: .env file not found at $ENV_FILE"
  echo "Copy .env.example to .env and fill in your values."
  exit 1
fi

echo "Generating compose configuration..."
cd "$COMPOSE_DIR"

docker compose --env-file "$ENV_FILE" \
  -f compose.yaml \
  -f overrides/compose.mariadb.yaml \
  -f overrides/compose.redis.yaml \
  -f overrides/compose.proxy.yaml \
  -f overrides/compose.https.yaml \
  config > "$REPO_DIR/compose.custom.yaml"

echo "Starting all services..."
docker compose --env-file "$ENV_FILE" -f "$REPO_DIR/compose.custom.yaml" up -d

echo "Deploy complete. Run scripts/create-site.sh to create your first site."
```

- [ ] **Step 2: Write deploy.ps1**

```powershell
#!/usr/bin/env pwsh
param()

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoDir = Split-Path -Parent $ScriptDir
$EnvFile = "$RepoDir/.env"
$ComposeDir = "$RepoDir/frappe_docker"

if (-not (Test-Path $EnvFile)) {
  Write-Error ".env file not found at $EnvFile. Copy .env.example to .env and fill in your values."
  exit 1
}

Write-Host "Generating compose configuration..."
Set-Location $ComposeDir

docker compose --env-file $EnvFile `
  -f compose.yaml `
  -f overrides/compose.mariadb.yaml `
  -f overrides/compose.redis.yaml `
  -f overrides/compose.proxy.yaml `
  -f overrides/compose.https.yaml `
  config > "$RepoDir/compose.custom.yaml"

Write-Host "Starting all services..."
docker compose --env-file $EnvFile -f "$RepoDir/compose.custom.yaml" up -d

Write-Host "Deploy complete. Run scripts/create-site.ps1 to create your first site."
```

- [ ] **Step 3: Make executable and commit**

Run:
```
chmod +x scripts/deploy.sh
git add scripts/deploy.sh scripts/deploy.ps1
git commit -m "feat: add deploy scripts (bash + PowerShell)"
```

---

### Task 6: Create Site Creation Scripts

**Files:**
- Create: `scripts/create-site.sh`
- Create: `scripts/create-site.ps1`

- [ ] **Step 1: Write create-site.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="$REPO_DIR/.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: .env file not found at $ENV_FILE"
  exit 1
fi

source "$ENV_FILE"

SITE_NAME="${1:-}"
if [ -z "$SITE_NAME" ]; then
  echo "Usage: $0 <site-name.example.com>"
  exit 1
fi

echo "Creating site $SITE_NAME..."

docker compose -f "$REPO_DIR/compose.custom.yaml" exec backend \
  bench new-site \
    --mariadb-user-host-login-scope=% \
    --db-root-password "$DB_PASSWORD" \
    --install-app erpnext \
    --admin-password "${ADMIN_PASSWORD:-admin}" \
    "$SITE_NAME"

echo "Install your custom apps:"
echo "  docker compose -f compose.custom.yaml exec backend bench --site $SITE_NAME install-app my_custom_app"
```

- [ ] **Step 2: Write create-site.ps1**

```powershell
#!/usr/bin/env pwsh
param(
  [Parameter(Mandatory=$true, Position=0)]
  [string]$SiteName
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoDir = Split-Path -Parent $ScriptDir
$EnvFile = "$RepoDir/.env"

if (-not (Test-Path $EnvFile)) {
  Write-Error ".env file not found at $EnvFile"
  exit 1
}

$EnvVars = @{}
Get-Content $EnvFile | ForEach-Object {
  if ($_ -match '^([^#=]+)=(.*)$') {
    $EnvVars[$matches[1]] = $matches[2]
  }
}

Write-Host "Creating site $SiteName..."

docker compose -f "$RepoDir/compose.custom.yaml" exec backend `
  bench new-site `
    --mariadb-user-host-login-scope=% `
    --db-root-password $EnvVars['DB_PASSWORD'] `
    --install-app erpnext `
    --admin-password $EnvVars['ADMIN_PASSWORD'] `
    $SiteName
```

- [ ] **Step 3: Make executable and commit**

Run:
```
chmod +x scripts/create-site.sh
git add scripts/create-site.sh scripts/create-site.ps1
git commit -m "feat: add site creation scripts (bash + PowerShell)"
```

---

### Task 7: Create Backup and Restore Scripts

**Files:**
- Create: `scripts/backup.sh`
- Create: `scripts/backup.ps1`
- Create: `scripts/restore.sh`

- [ ] **Step 1: Write backup.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
BACKUP_DIR="$REPO_DIR/backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

mkdir -p "$BACKUP_DIR"

echo "Backing up all sites..."
docker compose -f "$REPO_DIR/compose.custom.yaml" exec backend \
  bench --site all backup --with-files --backup-path "/home/frappe/frappe-bench/backups/$TIMESTAMP"

echo "Copying backup files to host..."
docker compose -f "$REPO_DIR/compose.custom.yaml" cp \
  "backend:/home/frappe/frappe-bench/backups/$TIMESTAMP" "$BACKUP_DIR/$TIMESTAMP"

echo "Backup saved to $BACKUP_DIR/$TIMESTAMP"
```

- [ ] **Step 2: Write backup.ps1**

```powershell
#!/usr/bin/env pwsh
param()

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoDir = Split-Path -Parent $ScriptDir
$BackupDir = "$RepoDir/backups"
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null

Write-Host "Backing up all sites..."
docker compose -f "$RepoDir/compose.custom.yaml" exec backend `
  bench --site all backup --with-files --backup-path "/home/frappe/frappe-bench/backups/$Timestamp"

Write-Host "Copying backup files to host..."
docker compose -f "$RepoDir/compose.custom.yaml" cp `
  "backend:/home/frappe/frappe-bench/backups/$Timestamp" "$BackupDir/$Timestamp"

Write-Host "Backup saved to $BackupDir/$Timestamp"
```

- [ ] **Step 3: Write restore.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
BACKUP_FILE="${1:-}"

if [ -z "$BACKUP_FILE" ]; then
  echo "Usage: $0 <path-to-backup-file.sql>"
  echo "Backups are stored in $REPO_DIR/backups/"
  exit 1
fi

source "$REPO_DIR/.env"

BACKUP_FILENAME=$(basename "$BACKUP_FILE")
SITE_NAME="${BACKUP_FILENAME%%-*}"
PRIVATE_FILE="${BACKUP_FILE%.sql}-files.tar"
COMPOSE_FILE="$REPO_DIR/compose.custom.yaml"

echo "Restoring site $SITE_NAME from $BACKUP_FILE..."

docker compose -f "$COMPOSE_FILE" cp "$BACKUP_FILE" "backend:/tmp/$BACKUP_FILENAME"

docker compose -f "$COMPOSE_FILE" exec backend \
  bench --site "$SITE_NAME" restore "/tmp/$BACKUP_FILENAME" --db-root-password "$DB_PASSWORD"

if [ -f "$PRIVATE_FILE" ]; then
  echo "Restoring private files..."
  docker compose -f "$COMPOSE_FILE" cp "$PRIVATE_FILE" "backend:/tmp/$(basename $PRIVATE_FILE)"
  docker compose -f "$COMPOSE_FILE" exec backend \
    tar -xf "/tmp/$(basename $PRIVATE_FILE)" -C "/home/frappe/frappe-bench/sites/"
fi

echo "Restore complete."
```

- [ ] **Step 4: Make executable and commit**

Run:
```
chmod +x scripts/backup.sh scripts/restore.sh
git add scripts/backup.sh scripts/backup.ps1 scripts/restore.sh
git commit -m "feat: add backup and restore scripts"
```

---

### Task 8: Create Crontab Helper (Linux)

**Files:**
- Create: `scripts/setup-cron.sh`

- [ ] **Step 1: Write setup-cron.sh**

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_SCRIPT="$SCRIPT_DIR/backup.sh"
CRON_SCHEDULE="0 */6 * * *"

echo "Adding backup cron job (every 6 hours)..."
(crontab -l 2>/dev/null | grep -v "$BACKUP_SCRIPT"; echo "$CRON_SCHEDULE $BACKUP_SCRIPT >> $SCRIPT_DIR/../backups/cron.log 2>&1") | crontab -

echo "Cron job installed."
crontab -l | grep "$BACKUP_SCRIPT"
```

- [ ] **Step 2: Make executable and commit**

Run:
```
chmod +x scripts/setup-cron.sh
git add scripts/setup-cron.sh
git commit -m "chore: add cron setup script for automated backups"
```

---

### Task 9: Create GitHub Actions CI/CD Workflow

**Files:**
- Create: `.github/workflows/deploy.yml`

- [ ] **Step 1: Write deploy.yml**

```yaml
name: Build and Deploy

on:
  push:
    branches: [main]
    paths:
      - "apps.json"
      - ".github/workflows/deploy.yml"

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: true

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Build custom Frappe image
        uses: docker/build-push-action@v5
        with:
          context: ./frappe_docker
          file: ./frappe_docker/images/layered/Containerfile
          build-args: |
            FRAPPE_PATH=https://github.com/frappe/frappe
            FRAPPE_BRANCH=version-16
            CACHE_BUST=${{ github.sha }}
          secrets: |
            apps_json=${{ github.workspace }}/apps.json
          tags: basapos:16
          outputs: type=docker,dest=/tmp/custom-image.tar

      - name: Upload image artifact
        uses: actions/upload-artifact@v4
        with:
          name: custom-image
          path: /tmp/custom-image.tar

  deploy:
    needs: build
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: true

      - name: Download image artifact
        uses: actions/download-artifact@v4
        with:
          name: custom-image
          path: /tmp

      - name: Load image on server
        run: |
          docker load -i /tmp/custom-image.tar
          docker tag basapos:16 basapos:16

      - name: Deploy stack
        run: |
          bash scripts/deploy.sh
        env:
          DB_PASSWORD: ${{ secrets.DB_PASSWORD }}
          ADMIN_PASSWORD: ${{ secrets.ADMIN_PASSWORD }}
          LETSENCRYPT_EMAIL: ${{ secrets.LETSENCRYPT_EMAIL }}
          DOMAINS: ${{ secrets.DOMAINS }}
```

- [ ] **Step 2: Commit**

Run:
```
git add .github/workflows/deploy.yml
git commit -m "ci: add GitHub Actions build and deploy workflow"
```

---

### Task 10: Create README

**Files:**
- Create: `README.md`

- [ ] **Step 1: Write README.md**

```markdown
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
```

- [ ] **Step 2: Commit**

Run:
```
git add README.md
git commit -m "docs: add README with usage instructions"
```
