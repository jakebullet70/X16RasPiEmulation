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
  the SD card against power-cut corruption (DietPi-RAMlog or read-only overlay), then
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
- **[release-no-AI.md](release-no-AI.md)** — The short, by-hand form of the
  release: dump the card, shrink it, re-arm DietPi's first-boot resize, and where
  the Wi-Fi country code actually has to go. Doc 07 Part B is the full version.

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
- `../scripts/release/prep-image-source.sh` — run on the Pi before capture:
  re-arms DietPi's first-boot resize and strips dev-Pi state. Dry-run by default.
- `../scripts/release/capture-image.sh` — read the card to a raw `.img`, from a
  USB reader or over SSH.
- `../scripts/release/check-image.sh` — read-only ship-readiness audit of a
  capture (resize armed, no credentials, no `.bak` litter, FAT size and label).
- `../scripts/release/refit-fat.sh` — rebuild a capture with a bigger FAT
  partition, offline, preserving PARTUUIDs and both filesystem UUIDs.
- `../scripts/release/set-fat-label.sh` — name the capture's FAT drive (`X16PI`),
  offline, verifying the volume serial and MBR disk id survive it. Needed because
  the refit is off by default and used to be the only thing that set a label.
- `../scripts/release/shrink-image.sh` — shrink + gzip via the vendored PiShrink.
- `../scripts/release/make-release.ps1` — Windows entry point; drives the three
  above inside WSL Ubuntu.
- `../tools/pishrink/` — PiShrink vendored at a pinned commit, with `VENDORED.md`
  explaining why `-s -n` is always passed.

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
- **Boot is settled** (2026-07-25): **39 s → 23 s** power-on to `READY.` on the
  owner's stopwatch; x16emu launches 6.3 s after kernel start, down from 13.1 s.
  Four fixes, all measured: `getty@tty1` no longer ordered behind
  `network.target` (it was waiting on DHCP), `getty@tty1`'s `Type=idle` 5 s
  stall removed, `serial-getty@ttyS0` disabled (a 90 s timeout every boot), and
  the splash hold cut to 1 s. The branded splash now paints at 2.7 s on the
  firmware's pre-KMS framebuffer, with the rainbow deliberately re-enabled at
  ~1 s. Reproduced by [`scripts/trim-boot.sh`](../scripts/trim-boot.sh) +
  [`config/x16-splash-early.service`](../config/x16-splash-early.service).
  What's left is firmware time and the TV's own sync delay — not ours to fix.
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
  discard those writes at reboot, so the shipped image keeps the root writable and relies on DietPi-RAMlog
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
  network can set up Wi-Fi by editing a file on the card. Association verified
  against a real AP after two bugs were fixed (`allow-hotplug`, and the
  per-interface `wpa_supplicant-<iface>.conf` systemd actually reads).
- **Wi-Fi is now consume-and-clear** (2026-07-29): a successful join clears the
  SSID and passphrase from the card, leaving only `wpa_supplicant.conf` on ext4
  (0600). A *failed* join leaves them alone so a typo can be corrected, and
  either way `x16-wifi-status.txt` on the card says what happened — the only
  feedback an owner with no shell can get. `X16_WIFI_COUNTRY` is carried across
  and never left blank, because DietPi warns on screen without one.
  This **replaced the `.x16-wifi.state` fingerprint stamp**, whose whole risk was
  shipping stale and making an owner's first edit look "unchanged": blank is now
  the idle state, so that failure is structurally impossible rather than guarded
  against. It does make the design incompatible with the Phase 5 read-only
  overlay (credentials on ext4 would be discarded while the card is already
  blank) — a non-issue for the shipped build, which keeps the root writable. Six behaviours covered by
  a sandbox test, including that the enable-the-radio reboot must *not* clear the
  card, and that a malformed country code can't inject through the reset `sed`.
