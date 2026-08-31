# Windows "Linux-in-a-Box" Installer (BasaPOS v3)

```
Date:     2026-08-31
Status:   Approved design — pending spec review
Supersedes: 2026-08-22-wsl-native-windows-installer-design.md
```

---

## 1 · Context

```
                    ┌──────────────────────────────────────────────┐
                    │            V2 (being replaced)               │
                    ├──────────────┬───────────────────────────────┤
                    │   LINUX      │   WINDOWS                     │
                    │   Docker ✅  │   WSL2 native appliance ❌    │
                    │              │   • hand-rolled systemd/nginx │
                    │              │     stack — crashes, styling  │
                    │              │   • Inno + 485-line PS maze   │
                    │              │   • useless WinForms launcher │
                    └──────────────┴───────────────────────────────┘

                    ┌──────────────────────────────────────────────┐
                    │            V3 (this design)                  │
                    ├──────────────┬───────────────────────────────┤
                    │   LINUX      │   WINDOWS                     │
                    │   Docker ✅  │   Docker-in-WSL2 ✅            │
                    │  (unchanged) │   SAME compose stack/images   │
                    │              │   click-and-run GUI installer │
                    │              │   no Inno · no Docker Desktop │
                    └──────────────┴───────────────────────────────┘
```

### Why v2 failed

| # | V2 flaw | Consequence |
|---|---------|-------------|
| V1 | Custom systemd/nginx/gunicorn deployment — novel stack Frappe upstream doesn't maintain | Hidden server crashes, broken styling |
| V2 | Inno Setup `[Code]` driving PowerShell | Endless finicky bugs (see git log) |
| V3 | WinForms control-panel launcher | Practically useless |
| V4 | Two app stacks (compose for Linux, systemd units for Windows) | Double the debugging surface |

**Core insight:** the Linux flow is reliable *because* it is the boring,
upstream-maintained `frappe_docker` compose stack. V3 runs that exact
stack on Windows — inside a WSL2 distro with Docker Engine (no Docker
Desktop). One app stack, two delivery paths.

---

## 2 · Requirements

```
R1  Windows runs the SAME compose stack/images   R5  Fully offline (Zimbabwe);
    as Linux — no second app stack                    updates via USB / rare net
R2  Click-and-run GUI: install, upgrade,         R6  CI-built releases from repo
    repair, uninstall — no wizards                     (multi-part assets ≤2GB ea.)
R3  Auto-start at boot, survives reboots         R7  LAN clients later, no rework
R4  Zero-support model ("charge once")           R8  Fresh start — no migration
                                                       from v2 field installs
```

**Audience:** the developer / a technician installs machines on-site.
"Click and run" replaces polish-for-owner with speed-for-tech.

**Non-goals (v3):**

| Out | Why |
|-----|-----|
| SYSTEM-level pre-login start | WSL distros register per-user — platform limit |
| Owner-facing control panel | V2 launcher taught us: techs use `wsl` + GUI install only |
| LAN mode | Designed (flag OFF), ships later — §8 |
| Changes to Linux/Docker flow | Shares `apps.json` + image only |
| Migration from v2 appliance | R8 — fresh installs only |

---

## 3 · System Map

