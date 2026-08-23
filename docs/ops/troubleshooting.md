# Troubleshooting

| Symptom | Where to look | Fix |
|---|---|---|
| Launcher says Appliance missing | %LOCALAPPDATA%\Programs\BasaPOS\data\distro missing ext4.vhdx | Press Repair |
| Stuck on Starting... | logs\autostart.log, appliance-status.txt | ERROR_HEALTH after boot attempts: reboot PC once; if persistent run verify.ps1 |
| Site unreachable from terminal | server firewall / hosts entry on terminal | see lan-mode.md |
| Forgot admin password | config\credentials.txt (Password button in launcher) | shown in app |
| Backup failed | run scripts\verify.ps1 output | disk full is most common; free space on C: |
Logs live in %LOCALAPPDATA%\Programs\BasaPOS\logs\.
