> **STATUS: SUPERSEDED (2026-08-31)** — Describes the removed v2 installer.
> Current design: `docs/superpowers/specs/2026-08-31-wsl-docker-parity-installer-design.md`
> Windows ops now live in: `docs/ops/windows-tech-runbook.md` (created by the v3 plan)

# Updating a shop machine (USB workflow)

1. On any online machine: download `BasaPOS-Setup-x.y.z.exe` + `SHA256SUMS`
   from the release page. Verify the hash.
2. Copy the Setup exe to a USB stick.
3. At the shop: close BasaPOS (the appliance keeps running), run the new Setup.
4. The installer detects the existing install and automatically:
   backs up data -> swaps the appliance -> restores data. Do NOT uninstall first.
5. When finished, open https://basapos.local and check the till works.
Time: ~10 minutes. No internet needed at the shop.