```
┌──────────────────────────── BUILD TIME (CI) ──────────────────────────────┐
│                                                                           │
│  apps.json (single source of truth)                                       │
│        │                                                                  │
│        ▼                                                                  │
│  frappe_docker compose image  ──── SAME image both targets ────┐         │
│        │                                                        │         │
│        │              ┌── Linux path (unchanged): scripts/*.sh │         │
│        │              │                                        │         │
│        ▼              ▼                                        ▼         │
│  compose up (CI runner) → create-site → bench backup      docker save     │
│        │                   --with-files                       │           │
│        ▼                                                    image.tar    │
│  site-snapshot/ ◄───────────────────────────────────────────  +          │
│                                                                   compose  │
│  distro build:  Ubuntu (digest-pinned) + systemd=true       files + .env │
│                 + Docker Engine + compose plugin                 │        │
│                 + /opt/basapos/{image.tar, site-snapshot,      ▼         │
│                    compose/, firstboot.service}          rootfs build     │
│                                                              │             │
│                                        docker export → gzip → split       │
│                                                              │             │
│              release assets: basapos-distro.tar.part-aa/ab/… + SHA256SUMS│
│              + BasaPOS-Setup.exe + wsl.msi (pinned) + SHA256SUMS         │
└───────────────────────────────────────────────────────────────────────────┘

┌──────────────────────────── RUNTIME (Windows) ────────────────────────────┐
│                                                                           │
│  C:\BasaPOS\                                                              │
│   ├── distro\ext4.vhdx   ◄──── wsl --import BasaPOS                       │
│   ├── config\            credentials.txt (ACL-restricted), settings.txt   │
│   ├── logs\              installer + boot logs                            │
│   ├── BasaPOS-Setup.exe  copy kept for upgrade/repair/uninstall           │
│   └── backups\           pre-upgrade safety copies                        │
│                                                                           │
│  ┌───────────────────────────────────────────────┐                        │
│  │  WSL2 distro "BasaPOS" (systemd = PID 1)      │                        │
│  │                                               │                        │
│  │  docker.service                               │                        │
│  │    └─ basapos-firstboot.service (oneshot)      │                        │
│  │         docker load → compose up → restore     │                        │
│  │         site → set-admin-password (sentinel-   │                        │
│  │         guarded, idempotent)                   │                        │
│  │    └─ compose stack: traefik · gunicorn ·      │                        │
│  │       socketio · scheduler · workers ·         │                        │
│  │       mariadb · redis   [restart: unless-      │                        │
│  │       stopped] — identical to Linux            │                        │
│  │                                               │                        │
│  │  site: basapos.local  (restored from snapshot) │                        │
│  └───────────────────────────────────────────────┘                        │
│        ▲                                                                  │
│        │  boots at Windows startup (+30s), retries until healthy          │
│  Scheduled Task "BasaPOS-Appliance"  (installing user, S4U)               │
│                                                                           │
│  hosts entry: 127.0.0.1 basapos.local  (WSL localhostForwarding → :80)    │
└───────────────────────────────────────────────────────────────────────────┘
```

### Key pipeline decision

| Option | Verdict |
|---|---|
| Docker-in-docker during distro build to bake `/var/lib/docker` | ❌ needs privileged CI, fragile |
| Ship `image.tar` + firstboot `docker load` | ✅ plain `docker build/export`, first boot +2–4 min, GUI shows progress |

Same logic for the site: CI creates the site in a throwaway compose run and
snapshots it (`bench backup --with-files`); firstboot restores the snapshot —
fast (~1 min), deterministic, no secrets baked.

---

## 4 · GUI Installer (`setup-gui/`)

**Tech:** .NET 10 (LTS) · WinForms · self-contained single-file win-x64
(built on Linux CI via `dotnet publish`; ~70 MB; zero runtime deps on target).

```
┌─ BasaPOS Setup ──────────────────────────────┐
│  ● Checking prerequisites…                   │
│  ● WSL2 ready                                │
│  ● Stitching payload  ▓▓▓▓▓▓▓░░░ 71%          │
│  ● Importing appliance                       │
│  ● Provisioning site…                        │
│  ● Waiting for healthy…                      │
│  ─────────────────────────────────────────── │
│  ✓ Done — Administrator password: ████ [copy]│
│  [ Open BasaPOS ]                            │
└──────────────────────────────────────────────┘
```

