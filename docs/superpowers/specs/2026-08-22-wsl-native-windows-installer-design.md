# WSL-Native Windows Appliance (BasaPOS v2)

```
Date:     2026-08-22
Status:   Approved design — pending annotated review
Supersedes: prototype installer (collaborator's package.zip)
```

---

## 1 · Context

```
                    ┌─────────────────────────────────────────┐
                    │            TODAY                        │
                    ├──────────────┬──────────────────────────┤
                    │   LINUX      │   WINDOWS                │
                    │   Docker ✅  │   Docker Desktop ⚠️      │
                    │              │   • autostart limits     │
                    │              │   • weird bugs           │
                    └──────────────┴──────────────────────────┘

                    ┌─────────────────────────────────────────┐
                    │            TARGET                       │
                    ├──────────────┬──────────────────────────┤
                    │   LINUX      │   WINDOWS                │
                    │   Docker ✅  │   Native WSL2 ✅         │
                    │  (unchanged) │   no Docker Desktop      │
                    │              │   one-click Setup.exe    │
                    └──────────────┴──────────────────────────┘
```

### Why the prototype can't ship as-is

| # | Prototype flaw | Consequence |
|---|----------------|-------------|
| P1 | Rootfs tarball is a **black box** | Built once on one machine (`C:\Users\bsmug\...`); nobody can rebuild it |
| P2 | Hardcoded paths everywhere | Build only works on that one machine |
| P3 | No boot-time start | Appliance depends on GUI/manual action |
| P4 | Baked-in creds (`Administrator/admin`) | Every install ships identical secrets |

---

## 2 · Requirements

```
R1  WSL-native replaces Docker on Windows        R5  Fully offline (Zimbabwe);
R2  Auto-start at boot, survives w/o GUI             updates via USB / rare net
R3  Standard install → delete Setup.exe          R6  CI-built releases from repo
R4  Zero-support model ("charge once")           R7  LAN clients later, no rework
```

**Non-goals (v1):**

| Out | Why |
|-----|-----|
| SYSTEM-level pre-login start | WSL distros register per-user — hard platform limit |
| Layered update payloads | Premature; revisit if USB updates prove painful |
| Multi-site | Single site `basapos.local` |
| Changes to Linux/Docker flow | Shares `apps.json` only |

---

## 3 · System Map

```
┌───────────────────────────── BUILD TIME (CI) ─────────────────────────────┐
│                                                                            │
│   appliance/                        package/                               │
│   ├── Containerfile                 ├── launcher/    (.NET 8 WinForms)     │
│   ├── provision.sh                  ├── BasaPOS.iss  (Inno Setup)          │
│   └── overlay/etc/wsl.conf          └── payload/install/*.ps1              │
│         │                                 │                                │
│         ▼                                  ▼                               │
│   docker build ─► docker export        ISCC.exe                             │
│         │                                  │                               │
│         └──────────► rootfs.tar.gz ◄───────┘                               │
│                          │                                                 │
│                          ▼                                                 │
│                 BasaPOS-Setup.exe  +  SHA256 checksum                      │
│                          │                                                 │
│   .github/workflows/release.yml  (tag push triggers all of the above)      │
└────────────────────────────────────────────────────────────────────────────┘

┌──────────────────────────── RUNTIME (Windows) ────────────────────────────┐
│                                                                           │
│   {app}\data\distro\ext4.vhdx   ◄──── wsl --import BasaPOS                │
│  ┌───────────────────────────────────────────┐                            │
│  │  appliance  (systemd = PID 1)             │                            │
│  │                                           │                            │
│  │  nginx :443 ──► gunicorn ──► ERPNext v16  │                            │
│  │               ► socketio                  │                            │
│  │  scheduler + workers      [frappe user]   │                            │
│  │  mariadb ─ redis          [localhost]     │                            │
│  │                                           │                            │
│  │  site: basapos.local                      │                            │
│  └───────────────────────────────────────────┘                            │
│        ▲                                                                  │
│        │ boots at startup, retries until healthy                          │
│  Scheduled Task "BasaPOS-Appliance"  (installing user, S4U)               │
│                                                                           │
│  BasaPOS.exe  — optional control panel (status · start · stop · backup)   │
│  hosts entry: 127.0.0.1 basapos.local                                     │
└───────────────────────────────────────────────────────────────────────────┘
```

---

## 4 · Appliance Pipeline

