# Commander X16 — Raspberry Pi 4

Flash `x16-appliance-r49.img.gz` with Raspberry Pi Imager (*Use custom image*, and
decline the customisation prompt). Any card 4 GB or larger. The first boot expands
the card and takes an extra minute; after that it goes straight to the X16.

**Your programs.** Put the card in a PC and a drive named **X16PI** appears. Copy
`.PRG` files into its `x16` folder. On the X16: `@CD:FAT-FILES`, then `@$` to list,
`LOAD"NAME.PRG",8`, `RUN`.

**Wi-Fi** is optional — Ethernet works out of the box. Edit `x16-wifi.conf` on that
same drive and fill in `X16_WIFI_SSID`, `X16_WIFI_PSK`, `X16_WIFI_COUNTRY`. The Pi
restarts once, connects, then blanks the password from the file — that means it
worked. `x16-wifi-status.txt` says what happened.

Full guide: `README-end-user.md`.
