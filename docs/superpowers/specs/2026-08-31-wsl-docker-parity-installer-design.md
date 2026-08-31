# Windows "Linux-in-a-Box" Installer (BasaPOS v3)

```
Date:     2026-08-31
Revision: 1.1 — hardened after 3-agent adversarial review
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

### v1.1 review hardening

This revision folds in findings from three adversarial review passes
(platform feasibility · field ops · consistency). Headline corrections:
S4U demoted (v2's own field history refuted it — commits `455545f`,
`8f2e578`, `1b92937`), WSL VM lifetime + memory provisioning added,
scheduled backups added, corrupt-VHD recovery de-circularized, offline
image set completed (4 images, not 1), TLS story made explicit, per-install
DB credentials, CI build-once parity, disk budget closed.

---

## 2 · Requirements

```
R1  Windows runs the SAME compose stack/images   R5  Fully offline (Zimbabwe);
    as Linux — no second app stack                    updates via USB / rare net
R2  Click-and-run GUI: install, upgrade,         R6  CI-built releases from repo
    repair, uninstall — no wizards                     (multi-part assets ≤2GB ea.)
R3  Auto-start at boot, survives reboots         R7  LAN clients later, no rework
    AND stays up through sleep/resume/idle        R8  Fresh start — no migration
R4  Zero-support model ("charge once"),              from v2 field installs
    including scheduled backups
```

**Audience:** the developer / a technician installs machines on-site.
"Click and run" replaces polish-for-owner with speed-for-tech.

**Non-goals (v3):**

| Out | Why |
|-----|-----|
| SYSTEM-level pre-login start | WSL distros register per-user — platform limit |
| Owner-facing control panel | V2 launcher taught us: techs use `wsl` + GUI install only |
| LAN mode | Designed (flag OFF), ships later — §8 |
| Changes to Linux/Docker flow | Shares `apps.json` + image + compose generation only |
| Migration from v2 appliance | R8 — fresh installs only |

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
│        ├─ compose run (CI runner) → create-site                           │
│        │       → bench backup --with-files → site-snapshot/               │
│        │         (snapshot has NO secrets — passwords reset per-install)  │
│        │                                                                  │
│        ├─ compose files + .env TEMPLATE generated by the SAME             │
│        │   scripts as the Linux flow (deploy.sh) — no fork, no drift      │
│        ▼                                                                  │
│  distro build:  Ubuntu (digest-pinned) + systemd=true                     │
│                 + Docker Engine + compose plugin                          │
│                 + /opt/basapos/{images.tar, site-snapshot/,               │
│                    compose/, firstboot phases}                            │
│                 + backup.timer + watchdog scripts                         │
│                                      │                                     │
│                        docker export → gzip → split → SHA256SUMS          │
│              release assets: basapos-distro.tar.part-aa/ab/…              │
│              + BasaPOS-Setup.exe + wsl.msi (pinned) + SHA256SUMS          │
└───────────────────────────────────────────────────────────────────────────┘

┌──────────────────────────── RUNTIME (Windows) ────────────────────────────┐
│                                                                           │
│  C:\BasaPOS\                                                              │
│   ├── distro\ext4.vhdx   ◄──── wsl --import BasaPOS                       │
│   ├── config\            credentials.txt (ACL), settings.txt,             │
│   │                      install-state.txt, version.txt                   │
│   ├── logs\              installer + boot + firstboot logs                │
│   ├── BasaPOS-Setup.exe  copy kept for upgrade/repair/uninstall           │
│   └── backups\           scheduled + pre-upgrade backups                  │
│                                                                           │
│  ┌───────────────────────────────────────────────┐                        │
│  │  WSL2 distro "BasaPOS" (systemd = PID 1)      │                        │
│  │                                               │                        │
│  │  docker.service                               │                        │
│  │    └─ basapos-firstboot.service (phased,      │                        │
│  │         sentinel-guarded — §3b)               │                        │
│  │    └─ basapos-backup.timer (daily — §5b)      │                        │
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
│        │  at-logon task + watchdog timer (§5)                             │
│  hosts: 127.0.0.1 basapos.local → https://basapos.local (:443)            │
└───────────────────────────────────────────────────────────────────────────┘
```

### Key pipeline decisions

| Decision | Verdict | Why |
|---|---|---|
| Docker-in-docker during distro build | ❌ | needs privileged CI, fragile |
| Ship `images.tar` + firstboot `docker load` | ✅ | plain build/export; first boot 5–15 min on POS-grade disks (GUI shows indeterminate progress + phase log) |
| `images.tar` after successful load | **deleted** | ~5 GB reclaimed inside vhdx; Repair requires USB (USB is already the update medium) |
| Site via CI snapshot + firstboot restore | ✅ | fast, deterministic, no secrets baked |
| Certs / DB creds / admin pw | generated per-install at firstboot | nothing secret ships in the artifact |
| Compose in distro | generated by the Linux flow's own scripts | kills fork drift at the root |

