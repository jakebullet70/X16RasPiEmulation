# Option A — DietPi X16 Appliance Plan

_Planning date: 2026-07-22_

Build a minimal Linux "appliance" image that boots straight into the Commander
X16 emulator (`x16emu`) fullscreen — no desktop, kiosk feel.

## Decisions locked in

- **Base OS:** DietPi (Debian-based, lightweight, built-in autostart/kiosk
  automation). arm64 build.
- **Target hardware:** Raspberry Pi 3 and Pi 4 from a **single arm64 image**.
  Both boot 64-bit DietPi and both use the same `vc4-kms-v3d` full-KMS display
  path — no per-model fork. Pi 3 is the performance floor.
- **Display path:** no X server. `x16emu` → SDL2 **KMSDRM** backend → HDMI.
- **User programs:** loaded via `x16emu -fsroot` pointed at a folder on the FAT
  `/boot` partition (drop `.prg`/`.bas` files from any PC).

## Architecture at a glance

```
Power on → DietPi (no desktop, autologin tty1)
        → custom autostart script (sets env, CPU governor)
        → x16emu -fullscreen via SDL2 KMSDRM backend  ⟲ relaunch on exit
        → HDMI 60Hz out + USB keyboard/gamepad in + HDMI audio
```

## Key technical decisions (and why)

- **No X server.** `x16emu` talks to SDL2, and SDL2's KMSDRM backend renders
  straight to the display from the console — no desktop, no compositor. Set
  `SDL_VIDEODRIVER=kmsdrm`. DietPi Lite ships without X, so nothing to strip.
- **Version-pin the emulator to its matching ROM.** The single biggest footgun:
  `x16emu` and the X16 ROM (`rom.bin`, from `x16-rom`) must be the **same
  release**. A mismatch boots to a broken/black state. Pull both from the same
  GitHub release tag rather than mixing latest-of-each.
- **Load user programs via `-fsroot`, not disk images.** Point
  `x16emu -fsroot` at a folder on the FAT `/boot` partition. Users drop
  `.prg`/`.bas` files onto that partition from any PC over USB/SD — no image
  tooling, and the X16 sees them as its filesystem.
- **Appliance loop, not a one-shot.** Run `x16emu` in a `while` loop so
  exiting/crashing relaunches instead of dropping to a shell.

## Build & config outline

### DietPi automation (mostly declarative)

- `dietpi-autostart` → **Custom** (option 17). Launch logic goes in
  `/var/lib/dietpi/dietpi-autostart/custom.sh`.
- In that script: export `SDL_VIDEODRIVER=kmsdrm`, set CPU governor to
  `performance`, then a relaunch loop calling
  `x16emu -fullscreen -fsroot /boot/firmware/x16 ...`.

### `config.txt` essentials

- `dtoverlay=vc4-kms-v3d` (full KMS — default on current images; confirm present)
- Force a clean 60 Hz mode for the target display (`hdmi_group`/`hdmi_mode` or
  the KMS equivalent) so VERA's 60 Hz output maps 1:1 without resampling
- `disable_overscan=1`, quiet / no-splash boot

### Building `x16emu` on the Pi

- Deps: `build-essential`, `libsdl2-dev` (Debian Bookworm SDL2 2.26 has KMSDRM)
- `git clone` x16-emulator at a **pinned tag** → `make` → `x16emu` binary
- Drop in `rom.bin` from the **same** release tag
- Building on a Pi 3 is slow but works; no cross-compile needed for a first pass

### Audio

- SDL → ALSA → HDMI. Set the HDMI output as the default ALSA card so
  PCM/PSG/YM2151 sound comes out the TV.

### Input

- USB keyboard and SDL game controllers work out of the box; map a gamepad to
  the X16 joystick.

## Phased plan

1. **Bring-up** — Flash DietPi arm64, first-boot config, confirm KMS display and
   console.
2. **Emulator runs** — Build/install `x16emu` + matching ROM; launch manually
   fullscreen from the console; confirm KMSDRM, HDMI mode, keyboard, audio.
3. **Appliance-ify** — Wire the custom autostart loop + env/governor; power-on
   to X16 with no shell visible.
4. **Tune** — Exact HDMI 60 Hz, boot-time trimming (disable unused services),
   input mapping, `-fsroot` user folder on `/boot`.
5. **Harden & package** — `log2ram` (or read-only overlay) to protect the SD
   card from power-cut corruption; then capture a shrunk, distributable `.img`
   (`dd` + PiShrink) — the "distro" artifact — plus a short README on adding
   `.prg` files.

## Risks / watch-items

- **Pi 3 headroom:** fine for typical software; VERA-heavy scenes (dual layers +
  many sprites) can dip. Acceptable; note in README.
- **HDMI EDID quirks:** some displays negotiate odd modes — forcing the mode in
  `config.txt` is the fix.
- **X16 is a moving target:** ROM/VERA revisions still change, so plan a simple
  update path (swap pinned binary + ROM). Re-flashing an image is heavier than
  apt — the tradeoff for the appliance feel.
- **SD longevity:** don't skip Phase 5 hardening if the unit is left powered and
  yanked off mains — the classic Pi-appliance failure mode.

## Open next step

Turn Phase 1–2 into a concrete, copy-pasteable build script (DietPi settings +
exact `make` / download / version-pinning commands), or keep research-level for
now.
