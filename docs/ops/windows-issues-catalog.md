# BasaPOS Windows Implementation — Issue Catalog

```
Date:     2026-08-28
Source:   Independent reviews (Windows installer/deployment + Frappe deployment)
Status:   Living tracker — update the Status column as items are fixed
Scope:    appliance/ + package/ (WSL-native Windows installer)
```

## How to read this

```
Sev:  C = Critical   H = High   M = Medium   L = Low
Status: FIXED (this pass) | OPEN | DESIGN-DEVIATION (documented tradeoff)
```

## The two shipped bugs (root causes)

```
BUG A (styles)   /home/frappe mode 0750 (Ubuntu HOME_MODE default) → nginx
                 workers (www-data) cannot traverse → EVERY /assets/* 404s
                 → page renders unstyled.  Fixed in provision.sh (chmod 0751)
                 + validate.sh assertion + drill stylesheet check.

BUG B (Not       Cert is generated correctly (SAN ✓, per-machine ✓) but was
Secure)          never imported into the Windows trust store → ERR_CERT_
                 AUTHORITY_INVALID.  Fixed: Ensure-TrustedCert (common.ps1)
                 called from setup.ps1 + boot-wrapper; removed on uninstall.
```

Both escaped CI because every health check used `curl -sk` and no drill
fetched an asset URL. Both gaps now have regression checks.

## WIN — Windows installer & deployment

