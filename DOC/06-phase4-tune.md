# Phase 4 — Tune (make it feel like a product)

_Written: 2026-07-22 · Target: Raspberry Pi 3 / 4 · Base: DietPi arm64 (Bookworm)_

Phase 3 gave you a Pi that powers on straight into the X16 and relaunches on exit.
Phase 4 is polish: lock the display to a clean 60 Hz, make the boot silent so the
X16 is the **only** thing ever on screen, cut boot time, and map a gamepad. None
of this is required to *function* — it's what separates "it works" from "it feels
like an appliance."

**Prerequisite gate:** Phase 3 complete — cold boot lands on the fullscreen X16
with no shell, keyboard + audio working, relaunch loop confirmed.

Repo artifacts used:
- `config/config.txt.snippet` — HDMI mode + full-KMS (already applied in Phase 1)
- `config/cmdline.txt.snippet` — **new** quiet-boot kernel params
- `scripts/custom.sh` — appliance loop (gets the gamepad env, if any)

Each item below is independent — do them in any order, re-checking the Phase 3
gate after each so you can attribute any regression to one change.

---

## 4.1 Lock the exact HDMI 60 Hz mode

The point of Option A is that VERA's 60 Hz output maps 1:1 to the display with no
resampling. Phase 1 already forced `hdmi_group=1` / `hdmi_mode=16` (1080p60). Now
**verify** it took and that the panel is genuinely at 60 Hz.

At the Pi (SSH or VT2 — see Phase 3 "breaking in"):
```bash
# What KMS actually selected for the connected HDMI output:
for s in /sys/class/drm/card*-HDMI-A-*/modes; do echo "== $s =="; cat "$s"; done
# Top line is the active mode, e.g. 1920x1080. Confirm it's the one you forced.

# Refresh/timing detail (Bookworm KMS):
modetest -c 2>/dev/null | grep -A2 -i connected   # needs libdrm-tests; optional
```

- **1080p60 too heavy on a Pi 3 for a VERA-busy scene?** Drop to 720p60: set
  `hdmi_mode=4` in `config.txt`. Still 60 Hz, less to scan out.
- **Panel negotiated something odd / black screen?** `hdmi_force_hotplug=1` is
  already set; if EDID is the problem, the forced group/mode is the fix — confirm
  no stray `video=` token in `cmdline.txt` is overriding it.

**Gate:** the active HDMI mode is the one you forced, at **60 Hz**, and the X16
image fills the screen with no letterbox/overscan (Phase 1 set `disable_overscan=1`).

### Vsync smoothness (subjective but important)
Load something that scrolls (a demo or a BASIC screen-scroll loop) and eyeball for
**tearing** and **judder**. SDL2's KMSDRM backend page-flips on vblank by default,
so a correct 60 Hz mode should scroll clean. Tearing usually means a wrong/again
mismatched mode; judder means the frame rate isn't a clean 60. This is the one
thing no VM or Docker test could show you — it's why Phase 4 needs the real Pi.

---

## 4.2 Silent boot — only the X16, ever

Two sources of on-screen noise before the emulator paints: the firmware **rainbow
splash** and the **kernel/console boot text + cursor**.

1. **Rainbow splash** — `config.txt` already has `disable_splash=1` (Phase 1).
   Confirm it's present.
2. **Kernel log + cursor + console blanking** — append the tokens from
   `config/cmdline.txt.snippet` to the single line in `/boot/cmdline.txt`
   (or `/boot/firmware/cmdline.txt`): `quiet loglevel=0 logo.nologo
   vt.global_cursor_default=0 consoleblank=0 plymouth.enable=0`. Keep
   `console=tty1` — KMSDRM needs the console tty to become DRM master.
3. **DietPi's own boot banner** — `custom.sh` already `clear`s the screen and
   hides the cursor right before the loop, covering the last flash.

**Gate:** from power-on you see (at most) a brief black screen, then the X16
`READY.` — no rainbow, no scrolling log, no login text, no cursor.

> Trade-off: a silent boot hides errors too. If the appliance ever won't come up,
> temporarily remove `quiet`/`loglevel=0` (or SSH in and read
> `/var/log/x16-appliance.log`) to see what failed.

---

