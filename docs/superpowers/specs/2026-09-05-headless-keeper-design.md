# Headless Keeper + App Shortcut (BasaPOS v3.1)

```
Date:     2026-09-05
Revision: 1.1 — amended per adversarial review (advocate + lens 1 + lens 2)
Status:   Approved — pending implementation plan
Amends:   2026-08-31-wsl-docker-parity-installer-design.md (autostart section)
```

---

## 1 · Problem

```
  TODAY (v3.0.x)                              WANTED
 ┌─────────────────────────┐                 ┌─────────────────────────┐
 │ logon → boot.cmd        │                 │ logon → keeper starts   │
 │ CONSOLE pops up         │                 │ (invisible, silent)     │
 │  └─ wsl.exe sleep =     │                 │  └─ site up             │
 │     the ONLY keeper     │                 │                         │
 │ user closes console ─┐  │                 │ user clicks "BasaPOS" ─┐│
 │                      ▼  │                 │                       ▼ │
 │ VM idles out ~60s →    │                 │ browser → basapos.local │
 │ SITE DOWN              │                 │ (already running)       │
 └─────────────────────────┘                 │ kill keeper anyhow ───┐ │
                                             │  └─ back ≤5 min       │
                                             └─────────────────────────┘
```

Field facts driving this design:
- WSL2 VM lives only while ≥1 `wsl.exe` client session is connected
  (`vmIdleTimeout` proven ignored on pinned WSL 2.7.11 — removed in v3.0.5).
- The Start Menu "BasaPOS" entry the user clicks is the **WSL distro's own
  auto-generated Terminal profile** (opens a shell = accidental keeper).
  v3 ships no shortcut of its own.
- CORRECTION (adversarial review v1.1): the compose stack **already**
  carries `restart: unless-stopped` (upstream anchor in
  `frappe_docker/compose.yaml:7`, confirmed 12× in generated
  `compose.custom.yaml`; `configurator` deliberately `on-failure`). There
  is NO compose change in this design. If a cold-boot symptom is ever
  observed, the prime suspect is the keeper gap itself (VM never boots
  without a `wsl.exe` client), to be verified live via
  `docker inspect -f '{{.HostConfig.RestartPolicy.Name}}'` +
  `systemctl is-enabled docker` — never by blindly stamping policies
  (flipping configurator to `unless-stopped` would loop it forever).

---

## 2 · Decisions (user-approved, review-amended)

```
 ┌──────────────────────────┬────────────────────────────────────────┐
 │ Question                 │ Decision                               │
 ├──────────────────────────┼────────────────────────────────────────┤
 │ Pre-login start?         │ NO — at-logon only. S4U was rejected   │
 │                          │ before (strips profile/env, breaks     │
 │                          │ WSL); technician machines log on.      │
 │ Clicking "BasaPOS" does? │ Opens https://basapos.local in default │
 │                          │ browser (plain .lnk, site already up). │
 │ Keeper location?         │ C:\BasaPOS\bin\BasaPOS.Keeper.exe       │
 │ Keeper publish model?    │ Self-contained single-file WinExe      │
 │                          │ (~15–25 MB). Field has no .NET runtime │
 │                          │ — framework-dependent would fail       │
 │                          │ silently. Matches Setup's model.       │
 │ Shortcut icon?           │ Favicon of bsmtechsolutions.co.zw,     │
 │                          │ converted ONCE, committed as           │
 │                          │ payload/basapos.ico, installed to      │
 │                          │ C:\BasaPOS\bin\basapos.ico.            │
 │ Shortcut naming?         │ Ours keeps clean "BasaPOS"; installer  │
 │                          │ hides the distro Terminal profile      │
 │                          │ (settings.json hidden:true, best-      │
 │                          │ effort, reverted on uninstall).        │
 │ Kill-the-keeper safety?  │ Repetition watchdog trigger (≤5 min).  │
 │ Account model?           │ SINGLE Windows account per machine     │
 │                          │ (kiosk-style). Triggers scoped to the  │
 │                          │ installing user; mutex is Global\.     │
 │ Power/sleep?             │ Appliance standard: powercfg no-sleep  │
 │                          │ on AC at install. Sleep/resume is      │
 │                          │ otherwise untested territory.          │
 │ WU overnight reboot?     │ Explicitly accepted gap: reboot →      │
 │                          │ login screen → site down until logon.  │
 │                          │ Mitigation: active hours +             │
 │                          │ NoAutoRebootWithLoggedOnUsers;         │
 │                          │ auto-logon documented as optional.     │
 │ ProgramData?             │ boot.cmd retires; install.log STAYS    │
 │                          │ (App.cs deliberately logs there so an  │
 │                          │ open handle can't abort reinstall      │
 │                          │ deletes of C:\BasaPOS).                │
 └──────────────────────────┴────────────────────────────────────────┘
```

