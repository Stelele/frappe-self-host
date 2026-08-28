# Troubleshooting

| Symptom | Where to look | Fix |
|---|---|---|
| Launcher says Appliance missing | %LOCALAPPDATA%\Programs\BasaPOS\data\distro missing ext4.vhdx | Press Repair |
| Stuck on Starting... | logs\autostart.log, appliance-status.txt | ERROR_HEALTH after boot attempts: reboot PC once; if persistent run verify.ps1 |
| Site unreachable from terminal | server firewall / hosts entry on terminal | see lan-mode.md |
| Forgot admin password | config\credentials.txt (Password button in launcher) | shown in app |
| Backup failed | run scripts\verify.ps1 output | disk full is most common; free space on C: |
| Browser says Not secure | cert missing from Windows trust store | re-run Repair in the launcher (re-imports the appliance cert); Firefox uses its own store — click through once or import config\tls\basapos.crt manually |
Logs live in %LOCALAPPDATA%\Programs\BasaPOS\logs\.
The appliance cert is exported to config\tls\basapos.crt and trusted via
Cert:\LocalMachine\Root automatically at install and after upgrades.
