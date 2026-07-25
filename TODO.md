# TODO

Running list of what's outstanding. Status of what's *done* lives in
[DOC/README.md](DOC/README.md); this file is only the open items.

## Blocking the Phase 5 image

- [ ] **Build the image with a 512 MB FAT partition + bind-mounted drop folder.**
      Layout decided and verified on hardware 2026-07-25 — see DOC/07 Part A2.
      FAT is fixed at build time (PiShrink expands root, never FAT), so it must
      fit a 4 GB card: 512 MB leaves ~3.2 GB for a system that needs ~1.4 GB.
      Library stays on ext4; `mount --bind /boot/firmware/x16 <fsroot>/FAT-FILES`
      exposes the PC-writable folder inside it. Confirmed: CD/DIR/LOAD all work
      in subdirectories, and SAVE writes back through the bind mount onto FAT.
      The bind-mount is **done** — `drop_attach()` in `custom.sh`, folder named by
      `X16_DROP_DIR` (default `FAT-FILES`), deployed and verified on the dev Pi.
      Remaining work: create the partition at that size when building, and ship
      `dist/fat-x16-README.TXT` in the folder.
      Repartitioning changes PARTUUID/UUIDs — update `cmdline.txt` and both
      `/etc/fstab` lines or it won't boot.

- [ ] **The shipped image must not carry the dev Pi's Wi-Fi state.** The applier
      exists now (`x16-wifi.conf` + `x16-wifi-apply.service`), but the image has
      to ship with `X16_WIFI_SSID=` empty and **no** `.x16-wifi.state` /
      `.x16-wifi.nohardware` stamp files on the FAT partition — a shipped stamp
      would make the owner's first edit look "unchanged" and be ignored.

## Phase 5 — harden & package ([DOC/07](DOC/07-phase5-harden-package.md))

- [ ] Clean the FAT partition before imaging — the dev Pi has accumulated
      `config.txt.bak-{audio-310,disbt,quiet,x16}`,
      `cmdline.txt.bak-{btquiet,edidfw,quiet}`, `config.txt.bak-x16wifi`, plus a
      Windows `System Volume Information` folder. All would ship to end users.

- [ ] Harden the SD card with **`log2ram`** (not the read-only overlay — it would
      silently discard SAVEs into the ext4 library; see DOC/07 Part A2). Then pull
      power mid-session several times and confirm it still boots clean.
- [ ] Capture the image: `dd` → PiShrink → `x16-appliance-r49.img.gz`.
- [ ] Verify by flashing a **blank** card and booting a second Pi through Gate 3.
- [ ] Re-check [dist/README-end-user.md](dist/README-end-user.md) against the
      final image — especially the FAT drive's label and free space, which is the
      first thing an owner sees.

## Phase 4 leftovers (subjective — need eyes on the TV)

- [ ] Cold-boot and confirm nothing flashes on screen before the splash: no
      kernel text, no cursor, no login line.
- [ ] Load something that scrolls and check for tearing / judder.

## Nice to have

## Boot time — DONE 2026-07-25 (x16emu launch 13.1 s → 6.2 s since kernel start)

Owner-reported wall clock, power-on to `READY.`: **39 s → 30 s** before the last
two fixes below; expect roughly 23 s after. The gap between "6 s since kernel
start" and the stopwatch is firmware/EEPROM before the kernel plus the TV's own
sync/input-switch delay — neither is ours to fix, and the TV is likely the
larger of the two.

Instrumented timeline (`/var/log/x16-appliance.log`, seconds since kernel start):
`getty@tty1` 3.2 → `custom.sh` entered 5.0 → display ready 5.1 → launch 6.2.

All fixes applied on the dev Pi and captured in
[`scripts/trim-boot.sh`](scripts/trim-boot.sh) (idempotent, `--revert`
supported). **Must be run when building the image.**

- [x] `getty@tty1` no longer ordered behind `network.target`. It was waiting for
      `ifup@eth0` → the router's `DHCPOFFER`, 7.9–14.9 s with the Pi idle.
      `getty@tty1` now starts at **3.3 s** (was 20.3 s).
- [x] `serial-getty@ttyS0` disabled + `console=ttyS0` dropped from `cmdline.txt`.
      It had been waiting out a 90 s device timeout every boot, so
      `multi-user.target` didn't activate until 92.9 s. Total boot is now ~16 s
      instead of ~93 s, and nothing blocks the X16.