## 4.3 Trim boot time

DietPi Lite is already lean; the wins here are disabling services the appliance
never uses so the X16 appears sooner.

```bash
# See what's slow / running:
systemd-analyze blame | head -20
systemctl list-units --type=service --state=running

# Common safe disables for a headless kiosk (skip any you actually rely on):
sudo systemctl disable --now dphys-swapfile 2>/dev/null   # DietPi already sets swap=0
sudo systemctl disable --now bluetooth 2>/dev/null        # unless you use a BT pad
sudo systemctl disable --now avahi-daemon 2>/dev/null     # mDNS not needed for kiosk
# Keep SSH (your service door) and networking if you fetch programs over the net.
```

- `boot_delay=0` is already in `config.txt`.
- Don't chase milliseconds by disabling networking/SSH — you'll want that door
  for updates (Phase 5 is easier with it).

**Gate:** measurably faster power-on-to-`READY.` with no lost function (keyboard,
audio, `-fsroot`, relaunch all still pass the Phase 3 gate).

---

## 4.4 Map a USB gamepad to the X16 joystick

SDL2 auto-detects USB game controllers; `x16emu` maps a detected controller to the
X16's joystick with no extra config for common pads. Plug one in and test in a
program that reads the joystick.

- **Pad not recognized / wrong buttons?** `x16emu` accepts controller options —
  check `x16emu --help` for the current joystick/gamepad flags on r49 and add them
  to the launch line in **both** `scripts/run-x16.sh` (manual) and
  `scripts/custom.sh` (appliance) so manual and autostart behave identically.
- SDL uses its built-in controller DB; a very obscure pad may need an
  `SDL_GAMECONTROLLERCONFIG` mapping exported in `custom.sh` before the loop.

**Gate:** the gamepad drives the X16 joystick in a test program; the mapping is
reflected in `custom.sh` so it survives a reboot.

---

## 4.5 Confirm the `-fsroot` user-program workflow

This is how end users get their `.prg`/`.bas` files onto the machine, so make sure
it's frictionless before packaging.

- `custom.sh` / `run-x16.sh` point `-fsroot` at `/boot/x16`. `/boot` is the FAT
  partition, so it mounts on any PC when the SD card is inserted.
- Drop a `.prg` into that `x16/` folder from another PC, boot the Pi, and confirm
  `DIR` lists it and `LOAD"NAME"` + `RUN` works inside the X16.

**Gate:** a file dropped on the FAT partition from a PC is visible and loadable in
the X16 with no in-emulator setup.

---

## Exit criteria (Phase 4 complete)
- HDMI locked to the intended mode at 60 Hz; scrolling is tear-free.
- Boot is visually silent — the X16 is the only thing that ever appears.
- Unused services trimmed; boot is faster with no regression.
- Gamepad (if used) mapped and persisted in `custom.sh`.
- `-fsroot` drop-a-file workflow confirmed end to end.

## Next (Phase 5 preview)
Protect the SD card from power-cut corruption (`log2ram` or a read-only overlay),
then capture the tuned system as a shrunk, distributable `.img` (`dd` + PiShrink)
and write the end-user README for adding programs. See `07-phase5-harden-package.md`.

## Troubleshooting
| Symptom | Likely cause / fix |
|---|---|
| Wrong resolution / black screen | Forced mode not applied — recheck `hdmi_group`/`hdmi_mode` in `config.txt`; ensure no `video=` in `cmdline.txt` overrides it. |
| Tearing while scrolling | Mode/refresh mismatch — confirm active mode is exactly 60 Hz; try `hdmi_mode=4` (720p60) on a Pi 3. |
| Rainbow splash still shows | `disable_splash=1` missing from `config.txt`. |
| Boot text / cursor still flashes | `cmdline.txt` tokens not on the single line, or `custom.sh`'s `clear`/cursor-hide not running (check it's the deployed copy). |
| Appliance won't boot after "quiet" | Temporarily drop `quiet`/`loglevel=0` to see the error, or SSH in and read `/var/log/x16-appliance.log`. |
| Gamepad ignored | Confirm SDL sees it (`SDL_VIDEODRIVER` unrelated); add the r49 joystick flag to both `run-x16.sh` and `custom.sh`. |
