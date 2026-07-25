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

- [ ] **The shipped image must not carry the dev Pi's Wi-Fi state.** The applier
      exists now (`x16-wifi.conf` + `x16-wifi-apply.service`), but the image has
      to ship with `X16_WIFI_SSID=` empty and **no** `.x16-wifi.state` /
      `.x16-wifi.nohardware` stamp files on the FAT partition — a shipped stamp
      would make the owner's first edit look "unchanged" and be ignored.

- [ ] **HDMI mode is not pinned in `config.txt`.** Found 2026-07-25: the dev Pi
      has no `hdmi_group` / `hdmi_mode` / `hdmi_force_hotplug`, even though
      `config.txt.snippet` contains them and DOC/06 §4.1 claims Phase 1 applied
      them. Consequence: the *firmware* builds the `video=` token from whatever
      it can read from the TV at power-on, and when the TV is off or slow it
      falls back to `video=HDMI-A-1:640x480M@60`. That gets injected as a
      cmdline mode which outranks the forced EDID — the appliance was observed
      scanning out **640x480**. On a TV that rejects 640x480 DMT this is the
      original black screen, back by another route. Needs the snippet's lines
      applied, plus `disable_fw_kms_setup=1` on Pi 4 (the snippet notes the
      firmware ignores `hdmi_mode` under full-KMS otherwise).

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
