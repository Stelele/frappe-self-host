# Windows "Linux-in-a-Box" Installer (BasaPOS v3)

```
Date:     2026-08-31
Revision: 2.0 — minimal core (install + uninstall only)
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
                    │              │   install + uninstall. that's │
                    │              │   it. no cleverness.          │
                    └──────────────┴───────────────────────────────┘
```

### Why v2 failed

| # | V2 flaw | Consequence |
|---|---------|-------------|
| V1 | Custom systemd/nginx/gunicorn deployment — novel stack Frappe upstream doesn't maintain | Hidden server crashes, broken styling |
| V2 | Inno Setup `[Code]` driving PowerShell | Endless finicky bugs (see git log) |
| V3 | WinForms control-panel launcher | Practically useless |
| V4 | Two app stacks (compose for Linux, systemd units for Windows) | Double the debugging surface |
| V5 | Speculative features (repair, upgrade drills, S4U experiments) | Complexity budget spent on maybes |

**Core insight:** the Linux flow is reliable *because* it is the boring,
upstream-maintained `frappe_docker` compose stack. V3 runs that exact
stack on Windows — inside a WSL2 distro with Docker Engine (no Docker
Desktop). One app stack, two delivery paths.

**v2.0 discipline:** install and uninstall are the ONLY Windows flows.
Broken install? Uninstall, reinstall. New app version? Uninstall, install,
restore backup. Every "what if" beyond that is deferred until field
evidence demands it.

---

## 2 · Requirements

```
R1  Windows runs the SAME compose stack/images   R5  Fully offline (Zimbabwe);
    as Linux — no second app stack                    updates via USB / rare net
R2  Click-and-run GUI: install and                R6  CI-built releases from repo
    uninstall — nothing else                          (multi-part assets ≤2GB ea.)
R3  Auto-start at logon, survives reboots         R7  Fresh start — no migration
    and stays up through idle                          from v2 field installs
R4  Zero-support model: daily backup timer
    baked into the distro
```

**Audience:** the developer / a technician installs machines on-site.

**Non-goals (v3):**

| Out | Why |
|-----|-----|
| Upgrade / repair mechanisms | v2's mess came from speculative flows. Reinstall covers both. Revisit with field evidence. |
| Watchdog / self-healing | `.wslconfig` + at-logon wrapper cover the real cases; reboot is the fallback |
| S4U autostart | v2 field history refuted it (`455545f`, `8f2e578`, `1b92937`) |
| SYSTEM-level pre-login start | WSL distros register per-user — platform limit |
| LAN mode | `settings.txt` placeholder only; mechanism later |
| Owner-facing control panel | techs use `wsl` + GUI install only |
| Changes to Linux/Docker flow | shares `apps.json` + image + compose generation only |
| Log streaming in GUI | open the logs folder instead |

---

## 3 · System Map

```
┌──────────────────────────── BUILD TIME (CI) ──────────────────────────────┐
│                                                                           │
│  apps.json (single source of truth)                                       │
│        │                                                                  │
│        ▼                                                                  │
│  ONE image build  (build once · save once — parity is by                  │
│        │            construction, not by assertion)                       │
│        │                                                                  │
│        ├─ frappe image ── docker save ──► images.tar                      │
│        │       + mariadb:11.8             (ALL FOUR stack images,         │
│        │       + redis:8.6-alpine (×2)     tags pinned — offline          │
│        │       + traefik:v3.6               firstboot CANNOT pull)        │
│        │                                                                  │
│        ├─ compose files + .env TEMPLATE generated by the SAME             │
│        │   scripts as the Linux flow (deploy.sh) — no fork, no drift      │
│        ▼                                                                  │
│  distro build:  Ubuntu (digest-pinned) + systemd=true                     │
│                 + Docker Engine + compose plugin                          │
│                 + /opt/basapos/{images.tar, compose/}                    │
│                 + basapos-firstboot.service (phased, sentinel)            │
│                 + basapos-backup.timer (daily — §5b)                      │
│                                      │                                     │
│                        docker export → gzip → split → SHA256SUMS          │
│              release assets: basapos-distro.tar.part-aa/ab/…              │
│              + BasaPOS-Setup.exe + wsl.msi (pinned) + SHA256SUMS          │
└───────────────────────────────────────────────────────────────────────────┘

┌──────────────────────────── RUNTIME (Windows) ────────────────────────────┐
│                                                                           │
│  C:\BasaPOS\                                                              │
│   ├── distro\ext4.vhdx   ◄──── wsl --import BasaPOS                       │
│   ├── config\            credentials.txt (ACL) · settings.txt             │
│   ├── logs\              installer + boot logs                            │
│   ├── BasaPOS-Setup.exe  kept copy (uninstall + reinstall only)           │
│   └── backups\           daily backups land here                          │
│                                                                           │
│  ┌───────────────────────────────────────────────┐                        │
│  │  WSL2 distro "BasaPOS" (systemd = PID 1)      │                        │
│  │                                               │                        │
│  │  docker.service                               │                        │
│  │    └─ basapos-firstboot.service (§3b)          │                        │
│  │    └─ basapos-backup.timer (§5b)               │                        │
│  │    └─ compose stack: traefik · gunicorn ·     │                        │
│  │       socketio · scheduler · workers ·        │                        │
│  │       mariadb · redis   [restart: unless-     │                        │
│  │       stopped] · log rotation · identical     │                        │
│  │       to Linux                                │                        │
│  │                                               │                        │
│  │  site: basapos.local  (restored from snapshot)│                        │
│  │  TLS: per-install self-signed cert generated  │                        │
│  │       at firstboot, trusted in Windows store  │                        │
│  └───────────────────────────────────────────────┘                        │
│        ▲                                                                  │
│        │  at-logon task (§5a)                                             │
│  hosts: 127.0.0.1 basapos.local → https://basapos.local (:443)            │
└───────────────────────────────────────────────────────────────────────────┘
```