| ID | Sev | Title | Location | Status |
|----|-----|-------|----------|--------|
| WIN-001 | C | TLS cert never trusted on Windows (Bug B) | payload/install/*.ps1 | FIXED |
| WIN-002 | C | Uninstall silently destroys all shop data (`wsl --unregister` + vhdx deletion, no prompt/backup) | remove-basapos.ps1:22, BasaPOS.iss | OPEN |
| WIN-003 | H | Launcher "Repair" = destructive full upgrade flow AND runs asInvoker while setup.ps1 needs elevation | Program.cs:267, app.manifest | OPEN |
| WIN-004 | H | WSL detection broken: inbox `wsl --status` exits 0 → bundled pinned MSI never installed → clean Win10 boxes fail import / no systemd | common.ps1:28-30, setup.ps1:295 | OPEN |
| WIN-005 | H | LAN mode: no firewall rule (spec §9), no port 80 proxy, no cleanup on disable/uninstall | boot-wrapper.ps1:75-81 | OPEN |
| WIN-006 | H | Upgrade restore omits `bench migrate` (spec §6) → schema drift after app upgrades | setup.ps1 restore script | OPEN |
| WIN-007 | M | Autostart Interactive+AtStartup ⇒ effectively at-logon, deviates from spec §7 S4U/M3 | register-autostart.ps1:14-21 | DESIGN-DEVIATION |
| WIN-008 | M | MariaDB root pw hardcoded in repo and identical across all appliances (spec §8 violation) | provision.sh:35, setup.ps1:185 | OPEN |
| WIN-009 | M | Inno [Code] poll loop Sleep(5000)×120 blocks wizard UI ≤10 min ("Not Responding") | BasaPOS.iss:110-127 | OPEN |
| WIN-010 | M | Upgrade backup copy-out not verified before distro destroyed (no -ErrorAction Stop, no file checks) | setup.ps1:136 | OPEN |
| WIN-011 | M | Elevation profile mismatch: {localappdata}/.wslconfig/{userstartup} resolve to elevated account, not daily user | BasaPOS.iss:13, setup.ps1:95 | OPEN |
| WIN-012 | M | .wslconfig writer appends duplicate INI sections; never fixes wrong-section keys; verify `instanceIdleTimeout` section | setup.ps1:94-109 | OPEN |
| WIN-013 | M | Health checks mask TLS problems (`curl -sk` in 5 files; launcher accepts any cert) | common.ps1, verify.ps1, Program.cs:167, drills | PARTIAL (drills now also check without -k) |
| WIN-014 | M | Hosts edits: no error handling on AV lock; uninstall drops any line containing "basapos.local" substring | setup.ps1:85-92, remove-basapos.ps1:26 | OPEN |
| WIN-015 | L | Undocumented `while true; sleep 60` keep-alive nohup'd in distro (restore path only) | setup.ps1:260 | OPEN |
| WIN-016 | L | credentials.txt plaintext forever; ACL locks out Administrators/SYSTEM | setup.ps1:118 | OPEN |
| WIN-017 | L | 10-min Inno timeout shows generic error while install continues in background | BasaPOS.iss:128 | OPEN |
| WIN-018 | L | Drill gaps: asset/CSS check, non-`-k` TLS check, upgrade trusts log text, scheduled-task path never run in CI | package/e2e/*.ps1 | PARTIAL (asset + TLS checks added) |
| WIN-019 | L | `ProgramData\BasaPOS\install-root.txt` world-readable path hint | setup.ps1:34-36 | OPEN |
| WIN-020 | L | Uninstall: unquoted -File path breaks for usernames with spaces | BasaPOS.iss [UninstallRun] | FIXED (quoted + -AppDir passed) |
| WIN-021 | L | Ensure-TrustedCert failure is log-only; install reports success while "Not Secure" persists (drills catch it in CI, not on user machines) | common.ps1 / setup.ps1 | OPEN |
| WIN-022 | L | Installs made before cert-trust fix leave permanent orphan self-signed certs in LocalMachine\Root (uninstall never removed them) | pre-existing installs | OPEN |
| WIN-023 | L | Firefox uses its own cert store — shows "Not Secure" regardless of Windows trust import (Edge/Chrome fine); documented in troubleshooting.md | browsers | KNOWN LIMITATION |

## FRP — Frappe appliance & deployment

| ID | Sev | Title | Location | Status |
|----|-----|-------|----------|--------|
| FRP-001 | C | /home/frappe 0750 → www-data blocked → all assets 404 (Bug A) | provision.sh:16 | FIXED |
| FRP-002 | H | Single Redis 6379 db0 shared cache+queue+socketio; cache flush nukes job queue | provision.sh:69-71 | OPEN |
| FRP-003 | H | Site DB password baked in image (site_config.json), identical across appliances (see WIN-008) | appliance image | OPEN |
| FRP-004 | M | nginx `location /` lacks proxy_read_timeout (60s default < gunicorn 120s) → long reports 504 | basapos.conf:45-51 | OPEN |
| FRP-005 | M | nginx: no gzip, no HTTP/2, /files served via gunicorn (slow LAN downloads) | basapos.conf | OPEN |
| FRP-006 | M | apps.json pins mutable branches (`version-16`); resolved commits not recorded → non-reproducible builds | apps.json, provision.sh | OPEN |
| FRP-007 | M | `[automount]` default on → appliance processes can read all of /mnt/c | wsl.conf | OPEN |
| FRP-008 | M | No journald caps / vhdx-growth strategy for run-for-months POS | units, docs | OPEN |
| FRP-009 | M | `.cache`/toolchains shipped in 1.9GB rootfs (bloat vs on-site rebuild tradeoff undocumented) | provision.sh hygiene() | OPEN |
| FRP-010 | L | No explicit `bench build` in provision (relies on get-app side effects) | provision.sh | OPEN |
| FRP-011 | L | validate.sh missed the shipped bug classes (now asserts home perms, asset symlinks, CSS bundles) | validate.sh | FIXED |
| FRP-012 | L | MariaDB: no explicit max_connections / isolation rationale | 50-basapos.cnf | OPEN |
| FRP-013 | L | Worker units hardcode bench_helper internals; no MemoryMax/limits | worker units | OPEN |
| FRP-014 | L | Docker/Linux path frozen (scripts/, frappe_docker, overrides/) + committed self-signed cert/key in certs/ | scripts/, certs/ | OPEN (decision needed: CI-smoke or retire) |
| FRP-015 | L | wsl.conf: no `[interop] appendWindowsPath=false` (PATH pollution) | wsl.conf | OPEN |

## Regression armour added (2026-08-28)

```
validate.sh        ✗ fails when /home/frappe lacks o+x
                   ✗ fails when sites/assets/{frappe,erpnext} symlinks missing
                   ✗ fails when no built CSS bundle under dist/css
install drills     ✗ fail when TLS not trusted (curl WITHOUT -k, schannel)
                   ✗ fail when login stylesheet != 200 (unstyled page)
                   ✗ post-upgrade: fail when new cert not re-trusted
import-boot e2e    ✗ fails when /home/frappe mode lacks o+x (stat inside distro)
                   ✗ fails when login asset != 200 (checked inside distro)
```

## Recommended fix order (Phase 3+)

0. Drill non-completion — see docs/ops/drill-failure-catalog.md (25 mechanisms,
   D1-D25, from 10 independent reviewers; Phase A/B/C fix order there)
1. WIN-002 uninstall data prompt (data safety for shops)
2. WIN-006 + WIN-010 upgrade correctness (migrate + verified backup)
3. WIN-004 WSL detection (clean Win10 boxes)
4. WIN-003 repair path (non-destructive, elevation-aware)
5. WIN-005 LAN firewall + cleanup
6. WIN-008/FRP-003 per-install generated DB root password
7. Remaining M/L items as backlog