```
 apps.json ──────────┐  (single source of truth,
                     │   shared with Docker flow)
                     ▼
 ┌───────────────────────────────────────────────────────────┐
 │ STAGE 1 · base                                            │
 │   ubuntu (digest-pinned) + runtime deps                   │
 │   + mariadb-server + redis-server + nginx                 │
 ├───────────────────────────────────────────────────────────┤
 │ STAGE 2 · bench                                           │
 │   frappe user (unprivileged) → /home/frappe/bench         │
 │   bench init ← apps.json (branch-pinned v16 apps)         │
 │   bench new-site basapos.local + install apps             │
 ├───────────────────────────────────────────────────────────┤
 │ STAGE 3 · services                                        │
 │   systemd units (NOT supervisor):                         │
 │   nginx · gunicorn · socketio · scheduler · workers       │
 │   app units → frappe user · db/cache → localhost binds    │
 ├───────────────────────────────────────────────────────────┤
 │ STAGE 4 · WSL hygiene                                     │
 │   /etc/wsl.conf → [boot] systemd=true                     │
 │   blank machine-id · neutral hostname                     │
 │   strip caches/logs/docker-isms                           │
 └───────────────────────────────────────────────────────────┘
                     │
                     ▼  docker export → gzip
              rootfs.tar.gz ─► structural assertions in CI:
              ✓ /sbin/init   ✓ etc/wsl.conf   ✓ systemd units   ✓ size report
```

---

## 5 · Install Flow (`setup.ps1`)

```
        ┌──────────────────────┐
        │  Setup.exe launched  │  (elevated, Inno post-install)
        └──────────┬───────────┘
                   ▼
   ┌───────────────────────────────┐
   │ 1· WSL features enabled?      │──no──► enable + install pinned MSI
   └───────────┬───────────────────┘
               ▼
   ┌───────────────────────────────┐   yes: register resume task,
   │ 2· reboot pending?            │──yes──► status=NEEDS_REBOOT,
   └───────────┬───────────────────┘         continue after restart
               ▼
   ┌───────────────────────────────┐
   │ 3· disk ≥ 8 GB free?          │──no──► abort w/ actionable msg
   └───────────┬───────────────────┘
               ▼
   ┌───────────────────────────────┐   yes: SKIP import (repair path),
   │ 4· distro already present?    │──yes───────┐
   └───────────┬───────────────────┘            │
               │ no                             │
               ▼                                │
   ┌───────────────────────────────┐            │
   │    UPGRADE DETECTED?  §6      │            │
   └───────────┬───────────────────┘            │
               ▼ fresh install                  │
   ┌───────────────────────────────┐            │
   │ 4a· import rootfs.tar.gz      │            │
   └───────────┬───────────────────┘            │
               ▼                                │
   ┌───────────────────────────────┐            │
   │ 5· hosts: 127.0.0.1 basapos   │◄───────────┘
   └───────────┬───────────────────┘
               ▼
   ┌───────────────────────────────┐
   │ 6· .wslconfig timeouts=-1     │   vmIdleTimeout / instanceIdleTimeout
   └───────────┬───────────────────┘
               ▼
   ┌───────────────────────────────┐   fresh only: gen 16-char pw →
   │ 7· credentials                │──►{app}\config\credentials.txt
   └───────────┬───────────────────┘   upgrade: preserve existing
               ▼
   ┌───────────────────────────────┐
   │ 8· register autostart task §7 │
   └───────────┬───────────────────┘
               ▼
   ┌───────────────────────────────┐
   │ 9· boot + health poll         │──► status=SETUP_COMPLETE
   └───────────────────────────────┘
```

**De-hardcoding rules:** every path from `$PSScriptRoot`/Inno constants · ISCC discovered or `-IsccPath` param · rootfs passed as parameter · zero absolute user paths.

---

## 6 · Upgrade Drill (zero-support backbone)

```
 SHOP OWNER ACTION            WHAT SETUP DOES AUTOMATICALLY
 ════════════════             ═══════════════════════════════════════
                              ┌─────────────────────────────┐
 runs newer                   │ A· backup inside old distro │
 Setup.exe ──────────────────►│    (with files)             │
      💾USB                   └──────────────┬──────────────┘
                                             ▼
                              ┌─────────────────────────────┐
                              │ B· copy backup OUT to       │
                              │    {app}\backups\pre-upgrade│
                              └──────────────┬──────────────┘
                                             ▼
                              ┌─────────────────────────────┐
                              │ C· unregister old distro    │
                              └──────────────┬──────────────┘
                                             ▼
                              ┌─────────────────────────────┐
                              │ D· import NEW rootfs        │
                              │    (new app code inside)    │
                              └──────────────┬──────────────┘
                                             ▼
                              ┌─────────────────────────────┐
                              │ E· restore backup + migrate │
                              │ F· continue install §5 (5→9)│
                              └──────────────┬──────────────┘
                                             ▼
                                   data survives ✓
                                   apps updated ✓
                                   same USB stick workflow ✓
```

---

## 7 · Autostart

**Platform constraint first:**

```
 WSL distros register PER-WINDOWS-USER
 ⇒ "start at boot" = "start AS THE OWNING USER at boot"
 ⇒ true SYSTEM pre-login start is out of scope (see non-goals)
```