### Key pipeline decisions

| Decision | Verdict | Why |
|---|---|---|
| Docker-in-docker during distro build | ❌ | needs privileged CI, fragile |
| Ship `images.tar` + firstboot `docker load` | ✅ | plain build/export; first boot 5–15 min on POS-grade disks (GUI shows indeterminate progress + phase status) |
| `images.tar` after successful load | **deleted** | ~5 GB reclaimed inside vhdx; reinstall = USB, which is already the medium |
| Site via firstboot `bench new-site` | ✅ | the exact proven path as Linux `create-site.sh` — no CI compose-run, no snapshot artifacts, no restore semantics |
| Certs / DB creds / admin pw | generated per-install at firstboot | nothing secret ships in the artifact |
| Compose in distro | generated by the Linux flow's own scripts | kills fork drift at the root |

### §3b · Firstboot phases (sentinel per phase — crash-safe)

```
 phase 1  docker load  images.tar            [sentinel: loaded]
 phase 2  generate DB root pw + .env         [sentinel: env]
          (from template — no baked secrets)
 phase 3  compose up (db/cache/proxy tiers)  [sentinel: stack]
 phase 4  bench new-site basapos.local         [sentinel: site]
          + install apps (apps.txt from
          image — same as create-site.sh)
          + migrate + build assets;
          admin pw from /mnt/c …/config
 phase 5  generate per-install cert (unique  [sentinel: cert]
          CN) + install into traefik
 phase 6  set Administrator password (from   [sentinel: pw]
          /mnt/c …/config; random per install)
 phase 7  compose up full stack --wait        [sentinel: done]
 phase 8  delete /opt/basapos/images.tar      (best-effort, last)

 CI drill: SIGKILL firstboot at every phase boundary → re-run →
 must converge. "Run twice after success" is NOT sufficient.
```

---

## 4 · GUI Installer (`setup-gui/`)

**Tech:** .NET 10 (LTS) · WinForms · self-contained single-file win-x64
(built on Linux CI via `dotnet publish`; ~70 MB; zero runtime deps on
target; `app.manifest` → `requireAdministrator`).

```
┌─ BasaPOS Setup ──────────────────────────────┐
│  ● Checking prerequisites…                   │
│  ● Enabling WSL features…                    │
│  ● Importing appliance  ▓▓▓▓▓▓▓░░░ 71%        │
│  ● Provisioning site…  (DO NOT power off)    │
│  ● Waiting for healthy…                      │
│  ─────────────────────────────────────────── │
│  ✓ Done — Administrator password: ████ [copy]│
│  [ Uninstall ]              [ Open BasaPOS ] │
└──────────────────────────────────────────────┘
```

```
INSTALL FLOW                      RE-RUN / EXISTING INSTALL
════════════                      ═════════════════════════
1· prereq check                   Window shows install status
     Win10 19044+ · virt          + two buttons:
     enabled? no →                  [ Uninstall ]  [ Reinstall ]
       BIOS-disabled = hard        Reinstall = uninstall → install
       abort w/ instructions       (one code path, no partial
     ≥25 GB free (parts×3 basis)    states, no in-place repair)
2· WSL present?
     no → dism /online /enable-
          feature VirtualMachinePlatform
          (+ WSL feature) → install
          pinned MSI
     reboot pending → tell tech
       "reboot, run Setup again"
       (no resume task — install is
       IDEMPOTENT: every step
       checks-before-does)
3· stitch parts → verify SHA256
     (BEFORE import)
4· wsl --import → C:\BasaPOS\distro
5· generate 16-char admin pw →
     config\credentials.txt (ACL)
     BEFORE firstboot — firstboot
     phase 2 appends DB root pw to
     the same file via /mnt/c
6· write .wslconfig (§5a) + hosts
     entry + settings.txt
     (LAN_MODE=false placeholder)
7· register at-logon task (§5a)
8· firstboot runs (§3b) — GUI
     polls https://basapos.local/
     api/method/ping (cert-pinned)
     poll: 10s interval · 15 min cap
     · backoff · inside-WSL fallback
     check (v2 lesson: Windows-side
     polling alone lies)
9· trust cert in Windows store,
     write version.txt → Done
     (password shown once, now)
```

