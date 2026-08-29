# Install Drill Failure Catalog

```
Date:     2026-08-29
Source:   10 independent reviewers (R1-R10), distinct focus lenses
Premise:  ESTABLISHED FACT — the CI install drill does not run to completion
Scope:    package/e2e/*.ps1 + everything they execute (setup.ps1, common.ps1,
          boot-wrapper.ps1, BasaPOS.iss, remove-basapos.ps1, ci.yml job)
Status:   Living tracker — update Status as items are fixed
```

## Verdict

```
The drill is structurally incapable of completing inside its job budget,
AND contains deterministic check-failures, AND converts every failure into
a hang/trap-die instead of a diagnosable red check.

  Σ drill-internal budgets ≈ 32-52 min  vs  ci.yml timeout-minutes: 25
  → GitHub kills the job mid-phase (usually §3) → no summary, no artifact
```

## Dedupe note

10 reviewers → 60+ raw findings → 25 unique mechanisms below.
Convergence count = how many reviewers independently found it.

## Tier 0 — Structural: the drill cannot finish even when green

| ID | Conv | Mechanism | Locations | Status |
|----|------|-----------|-----------|--------|
| D1 | 5 | Job timeout (25m) < sum of drill phase budgets (~32-52m); artifact download eats ~3m of the 25 | ci.yml `install-drill` vs drill WaitForExit caps | FIXED (Phase A) + re-scoped 2026-08-29: drill split into 3 CI steps (install/upgrade/uninstall), each fail-fast with step-level attribution; the 60-min cap is now a safety net, not a requirement |
| D2 | 5 | Unbounded blocking calls: ~~every curl lacks `--max-time`~~ (bounded in restructure), ~~uninstaller `-Wait` unbounded~~ (bounded 10m + kill/reap); wsl.exe wake/journalctl calls STILL unbounded. Half-open WSL2 localhost relay (the documented post-reimport state) makes a single curl hang forever → job kill, no diagnostics | drills, common.ps1:68, boot-wrapper.ps1:59-66, drill:197 | FIXED (Phase C: all curls -m bounded; wsl.exe wake/diag bounded via Invoke-BoundedWsl/Start-Job; uninstaller wait bounded 10m + kill/reap) |
| D3 | 5 | Inno poll (10m) < setup.ps1 runtime (fresh 12-25m, upgrade 18-35m) → `ewNoWait` setup.ps1 orphaned and racing later phases (two writers to setup-status.txt, concurrent wsl ops) | BasaPOS.iss:106-128, drill kill only hits Setup.exe | FIXED (Phase B/C: drill gates on setup-status terminal state; orphan setup.ps1 killed pre-upgrade; D16 hard-gates unregister) |
| D4 | 1* | Inno [Code] `MsgBox()` is NOT suppressed by /SUPPRESSMSGBOXES (official docs) → modal box on headless session-0 → Setup.exe hangs forever on ERROR/timeout paths | BasaPOS.iss:123,128 | FIXED (Phase C: SuppressibleMsgBox in .iss) |

*D4: one reviewer dissented (claimed auto-dismiss); the dissent cited no docs
and self-flagged as unverified. Official Inno docs list [Code] MsgBox among
the non-suppressible boxes. Treat as real.

## Tier 1 — Deterministic failures (drill ends red every run)

