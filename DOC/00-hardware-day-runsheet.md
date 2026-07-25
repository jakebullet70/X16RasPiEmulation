# Hardware Day — One-Page Run-Sheet

_Pi 3/4 · DietPi arm64 Bookworm · x16emu **r49** · print this, keep the full docs open for troubleshooting_

**Have ready:** Pi 3/4 · SD card + PC reader · HDMI display · USB keyboard ·
Ethernet cable (or Wi-Fi creds) · the image `DietPi_RPi234-ARMv8-Bookworm.img.xz`
(in repo root) · this repo's `config/` + `scripts/`.

**Golden rules:** ✋ Don't pass a gate that's red — fix it first. 🖥️ Run the
emulator at the **physical console (tty on HDMI), never over SSH** — KMSDRM must be
DRM master. 🔁 Emulator + ROM are **version-locked at r49**.

---

## ☐ Phase 1 — Bring-up
1. Flash `DietPi_RPi234-ARMv8-Bookworm.img.xz` (Pi Imager / Etcher — flashes `.xz` directly).
2. Card still in PC, edit the boot (FAT) partition:
   - Merge `config/dietpi.txt.snippet` → `dietpi.txt` (keep `AUTO_SETUP_AUTOSTART_TARGET_INDEX=7`).
   - Append `config/config.txt.snippet` → `config.txt`.
   - Append `config/cmdline.txt.snippet` tokens → the **single line** of `cmdline.txt` (keep `console=tty1`).
   - Wi-Fi only: fill `dietpi-wifi.txt`, set `AUTO_SETUP_NET_WIFI_ENABLED=1` in
     `dietpi.txt`, **and delete the `dtoverlay=disable-wifi` line you just pasted
     from `config.txt.snippet`** — it switches the radio off in the device tree,
     so `wlan0` never appears and the credentials are silently ignored.
   - _(path is `/boot/…` or `/boot/firmware/…` depending on image — use whichever exists.)_
3. Insert card, connect HDMI+keyboard+Ethernet, power on. First-boot install runs (may reboot) → console autologin.
```bash
ls -l /dev/dri/          # expect card0/card1 + renderD128
dmesg | grep -i vc4      # vc4/drm messages, no fallback-to-fbdev
```
> ### 🚩 GATE 1: `/dev/dri/card*` exists AND vc4 KMS loaded.  ✋ If not → check `dtoverlay=vc4-kms-v3d` in config.txt, reboot.

## ☐ Phase 2 — Emulator runs
```bash
# copy scripts to the Pi (scp/git/USB), then:
chmod +x ~/scripts/*.sh
~/scripts/install-x16.sh          # SDL2 + x16emu r49 + rom.bin -> /opt/x16, makes /boot/firmware/x16
#   fallback if binary won't run:  ~/scripts/build-x16-from-source.sh
```
**At the physical console, NOT SSH:**
```bash
~/scripts/run-x16.sh              # -> fullscreen X16 "READY."
```
Check: video fullscreen 60 Hz no tearing · keyboard types · audio out HDMI
(`aplay -l` → `/etc/asound.conf` if silent) · drop a `.prg` on `/boot/firmware/x16` → `DIR`/`LOAD` sees it.
> ### 🚩 GATE 2: X16 boots to READY. fullscreen from console; keyboard + audio work; `/boot/firmware/x16` file loads.

## ☐ Phase 3 — Appliance (power-on → X16, no shell)
```bash
sudo install -m 0755 ~/scripts/custom.sh /var/lib/dietpi/dietpi-autostart/custom.sh
sudo /var/lib/dietpi/dietpi-autostart/custom.sh   # test loop at console; relaunch-on-exit = correct
sudo sed -i 's/^AUTO_SETUP_AUTOSTART_TARGET_INDEX=.*/AUTO_SETUP_AUTOSTART_TARGET_INDEX=17/' /boot/dietpi.txt
#   (or: sudo dietpi-autostart -> 17 Custom script, no autologin)
sudo reboot
```
**Break-in (keep handy):** SSH · or `Ctrl+Alt+F2` for a fresh VT · stop loop: `sudo pkill -f custom.sh` then `pkill -f x16emu`.
**Rollback:** set index back to `7`, reboot. Log: `/var/log/x16-appliance.log`.
> ### 🚩 GATE 3: Cold boot → fullscreen X16, no shell/login; keyboard+audio; exit/crash relaunches; SSH/VT2 still work.

## ☐ Phase 4 — Tune
- **HDMI:** `cat /sys/class/drm/card*-HDMI-A-*/modes` → confirm forced mode @60 Hz; load a scroller, check no tearing. (Pi 3 heavy? `hdmi_mode=4` = 720p60.)
- **Silent boot:** confirm `disable_splash=1` (config.txt) + cmdline tokens applied → only the X16 ever on screen.
- **Trim:** `systemd-analyze blame | head`; disable unused (`bluetooth`, `avahi-daemon`) — **keep SSH + networking**.
- **Gamepad:** plug USB pad, test joystick; add r49 joystick flag to **both** `run-x16.sh` and `custom.sh`.
> ### 🚩 GATE 4: 60 Hz locked + tear-free · boot visually silent · faster, no regression · gamepad persisted.

## ☐ Phase 5 — Harden & package (the deliverable)
- **Harden (pick one):** `log2ram` via `dietpi-software` (writable) **or** read-only overlay via `dietpi-config` (sealed). Then pull power mid-session a few times → still boots clean.
- **Image (on Linux / WSL Ubuntu / Pi+reader):**
```bash
lsblk -o NAME,SIZE,MODEL,TRAN                     # find whole card /dev/sdX (NOT a partition!)
sudo dd if=/dev/sdX of=x16-appliance-r49.img bs=4M status=progress conv=fsync && sync
wget https://raw.githubusercontent.com/Drewsif/PiShrink/master/pishrink.sh && chmod +x pishrink.sh
sudo ./pishrink.sh -z x16-appliance-r49.img       # -> x16-appliance-r49.img.gz (auto-expands on first boot)
```
- **Verify:** flash the `.img.gz` to a **blank** card, boot a second Pi → re-pass Gate 3. Ship with the end-user README (doc 07 Part C).
> ### 🚩 GATE 5: hardened + power-cut-survives · shrunk auto-expanding `.img.gz` boots a blank card through Gate 3.

---
**Full detail / troubleshooting tables:** `03` (P1-2) · `05` (P3) · `06` (P4) · `07` (P5). **x86 pre-test:** `04`.