```
 Windows boots
      │
      ▼  (+30s delay)
 ┌──────────────────────────────────────────────────────┐
 │ Task: BasaPOS-Appliance                              │
 │   principal : installing user                        │
 │   logon type: S4U (no stored password,               │
 │                runs without interactive login)       │
 │   run level : highest                                │
 └──────────────────────────┬───────────────────────────┘
                            ▼
 ┌──────────────────────────────────────────────────────┐
 │ Boot wrapper (PowerShell):                           │
 │   1· wsl -d BasaPOS -u root --exec /bin/true         │
 │   2· poll https://basapos.local/api/method/ping      │
 │   3· retry on failure  (slow disks, VM cold starts)  │
 │   4· LAN_MODE? refresh portproxy  §9                 │
 └──────────────────────────────────────────────────────┘
```

**Fallback:** if S4U misbehaves on target hardware → switch trigger to *at logon* (kiosk machines should run Windows auto-logon anyway).

**Launcher independence:**

```
 launcher closed?   irrelevant ✓      launcher killed?   irrelevant ✓
 launcher never opened?  irrelevant ✓ appliance keeps running ✓
```

---

## 8 · Hardening Matrix

| Surface | Measure |
|---|---|
| Services | unprivileged `frappe` user; root only for import/boot exec |
| Credentials | random per-install admin pw · ACL-restricted `credentials.txt` · shown once in launcher |
| Secrets in artifact | none baked — TLS cert generated at first boot (unique CN), pw generated at install |
| Telemetry | zero — appliance makes no outbound connections by design |
| Supply chain | base digest-pinned · app branches pinned · MSI version pinned · SHA256 published per release |
| Network | mariadb/redis localhost-only inside distro · unreachable from Windows except via app |

---

## 9 · LAN Mode (designed now · flag OFF in v1)

```
 settings.txt:  LAN_MODE=false   ← v1 default (localhost only)

 LAN_MODE=true flips on:
 ─────────────────────────────
   firewall rule  TCP 443 · Private profile only
        │
        ▼
   ┌──────────────────── Windows version? ────────────────────┐
   │                                                          │
   ▼ Win11 22H2+                                       Win10 ▼
 mirrored networking                          NAT + portproxy
 (.wslconfig: networkingMode=mirrored)        netsh portproxy 443→distro IP
 host ports bound directly                    refreshed each boot by wrapper §7
        │                                          │
        └────────────┬─────────────────────────────┘
                     ▼
   clients add: <server-ip> basapos.local  (hosts file)
   — same pattern as existing Linux README —
```

---

## 10 · Failure Modes

| Failure | Handling |
|---|---|
| Reboot pending mid-install | resume task continues automatically (proven pattern) |
| Import fails / VHD missing later | launcher **Repair**, or re-run Setup (idempotent) |
| Site never healthy | boot wrapper retries · orange status + logs in `{app}\logs` |
| Low disk before import | explicit guard, actionable message |
| Corrupt VHD | re-run Setup → fresh import; upgrade drill's backup restores data |
| WSL update breaks things | MSI pinned · timeouts stay disabled |

---

## 11 · Verification

```
 LAYER              CHECK                              WHERE
 ─────────────────────────────────────────────────────────────────
 appliance build    tarball structure asserts          CI, every build
 provisioning       shellcheck · idempotence lint      CI, every build
 backup/restore     full roundtrip w/ live mariadb     CI, every build
 windows e2e        clean install · reboot-no-login    manual, Win10+Win11 VMs
                    delete-Setup-still-works
                    upgrade drill v(n−1)→v(n)
                    uninstall cleanliness
                    S4U task fires correctly
 launcher           status states · repair path        smoke checklist
 release            Setup.exe + checksum published     tag push
```

---

## 12 · Repo Layout (after)

```
 frappe-offline/
 ├── appliance/                      # NEW
 │   ├── Containerfile
 │   ├── provision.sh
 │   ├── overlay/etc/wsl.conf
 │   └── systemd/*.unit
 ├── package/                        # FROM COLLABORATOR ZIP (refactored)
 │   ├── launcher/                   # .NET 8 control panel
 │   ├── BasaPOS.iss
 │   ├── build.ps1                   # de-hardcoded payload assembler
 │   └── payload/install/*.ps1       # setup · boot wrapper · remove-hosts
 ├── scripts/                        # Linux/Docker flow — UNCHANGED
 ├── apps.json                       # shared source of truth
 ├── docs/superpowers/specs/         # this doc
 └── .github/workflows/release.yml   # tag → Setup.exe + checksums
```

---

## 13 · Milestones

```
 M1 ██ appliance builds reproducibly in CI; tarball checks pass
 M2 ████ de-hardcoded local build → working Setup.exe; clean-install E2E on Win11 VM
 M3 ██████ autostart across reboot-without-login verified
 M4 ████████ upgrade drill passes; uninstall clean
 M5 ██████████ release workflow publishes Setup.exe+checksum; hardening pass; ops docs
    (USB update how-to · LAN_MODE how-to)
```