```
INSTALL FLOW                    RE-RUN (existing install detected)
════════════                    ═════════════════════════════════
1· prereq check                 Window offers:
     Win10 19041+ · virt        ┌────────┬────────┬────────┐
     enabled · ≥15 GB free      │Upgrade │ Repair │Uninstall│
2· WSL present?                 └────────┴────────┴────────┘
     no → install pinned MSI
     reboot needed → resume
     task continues after
3· stitch parts → verify
     SHA256
4· wsl --import → C:\BasaPOS\distro
5· generate 16-char password
     → config\credentials.txt (ACL)
     → read by firstboot via /mnt/c
6· hosts: 127.0.0.1 basapos.local
7· register autostart task  §5
8· firstboot runs (load →
     compose up → restore →
     set password)
9· poll http://basapos.local/
     api/method/ping → Done
```

- GUI drives everything directly: `wsl.exe`, `tar`, `schtasks`, file I/O.
  **No PowerShell scripts in the install path.**
- Idempotent: every step checks-before-does; interrupted installs re-run clean.
- Uninstall button = §7 uninstall flow; "Open BasaPOS" = default browser.

---

## 5 · Autostart

```
 Windows boots
      │
      ▼  (+30s delay)
┌──────────────────────────────────────────────────────┐
│ Task: BasaPOS-Appliance                              │
│   principal : installing user                        │
│   logon type: S4U (no stored password)               │
│   run level : highest                                │
└──────────────────────────┬───────────────────────────┘
                           ▼
┌──────────────────────────────────────────────────────┐
│ Boot wrapper (GUI-extracted .cmd → wsl.exe):         │
│   1· wsl -d BasaPOS --exec /bin/true   (start VM)    │
│   2· systemd → docker.service → firstboot (once)     │
│   3· restart policies bring stack up                 │
│   4· poll /api/method/ping · retry on failure        │
└──────────────────────────────────────────────────────┘
```

**Fallback:** S4U misbehaves on target hardware → switch trigger to *at logon*
(kiosk machines run Windows auto-logon anyway).

**Launcher independence:** the GUI exe is only needed for install/upgrade/
repair/uninstall. Closing it, deleting it, never opening it — the appliance
keeps running.

---

## 6 · Upgrade Drill (zero-support backbone)

```
 SHOP OWNER/TECH ACTION          WHAT SETUP DOES AUTOMATICALLY
 ════════════════                ═══════════════════════════════════════
                                 ┌─────────────────────────────┐
 runs newer                      │ A· bench backup --with-files │
 BasaPOS-Setup.exe ─────────────►│    (inside OLD distro)      │
      💾USB                      └──────────────┬──────────────┘
                                                ▼
                                 ┌─────────────────────────────┐
                                 │ B· copy backup OUT to       │
                                 │    C:\BasaPOS\backups\      │
                                 └──────────────┬──────────────┘
                                                ▼
                                 ┌─────────────────────────────┐
                                 │ C· wsl --unregister old     │
                                 │ D· import NEW distro        │
                                 │ E· firstboot: load image,   │
                                 │    compose up, RESTORE      │
                                 │    backup, migrate          │
                                 │ F· keep existing password if   │
                                 │    credentials.txt exists,     │
                                 │    else regenerate → poll      │
                                 └──────────────┬──────────────┘
                                                ▼
                                      data survives ✓
                                      apps updated ✓
                                      same USB workflow ✓
```

---

## 7 · Uninstall

```
1· wsl --unregister BasaPOS          (removes vhdx + distro)
2· delete scheduled task
3· remove hosts entry
4· delete C:\BasaPOS\                (prompts to keep backups\)
```

Clean machine afterward — verified by e2e drill.

---

## 8 · LAN Mode (designed now · flag OFF in v3)

```
settings.txt:  LAN_MODE=false   ← v3 default (localhost only)

LAN_MODE=true flips on:
─────────────────────────────
  firewall rule  TCP 80 · Private profile only
       │
       ▼
  ┌──────────────────── Windows version? ────────────────────┐
  ▼ Win11 22H2+                                       Win10 ▼
mirrored networking                          NAT + portproxy
(.wslconfig: networkingMode=mirrored)        netsh portproxy 80→distro IP
host ports bound directly                    refreshed each boot by wrapper
       │                                          │
       └────────────┬─────────────────────────────┘
                    ▼
  clients add: <server-ip> basapos.local  (hosts file)
  — same pattern as existing Linux README —
```

