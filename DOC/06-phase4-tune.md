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

1. **Rainbow splash** — originally hidden with `disable_splash=1` (Phase 1).
   **Reversed 2026-07-25: it is now `disable_splash=0`, i.e. the rainbow shows.**
   Once boot-to-X16 came down to ~6 s, the remaining complaint was the *black*
   period before anything appears. The firmware puts the rainbow up at ~1 s and
   supports no custom image there, so it is the only possible feedback that
   early; the branded splash paints over it at ~2.7 s. Set it back to `1` if you
   prefer black until the branded splash.
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

**Gate: PASSED 2026-07-25.** Power-on to X16 measured at **18 s** (was 20 s), with
keyboard, audio, gamepad, `-fsroot` and relaunch all intact.

Measure it like this — `systemd-analyze` is misleading here:

```bash
UP=$(cut -d. -f1 /proc/uptime); AGE=$(ps -o etimes= -p "$(pgrep -x x16emu)" | tr -d ' ')
echo "boot-to-X16: $((UP-AGE))s"
```

> **Ignore `systemd-analyze`'s headline number.** It reports ~1 min 32 s on this
> appliance, but nothing is actually waiting: `getty@tty1` (the X16's parent)
> starts at 8.3 s, no unit enters active late, and the journal is empty between
> 78 s and 96 s. The figure is an artifact of the clock jumping when
> `systemd-timesyncd` corrects the fake-hwclock mid-boot. Trust wall-clock
> power-on-to-picture, or the process age above.

Where the 18 s actually goes: ~8.3 s to `getty@tty1`, of which **4.7 s is
`ifup@eth0`** blocking `network.target` (which `systemd-user-sessions`, and hence
`getty`, is ordered after); then `custom.sh`'s KMS/HDMI wait; then the 3 s
`X16_SPLASH_SECONDS` hold. The remaining big lever is that `ifup` wait — a
drop-in dropping `After=network.target` from `systemd-user-sessions.service`
would reclaim most of it, at the cost of fighting the distro's ordering.

> **Superseded 2026-07-25 — this 18 s is not the current number.** That `ifup`
> lever was pulled, along with three others, taking power-on to `READY.` to
> **23 s** on the owner's stopwatch and the emulator's launch to **6.3 s** after
> kernel start. One correction that matters if you retrace this: a **drop-in
> cannot** remove the ordering — systemd registers the mirrored `Before=` edge
> on the other unit while parsing, and that survives. It needs a full unit
> override. All of it is in [`scripts/trim-boot.sh`](../scripts/trim-boot.sh)
> and the boot-time section of [`../TODO.md`](../TODO.md).

Disabled on the dev Pi (no user-visible effect): `samba-ad-dc` (a domain
controller; the file share only needs `smbd`/`nmbd`), `triggerhappy` + its socket,
`systemd-pstore`. Also set `AUTO_SETUP_BOOT_WAIT_FOR_NETWORK=0` in `dietpi.txt`.
**Kept:** `dropbear` (SSH — your way back in), `smbd`/`nmbd` (file share), `cron`,
`fake-hwclock`, `networking`, `x16-splash`.

---

## 4.4 Map a USB gamepad to the X16 joystick

> **Corrected 2026-07-25.** An earlier draft of this section said `x16emu` maps a
> detected controller with no extra config. It does **not**. Verified against the
> r49 source (`src/joystick.c`): `Joystick_slots_enabled[]` initialises to all
> `false`, and `joystick_add()` skips every disabled slot — so with no `-joyN`
> flag a plugged-in pad is opened and then ignored. **The flag is required.**

r49 exposes four bare flags, one per SNES controller port — `-joy1` `-joy2`
`-joy3` `-joy4`. They take no argument; each simply enables that port to accept a
pad. Enabling a port with nothing plugged in costs nothing.

Both launchers now pass them, driven by `X16_JOYSTICKS` in `x16.conf` (0–4,
default 1), so manual and appliance launches behave identically:

```bash
# what the appliance ends up running, with X16_JOYSTICKS=2:
x16emu -fullscreen -widescreen -scale 3 -joy1 -joy2 -rom ... -fsroot ...
```

Change the port count live over SSH with `x16-display` (option 5), or by editing
`x16.conf` from any PC with the SD card in it.

- **Pad still ignored?** SDL only offers a device to the emulator if
  `SDL_IsGameController()` is true — i.e. the pad is in SDL's controller
  database. A very obscure pad needs an `SDL_GAMECONTROLLERCONFIG` mapping
  exported in `custom.sh` before the loop; generate one with SDL's
  `controllermap` utility or the community `gamecontrollerdb.txt`.
- **Wrong buttons?** Same cause — a generic/incorrect SDL mapping. Fix it with a
  `SDL_GAMECONTROLLERCONFIG` entry rather than by changing `x16emu` flags.

**Gate: PASSED on real hardware 2026-07-25.** A cheap SNES-style USB pad
(`0810:e501`, "Personal Communication Systems") drives the X16 joystick. SDL maps
it from its built-in table as "NEXT SNES Controller" — no extra mapping needed —
and the only thing that had ever been missing was `-joy1`. Verified with
`10 J=JOY(1) : PRINT J : GOTO 10` after a reboot, so the setting survives.

`scripts/gamepad-test.sh` (installed as `x16-gamepad-test`) diagnoses any other
pad: it lists what USB and the kernel see, then asks libSDL2 itself through
`ctypes` whether `SDL_IsGameController()` is true — the exact test `x16emu`
applies. Don't infer the answer by grepping GUIDs out of the library; SDL masks
the GUID's CRC16 field and falls back to vendor/product matching, so a supported
pad need not appear as an exact string.

---

## 4.5 Confirm the `-fsroot` user-program workflow

This is how end users get their `.prg`/`.bas` files onto the machine, so make sure
it's frictionless before packaging.

- `custom.sh` / `run-x16.sh` point `-fsroot` at `/boot/firmware/x16`. On Bookworm
  **`/boot/firmware` is the FAT partition** — the one that mounts on any PC when
  the SD card is inserted. (Plain `/boot` is ext4 root and is *not* visible to a
  PC; an earlier revision of these scripts used `/boot/x16` and got this wrong.)
  The scripts probe for the real FAT mount, falling back to `/boot` on pre-Bookworm
  images, so both layouts work.
- Drop a `.prg` into that `x16/` folder from another PC, boot the Pi, and confirm
  `DIR` lists it and `LOAD"NAME"` + `RUN` works inside the X16.
- Space check: the FAT partition is small (~128 MB on a stock image, 256 MB once refit-fat.sh has run). It's sized
  for a personal selection of programs, not the whole community library — see
  `fetch-sdcard.sh --dest` if you want the big collection on the ext4 root.

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
Protect the SD card from power-cut corruption (DietPi-RAMlog, already on by default),
then capture the tuned system as a shrunk, distributable `.img` (`dd` + PiShrink)
and write the end-user README for adding programs. See `07-phase5-harden-package.md`.

## Troubleshooting
| Symptom | Likely cause / fix |
|---|---|
| Wrong resolution / black screen | Forced mode not applied — recheck `hdmi_group`/`hdmi_mode` in `config.txt`; ensure no `video=` in `cmdline.txt` overrides it. |
| Tearing while scrolling | Mode/refresh mismatch — confirm active mode is exactly 60 Hz; try `hdmi_mode=4` (720p60) on a Pi 3. |
| Rainbow splash shows | Intended since 2026-07-25 (`disable_splash=0`) — it is the only feedback possible at ~1 s. Set `disable_splash=1` for black until the branded splash. |
| Boot text / cursor still flashes | `cmdline.txt` tokens not on the single line, or `custom.sh`'s `clear`/cursor-hide not running (check it's the deployed copy). |
| Appliance won't boot after "quiet" | Temporarily drop `quiet`/`loglevel=0` to see the error, or SSH in and read `/var/log/x16-appliance.log`. |
| Gamepad ignored | `X16_JOYSTICKS=0` in `x16.conf`, or the launcher isn't passing `-joyN` (r49 ignores pads without it — see 4.4). If the flag is there, SDL doesn't recognise the pad: needs an `SDL_GAMECONTROLLERCONFIG` mapping. |