- [x] **`getty@tty1` `Type=idle` removed — a flat 5 s.** systemd holds an idle
      unit's `ExecStart` until the job queue drains or 5 s pass, so a login
      prompt doesn't interleave with boot messages. tty1 here is the emulator,
      not a prompt (`agetty -l custom.sh`), and the queue never drains early
      because DHCP runs to ~14 s — so it always paid the full 5 s. Found only
      after instrumenting `custom.sh`: the unit was active at 3.2 s but the
      script wasn't entered until 9.9 s.
- [x] `X16_SPLASH_SECONDS` 3 → 1.

- [x] **Splash now paints at 2.68 s instead of 4.78 s** via
      `config/x16-splash-early.service`. The Pi firmware hands the kernel a
      `simple-framebuffer` at 0.7 s whose format (`r5g6b5`, 1920x1080, stride
      3840) is byte-identical to the KMS console's, so the existing blob can be
      written to it with no conversion — no need to wait for vc4 at 4.3 s.
      Both splash units are kept: the KMS handover blanks the console
      (`switching to colour dummy device` at ~4.35 s), and `x16-splash.service`
      repaints at ~4.8 s. Brief ~0.45 s blank there — worth an eyeball.

Remaining, optional:

- [ ] ~1.7 s still passes between `getty@tty1` activating (3.2 s) and `custom.sh`
      being entered (5.1 s) — agetty startup. Probably where a dedicated
      `x16.service` would help, but it steps outside `dietpi-autostart`, which is
      DietPi's supported mechanism. Small, and the big wins are banked.
- [ ] ~2.7 s is the practical floor for the splash: systemd only takes over at
      ~1.7 s and the unit has no ordering left to drop. Earlier would have to
      come from the firmware, which supports no custom image — its only boot
      visual is the rainbow test pattern (`disable_splash=0`), currently off.
- [ ] Cheap trims: `rpi-eeprom-update` 688 ms, `keyboard-setup` 302 ms, FAT
      `systemd-fsck` 435 ms. Kernel is 1.66 s, so ~3 s is close to the floor.
- [ ] **Static IP is not needed for boot speed** and should NOT ship in the
      image (unknown network, collision risk). DHCP now finishes in the
      background, ~14 s after the X16 is already up. If a stable address is
      wanted on a dev unit, prefer a DHCP reservation on the router over editing
      `/etc/network/interfaces` — no pool collision, survives re-imaging, and no
      risk of locking yourself out of a headless Pi.
- [x] **`x16-wifi-apply` tested against a real AP (2026-07-25) — and it did not
      work first time.** Two bugs, both fixed and re-verified from a clean
      "owner" state (radio disabled, `allow-hotplug` commented, no stamp):
      the applier now un-comments `allow-hotplug wlan0` (DietPi comments it out
      when Wi-Fi is disabled, so the radio came up but nothing ever launched
      `wpa_supplicant`), and it writes the per-interface
      `wpa_supplicant-<iface>.conf` that systemd's template unit actually reads.
      The old code's `systemctl restart wpa_supplicant@wlan0` reported *success*
      for a unit that died 260 ms later, so the `ifup` fallback never ran.
      Result: associates unaided at boot, DHCP lease, routes to the internet,
      and the emulator still launches at 6.6 s.
- [ ] Still untested on a **Pi 3** — different Wi-Fi chip (BCM43438 / BCM43455
      vs the Pi 4's) and slower firmware load, so the "interface appeared after
      Ns" path may behave differently.
- [ ] Untested: an AP that is genuinely absent or has a wrong passphrase now
      that the apply path works. The "keep the stamp, let wpa_supplicant retry"
      design has never been exercised against a real failure.
- [ ] Consider bundling `x16-gamepad-test` and `x16-wifi` into the shipped image,
      or leaving them as repo-only service tools.
- [ ] `/usr/local/bin/x16-esc-test` exists on the dev Pi but is not in the repo —
      decide whether it's worth keeping.

## Watch out for (bitten by these already)

- **A systemd drop-in cannot remove an ordering dependency.** `After=` (empty)
  resets the unit's own list, but systemd already registered the mirrored
  `Before=` edge on the other unit while parsing, and that survives. Verified
  here: the drop-in loaded correctly and changed nothing across a full reboot.
  Use a full unit override in `/etc/systemd/system/` so the line is never parsed.

- Anything writing `x16.conf` must round-trip **every** key; `x16-display`
  rewrites the file wholesale and silently dropped settings until
  `smoke-test.sh` grew a guard for it.
- Forced-EDID changes: verify with `cat /sys/module/drm/parameters/edid_firmware`
  and the connector's `modes` list, and re-check **audio** afterwards. Both have
  failed silently before ([DOC/08](DOC/08-display-fixes.md)).
- Wi-Fi credentials do nothing while `dtoverlay=disable-wifi` is present. Use
  `x16-wifi`, which refuses to pretend otherwise.
