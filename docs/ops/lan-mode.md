# LAN mode (terminals connecting over the shop network)

On the server PC, edit `%LOCALAPPDATA%\Programs\BasaPOS\app\settings.txt`:
    LAN_MODE=true
Restart the PC (or re-run Repair in the launcher).
Windows Firewall prompt: allow on Private networks only.
On each terminal: add `<server-ip> basapos.local` to
`C:\Windows\System32\drivers\etc\hosts` (needs admin), then browse
https://basapos.local and accept the certificate warning once.
