# Headless Keeper + App Shortcut (BasaPOS v3.1)

```
Date:     2026-09-05
Revision: 1.0 — approved design
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
- WSL2 VM lives only while ≥1 `wsl.exe` client session exists
  (`vmIdleTimeout` proven ignored on pinned WSL 2.7.11 — removed in v3.0.5).
- The Start Menu "BasaPOS" entry the user clicks is the **WSL distro's own
  auto-generated Terminal profile** (opens a shell = accidental keeper).
  v3 ships no shortcut of its own. It stays (cannot be cleanly removed);
  once the hidden keeper exists it becomes a harmless Linux shell.
- Generated compose has **zero `restart:` policies** and firstboot is
  `RemainAfterExit=yes` → a VM cold boot today leaves containers DOWN.
  Any self-healing keeper must fix this or it reboots into a dead site.

---

## 2 · Decisions (user-approved)

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
 │                          │ (ProgramData path retires entirely).   │
 │ Shortcut icon?           │ Favicon of bsmtechsolutions.co.zw      │
 │                          │ (192px PNG → multi-size .ico).         │
 │ Kill-the-keeper safety?  │ Repetition watchdog trigger (≤5 min).  │
 └──────────────────────────┴────────────────────────────────────────┘
```

Rejected alternatives: bare-`wsl.exe` task only (interactive tasks show a
console; Win11-`conhost --headless` fragile); Windows Service as keeper
(SYSTEM cannot see per-user WSL distros — same failure class as S4U).

---

## 3 · Architecture

```
 Windows logon
  └─ Task: BasaPOS-Keeper (sole task; Appliance task + boot.cmd RETIRED)
      ├─ trigger: at logon
      ├─ trigger: every 5 min, indefinitely ("don't start new instance")
      ├─ settings: no time limit, RestartCount=3 / RestartInterval=PT1M
      └─ action: C:\BasaPOS\bin\BasaPOS.Keeper.exe   (WinExe, no console)
          ├─ named mutex → 2nd copy exits instantly (watchdog-safe)
          ├─ heartbeat → C:\BasaPOS\logs\keeper.log (1 MB roll)
          └─ loop forever:
               spawn wsl.exe -d BasaPOS --exec /bin/sleep infinity (hidden)
               │
               ├─ VM boots if down → systemd → docker.service (enabled)
               │    └─ containers [restart: unless-stopped] ← NEW
               │         └─ https://basapos.local healthy
               │
               └─ child exits? → log → sleep 5s → respawn

 User clicks "BasaPOS" ──→ Start Menu / Desktop .lnk ──→ browser
                           icon: basapos.ico (from site favicon)
```

---

## 4 · Components

```
 ┌────────────────────┬──────────────────────────────────────────────┐
 │ Unit               │ Purpose / interface                          │
 ├────────────────────┼──────────────────────────────────────────────┤
 │ BasaPOS.Keeper.exe │ Hidden supervisor. Deps: wsl.exe, mutex,     │
 │ (new, minimal —    │ log file. NO WinForms (~1–5 MB, not 60).     │
 │ no GUI framework)  │ Exit codes: 0 clean-stop / 1 fatal (bad     │
 │                    │ distro) / 2+ unexpected (→ task restarts).   │
 │ TaskRegistrar v2   │ Creates ONE task (2 triggers via PS          │
 │                    │ ScheduledTaskTrigger array), deletes         │
 │                    │ BasaPOS-Appliance + BasaPOS-Setup-Resume.    │
 │ ShortcutCreator    │ Start Menu + Desktop BasaPOS.lnk → SiteUrl,  │
 │ (new)              │ icon basapos.ico. Idempotent, removes on     │
 │                    │ uninstall.                                   │
 │ gen-compose.sh     │ Adds `restart: unless-stopped` to EVERY      │
 │                    │ service (cold-boot hole fix).                │
 │ Uninstaller        │ Kill keeper by EXE PATH → delete task →      │
 │                    │ delete shortcuts → existing flow. Retires    │
 │                    │ C:\ProgramData\BasaPOS + boot.cmd.           │
 │ payload/basapos.ico│ Multi-size .ico (16/32/48/256), converted ONCE from │
 │                    │ the site favicon and COMMITTED to the repo (builds  │
 │                    │ must stay offline-capable — no fetch at build time).│
 │                    │ Source: https://bsmtechsolutions.co.zw/wp-content/  │
 │                    │ uploads/2026/05/cropped-site_logo--192x192.png      │
 └────────────────────┴──────────────────────────────────────────────┘
```

---

## 5 · Restart matrix (the whole point)

```
 ┌────────────────────────────────┬───────────────┬──────────────────┐
 │ Failure                        │ Layer         │ Recovery         │
 ├────────────────────────────────┼───────────────┼──────────────────┤
 │ wsl.exe child dies / VM killed │ supervisor    │ ~5 s respawn     │
 │ keeper crashes (non-zero exit) │ task restart  │ ~1 min, ×3 tries │
 │ keeper killed (Task Mgr) /     │ repetition    │ ≤5 min (mutex    │
 │ clean exit / retries exhausted │ trigger       │ makes it safe)   │
 │ reboot                         │ at-logon      │ at logon         │
 │ container dies                 │ compose       │ docker restarts  │
 │                                │ unless-stopped│ it               │
 │ dockerd/VM cold boot           │ systemd chain │ auto ( §3 )      │
 └────────────────────────────────┴───────────────┴──────────────────┘
```

Out of scope (documented, not handled): someone **disabling the scheduled
task itself** — no software can resurrect that; same limit as Windows
services. Logoff stops the site (inherent to at-logon; accepted in §2).

---

## 6 · Failure modes

```
 ┌──────────────────────┬────────────────────────────────────────────┐
 │ Mode                 │ Behaviour                                  │
 ├──────────────────────┼────────────────────────────────────────────┤
 │ Distro missing       │ keeper exits 1 (fatal, no loop) → task     │
 │ (uninstalled distro) │ restart burns 3× then stops; log explains  │
 │ wsl.exe missing      │ keeper exits 1; same as above              │
 │ Two keepers (double  │ mutex: 2nd exits 0 instantly; single wsl   │
 │ trigger overlap)     │ child only                                 │
 │ Log file locked/full │ best-effort logging, never crashes keeper  │
 │ Icon fetch fails     │ .ico is committed, so this cannot happen at     │
 │                    │ build time; if the SOURCE favicon is unreachable │
 │                    │ when (re)generating, keep the existing .ico      │
 └──────────────────────┴────────────────────────────────────────────┘
```

---

## 7 · Testing

```
 install → close ALL windows → site stays up (no console anywhere)
 taskkill /F BasaPOS.Keeper.exe → keeper back ≤5 min, site unaffected*
 wsl --shutdown → VM reboots, containers auto-up (NEW behaviour)
 reboot → site up after logon, no clicks needed
 click "BasaPOS" → browser opens site, no console flash
 uninstall → keeper dead, task gone, shortcuts gone,
             no C:\ProgramData\BasaPOS, no C:\BasaPOS
 unit: keeper loop (spawn/respawn/mutex) factored testable;
       task args; shortcut paths; compose restart policy present
```

\* Site unaffected because traefik/containers keep running on the live VM;
only the keeper client respawns.

---

## 8 · Retired (removed by this design)

- `C:\ProgramData\BasaPOS\boot.cmd` + `BootWrapper.cs` action (file,
  writer, and its task trigger) — supervisor replaces it.
- `BasaPOS-Appliance` scheduled task (uninstall still deletes the name).
- Visible console at logon — nothing user-facing remains except shortcuts.
