# PiShrink — vendored copy

Upstream: <https://github.com/Drewsif/PiShrink> (MIT — `LICENSE` kept alongside).

| | |
| --- | --- |
| Pinned commit | `a5f9463c01607ab07402c7e75c9cfd4bb3a0e886` (2026-03-16) |
| Script version | `v26.03.16` |
| `sha256(pishrink.sh)` | `71026f0c02ac099e588a3eb8f70760c1b680aa8ea3acde61a0141fbaeb68c777` |

Vendored rather than `wget`-ed at release time so a build is reproducible: the
release procedure is one of the few things here that can't be re-run on a whim,
and "it worked last month" should mean the same bytes.

Refresh it deliberately, not casually — re-download at a new commit, update the
three rows above, and re-run a full capture → shrink → flash → boot cycle before
trusting it.

## How we invoke it

`scripts/release/shrink-image.sh` always passes **`-s -n`**:

- **`-s` — skip PiShrink's first-boot autoexpand.** This is the important one.
  PiShrink expands the root filesystem by writing its own `/etc/rc.local`, which
  calls `raspi-config --expand-rootfs` and falls back to driving `fdisk` against
  a hard-coded `/dev/mmcblk0`. That shape is Raspberry Pi OS's, not DietPi's:
  this image has **no `/etc/rc.local` at all** (PiShrink says so itself — "An
  existing /etc/rc.local was not found, autoexpand may fail...") and no
  `raspi-config`.

  DietPi already ships the equivalent and does it better:
  `dietpi-fs_partition_resize.service` runs *before* `local-fs.target` — far
  earlier than an `rc.local` at the end of boot — uses `sfdisk`/`resize2fs`,
  understands the `/boot/firmware` FAT partition, and reboots itself once if the
  kernel needs to re-read the partition table. Confirmed working on real
  hardware. So we let DietPi own the expansion and tell PiShrink to keep its
  hands off. See `scripts/release/prep-image-source.sh` for the one thing that
  has to be done for it: **re-arming** the service, which deletes its own
  `WantedBy` symlink after it runs.

- **`-n` — no update check.** Upstream otherwise curls the GitHub releases API on
  every run just to print "there's a newer version". A release build shouldn't
  need the network or behave differently on a day GitHub is slow. (It only
  *prints* — it never self-updates — but pinning means we don't want the nag.)

`-z` (gzip) is passed by default, and `-a` (parallel, via `pigz`) when `pigz` is
installed.

## What it actually does to the image

Shrinks the **last** partition — the ext4 root — to its used size, then
truncates the file. The FAT partition is untouched and keeps whatever size it
was built at, which is why `DOC/07-phase5-harden-package.md` Part A2 has to size
FAT for the *smallest* supported card up front: no amount of expanding on the
owner's 32 GB card will ever grow it.