| ID | Conv | Mechanism | Locations | Status |
|----|------|-----------|-----------|--------|
| D5 | 2 | **schannel revocation fail-closed**: plain `curl.exe -s` (no -k) sets REVOCATION_CHECK_CHAIN; self-signed cert has no CRL/OCSP → CRYPT_E_NO_REVOCATION_CHECK → error 35 / http 000 **even with the cert correctly in Root**. The no-k TLS checks can NEVER pass as written (verified against curl schannel.c source) | drill:93,171; minimal:81 | FIXED (Phase A: --ssl-no-revoke -m 20 on all 3 no-k curls) |
| D6 | 3 | `-o /dev/null` in minimal drill's $ping: System32 curl.exe has NO /dev/null special-casing (verified in tool_operate.c) → write failure → ping always 000 → drill-debug always red | minimal:7 | FIXED (Phase A: -o NUL) |
| D7 | 3 | Cert import gated on `$online` (Windows-side curl) — after upgrade, localhost forwarding is broken (drill's own comments) → `$online=$false` → cert NEVER imported → post-upgrade TLS check unsatisfiable even after networking settles | setup.ps1:347-352 | FIXED (Phase B: Ensure-TrustedCert runs unconditionally, self-guarded on cert existence) |
| D8 | 3 | Native-stderr termination (mitigated in restructure: `$PSNativeCommandUseErrorActionPreference=$false` in drill-common.ps1; minimal drill retired — all drills now run under pwsh): (a) full drill runs pwsh 7.3+ where `$PSNativeCommandUseErrorActionPreference=$true` + EAP=Stop turns the ONE unredirected native call (drill:117 powershell.exe) into trap-death on any leaked stderr from Ensure-TrustedCert's uncaught non-terminating errors; (b) minimal drill runs under powershell.exe 5.1 where `2>$null`/`2>&1` on failing native = terminating error (schtasks line 72 fires when task missing → "DRILL DIED") | drill:117; minimal:72 | FIXED (Phase A/C: EAP guard in drill-common; drills have no unredirected native calls; minimal retired) |
| D9 | 1† | Restore exit-code plumbing broken at 3 layers: `bash -c "... ; echo WSL_EXIT:$? >> log"` returns 0 ALWAYS (echo is last cmd); per-step `$(ts) ... $?` logs print 0 (command substitution resets $?); setup's `if ($exitCode -ne 0) throw` is dead code. Every restore failure invisible | setup.ps1:242-243,203-231 | FIXED (Phase B: rc=$? captured per step; restore failure aborts before post-steps; outer exit propagated) |

†D9 empirically verified by reviewer with live bash experiments.

| ID | Conv | Mechanism | Locations | Status |
|----|------|-----------|-----------|--------|
| D10 | 2 | `Get-Process conhost → Stop-Process -Force` at §3/§4 kills ALL conhost.exe on the runner **including the drill's own console** — the exact 0xE9 "no process on the other end of the pipe" signature commit a19fca4 mis-fixed by switching to pwsh | drill:150-151,191 | FIXED (restructure: conhost dropped from kill list, drill-upgrade.ps1) |
| D11 | 3 | DEGRADED laundering + regex asymmetry: Inno treats `SETUP_COMPLETE_DEGRADED` as success substring; drill §1 anchors `^SETUP_COMPLETE$` (fails on DEGRADED) but §3 anchors `^SETUP_COMPLETE` (passes on DEGRADED) → failures move to flakier later checks | BasaPOS.iss:67, drill:78 vs 163 | FIXED (Phase A: ^SETUP_COMPLETE$ anchored in both drills) |
| D12 | 1 | Upgrade mysqladmin wait runs as default user frappe (no -u root) → Access denied → loop burns full 60s timeout every upgrade AND validates nothing | setup.ps1:321 | FIXED (Phase B: Wait-MariaDbReady runs mysqladmin -u root -p<rootpw>) |
| D13 | 1 | Fresh path has NO DB-ready wait before `bench set-admin-password` (upgrade path has one) → cold mariadb → throw → ERROR status | setup.ps1:125 | FIXED (Phase B: Wait-MariaDbReady before New-Credentials AND before backup) |
| D14 | 3 | .wslconfig idle-disable written AFTER first boot (and possibly into wrong INI section) → never applied → VM idles ~60s between phases → cold boots + the exact wedged-VM hangs the comments blame | setup.ps1:94-109,325-329 | FIXED (Phase C: section-aware .wslconfig written before first boot + fresh-path keep-alive) |
| D15 | 2 | Restore's internal health window (6×5s=30s) < gunicorn --preload cold start on 2 vCPU → "site confirmed online" never logged → drill's restore check fails on healthy site | setup.ps1:226-231 | FIXED (Phase C: restore health window 6x5s -> 18x10s + curl -m 20) |

## Tier 2 — Flaky / conditional

| ID | Conv | Mechanism | Locations | Status |
|----|------|-----------|-----------|--------|
| D16 | 2 | Disk: 12GB gate measured after 2.1GB payload landed (coin flip at ~11.9GB free); failed unregister (120s cap, WARN-only) leaves vhdx#1 + import#2 → C: exhaustion mid-import; WSL swap.vhdx on C: | setup.ps1:73,310-315 | FIXED (Phase C: unregister hard-gates on failure/timeout; DistroDir cleaned before re-import) |
| D17 | 3 | `\\wsl$` copies single-shot, no retry, no validation: backup copy-out unverified before distro destroyed; cert copy swallow-then-fail-later (R9-3 chain) | setup.ps1:136, common.ps1:104 | FIXED (Phase C: \\wsl$ copies retried + verified; backup verified before unregister; wsl.localhost fallback) |
| D18 | 1 | Drill path never proves WSL is systemd-capable (wsl --status exit 0 for inbox WSL; pinned MSI dead weight) — WIN-004's CI twin | common.ps1:28, setup.ps1:295 | FIXED (Phase C: drill asserts WSL PID1 == systemd, bounded) |
| D19 | 1 | Defender real-time scans every GB-scale I/O (2GB tar ×2 extracts, 6-8GB vhdx ×2) — the multiplier turning D1's arithmetic from tight to impossible | runner default | FIXED (Phase C: Add-CiDefenderExclusions in drill-install; non-fatal if Defender disabled) |
| D20 | 1 | Runner images intermittently carry RebootPending keys → every install takes NEEDS_REBOOT exit → resume task can never fire (no logon) → phase-1 all red | common.ps1:22-26 | FIXED (Phase C: setup.ps1 skips the NEEDS_REBOOT diversion under CI - GitHub sets CI=true) |
| D21 | 1 | boot-wrapper service-restart fires at t=60s of an 8-min window (deadline-7 math) — restarts gunicorn mid-cold-start | boot-wrapper.ps1:86 | FIXED (Phase C: boot-wrapper restarts services at 4 min, not 60s) |
| D22 | 2 | `$p.ExitCode` read after force-kill without reaping → InvalidOperationException → trap-die (masks real cause) | drill:75,155 | FIXED (Phase A: WaitForExit() reap after kill, both drills) |
| D23 | 1 | Copy-CiLogs called only AFTER uninstall deleted {app}\logs → zero logs on every failing run; uninstaller launched without /LOG= → §4 failures black-box | drill:209,197 | FIXED (Phase A: Copy-CiLogs pre-§4 + /LOG= + ci.yml upload path) |
| D24 | 1 | No `bench migrate` post-restore (win-field issue; drill masks it by same-version restore) — = catalog WIN-006 | setup.ps1 restore script | FIXED (Phase C: bench migrate added post-restore; aborts on failure) |
| D25 | 1 | If restore silently fails (D9), admin password never re-synced (skipped on upgrade path) → silent lockout on real machines | setup.ps1:307-326 | FIXED (Phase C: New-Credentials re-run after restore - set-admin-password re-sync) |

## Cleared — verified non-issues (stop chasing these)

```
✓ login page DOES emit <link href=...css>  — verified from shipped image
  (login.html:88 include_style → jinja_globals.py:144)
✓ bench PATH under `bash -c`/`su frappe`   — /usr/local/bin/bench ✓
✓ here-string $/backtick escaping           — audit clean, LF write survives
✓ curl.exe resolution on runners            — System32 (schannel) wins PATH;
                                            Git curl not on PATH
✓ cert without EKU                          — valid any-purpose (schannel OK)
✓ PEM over \\wsl$                           — binary-safe copy, LF intact
✓ Import-Certificate PEM/5.1/PKI module     — present and working
✓ backup file naming vs restore globs       — match (v16 verified)
✓ status-file encoding/BOM, dot-sourcing    — clean
✓ mdev mariadb init race                    — datadir baked at build
```

## Restructure (2026-08-29)

```
BEFORE: install-drill.ps1 (4 phases, monolith)      AFTER: 3 scripts = 3 CI steps
        + install-drill-minimal.ps1 (drifted copy)          + drill-common.ps1 (shared)

  step 1: drill-install.ps1    install + boot-wrapper   fails -> job red HERE, rest skipped
  step 2: drill-upgrade.ps1    backup/restore cycle     fails -> job red HERE, uninstall skipped
  step 3: drill-uninstall.ps1  removal checks           fails -> job red HERE

Why: state must share one runner (upgrade needs the installed distro), but
attribution, fail-fast, and per-step logs needed boundaries. The 60-min job
timeout became a safety net instead of a structural requirement.
Folded into the moved code: conhost kill removed (D10), uninstaller wait
bounded (part of D2), native-EAP guard (part of D8), all curls -m bounded.
install-drill-minimal.ps1 retired (drill-debug now runs drill-install.ps1).
```

## Recommended fix order

```
PHASE A (one-liners, unblock diagnosis) — DONE 2026-08-29
  D5  --ssl-no-revoke on the 3 no-k curls        (makes TLS checks passable)
  D6  -o NUL in minimal drill                     (unbreaks drill-debug)
  D1  timeout-minutes: 25 → 60                    (stop the guaranteed kill)
  D11 anchor ^SETUP_COMPLETE$ in §3               (stop DEGRADED laundering)
  D22 reap killed processes before ExitCode read
  D23 Copy-CiLogs before §4 + /LOG= on uninstaller

PHASE B (plumbing honesty) — DONE 2026-08-29
  D9  fix exit propagation (rc=$? capture, exit $rc)
  D12 mysqladmin -u root -p<pw>
  D7  import cert unconditionally (self-guarded on cert existence)
  D3  drill gates on setup-status terminal state, not Setup.exe exit;
      PID-file to detect/kill orphaned setup.ps1 before §3
  D10 drop conhost from kill list
  D13 add DB-ready wait on fresh path

PHASE C (robustness) — DONE 2026-08-29
  D2  --max-time/--connect-timeout on ALL curls; Start-Process+WaitForExit
      caps on wsl.exe/unins invocations
  D4  SuppressibleMsgBox in .iss
  D14 write .wslconfig BEFORE first wsl boot (+ correct sections)
  D15 widen restore health window to ~2-5 min
  D16 gate unregister failure hard; clean DistroDir before re-import
  D17 retry + verify \\wsl$ copies (and backup before unregister)
  D8  $PSNativeCommandUseErrorActionPreference=$false at drill tops;
      run minimal drill under pwsh
  D18 assert PID1=systemd in drill §1
```

## Failure-mode classification (what "doesn't run to completion" is made of)

```
JOB-TIMEOUT KILL   D1 (always, eventually) + D2/D4 hangs feeding it
TRAP-DIE           D8 (pwsh7 stderr flip; 5.1 schtasks redirect) + D22
HANG               D2 unbounded curl/wsl/unins; D4 modal MsgBox
COMPLETES-RED      D5/D6/D7/D11/D15 deterministic check failures
```