- GUI drives everything directly: `wsl.exe`, `tar`, `dism`, hosts file
  I/O, Task Scheduler via `/create` (at-logon task is all schtasks can
  express anyway). **No PowerShell scripts in the install path.**
  (CI/e2e tooling may still use PS — that's not the install path.)
- `wsl.exe` wrapper hardening (hard-won v2 lessons): timeouts on every
  call, `CreateNoWindow`, UTF-16 output decoding, stdout drained before
  wait-for-exit.
- Idempotent: every step checks-before-does; any interrupted install is
  completed by re-running Setup — no resume machinery, no state files
  beyond `version.txt`.
- Uninstall button = §6. "Open BasaPOS" = default browser.

---

## 5 · Autostart & Scheduled Backups

### §5a · Autostart — at-logon, nothing else

```
 PLATFORM FACT (paid for in v2 field commits 455545f, 8f2e578, 1b92937):
 S4U sessions strip the user profile — WSL registration (HKCU) and the
 boot wrapper break. At-logon only. Kiosk machines run Windows
 auto-logon anyway.

 .wslconfig provisioned at install (machine-global — documented):
   vmIdleTimeout=-1 · memory=<sized for ERPNext+MariaDB, e.g. 6GB>
   (v2 lesson d0da637 — the VM WILL idle out without this)
   Removed at uninstall (only the keys we wrote).
```

```
 Windows boots → user logs on
      │
      ▼  (+30s delay)
┌──────────────────────────────────────────────────────┐
│ Task: BasaPOS-Appliance (at-logon, highest)          │
│   boot wrapper (.cmd in ProgramData — v2 lesson):    │
│   1· wsl -d BasaPOS --exec /bin/true   (start VM)   │
│   2· systemd → docker → firstboot (once)             │
│   3· restart policies bring stack up                 │
│   4· hwclock -s (clock resync — sleep drift)         │
│   5· poll https://…/ping · retry                     │
└──────────────────────────────────────────────────────┘
```

**Launcher independence:** the GUI exe is only needed for
(un)install. Closing it, deleting it, never opening it — the appliance
keeps running.

### §5b · Scheduled backups — the zero-support insurance

```
 systemd timer in distro (daily, off-hours):
   bench backup --with-files → copy OUT to /mnt/c/BasaPOS/backups/
   · keep-last-N retention (default 7)
   · skip + log if Windows free space < guard
   · same logic as scripts/backup.sh (Linux parity)

 Reinstall restores nothing automatically — but backups\ survives
 uninstall-by-default, and restoring a backup after reinstall is a
 documented two-command bench operation in the tech runbook.
```

---

## 6 · Uninstall

```
1· wsl --unregister BasaPOS          (removes vhdx + distro)
2· delete at-logon task
3· remove hosts entry
4· remove .wslconfig (only the keys we wrote)
5· delete C:\BasaPOS\                (prompts to keep backups\)
```

Clean machine afterward — verified by scripted e2e drill (§8).

---

## 7 · Hardening Matrix

| Surface | Measure |
|---|---|
| Services | unprivileged inside distro; root only for import/boot exec |
| Credentials | per-install: admin pw + DB root pw generated at firstboot (never baked) · ACL-restricted `credentials.txt` · shown once in GUI |
| Secrets in artifact | none baked — site snapshot contains no secrets; `.env` ships as TEMPLATE, secrets filled at firstboot |
| TLS | per-install self-signed cert (unique CN) generated at firstboot · GUI imports to Windows trust store · health poll cert-pinned |
| Telemetry | zero — appliance makes no outbound connections by design |
| Supply chain | base digest-pinned · app branches pinned in `apps.json` · all 4 image tags pinned · WSL MSI version pinned · SHA256SUMS per release |
| Network | mariadb/redis inside distro network only; localhost-forwarded web ports |
| Payload integrity | stitch → SHA256 verify BEFORE import |
| Disk hygiene | compose log rotation (`max-size`/`max-file`) · images.tar deleted post-load · backup retention bounded |

---

## 8 · Verification

```
 LAYER              CHECK                              WHERE
 ─────────────────────────────────────────────────────────────────
 distro build       tarball structure asserts:         CI, every build
                    systemd ✓ docker ✓ images.tar(4) ✓
                    snapshot ✓ compose ✓ wsl.conf ✓
                    backup.timer ✓
 image parity       frappe image manifest digest ==    CI, every build
                    the ONE saved images.tar (build
                    once — never a second build)
 compose parity     sha256(compose+env template in     CI, every build
                    distro) == Linux-flow-generated
 provisioning       firstboot KILL-AT-EVERY-PHASE      CI, every build
                    drill → re-run converges (not
                    just run-twice)
 backup timer       trigger basapos-backup.service in       CI, every build
                    distro test → backup file lands in
                    /mnt/c target; retention prunes
 windows e2e        scripted drills (setup-gui/e2e/,   windows runner,
                    CI harness — PS allowed in CI,      every release
                    just not in the install path):
                    · clean install (Win10 19044 +
                      Win11) · reboot → at-logon task
                    · delete-Setup-still-works
                    · power-cut-mid-firstboot ×4 phases
                      → re-run Setup converges
                    · reinstall path (uninstall →
                      install)
                    · uninstall cleanliness
 GUI                install/uninstall/reinstall         smoke checklist
 release            parts + Setup.exe + SHA256SUMS      tag push
 CI disk            per-stage cleanup + size budget     every build
                    (buildx prune, delete tars post-use)
```

---

## 9 · Failure Modes

| Failure | Handling |
|---|---|
| BIOS virt disabled | hard abort with per-machine instructions (no zombie installs) |
| Reboot needed mid-install (WSL enable) | Setup says "reboot and run again" — install is idempotent, no resume machinery |
| Part corrupt / bad USB | SHA256 verify pre-import; actionable message |
| Import fails / VHD missing later | reinstall (uninstall → install) |
| Power cut mid-firstboot | per-phase sentinels (§3b); re-run Setup converges; atomic site swap |
| Site never healthy | poll 10s/15min cap/backoff; "DO NOT power off" state; terminal failure state with ONE actionable instruction (reinstall); inside-WSL fallback check |
| VM idles out mid-session | `vmIdleTimeout=-1` in .wslconfig |
| Clock drift after sleep | boot wrapper `hwclock -s` at logon; persistent wedge → reboot (documented) |
| Low disk | guard ≥25 GB at install; backup timer skips on low disk; log rotation bounded |
| WSL update breaks things | pinned MSI shipped in payload |
| Password lost | reinstall, or `bench set-admin-password` via `wsl` (runbook) |
| SmartScreen warn | one-time "More info → Run anyway"; code-signing cert optional later |
| Third-party AV heuristics | documented tech runbook step: AV exclusion for `C:\BasaPOS` + Setup.exe |

---

## 10 · Repo Layout (after)

```
frappe-offline/
├── appliance/                      # REBUILT for v3
│   ├── Containerfile               # Ubuntu + docker engine + payload
│   ├── build.sh                    # build → validate → export → split
│   ├── validate.sh                 # structural + parity asserts
│   └── overlay/etc/wsl.conf
├── setup-gui/                      # NEW — .NET 10 WinForms installer
│   ├── BasaPOS-Setup.csproj
│   └── e2e/                        # scripted drills (CI harness)
├── scripts/                        # Linux/Docker flow — UNCHANGED
│   └── (*.ps1 Docker-Desktop twins: DELETED — superseded by GUI)
├── apps.json                       # shared source of truth
├── docs/superpowers/specs/         # this doc
└── .github/workflows/              # ci.yml rewritten for v3
                                    # release.yml: tag → assets + checksums

DELETED
────────
package/                (BasaPOS.iss · build.ps1 · payload/ · launcher/)
old appliance content   (systemd-nginx units, non-docker provision)

DEPENDENT SURFACES REWRITTEN (not silently stale)
────────
README.md               Windows section: GUI flow replaces ps1 quickstart;
                        appliance section points at v3 artifact
.github/workflows/ci.yml  8-job v2 graph → v3 jobs (drills live here)
docs/superpowers/plans/ 2026-08-22 + 2026-08-23 plans marked SUPERSEDED
```

---

## 11 · Milestones

```
M1 ██    CI: ONE image build → images.tar (4 pinned) + snapshot +
         distro tarball; structure/parity/kill-drill asserts;
         disk-budgeted
M2 ████   GUI: stitch/verify, features+MSI, import, firstboot
         orchestration, cert trust, poll → clean-install E2E
         on Win11 VM
M3 ██████ at-logon autostart verified across reboot; Win10 19044
         drill; reinstall path; uninstall clean
M4 ████████ release workflow: parts + Setup.exe + SHA256SUMS;
         tech runbook (AV step · backup-restore-after-reinstall)
```