### §3b · Firstboot phases (sentinel per phase — crash-safe)

```
 phase 1  docker load  images.tar            [sentinel: loaded]
 phase 2  generate DB root pw + .env         [sentinel: env]
          (from template — no baked secrets)
 phase 3  compose up (db/cache/proxy tiers)  [sentinel: stack]
 phase 4  restore site-snapshot into scratch
          site → verify → ATOMIC swap to
          basapos.local (drop-before-restore
          if half-restored site exists)      [sentinel: site]
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
│  [ Open BasaPOS ]                            │
└──────────────────────────────────────────────┘
```

```
INSTALL FLOW                      RE-RUN (existing install detected)
════════════                      ═════════════════════════════════
1· prereq check                   Version guard FIRST: Setup compares
     Win10 19041+ (verify on        payload version vs config\version.txt
     19044 floor in e2e — §11)      → older payload + existing install =
     virt enabled? no →              REFUSE with clear message
       BIOS-disabled = hard        ┌────────┬────────┬────────┐
       abort w/ instructions       │Upgrade │ Repair │Uninstall│
     ≥25 GB free (parts×3 basis)   └────────┴────────┴────────┘
2· WSL present?
     no → dism /online /enable-
          feature VirtualMachinePlatform
          (+ WSL feature) → install
          pinned MSI
     reboot pending → resume task
       (at-logon trigger, one-shot,
       SELF-DELETES on success;
       install-state.txt marker so
       Setup resumes at right step;
       USB unplugged at resume →
       clear "reinsert USB" state)
3· stitch parts → verify SHA256
     (BEFORE import)
4· wsl --import → C:\BasaPOS\distro
5· write .wslconfig (§5) + hosts
     entry + settings.txt
     (LAN_MODE=false)
6· register at-logon task (§5)
7· generate 16-char admin pw →
     config\credentials.txt (ACL)
     BEFORE firstboot — firstboot
     phase 2 appends DB root pw to
     the same file via /mnt/c
8· firstboot runs (§3b) — GUI
     polls https://basapos.local/
     api/method/ping (cert-pinned
     to the per-install cert)
     poll: 10s interval · 15 min cap
     · backoff · inside-WSL fallback
     check (v2 lesson: Windows-side
     polling alone lies)
9· trust cert in Windows store,
     write version.txt → Done
     (password shown once, now)
```