Rejected alternatives: bare-`wsl.exe` task only (interactive tasks show a
console; Win11-`conhost --headless` fragile); Windows Service as keeper
(SYSTEM cannot see per-user WSL distros — same failure class as S4U).

---

## 3 · Architecture

```
 Windows logon (installing user)
  └─ Task: BasaPOS-Keeper (sole task; Appliance task + boot.cmd RETIRED)
      ├─ trigger: at logon (scoped to installing user)
      ├─ trigger: every 5 min, indefinitely ("don't start new instance")
      ├─ settings: no time limit, RestartCount=3 / RestartInterval=PT1M
      ├─ principal: highest run level, interactive
      └─ action: C:\BasaPOS\bin\BasaPOS.Keeper.exe   (no console ever)
          ├─ named mutex Global\BasaPOS.Keeper → 2nd copy exits 0
          │   instantly (watchdog-safe)
          ├─ watchdog thread: FailFast if main loop stalls >N sec
          │   (hang → crash → task-restart path; a hung keeper
          │   otherwise looks "Running" forever)
          ├─ heartbeat → C:\BasaPOS\logs\keeper.log, 1 line / 60 s,
          │   format: ts | state | child-pid | site-probe | note;
          │   retention: keeper.log + keeper.log.1 (older deleted)
          └─ loop forever:
               ├─ child = spawn wsl.exe -d BasaPOS --exec /bin/sleep
               │   infinity (CreateNoWindow, stderr captured, child in
               │   kill-on-close Job Object so keeper death reaps it)
               ├─ every ~60 s: probe https://basapos.local/api/method/ping
               │   (reuse HealthPoller semantics); log VM-UP vs SITE-UP
               │   distinctly; M consecutive failures → log + capture
               │   `systemctl is-active docker` via wsl (read-only diag)
               ├─ child exits? → log exit code + stderr tail →
               │   ├─ distro still listed? NO after N×30 s retries →
               │   │   exit 1 FATAL (no loop; task burns 3× then stops)
               │   └─ else → exponential backoff (5 s → cap 60 s) →
               │       respawn (circuit-breaker marker file after N
               │       fast exits so crash-loops are discoverable)
               └─ exit codes: 0 = clean stop only; ANY non-zero → task
                   restart ×3 (code value is for logs, Task Scheduler
                   cannot distinguish them)

 User clicks "BasaPOS" ──→ Start Menu / Desktop .lnk ──→ browser
                           icon: C:\BasaPOS\bin\basapos.ico
```

---

## 4 · Components

```
 ┌────────────────────┬──────────────────────────────────────────────┐
 │ Unit               │ Purpose / interface                          │
 ├────────────────────┼──────────────────────────────────────────────┤
 │ BasaPOS.Keeper     │ Hidden supervisor (§3). Seam for tests:      │
 │ (new project, raw  │ IProcessRunner over wsl.exe (spawn/wait/     │
 │ .NET, NO WinForms; │ kill/stderr). Self-contained single-file.    │
 │ tests: new         │                                              │
 │ BasaPOS.Keeper.    │                                              │
 │ Tests project)     │                                              │
 │ TaskRegistrar v2   │ Creates ONE task by same name (overwrite via │
 │                    │ -Force): 2 triggers via PS array, indefinite │
 │                    │ repetition, IgnoreNew, Highest principal,    │
 │                    │ installing-user scope. UPGRADE contract:     │
 │                    │ Stop-ScheduledTask BOTH old names first      │
 │                    │ (running v3.0.x keeper never exits on its    │
 │                    │ own), delete boot.cmd, THEN register +       │
 │                    │ Start-ScheduledTask.                         │
 │ ShortcutCreator    │ Start Menu + Desktop BasaPOS.lnk → SiteUrl,  │
 │ (new)              │ icon C:\BasaPOS\bin\basapos.ico (copies the  │
 │                    │ .ico there first). Idempotent overwrite.     │
 │                    │ Hides distro Terminal profile (best-effort). │
 │                    │ Removes all three on uninstall.              │
 │ Compose policy     │ NO CODE CHANGE. Verification step + CI/test  │
 │ (verification      │ asserting: every service has a restart       │
 │ only)              │ policy AND configurator stays on-failure.    │
 │ Uninstaller        │ ORDER: disable task → delete task → tree-    │
 │                    │ kill keeper by EXE PATH (Get-Process | Where │
 │                    │ Path -eq …) → wsl --shutdown → unregister →  │
 │                    │ delete files. (Kill-first respawns the       │
 │                    │ keeper mid-uninstall.) Retires boot.cmd;     │
 │                    │ ProgramData dir survives ONLY for            │
 │                    │ install.log (by design, §2).                 │
 │ payload/basapos.ico│ Multi-size .ico (16/32/48/256), converted    │
 │                    │ ONCE from the site favicon and COMMITTED     │
 │                    │ (builds stay offline-capable). Source:       │
 │                    │ https://bsmtechsolutions.co.zw/wp-content/   │
 │                    │ uploads/2026/05/cropped-site_logo--192x192   │
 │                    │ .png                                         │
 └────────────────────┴──────────────────────────────────────────────┘
```

