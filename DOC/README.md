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
- **[09-bare-metal-review.md](09-bare-metal-review.md)** — Revisits the Option B
  (BMC64-style bare-metal) question now that Option A is built and debugged on
  hardware: which of our display bugs bare metal would actually have prevented,
  what it simplifies (storage, power-cut hardening), what it throws away, and why
  stripping the Linux boot is the better-value path if boot speed is the goal.
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
- **"Where do user programs live?" — SETTLED** (2026-07-25). It was a real
  tension: the shipped image wants the fsroot on FAT so an owner can drop `.PRG`
  files in from any PC, but the community library (~250 MB) will not fit there.
  Resolved by having **both**: the library on ext4 as the fsroot, with the FAT
  folder bind-mounted inside it as `FAT-FILES/` (`x16emu` takes only one
  `-fsroot`). One small drive on the owner's PC, library at the X16's root, their
  own files one level down — and `SAVE` writes back through the mount onto the
  card. Implemented as `drop_attach()` in `custom.sh` and verified on hardware,
  including the negative cases; `X16_DROP_DIR` names the folder (`FAT-FILES`).
- **The library moved to `/mnt/x16`** (2026-07-25). It had been `/boot/x16`, which
  is actively misleading: on Bookworm `/boot` is the ext4 root while the card's
  FAT partition is `/boot/firmware`, so the name implied "on the card, visible
  from a PC" — the exact misreading behind the original broken drop workflow.
  Same partition, honest name. Dev Pi moved, `X16_FSROOT`, the Samba `[X16]`
  share and the service tools all updated; `/boot/x16.conf` fallbacks in the
  launchers are a *config file* for older layouts and were deliberately left.
- **The ext4 library is READ/WRITE and stays that way.** Earlier notes described
  it as "read-only", which was about it being bundled content, not a mount
  option — confirmed on hardware that `/` is `rw` and the X16 can `SAVE` into the
  library root. This does constrain hardening: a read-only overlay would silently
  discard those writes at reboot, so the shipped image uses `log2ram`
  (`07-phase5-harden-package.md`, Part A2).
- **`x16-display` no longer eats settings**: its `save()` rewrote `x16.conf` with
  only four keys, silently erasing anything else (`X16_SPLASH_SECONDS` was already
  affected). `smoke-test.sh` now fails if a key the appliance reads is missing
  from `save()`.
- **HDMI mode now pinned in `config.txt`** (2026-07-25, confirmed on the TV): the
  firmware had been deriving `video=` from whatever the TV answered at power-on
  and falling back to `640x480`, which outranked the forced EDID. With
  `hdmi_group=1` / `hdmi_mode=16` / `hdmi_force_hotplug=1` / `disable_fw_kms_setup=1`
  there is no `video=` token at all and the connector offers only 1920x1080.
- **Wi-Fi applier shipped** (2026-07-25): `x16-wifi.conf` on the FAT partition,
  applied at boot by `x16-wifi-apply.service`, so an owner with no shell and no
  network can set up Wi-Fi by editing a file on the card. Defers to
  `dietpi-config` when the card hasn't changed. Association itself still untested
  against a real AP — see `../TODO.md`.
- **Dev Pi is current** (2026-07-25): reachable as `X16RasPi` / 192.168.1.193, the
  updated `custom.sh` is deployed and it boots into the X16 with `-joy1` and the
  full library. Previous appliance files backed up in `/root/x16-backup-*`.
- **Forced EDID had never worked, and fixing it briefly broke audio** — both
  found and fixed on hardware 2026-07-25. The cmdline used the pre-6.x parameter
  name (`drm_kms_helper.edid_firmware`, silently ignored), and the synthetic EDID
  lacked an HDMI VSDB so the sink was treated as DVI and vc4 refused audio
  (ENOTSUPP/524). Both traps documented in `08-display-fixes.md`.
- **HDMI audio CONFIRMED working by ear** (2026-07-25) with the EDID forced, via
  `PSGINIT` / `PSGVOL 0,63` / `PSGNOTE 0,$4A` at the BASIC prompt.
- **Phase 4 essentially complete**: 60 Hz + forced EDID verified (4.1), quiet-boot
  tokens all active (4.2), services trimmed and boot measured at 18 s (4.3),
  gamepad working (4.4). Only the subjective checks remain — eyeball a cold boot
  for stray text, and a scrolling demo for tearing.
- **Resume point:** Phase 4 remaining items (60 Hz lock, silent-boot check, boot
  trim), then Phase 5 (harden + package).

## Open questions

- Phase 5 output (`x16-appliance-r49.img.gz` + README) is the shippable distro.
