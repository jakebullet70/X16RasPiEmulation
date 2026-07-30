# Release notes — the by-hand version

Bench notes for cutting a release image, kept because they were worked out on
real hardware. The scripted version of all of this is
[`scripts/release/`](../scripts/release/), documented in
[07-phase5-harden-package.md](07-phase5-harden-package.md) Part B — use that for
an actual release. This page is the short form, with the traps marked.

---

## Dumping the Pi's SD card over SSH

From WSL on Windows:

```bash
ssh root@<pi-ip> "sync; dd if=/dev/mmcblk0 bs=4M status=progress" \
  | dd of=dietpi_clean.img bs=4M iflag=fullblock conv=fsync
```

- No `sudo` — you log in as `root` on DietPi, and DietPi doesn't install `sudo`
  by default.
- `iflag=fullblock` on the receiving end: reads from a pipe come back short, and
  without it `dd` writes short blocks.
- This is a **live, mounted, read-write** filesystem, so the image lands slightly
  inconsistent. It survives because PiShrink runs `e2fsck -pf` before resizing.
  Capturing the card in a reader with the Pi powered off is the clean way.

Scripted: `scripts/release/capture-image.sh --from-ssh root@<pi-ip>`, which also
refuses a partition instead of a whole disk, checks free space, and fails if the
copy comes out short.

## Shrinking it

```bash
sudo tools/pishrink/pishrink.sh -s -n -z dietpi_clean.img
```

PiShrink is vendored at a pinned commit in [`tools/pishrink/`](../tools/pishrink/)
— see `VENDORED.md` there for why, and why both flags are always passed.

**`-s` is the important one: it disables PiShrink's own first-boot expansion, and
that is deliberate.** PiShrink expands by writing an `/etc/rc.local` that calls
`raspi-config --expand-rootfs`. That is Raspberry Pi OS's mechanism; this image
is DietPi, which has neither. DietPi's own resizer does the job better and much
earlier in boot — see below.

`-n` skips the update check so a release build doesn't depend on GitHub being up.
`-z` gzips the result.

## Resizing on boot

DietPi's `dietpi-fs_partition_resize.service` expands the root filesystem on
first boot. It is **not** the same as PiShrink's autoexpand and does not need it.

```bash
sudo systemctl enable dietpi-fs_partition_resize.service
```

That is the whole fix, and it matters every single time: the service's first act
is to delete its own `WantedBy` symlink —

```sh
rm -Rfv /etc/systemd/system/*.wants/dietpi-fs_partition_resize.service
```

— so on any Pi that has booted more than once it reads `disabled`, and an image
captured from it will never expand on anyone's card. Re-arm it, then **power off
rather than reboot**: a reboot runs the service, finds nothing to expand, and
disarms it again.

Two corrections to the older version of these notes:

- **`parted` is not needed.** DietPi's resizer uses `sfdisk` and `resize2fs`.
  `parted` is a *PiShrink* dependency — on the host that runs the shrink, and
  inside the image only for PiShrink's own autoexpand, which `-s` turns off.
- **There is no `/var/lib/dietpi/.fs_partition_resize` flag file** on this DietPi
  version, so removing one does nothing. The enable symlink *is* the state.

Scripted, along with stripping the dev Pi's Wi-Fi credentials, `.bak` litter and
logs: `sudo scripts/release/prep-image-source.sh --apply`.

## Wi-Fi country code

Don't hand-edit `/etc/wpa_supplicant/wpa_supplicant.conf` on this appliance.
[`x16-wifi-apply.sh`](../scripts/x16-wifi-apply.sh) rewrites that file from
`x16-wifi.conf` whenever the card changes, and separately maintains the
per-interface `wpa_supplicant-wlan0.conf` that systemd's template unit is the one
actually reading — so a hand edit is either overwritten or ignored.

The shipped default is **`US`**, and it has to be `US` in **four** places or
DietPi can change it back on its own. Set it where it lasts:

- `X16_WIFI_COUNTRY=US` in `x16-wifi.conf` on the FAT partition (this is also the
  owner's route — no shell needed).
- `X16_WIFI_COUNTRY=US` in `/opt/x16/x16-wifi.conf.original`, the ext4 template
  the applier rebuilds the card from after a successful join. Miss this one and
  the country reverts *later*, not at capture.
- `AUTO_SETUP_NET_WIFI_COUNTRY_CODE=US` in **both** `dietpi.txt` files, for
  DietPi's own tools. There are two on Bookworm — `/boot/dietpi.txt` on the ext4
  root and `/boot/firmware/dietpi.txt` on the card — separate files, not links.
  This is the half that looks cosmetic and isn't: `dietpi-config` and DietPi
  updates read the key and run `dietpi-set_hardware serialconsole`-style
  reconfiguration, so a stale `GB` here can reset the regulatory domain on a unit
  already in an owner's hands.

`prep-image-source.sh` now rewrites all four to agree, and `check-image.sh` fails
an image where the template or either `dietpi.txt` disagrees with the card.

The radio comes up rfkill-soft-blocked until a regulatory domain is set, so a
missing or wrong country looks exactly like a wrong password.

## The FAT drive's name

The shipped label is **`X16PI`** — `dist/README-end-user.md` tells the owner to
look for a drive by that name, so an unlabelled card makes the README wrong.

It cannot be set on the running Pi: `/boot/firmware` is mounted *and* its `x16/`
folder is bind-mounted into the emulator's fsroot, so the kernel's cached boot
sector can overwrite a live `fatlabel` on unmount. Do it offline on the capture:

```bash
sudo scripts/release/set-fat-label.sh --label X16PI <image.img>
sudo scripts/release/set-fat-label.sh --check <image.img>   # just report
```

`make-release.ps1` runs this automatically (`-FatLabel`, default `X16PI`). The
script refuses to finish if the FAT **volume serial** changed — `/etc/fstab`
mounts `/boot/firmware` by it, so that would boot with no boot partition.

## Wi-Fi is disabled in TWO places, not one

If you are debugging "the Pi says it has no Wi-Fi", check both:

| Off-switch | What it does | Where |
| --- | --- | --- |
| `dtoverlay=disable-wifi` | keeps the chip off the SDIO bus entirely | `config.txt`, read by the **firmware** |
| `blacklist brcmfmac` etc. | chip is present, driver never binds | `/etc/modprobe.d/dietpi-disable_wifi.conf` |

Undoing only the overlay gets you a Pi where `dmesg` proudly reports
`mmc1: new high speed SDIO card at address 0001` and `/sys/class/net` still has
no `wlan0`. That cost a full test cycle on 2026-07-29. `x16-wifi-apply` now
clears both; `prep-image-source.sh` restores both before capture.

The overlay is firmware-level, so it cannot be undone for the boot you are
already in — hence the one-time self-reboot. The blacklist *can* be undone live,
which is why enabling Wi-Fi costs exactly one reboot and not two.