---

## 5 · Restart matrix (the whole point)

```
 ┌────────────────────────────────┬───────────────┬──────────────────┐
 │ Failure                        │ Layer         │ Recovery         │
 ├────────────────────────────────┼───────────────┼──────────────────┤
 │ wsl.exe child dies / VM killed │ supervisor    │ backoff respawn  │
 │ keeper crashes (non-zero exit) │ task restart  │ ~1 min, ×3 tries │
 │ keeper HANGS (no exit)         │ watchdog      │ FailFast → crash │
 │                                │ thread        │ → layer above    │
 │ keeper killed (Task Mgr) /     │ repetition    │ ≤5 min (mutex    │
 │ clean exit / retries exhausted │ trigger       │ makes it safe)   │
 │ reboot                         │ at-logon      │ at logon         │
 │ container dies at runtime      │ keeper probe  │ logged (VM-UP /  │
 │                                │ + compose     │ SITE-DOWN);      │
 │                                │ policy        │ docker restarts  │
 │ dockerd/VM cold boot           │ upstream      │ auto (policies   │
 │                                │ policies +    │ verified, not    │
 │                                │ systemd chain │ added, §1)       │
 │ host sleep/resume              │ powercfg      │ no-sleep on AC;  │
 │                                │ (install)     │ resume path      │
 │                                │               │ untested, logged │
 └────────────────────────────────┴───────────────┴──────────────────┘
```

Out of scope (documented, not handled): someone **disabling the scheduled
task itself**; WU reboot → login screen (§2); logoff stops the site
(inherent to at-logon).

---

## 6 · Failure modes

```
 ┌──────────────────────┬────────────────────────────────────────────┐
 │ Mode                 │ Behaviour                                  │
 ├──────────────────────┼────────────────────────────────────────────┤
 │ Distro missing       │ N×30 s retries (covers slow early-logon    │
 │                      │ WSL init) → exit 1 fatal; log names distro │
 │                      │ absence distinctly from transient wsl      │
 │                      │ errors (stderr captured, never discarded)  │
 │ Keeper hang          │ watchdog FailFast → task-restart path (§5) │
 │ Crash-loop (fast     │ backoff caps at 60 s; marker file after N  │
 │ child exits)         │ fast exits; no silent CPU churn            │
 │ schtasks /end vs     │ /end on hung process can flip state Ready  │
 │ taskkill divergence  │ while process lives → mutex blocks dupes;  │
 │                      │ tested (§7)                                │
 │ Two keepers (trigger │ mutex: 2nd exits 0; single wsl child only  │
 │ overlap)             │                                            │
 │ Second Windows       │ Out of scope per §2 single-account rule;   │
 │ account              │ foreign keeper fatal-exits loudly (log)    │
 │ Log locked/full      │ best-effort logging, never crashes keeper; │
 │                      │ retention §3                               │
 │ Upgrade over running │ v2 stops old tasks BEFORE copying exe (§4) │
 │ v3.0.x               │ — locked-exe copy failure impossible       │
 │ Uninstall respawn    │ task deleted BEFORE kill (§4 order) — no   │
 │ race                 │ +1 min / +5 min resurrection window        │
 └──────────────────────┴────────────────────────────────────────────┘
```

---

## 7 · Testing

```
 install → close ALL windows → site stays up (no console anywhere)
 taskkill /F BasaPOS.Keeper.exe → keeper back ≤5 min, site unaffected*
 schtasks /end + hang-simulation + logoff→logon matrix
 wsl --shutdown → VM reboots, containers auto-up
 reboot → site up after logon, no clicks needed
 click "BasaPOS" → browser opens site, no console flash; Start search
   shows OUR entry first (profile hidden)
 upgrade v3.0.x → v3.1: old keeper stopped, new running, no console
 uninstall → keeper dead, task gone, shortcuts gone, no boot.cmd,
             ProgramData holds ONLY install.log
 unit: keeper loop via IProcessRunner (spawn/respawn/mutex/backoff/
       fatal-vs-transient matrix); task XML snapshot asserting
       indefinite Repetition.Duration + IgnoreNew + principal;
       compose assertion (policies exist, configurator on-failure);
       shortcut paths + icon copy
```

\* Site unaffected because traefik/containers keep running on the live VM;
only the keeper client respawns.

---

## 8 · Retired (removed by this design)

- `C:\ProgramData\BasaPOS\boot.cmd` + `BootWrapper.cs` writer + its task
  trigger — supervisor replaces it. (ProgramData dir itself stays for
  `install.log`, §2.)
- `BasaPOS-Appliance` scheduled task (uninstall still deletes the name).
- Visible console at logon — nothing user-facing remains except shortcuts.
