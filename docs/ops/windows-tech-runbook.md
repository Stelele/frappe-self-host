# BasaPOS on Windows — Tech Runbook

## Install (fresh machine)

1. BIOS: enable virtualization (VT-x/AMD-V).
2. AV exclusion for `C:\BasaPOS` and `BasaPOS-Setup.exe` (retail AV heuristic-trips on installers).
3. Copy `BasaPOS-Setup.exe` + the entire `payload/` folder to the same directory on the target.
4. Run `BasaPOS-Setup.exe` as admin → **Install**. First boot takes 5–15 min (image load + site creation).
5. A reboot may be requested once (WSL features) → reboot, run Setup again — it continues.
6. Done = password dialog. Site: https://basapos.local

## If install breaks

Uninstall → Install again. Every step is idempotent; nothing partial survives.
Unattended (tech CLI / CI): `BasaPOS-Setup.exe --install --unattended --payload <dir>` (exit 0 ok, 1 fatal, 3 not healthy, 4 reboot needed).

## Restore a backup after reinstall

```powershell
# 1. copy the backup into the distro (native fs — restoring off /mnt/c breaks)
wsl -d BasaPOS -- mkdir -p /opt/restore
cmd /c "wsl -d BasaPOS -- tar -C /mnt/c/BasaPOS/backups/<TS> -cf - ." | wsl -d BasaPOS -- tar -C /opt/restore -xf -
# 2. restore (substitute the actual file names + a NEW admin password)
wsl -d BasaPOS -- docker compose --env-file /opt/basapos/compose/.env -f /opt/basapos/compose/compose.final.yaml run --rm --no-deps backend bench --site basapos.local restore --with-files --admin-password <NEWPW> /opt/restore/<site>-database.sql.gz
```

## Manual backup / password reset

```powershell
wsl -d BasaPOS -u root -- systemctl start basapos-backup.service
wsl -d BasaPOS -- docker compose --env-file /opt/basapos/compose/.env -f /opt/basapos/compose/compose.final.yaml run --rm --no-deps backend bench --site basapos.local set-admin-password <NEWPW>
```

## Logs

- Installer: `%TEMP%\basapos-setup.log`, `C:\BasaPOS\logs\`
- Firstboot: `C:\BasaPOS\logs\firstboot.log` and in distro `/var/log/basapos-firstboot.log`
- In distro: `journalctl -u basapos-firstboot`

## Known behavior

- Sleep/resume may wedge localhost forwarding once; a reboot heals it (documented platform behavior).
- Daily backup lands in `C:\BasaPOS\backups\` at 02:00 (keeps last 7).
- Uninstall keeps `C:\BasaPOS\backups\` on purpose.
