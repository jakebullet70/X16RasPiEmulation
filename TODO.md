# TODO

Running list of what's outstanding. Status of what's *done* lives in
[DOC/README.md](DOC/README.md); this file is only the open items.

## Blocking the Phase 5 image

- [ ] **Build the image with a 512 MB FAT partition + bind-mounted drop folder.**
      Layout decided and verified on hardware 2026-07-25 — see DOC/07 Part A2.
      FAT is fixed at build time (PiShrink expands root, never FAT), so it must
      fit a 4 GB card: 512 MB leaves ~3.2 GB for a system that needs ~1.4 GB.
      Library stays on ext4; `mount --bind /boot/firmware/x16 <fsroot>/MYFILES`
      exposes the PC-writable folder inside it. Confirmed: CD/DIR/LOAD all work
      in subdirectories, and SAVE writes back through the bind mount onto FAT.
      Remaining work: create the partition at that size when building, add the
      bind-mount to `custom.sh`, and ship `dist/fat-x16-README.TXT` in the folder.
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

- [ ] Harden the SD card: `log2ram` **or** read-only overlay. Then pull power
      mid-session several times and confirm it still boots clean.
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

- [ ] Reclaim ~4.7 s of boot: `ifup@eth0` blocks `network.target`, which
      `systemd-user-sessions` and therefore `getty@tty1` are ordered after. A
      drop-in dropping that ordering would get boot-to-X16 from ~18 s to ~13 s,
      at the cost of fighting Debian's default ordering.
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

- Anything writing `x16.conf` must round-trip **every** key; `x16-display`
  rewrites the file wholesale and silently dropped settings until
  `smoke-test.sh` grew a guard for it.
- Forced-EDID changes: verify with `cat /sys/module/drm/parameters/edid_firmware`
  and the connector's `modes` list, and re-check **audio** afterwards. Both have
  failed silently before ([DOC/08](DOC/08-display-fixes.md)).
- Wi-Fi credentials do nothing while `dtoverlay=disable-wifi` is present. Use
  `x16-wifi`, which refuses to pretend otherwise.