- **Consume-and-clear verified on hardware, after four more bugs** (2026-07-29).
  A real Pi 4 read credentials off the card, enabled the radio, rebooted itself
  once, joined, cleared its own `x16-wifi.conf` keeping the country, and wrote
  the "Connected" status. A further reboot brought Wi-Fi up unaided from a blank
  card in 13 s. The four bugs are each worth remembering as a *class*:
  - **A distro switches a feature off in more than one place.** Removing
    `dtoverlay=disable-wifi` puts the chip back on the SDIO bus, but
    `/etc/modprobe.d/dietpi-disable_wifi.conf` blacklists `cfg80211`/`brcmfmac`/
    `brcmutil` so the driver never binds. The applier reported "This Pi does not
    appear to have Wi-Fi" on a Pi 4 with the AP in range. We had verified the
    overlay handling and stopped looking.
  - **A file meant for a Windows editor will arrive with CRLF.**
    `x16-wifi.conf` was sourced directly, so a Notepad save put `\r` inside every
    value; `wpa_passphrase` then died and wrote a config with no network block.
    Invisible on a dev box — git-bash strips CR when sourcing, so it reproduces
    only on the target.
  - **A guarded optional dependency can silently never run.** The rfkill unblock
    sat behind `command -v rfkill`, and `rfkill` is not in the image — so the
    step the script's own header called mandatory had never once executed.
  - **The same state can mean two opposite things.** A blank card means "never
    configured" *or* "configured, and cleared because it worked" — reporting
    both as "Wi-Fi is not set up" contradicted the success message on the very
    next boot.
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
  tokens all active (4.2), services trimmed (4.3 — measured at 18 s at the time,
  since taken to 23 s wall-clock / 6.3 s to launch by the boot work above),
  gamepad working (4.4). Only the subjective checks remain — eyeball a cold boot
  for stray text, and a scrolling demo for tearing.
- **The release is scripted and PiShrink is vendored** (2026-07-29):
  `scripts/release/` does prep → capture → check → shrink, driven from Windows by
  `make-release.ps1` through WSL. Two things this pinned down:
  **DietPi's first-boot resize disarms itself** (its first act is to delete its own
  `WantedBy` symlink), so it must be re-armed on the Pi before every capture —
  the dev Pi reads `disabled` right now. And **PiShrink is invoked with `-s`**,
  because its autoexpand writes a Raspberry Pi OS `/etc/rc.local` calling
  `raspi-config`, neither of which exists here; DietPi's own resizer runs earlier
  and does it properly.
- **`check-image.sh` run against a real build** found what it was written to find:
  the Wi-Fi stamp and credentials shipping, 11 `config.txt`/`cmdline.txt` `.bak`
  files, and Windows' `System Volume Information` folder. It also caught the one
  that mattered most — **our credentials were inside the image on ext4**, in
  `wpa_supplicant-wlan0.conf` and the applier's own `.bak-x16wifi`. Clearing the
  card is not enough; the stored PSK is a hash, which is not reassuring, because
  `wpa_supplicant` joins with the hash directly. `prep-image-source.sh` now
  deletes them and restores `dtoverlay=disable-wifi`, since testing Wi-Fi on the
  build Pi is exactly what removes it.
- **The hardening was already done, and the plan for it was wrong** (2026-07-29).
  DietPi ships its own RAMlog and enables it by default: `/var/log` is a 50 MB
  tmpfs straight from `/etc/fstab`. Doc 07 Part A had said to
  `dietpi-software install 137` (log2ram) — that would have layered a second
  log-in-RAM system onto one already running. Corrected everywhere;
  `check-image.sh` now fails an image whose `/var/log` is not a tmpfs.
- **FAT revised 512 MB → 256 MB, and it is buildable now** (2026-07-29). A built
  image has 222 MB free at 256 MB, so the rest is worth more to the root
  filesystem on a 4 GB card. [`scripts/release/refit-fat.sh`](../scripts/release/refit-fat.sh)
  does it offline between capture and shrink — it cannot be done on a running Pi,
  because growing FAT moves the start of the mounted root. TODO's warning that
  repartitioning would force `cmdline.txt` and `/etc/fstab` edits turned out to be
  **avoidable**: keeping the MBR disk identifier keeps the PARTUUIDs, a raw
  partition copy keeps the root's filesystem UUID, and `mkfs.vfat -i` keeps the
  FAT volume serial. Verified 128 → 256 MB on a real build with all three
  identifiers unchanged and 424/424 boot files copied.
