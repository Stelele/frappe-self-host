# Unified CI Pipeline

```
Date:     2026-08-28
Status:   Approved (design approved in session; spec = implementation contract)
Replaces: appliance.yml · windows-release.yml · installer-lint.yml · deploy.yml · drill-debug.yml
```

## 1 · Why

```
BEFORE (5 files)                          AFTER (1 file)
┌─────────────────────┐                   ┌─────────────────────┐
│ appliance.yml       │─┐                 │                     │
│ windows-release.yml │ ├─ cross-trigger  │  ci.yml             │
│ installer-lint.yml  │ │  duplicates:    │   tiered by event   │
│ deploy.yml          │ │  same rootfs    │   parallel tracks   │
│ drill-debug.yml     │─┘  built twice    │                     │
└─────────────────────┘                   └─────────────────────┘
```

Problems: appliance.yml built standalone AND as a reusable child of
windows-release.yml → duplicate 45-min builds; lint overlapped release
triggers; `paths:` filters were the root cause of run duplication;
deploy.yml "deployed" to an ephemeral runner.

## 2 · Job Graph

```
            pull_request · push(main/master + tags v*) · workflow_dispatch

            ┌────────────────────────────────────────────────────────┐
            │ lint  (ubuntu · pwsh-parse every .ps1)     [all tiers] │
            └───────┬───────────────────────────────┬────────────────┘
                    ▼                               ▼
         ┌──────────────────┐             ┌──────────────────┐
         │ linux-image      │             │ rootfs           │
         │ frappe_docker    │             │ docker build +   │
         │ build → artifact │             │ cache + validate │
         │ [full tier]      │             │ → artifact       │
         └──────────────────┘             └────────┬─────────┘
                                                   ▼
                                        ┌──────────────────┐
                                        │ e2e-boot (win)   │ [all tiers]
                                        └──────────────────┘
                                                   ▼
                                        ┌──────────────────┐
                                        │ installer (win)  │ [full tier]
                                        └───────┬──────────┘
                                                ▼
                                        ┌──────────────────┐
                                        │ install-drill    │ [full tier]
                                        └──────────────────┘
                                                ▼ tags only
                                        ┌──────────────────┐
                                        │ release          │ [tag only]
                                        └──────────────────┘

         drill-debug (win · dispatch-only)   re-drills a prior run's Setup.exe
```

## 3 · Tier Matrix

| Job | PR | push main | tag v* | dispatch (no input) | dispatch (run_id) |
|---|---|---|---|---|---|
| lint | ✓ | ✓ | ✓ | ✓ | – |
| rootfs | ✓ (cache-hit fast) | ✓ | ✓ | ✓ | – |
| e2e-boot | ✓ | ✓ | ✓ | ✓ | – |
| linux-image | – | ✓ | ✓ | ✓ | – |
| installer | – | ✓ | ✓ | ✓ | – |
| install-drill | – | ✓ | ✓ | ✓ | – |
| release | – | – | ✓ | – | – |
| drill-debug | – | – | – | – | ✓ |

Gate expressions (tag pushes ARE `event_name == 'push'`):

```
base tier  (lint, rootfs, e2e-boot):   if: !github.event.inputs.run_id
full tier  (linux-image, installer,
            install-drill):            if: !github.event.inputs.run_id
                                       && github.event_name != 'pull_request'
release:                               if: startsWith(github.ref, 'refs/tags/v')
drill-debug:                           if: github.event_name == 'workflow_dispatch'
                                          && github.event.inputs.run_id
```

Dispatch-with-`run_id` skips everything except drill-debug (needs-chain
skips the tiers; drill-debug has no `needs`).

## 4 · Carried Over Unchanged

| Thing | Source |
|---|---|
| rootfs cache key `rootfs-${{ hashFiles('appliance/**','apps.json') }}` | appliance.yml (same key keeps hitting existing cache) |
| build→smoke→stamp→export→validate flow + checksum report | appliance.yml |
| Pinned WSL MSI 2.7.11 download | windows-release.yml |
| installer assembly (`package/build.ps1` + ISCC discovery) | windows-release.yml |
| e2e-import-boot / install-drill invocation + log artifacts on failure | windows-release.yml |
| pwsh `[scriptblock]::Create` parse loop | installer-lint.yml |
| frappe_docker image build args/secrets (submodules checkout) | deploy.yml build job |
| Per-job timeouts | various |
| `gh release create` on tags with SHA256SUMS | windows-release.yml |

## 5 · Deliberate Changes

| # | Change | Why |
|---|---|---|
| 1 | `concurrency: ci-${{ github.event_name }}-${{ github.ref }}` + `cancel-in-progress` | kill superseded duplicate runs; event-name in the key so a dispatch (drill-debug/manual) can never cancel an in-flight push/tag pipeline on the same ref |
| 2 | `paths:` filters removed entirely | tiers replace them; ends double-build problem |
| 3 | deploy.yml's `deploy` job dropped (build + artifact only) | deploying to an ephemeral runner is theater; secrets (DB_PASSWORD etc.) no longer referenced; deploy.yml never fired anyway (`branches: [main]` vs default `master`) |
| 4 | drill-debug queries `--workflow=ci` for prior artifacts | workflow renamed |
| 5 | Workflow-level `permissions: contents: read`; `contents: write` only on release job; `actions: read` on drill-debug | least privilege |
| 6 | `retention-days`: 14 for rootfs + docker image; **30 for BasaPOS-Setup** | no paths filters → artifacts on every push; drill-debug re-drills prior runs' Setup.exe and breaks silently past expiry, so it gets the longer window (with an explicit expiry error message) |
| 7 | linux-image: `cache-from/to: type=gha` + `CACHE_BUST=hashFiles('apps.json','frappe_docker/**')` instead of `github.sha` | sha-keyed bust made the build uncacheable on every push; content-hash keys preserve the bust-on-apps-change intent |
| 8 | Appliance logs copied to `$RUNNER_TEMP\basapos-logs` by drill scripts; upload-artifact globs point there | `%LOCALAPPDATA%` literals in upload paths were never expanded (pre-existing silent no-op — logs never uploaded) |

### Accepted trade-offs (post-review)

- **PR tier has no installer/drill coverage** (old windows-release ran the
  drill on `package/**` PRs). Accepted by owner: master-push full tier catches
  breakage minutes after merge; PRs stay cheap. Revisit if PR volume grows or
  an installer regression slips through.
- **Docs-only pushes to master run the full tier** (incl. linux-image —
  mitigated by the content-hash cache — and 2GB artifact uploads bounded by
  retention). Accepted for simplicity; revisit if runner/storage costs bite.

## 6 · Verification

```
LAYER              CHECK
──────────────────────────────────────────────────────────────
yaml validity      python yaml.safe_load (no actionlint offline)
tier logic         manual matrix walk-through against §3
graph sanity       needs-chain review (§2)
regression         first PR/push run on GitHub must show:
                    - exactly ONE rootfs build
                    - PR run stops after e2e-boot
                    - tag run publishes release
```
