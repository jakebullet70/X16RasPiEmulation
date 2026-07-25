# TODO

Running list of what's outstanding. Status of what's *done* lives in
[DOC/README.md](DOC/README.md); this file is only the open items.

## Blocking the Phase 5 image

- [ ] **Decide where user programs live in the shipped image.** The distributable
      appliance wants `-fsroot` on the FAT partition so an owner can drop `.PRG`
      files in from any PC ([dist/README-end-user.md](dist/README-end-user.md)
      describes this). But FAT is ~128 MB and the community library is ~250 MB,
      so a machine with the full library must keep the fsroot on ext4 and add
      files over Samba. `X16_FSROOT` lets each machine choose; the *image* still
      has to pick one story.
      Leaning: ship a small curated selection on FAT, treat the full library as
      an optional `x16-fetch-sd --dest` extra.
      Note this interacts with hardening — under a read-only root overlay,
      anything written to an ext4 fsroot does not survive reboot.

## Phase 5 — harden & package ([DOC/07](DOC/07-phase5-harden-package.md))

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
- [ ] `x16-wifi` is untested against a real access point — the dev Pi runs
      Ethernet with the radio disabled in the device tree. The refusal path (no
      `wlan0`) and the status view are verified; scan/join are not.
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