- GUI drives everything directly: `wsl.exe`, `tar`, `dism`, Task
  Scheduler COM interop (or `/xml`) — not plain `schtasks` flags for
  anything non-trivial. **No PowerShell scripts in the install path.**
  (CI/e2e tooling may still use PS — that's not the install path.)
- `wsl.exe` wrapper hardening (hard-won v2 lessons): timeouts on every
  call, `CreateNoWindow`, UTF-16 output decoding, stdout drained before
  wait-for-exit.
- Idempotent: every step checks-before-does; interrupted installs re-run
  clean from `install-state.txt`.
- Repair = fresh re-import + restore of newest scheduled backup from
  `backups\` (NOT the upgrade drill — that needs a bootable old distro).
  Repair menu also includes **Reset admin password** (generates new pw →
  `bench set-admin-password` → rewrites `credentials.txt`).
- Uninstall button = §7. "Open BasaPOS" = default browser.
- Log streaming across the WSL boundary is M5 scope; until then the GUI
  shows phase status + "Open logs folder".

---

## 5 · Autostart, Watchdog & Scheduled Backups

### §5a · Autostart — at-logon is PRIMARY

```
 PLATFORM FACT (paid for in v2 field commits 455545f, 8f2e578, 1b92937):
 S4U sessions strip the user profile — WSL registration (HKCU) and the
 boot wrapper break. S4U is NOT the primary mechanism.

 Primary:  at-logon trigger + Windows auto-logon (kiosk machines should
           run auto-logon anyway)
 M3 experiment: S4U via Task Scheduler COM/xml — earns its way in only
           if the e2e drill proves it on the 19041-floor VM
```

```
 Windows boots / user logs on
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
│   6· write C:\BasaPOS\status.txt (for "wait-then-    │
│      open" shortcut — no dead-browser panic at open) │
└──────────────────────────────────────────────────────┘
```

### §5b · Watchdog — one mechanism, three failure classes

```
 Task: BasaPOS-Watchdog — every 5 min
   ├─ VM idled out?            → wsl --exec /bin/true restarts it
   ├─ slept/resumed?           → clock resync + health re-poll
   │                             (localhostForwarding wedge heals via
   │                              wsl --shutdown + restart, max 1×/hour)
   └─ unhealthy?               → restart attempt + red status.txt

 .wslconfig provisioned at install (machine-global — documented):
   vmIdleTimeout=-1 · memory=<sized for ERPNext+MariaDB, e.g. 6GB>
   (v2 lesson d0da637 — the VM WILL idle out without this)
   Removed at uninstall (only if we wrote it).
```

### §5c · Scheduled backups — the zero-support insurance

```
 systemd timer in distro (daily, off-hours):
   bench backup --with-files → copy OUT to /mnt/c/BasaPOS/backups/
   · keep-last-N retention (default 7)
   · skip + log if Windows free space < guard
   · same logic as scripts/backup.sh (Linux parity)

 Recovery dependency: corrupt-VHD repair (§10) restores the NEWEST
 scheduled backup — never relies on the broken distro backing itself up.
```

**Launcher independence:** the GUI exe is only needed for install/upgrade/
repair/uninstall. Closing it, deleting it, never opening it — the appliance
keeps running.

---

## 6 · Upgrade Drill (zero-support backbone)

```
 TECH ACTION                      WHAT SETUP DOES AUTOMATICALLY
 ═══════════                      ═══════════════════════════════════════
                                 ┌─────────────────────────────┐
 runs newer                      │ 0· version guard: payload   │
 BasaPOS-Setup.exe ─────────────►│    NEWER than installed?    │
      💾USB                      │    else REFUSE (no silent   │
                                 │    downgrade-restore)       │
                                 └──────────────┬──────────────┘
                                 ┌─────────────────────────────┐
                                 │ A· free space re-checked    │
                                 │    (stitched tar + backup   │
                                 │    copy-out + new vhdx)     │
                                 │ B· bench backup --with-     │
                                 │    files (inside OLD distro)│
                                 │    ✗ FAILS → HARD STOP:     │
                                 │    "BACKUP FAILED — nothing │
                                 │    unregistered" (old       │
                                 │    distro untouched)        │
                                 └──────────────┬──────────────┘
                                                ▼
                                 ┌─────────────────────────────┐
                                 │ C· copy backup OUT to       │
                                 │    backups\pre-upgrade\     │
                                 │ D· wsl --unregister old     │
                                 │ E· import NEW distro        │
                                 │ F· firstboot: load → stack →│
                                 │    copy backup INTO distro- │
                                 │    native fs FIRST (v2      │
                                 │    lesson cb317de) →        │
                                 │    restore + migrate        │
                                 │ G· keep existing password   │
                                 │    if credentials.txt       │
                                 │    exists, else regenerate  │
                                 │ H· vhdx --set-sparse + old  │
                                 │    vhdx deleted → poll      │
                                 └──────────────┬──────────────┘
                                                ▼
                                      data survives ✓
                                      apps updated ✓
                                      same USB workflow ✓

 Restore failure (F): abort with actionable GUI message + "Retry
 restore" (no re-backup). NEVER silently fall back to the CI snapshot —
 that would look like success while losing all field data.
```

---

## 7 · Uninstall

```
1· wsl --unregister BasaPOS          (removes vhdx + distro)
2· delete scheduled tasks (appliance + watchdog)
3· remove hosts entry
4· remove .wslconfig (only the keys we wrote)
5· delete C:\BasaPOS\                (prompts to keep backups\)
```

Clean machine afterward — verified by scripted e2e drill (§11).

---

## 8 · LAN Mode (designed now · flag OFF in v3)

```
settings.txt:  LAN_MODE=false   ← v3 default (localhost only)

ACTORS (no passive voice): GUI writes the flag; boot wrapper READS
settings.txt every boot and applies/removes the machine config.

LAN_MODE=true flips on (applied by wrapper at next boot):
─────────────────────────────
  firewall rule  TCP 443 · Private profile only   (HTTPS — matches
       │                                          the compose stack)
       ▼
  ┌──────────────────── Windows version? ────────────────────┐
  ▼ Win11 22H2+                                       Win10 ▼
mirrored networking                          NAT + portproxy
(.wslconfig: networkingMode=mirrored)        netsh portproxy 443→distro IP
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
| Credentials | per-install: admin pw + DB root pw generated at firstboot (never baked) · ACL-restricted `credentials.txt` · shown once in GUI · Reset path in Repair |
| Secrets in artifact | none baked — site snapshot contains no secrets; `.env` ships as TEMPLATE, secrets filled at firstboot |
| TLS | per-install self-signed cert (unique CN) generated at firstboot · GUI imports to Windows trust store · health poll cert-pinned |
| Telemetry | zero — appliance makes no outbound connections by design |
| Supply chain | base digest-pinned · app branches pinned in `apps.json` · all 4 image tags pinned · WSL MSI version pinned · SHA256SUMS per release |
| Network | mariadb/redis inside distro network only; localhost-forwarded web ports |
| Payload integrity | stitch → SHA256 verify BEFORE import |
| Disk hygiene | compose log rotation (`max-size`/`max-file`) · images.tar deleted post-load · vhdx set-sparse + compact at upgrade · backup retention bounded |

---

## 10 · Failure Modes

| Failure | Handling |
|---|---|
| BIOS virt disabled | hard abort with per-machine instructions (no zombie installs) |
| Reboot pending mid-install (WSL enable) | at-logon resume task, one-shot, self-deleting; `install-state.txt` resumes at correct step; USB unplugged at resume → "reinsert USB" state |
| Part corrupt / bad USB | SHA256 verify pre-import; actionable message |
| Import fails / VHD missing later | GUI **Repair**: fresh import + newest scheduled backup restore |
| Corrupt VHD | Repair (above) — recovery rides §5c scheduled backups, never the dead distro |
| OLD distro won't boot (upgrade) | drill step B hard-stops BEFORE unregister — data reachable via backups\ |
| Restore dies mid-upgrade | abort + "Retry restore"; never silent CI-snapshot fallback |
| Power cut mid-firstboot | per-phase sentinels (§3b); re-run converges; atomic site swap |
| Site never healthy | poll 10s/15min cap/backoff; "DO NOT power off" state; terminal failure state with ONE actionable instruction; inside-WSL fallback check |
| VM idles out mid-session | `vmIdleTimeout=-1` + watchdog (§5b) |
| Sleep/resume (nightly, POS reality) | watchdog: clock resync + forwarding-wedge heal (§5b) |
| Low disk | guard ≥25 GB at install, re-checked at upgrade with drill-specific threshold; backup timer skips on low disk; log rotation bounded |
| Disk full at runtime | MariaDB crash-loop prevention: compose log caps + retention + §5c guard; §10 row documents symptom → Repair |
| WSL update breaks things | pinned MSI shipped in payload |
| Old-USB downgrade attempt | version guard REFUSES (§6 step 0) |
| Password lost | Repair → Reset admin password |
| SmartScreen warn | one-time "More info → Run anyway"; code-signing cert optional later |
| Third-party AV heuristics | documented tech runbook step: AV exclusion for `C:\BasaPOS` + Setup.exe |

---

## 11 · Verification

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
 backup/restore     full roundtrip w/ live mariadb      CI, every build
 windows e2e        scripted drills (setup-gui/e2e/,   windows runner,
                    CI harness — PS allowed in CI,      every release
                    just not in the install path):
                    · clean install (Win10 19044 +
                      Win11) · reboot-without-login
                    · delete-Setup-still-works
                    · sleep/resume → healthy
                    · power-cut-mid-firstboot ×4 phases
                    · upgrade drill v(n−1)→v(n)
                    · upgrade-from-DEAD-distro
                    · old-USB downgrade refused
                    · disk-full behavior
                    · uninstall cleanliness
                    · at-logon task fires (S4U only
                      if it earns in)
 GUI                install/upgrade/repair/uninstall    smoke checklist
 release            parts + Setup.exe + SHA256SUMS      tag push
 CI disk            per-stage cleanup + size budget     every build
                    (buildx prune, delete tars post-use)
```

---

## 12 · Repo Layout (after)

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

## 13 · Milestones

```
M1 ██    CI: ONE image build → images.tar (4 pinned) + snapshot +
         distro tarball; structure/parity asserts; disk-budgeted
M2 ████   GUI: stitch/verify, features+MSI+reboot-resume, import,
         firstboot orchestration, cert trust, poll → clean-install
         E2E on Win11 VM (Win10 19044 in M3)
M3 ██████ at-logon autostart verified across reboot-without-login;
         watchdog (idle/sleep/resume) verified; S4U experiment
         gated here; Win10-floor drill
M4 ████████ scheduled backups live; upgrade drill (+ dead-distro,
         downgrade-refused, power-cut drills); uninstall clean
M5 ██████████ release workflow: parts + Setup.exe + SHA256SUMS;
         hardening pass; log streaming in GUI; ops docs
         (USB update · LAN_MODE · tech runbook incl. AV step)
```
