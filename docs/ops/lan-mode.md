# LAN mode (terminals connecting over the shop network)

On the server PC, edit `%LOCALAPPDATA%\Programs\BasaPOS\app\settings.txt`:
    LAN_MODE=true
Restart the PC (or re-run Repair in the launcher).
Windows Firewall prompt: allow on Private networks only.
On each terminal: add `<server-ip> basapos.local` to
`C:\Windows\System32\drivers\etc\hosts` (needs admin), then browse
https://basapos.local.

The server PC itself trusts the appliance certificate automatically
(imported at install). Terminals do NOT have it in their store: either
accept the certificate warning once per terminal, or copy
`%LOCALAPPDATA%\Programs\BasaPOS\config\tls\basapos.crt` to the terminal
and import it into `Local Machine \ Trusted Root Certification Authorities`
(certmgr.msc).