---

## 9 · Hardening Matrix

| Surface | Measure |
|---|---|
| Services | unprivileged inside distro; root only for import/boot exec |
| Credentials | random per-install admin pw (reset at firstboot, never baked) · ACL-restricted `credentials.txt` · shown once in GUI |
| Secrets in artifact | none baked — site snapshot contains no per-install secrets |
| Telemetry | zero — appliance makes no outbound connections by design |
| Supply chain | base digest-pinned · app branches pinned in `apps.json` · WSL MSI version pinned · SHA256SUMS per release |
| Network | mariadb/redis inside distro network only; localhost-forwarded web ports |
| Payload integrity | stitch → SHA256 verify BEFORE import |

---

## 10 · Failure Modes

| Failure | Handling |
|---|---|
| Reboot pending mid-install (WSL enable) | resume task re-launches GUI install automatically |
| Part download/copy corrupt | SHA256 verify pre-import; actionable message |
| Import fails / VHD missing later | GUI **Repair**; re-run Setup (idempotent) |
| Site never healthy | GUI retries, shows log tail; logs in `C:\BasaPOS\logs` |
| Low disk before import | explicit guard (≥15 GB), actionable message |
| Corrupt VHD | re-run Setup → fresh import; upgrade drill's backup restores data |
| WSL update breaks things | pinned MSI shipped in payload |
| Unsigned-exe SmartScreen warning | one-time "More info → Run anyway"; code-signing cert optional later |

---

## 11 · Verification

```
 LAYER              CHECK                              WHERE
 ─────────────────────────────────────────────────────────────────
 distro build       tarball structure asserts:         CI, every build
                    systemd ✓ docker ✓ image.tar ✓
                    snapshot ✓ compose ✓ wsl.conf ✓
 image parity       sha256(distro image.tar) ==          CI, every build
                    sha256(Linux image)
 provisioning       firstboot idempotence (run twice)   CI, every build
 backup/restore     full roundtrip w/ live mariadb      CI, every build
 windows e2e        clean install · reboot-no-login     manual, Win10+Win11
                    delete-Setup-still-works            VMs
                    upgrade drill v(n−1)→v(n)
                    uninstall cleanliness
                    S4U task fires correctly
 GUI                install/upgrade/repair/uninstall    smoke checklist
 release            parts + Setup.exe + SHA256SUMS      tag push
```

---

## 12 · Repo Layout (after)

```
frappe-offline/
├── appliance/                      # REBUILT for v3
│   ├── Containerfile               # Ubuntu + docker engine + payload
│   ├── build.sh                    # build → validate → export → split
│   ├── validate.sh                 # structural asserts
│   └── overlay/etc/wsl.conf
├── setup-gui/                      # NEW — .NET 10 WinForms installer
│   ├── BasaPOS-Setup.csproj
│   └── …
├── scripts/                        # Linux/Docker flow — UNCHANGED
├── apps.json                       # shared source of truth
├── docs/superpowers/specs/         # this doc
└── .github/workflows/release.yml   # tag → assets + checksums

DELETED
────────
package/                (BasaPOS.iss · build.ps1 · payload/ · launcher/ · e2e/)
old appliance content   (systemd-nginx units, provision of non-docker stack)
```

---

## 13 · Milestones

```
M1 ██    CI builds image.tar + site snapshot + distro tarball
         reproducibly; structural + parity asserts pass
M2 ████   GUI: stitch/verify, WSL handling (MSI, reboot-resume),
         import, firstboot orchestration, health poll
         → clean-install E2E on Win11 VM
M3 ██████ autostart across reboot-without-login verified (S4U)
M4 ████████ upgrade drill passes; uninstall clean
M5 ██████████ release workflow publishes parts + Setup.exe +
         SHA256SUMS; hardening pass; ops docs
         (USB update how-to · LAN_MODE how-to · tech runbook)
```