- **The whole release ran end to end** (2026-07-29). New Wi-Fi applier deployed,
  `prep-image-source.sh --apply`, capture over SSH (3.997 GB at 9.7 MB/s — the
  link, not the card; a USB reader would be far quicker), refit to 256 MB, ship
  check, PiShrink. Out: **`x16-appliance-r49.img.gz`, 578 MB**, checked clean on
  the unpacked artifact with **no failures and 2 warnings** — the baked-in SSH
  host keys, and `dietpi.txt` still saying `CONFIG_SERIAL_CONSOLE_ENABLE=1` while
  the getty is off (a stale setting that `dietpi-config` or a DietPi update would
  act on, handing back the 90 s boot stall). Both are decisions, not defects.
  Two bugs surfaced only by running it: `rm -f` on `dietpi-ramlog_store`, which is
  a directory, aborted the prep mid-way; and the capture hung on an
  unanswerable host-key prompt because WSL runs as root there, whose
  `known_hosts` is empty (fixed with `StrictHostKeyChecking=accept-new`).
- **Two ship decisions settled** (2026-07-30). **Country code is `US` everywhere**
  — it had shipped split, and the `dietpi.txt` half was not cosmetic as assumed:
  `dietpi-config` and DietPi updates act on that key through
  `dietpi-set_hardware`, so a shipped unit's regulatory domain could change by
  itself, with a symptom indistinguishable from a wrong passphrase. There are
  **two** `dietpi.txt` files on Bookworm — `/boot` (ext4) and `/boot/firmware`
  (card) — separate files, both saying `GB`. `prep-image-source.sh` now makes the
  card, the ext4 reset template and both `dietpi.txt` copies agree, and
  `check-image.sh` fails an image where they don't.
  **The FAT drive is named `X16PI`**, which needed new tooling rather than a flag:
  the only thing that had ever set a label was `refit-fat.sh`'s `mkfs.vfat -n`,
  and the refit is off by default now that FAT stays at 128 MB — so the label had
  no path to the shipped image. `set-fat-label.sh` does it offline on the capture
  (not on the Pi: `/boot/firmware` is mounted and bind-mounted into the running
  emulator, so a live relabel may not survive the unmount), verifying the FAT
  volume serial and MBR disk id are untouched — `/etc/fstab` mounts
  `/boot/firmware` by that serial. Tested against a synthetic card image
  including the dirty-bit case a live capture always carries.
- **Resume point:** flash `x16-appliance-r49.img.gz` to a blank card and boot it —
  the **Pi 4 first**, so a failure can only be the Wi-Fi rewrite, then the same
  card into the **Pi 3** for Gate 5's second-Pi requirement plus the 720p splash
  and non-HDMI display paths. The clone has SSH, so iterate on it rather than
  re-capturing; the dev card stays a golden master.

## Open questions

- Phase 5 output (`x16-appliance-r49.img.gz` + README) is the shippable distro.
- The dev Pi's dropbear host keys are baked into the image. `--reset-host-keys`
  regenerates them; dropbear runs without `-R` here, so simply deleting them
  would ship an image with no SSH at all.
- **`config/x16-wifi.conf` in the repo is not the file that ships.** The card and
  the ext4 reset template carry a terse 7-line version (261 bytes); the repo's is
  the 25-line owner-facing one with the "leave empty to stay on Ethernet",
  country-examples and plain-text-warning comments. `prep-image-source.sh` builds
  the template from *the card*, so the repo copy has never been deployed. Since
  `dist/README-end-user.md` sends the owner into this file to edit it, the
  in-file guidance is the guidance — decide whether to push the repo version onto
  the card before capture.
