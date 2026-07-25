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

## Boot time — DONE 2026-07-25 (20.3 s → 3.3 s to the X16)

Both fixes applied on the dev Pi and captured in
[`scripts/trim-boot.sh`](scripts/trim-boot.sh) (idempotent, `--revert`
supported). **Must be run when building the image.**

- [x] `getty@tty1` no longer ordered behind `network.target`. It was waiting for
      `ifup@eth0` → the router's `DHCPOFFER`, 7.9–14.9 s with the Pi idle.
      `getty@tty1` now starts at **3.3 s** (was 20.3 s).
- [x] `serial-getty@ttyS0` disabled + `console=ttyS0` dropped from `cmdline.txt`.
      It had been waiting out a 90 s device timeout every boot, so
      `multi-user.target` didn't activate until 92.9 s. Total boot is now ~16 s
      instead of ~93 s, and nothing blocks the X16.

Remaining, optional:

- [ ] `X16_SPLASH_SECONDS=3` is now the single largest delay before the `READY.`
      prompt — 3 s of deliberate hold on a 3.3 s boot. Reconsider (1 s?) now that
      there is no long wait for it to cover.
- [ ] A dedicated `x16.service` (`After=basic.target`, `TTYPath=/dev/tty1`) would
      drop agetty + login + shell profile from the path — maybe 0.5–1 s more, and
      more deterministic. Trade-off: steps outside `dietpi-autostart`, which is
      DietPi's supported mechanism. Low value now that the big win is banked.
- [ ] Cheap trims: `rpi-eeprom-update` 688 ms, `keyboard-setup` 302 ms, FAT
      `systemd-fsck` 435 ms. Kernel is 1.66 s, so ~3 s is close to the floor.
- [ ] **Static IP is not needed for boot speed** and should NOT ship in the
      image (unknown network, collision risk). DHCP now finishes in the
      background, ~14 s after the X16 is already up. If a stable address is
      wanted on a dev unit, prefer a DHCP reservation on the router over editing
      `/etc/network/interfaces` — no pool collision, survives re-imaging, and no
      risk of locking yourself out of a headless Pi.
- [ ] `x16-wifi` / `x16-wifi-apply` are untested against a REAL access point. On
      the dev Pi the radio came up and the applier drove it correctly (interface
      detection, regulatory domain, rfkill, config generation, and the failure
      path all exercised), but association itself has never succeeded because
      that Pi is Ethernet-only. Test on a Pi 3 too — different Wi-Fi chip
      (BCM43438 / BCM43455 vs the Pi 4's), and slower firmware load.
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
