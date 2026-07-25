# Phases 1 & 2 — Hardware Runbook

_Written: 2026-07-22 · Target: Raspberry Pi 3 / 4 · Base: DietPi arm64 (Bookworm)_

This runbook executes **Phase 1 (bring-up)** and **Phase 2 (emulator runs)** from
the Option A plan. It requires the physical Pi, an SD card, an HDMI display, and
a USB keyboard — those steps can't be done from the dev machine, so everything
here is copy-paste ready for the Pi.

Version pinned in this pass: **x16-emulator r49 ("Pyrite")** with the matching
**x16-rom r49**. Both are locked together via the `X16_VER` variable in the
install scripts; bump it in one place to update.

Repo artifacts used:
- `config/dietpi.txt.snippet` — first-boot automation
- `config/config.txt.snippet` — full-KMS + forced 60 Hz HDMI
- `scripts/install-x16.sh` — prebuilt aarch64 install (primary)
- `scripts/build-x16-from-source.sh` — compile fallback
- `scripts/run-x16.sh` — manual fullscreen launch

---

## Phase 1 — Bring-up

### 1.1 Flash DietPi (64-bit)
1. Download the **DietPi image for Raspberry Pi (ARMv8 / 64-bit)** from
   <https://dietpi.com/#download>. 64-bit matters: the prebuilt emulator is
   aarch64 and needs glibc ≥ 2.35 (DietPi Bookworm ships 2.36).
2. Flash it to the SD card (Raspberry Pi Imager, balenaEtcher, or `dd`).

### 1.2 Pre-configure on the SD card (before first boot)
With the card still in your PC, edit the boot partition:
1. Merge the keys from `config/dietpi.txt.snippet` into `/boot/dietpi.txt`.
   Keep `AUTO_SETUP_AUTOSTART_TARGET_INDEX=7` (console autologin) for now.
2. Append the lines from `config/config.txt.snippet` to `/boot/config.txt`
   (or `/boot/firmware/config.txt` if that's what your image uses).
3. Wi-Fi only: fill in `/boot/dietpi-wifi.txt`.

### 1.3 First boot
1. Insert the card, connect HDMI + keyboard + Ethernet, power on.
2. DietPi runs its unattended first-boot install (a few minutes, it may reboot).
3. You should land at a **console autologin** on the HDMI display.

### 1.4 Confirm KMS + console (the Phase 1 gate)
From the Pi console (or SSH in):
```bash
# Full-KMS DRM device present?
ls -l /dev/dri/          # expect card0/card1 + renderD128
# Which KMS driver is bound?
sudo cat /sys/class/drm/card*/device/driver/module/drivers/* 2>/dev/null
dmesg | grep -i vc4       # expect vc4 / drm messages, no fallback-to-fbdev errors
```
**Gate:** `/dev/dri/card*` exists and vc4 KMS is loaded. If not, re-check
`dtoverlay=vc4-kms-v3d` in config.txt and reboot.

---

## Phase 2 — Emulator runs

### 2.1 Get the scripts onto the Pi
Copy this repo's `scripts/` folder to the Pi (e.g. `scp -r scripts pi-user@<ip>:~/`
or `git clone`), then:
```bash
chmod +x ~/scripts/*.sh
```

### 2.2 Install x16emu + matching ROM (primary path)
```bash
~/scripts/install-x16.sh
```
This installs SDL2, downloads the prebuilt `x16emu_linux-aarch64-r49.zip` to
`/opt/x16`, ensures a matching `rom.bin` is present (auto-fetching the r49 ROM if
the emulator zip didn't bundle it), creates `/boot/firmware/x16` for user programs, and
symlinks `x16emu` into `PATH`.

> Fallback: if the prebuilt binary won't run (wrong arch / old glibc), use
> `~/scripts/build-x16-from-source.sh` instead — same result, compiled locally.

### 2.3 Launch fullscreen (the Phase 2 gate)
**Do this at the physical console (tty on the HDMI screen), _not_ over SSH** —
the KMSDRM backend must become DRM master, which an SSH session can't do.
```bash
~/scripts/run-x16.sh
```
Expected: the display switches to fullscreen and the **X16 BASIC "READY."**
prompt appears; the USB keyboard types into it.

Quick checks:
- **Video:** fullscreen, correct 60 Hz mode, no tearing/letterbox surprises.
- **Keyboard:** typing works; `Ctrl` combos and cursor keys respond.
- **Audio:** run something that beeps, or in BASIC nudge the PSG; sound should
  come out the HDMI display's speakers. If silent, set HDMI as the default ALSA
  device (`aplay -l` to find the card; set it in `/etc/asound.conf`).
- **Loading programs:** drop a `.prg` onto the `/boot` partition's `x16/` folder
  from any PC; inside the X16 it's visible via the `-fsroot` mount (`LOAD`/`DIR`).

**Gate:** X16 boots to READY. fullscreen from the console, keyboard + audio work,
and a file placed in `/boot/firmware/x16` is reachable from within the emulator.

---

## Exit criteria (Phases 1 & 2 complete)
- 64-bit DietPi boots to a console with working full-KMS video.
- `x16emu r49` + matching ROM installed at `/opt/x16`.
- `run-x16.sh` brings up the X16 fullscreen with working keyboard, audio, and
  `-fsroot` file loading.

## Next (Phase 3 preview)
Wire `run-x16.sh`'s command into DietPi's custom autostart
(`/var/lib/dietpi/dietpi-autostart/custom.sh`) inside a relaunch loop, and flip
`AUTO_SETUP_AUTOSTART_TARGET_INDEX=17`, so power-on drops straight into the X16
with no shell. See `02-option-a-plan.md`.

## Troubleshooting
| Symptom | Likely cause / fix |
|---|---|
| `x16emu: cannot open /dev/dri...` over SSH | Expected — run at the physical tty, not SSH. |
| Black screen / no signal | Force `hdmi_group`/`hdmi_mode` in config.txt; set `hdmi_force_hotplug=1`. |
| `error while loading shared libraries: libSDL2` | `sudo apt-get install -y libsdl2-2.0-0`. |
| Binary won't run / `GLIBC_2.35 not found` | Image is too old / 32-bit → use `build-x16-from-source.sh`. |
| `rom.bin` missing at launch | Re-run installer; or manually place matching r49 `rom.bin` in `/opt/x16`. |
| No sound | Set HDMI as default ALSA card (`aplay -l` → `/etc/asound.conf`). |
