# RasPiEmulation — Commander X16 on Raspberry Pi

Planning and research docs for building a Raspberry Pi that boots straight into
the Commander X16 emulator.

## Contents

- **[00-hardware-day-runsheet.md](00-hardware-day-runsheet.md)** — One-page bench
  sheet: all five phase gates with copy-paste commands, for running the whole build
  on a Pi in one sitting without flipping between docs. Start here on hardware day.
- **[01-feasibility-research.md](01-feasibility-research.md)** — Can the BMC64
  bare-metal approach be applied to the X16 emulator? Compares BMC64 (VICE +
  Circle) with x16-emulator (C + SDL2), lays out Option A (Linux appliance) vs
  Option B (true bare-metal), with sources.
- **[02-option-a-plan.md](02-option-a-plan.md)** — The chosen first approach: a
  DietPi arm64 appliance image for Pi 3 & Pi 4 that boots into `x16emu`
  fullscreen. Decisions, build/config outline, phased plan, and risks.
- **[03-phase1-2-runbook.md](03-phase1-2-runbook.md)** — Copy-paste hardware
  runbook executing Phase 1 (DietPi bring-up + KMS check) and Phase 2 (install
  x16emu r49 + ROM, manual fullscreen launch), with gates and troubleshooting.
- **[04-testing-on-emulator.md](04-testing-on-emulator.md)** — Testing the scripts
  on x86 before touching hardware: Docker container (fast logic test) and DietPi
  x86 VM paths, with an explicit what-it-does/doesn't-prove table.
- **[05-phase3-appliance.md](05-phase3-appliance.md)** — Phase 3: wire the
  autostart appliance loop (`custom.sh`) and flip `dietpi-autostart` to Custom
  (17) so power-on drops straight into the X16 fullscreen with no shell, with
  break-in, rollback, and troubleshooting.
- **[06-phase4-tune.md](06-phase4-tune.md)** — Phase 4: lock the exact HDMI 60 Hz
  mode, silence the boot (only the X16 ever on screen), trim boot time, and map a
  USB gamepad. Product-feel polish, each item independently gated.
- **[07-phase5-harden-package.md](07-phase5-harden-package.md)** — Phase 5: harden
  the SD card against power-cut corruption (`log2ram` or read-only overlay), then
  capture a shrunk, auto-expanding `.img` (`dd` + PiShrink) and ship an end-user
  README — the distributable "distro" deliverable.
- **[08-display-fixes.md](08-display-fixes.md)** — The real-hardware "black screen"
  saga: five stacked causes (boot race, missing Mesa userspace, TV-won't-sync-DMT,
  desktop-GL renderer draws black, sizing toggle) with the golden diagnostic path
  and the forced-EDID deploy checklist. Read this if the screen is ever blank.

## Artifacts

- `../config/dietpi.txt.snippet` — DietPi first-boot automation keys.
- `../config/config.txt.snippet` — full-KMS + forced 60 Hz HDMI firmware config.
- `../config/cmdline.txt.snippet` — quiet-boot kernel params (Phase 4).
- `../scripts/install-x16.sh` — install prebuilt aarch64 x16emu + matching ROM.
- `../scripts/build-x16-from-source.sh` — compile fallback.
- `../scripts/run-x16.sh` — manual fullscreen launch (Phase 2).
- `../scripts/custom.sh` — Phase 3 DietPi custom-autostart appliance loop
  (deploys to `/var/lib/dietpi/dietpi-autostart/custom.sh`).
- `../scripts/x16-display.sh` — interactive SSH tool to change aspect / scale /
  resolution / force-EDID live (deploys to `/usr/local/bin/x16-display`).
- `../scripts/smoke-test.sh` — headless install/launch check for VM/container/CI.
- `../config/x16.conf` — appliance display/audio settings (boot partition,
  editable from any PC).
- `../tools/gen_edid.py` — generates the forced 1080p-only CEA EDID
  (`x16-1080p.edid`) that fixes the black-screen-on-DMT problem.
- `../dist/README-end-user.md` — the plain-language README that ships alongside
  the distributable `.img.gz` (Phase 5 Part C).

## Status

- Direction chosen: **Option A** (DietPi appliance).
- Version pinned: **x16-emulator r49** + matching **x16-rom r49**.
- **All five phases authored** (runbooks + scripts + config).
- **Phases 1 & 2 PASSED on a real Pi 4** (2026-07-23): KMS up, x16emu r49 + ROM at
  `/opt/x16`, X16 boots fullscreen with working keyboard. Phase 3 autostart deployed.
- **Black-screen saga solved** — five stacked display causes diagnosed and fixed;
  the fixes are now baked into the repo scripts/config (see `08-display-fixes.md`).
- **`-fsroot` moved to the FAT boot partition** (2026-07-25): it was `/boot/x16`
  on the ext4 root, which a PC cannot see — so the documented "drop files on the
  card from any PC" workflow never actually worked. Now `/boot/firmware/x16`
  (scripts probe for the real FAT mount). `install-x16.sh` migrates anything left
  in the old location.
- **End-user README written** (`../dist/README-end-user.md`) — Phase 5 Part C.
- **Gamepad WORKING on hardware** (2026-07-25): r49 ignores pads unless `-joyN`
  enables the port, so both launchers now pass it, driven by `X16_JOYSTICKS` in
  `x16.conf`. Doc 06 §4.4 corrected — it had claimed no flag was needed.
  Confirmed with a `0810:e501` SNES-style USB pad, which SDL maps built-in as
  "NEXT SNES Controller". `x16-gamepad-test` diagnoses other pads by asking
  libSDL2 directly via ctypes.
- **`X16_FSROOT` added, and the FAT plan does not fit every machine.** The dev Pi
  already holds the ~250 MB community library in `/boot/x16` (ext4); the FAT boot
  partition is 127 MB total. So the fsroot is now configurable: default is the
  FAT `x16/` folder (drop files from any PC), overridable per machine. The dev Pi
  is set to `X16_FSROOT=/boot/x16` and therefore uses Samba/scp, **not** the
  SD-card drop workflow that `dist/README-end-user.md` describes. Reconcile
  before packaging — see "Open questions" below.
- **`x16-display` no longer eats settings**: its `save()` rewrote `x16.conf` with
  only four keys, silently erasing anything else (`X16_SPLASH_SECONDS` was already
  affected). `smoke-test.sh` now fails if a key the appliance reads is missing
  from `save()`.
- **Dev Pi is current** (2026-07-25): reachable as `X16RasPi` / 192.168.1.193, the
  updated `custom.sh` is deployed and it boots into the X16 with `-joy1` and the
  full library. Previous appliance files backed up in `/root/x16-backup-*`.
- **Resume point:** Phase 4 remaining items (60 Hz lock, silent-boot check, boot
  trim), then Phase 5 (harden + package).

## Open questions

- **Where do user programs live?** Two workflows are in tension. The distributable
  image wants the fsroot on the FAT partition so a non-technical owner can drop
  `.PRG` files in from any PC (what `dist/README-end-user.md` says). But the FAT
  partition is 127 MB and the community library is ~250 MB, so a machine with the
  full library must keep the fsroot on ext4 and add files over the network.
  `X16_FSROOT` lets each machine choose, but the *shipped* image has to pick one
  story. Likely resolution: ship with a small curated selection on FAT, and treat
  the full library as an optional `x16-fetch-sd --dest` extra for networked users.
  Decide before capturing the Phase 5 image.
- Phase 5 output (`x16-appliance-r49.img.gz` + README) is the shippable distro.
