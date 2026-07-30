# Phase 5 — Harden & Package (the distributable image)

_Written: 2026-07-22 · Target: Raspberry Pi 3 / 4 · Base: DietPi arm64 (Bookworm)_

The appliance now boots straight into a tuned X16. Phase 5 makes it **durable**
(survive having mains yanked mid-run — the classic Pi-appliance failure mode) and
turns the working SD card into a **shrunk, shareable `.img`** — the actual "distro"
deliverable — plus an end-user README for adding programs.

**Prerequisite gate:** Phase 4 complete — silent boot, locked 60 Hz, gamepad (if
used) and `-fsroot` workflow all verified on the real Pi.

Do **harden first, then image** — you want the protection baked into what you
distribute.

---

## Part A — Harden the SD card against power-cut corruption

A Pi that's left powered and switched off at the wall will eventually corrupt an
ext4 root that was mid-write. Two approaches, cheapest first.

### Option 1 — DietPi-RAMlog (already on; nothing to install)
_Corrected 2026-07-29 — this section used to say "install log2ram". Don't._

Keeps the root filesystem writable but holds the chatty, wear-heavy `/var/log`
in RAM. **DietPi ships this itself and has it enabled by default**, so on this
image the hardening is already in place. Verified on the dev Pi:

```bash
findmnt /var/log
#   TARGET   SOURCE FSTYPE OPTIONS
#   /var/log tmpfs  tmpfs  rw,nosuid,nodev,noatime,lazytime,size=51200k
systemctl is-active dietpi-ramlog      # active
```

The mount comes straight from `/etc/fstab`, so it survives re-imaging without any
action from us.

> **Do not install `log2ram` on top.** It does the same job and both want to own
> `/var/log`. The earlier advice here (`dietpi-software install 137`) would have
> layered a second log-in-RAM system onto one that was already running.
> `check-image.sh` fails an image whose `/var/log` is *not* a tmpfs, and warns if
> `log2ram` is present as well.

The appliance's own log (`/var/log/x16-appliance.log`) lives in RAM as a result —
fine, it's diagnostic, not precious — which is worth remembering when debugging:
it does not survive a power cut.

### Option 2 — Read-only root overlay (strongest; a bit more setup)
Mount root read-only with a RAM overlay so **nothing** persists a write across
reboot — power-cut-proof by construction. DietPi exposes this directly:

```bash
sudo dietpi-config    # → Advanced Options → Overlay filesystem → Enable
sudo reboot
```

Trade-off: to change anything (update the emulator, edit `custom.sh`) you must
toggle the overlay off, make the change, re-enable, reboot. Since user programs go
on the **FAT `/boot` partition** (which stays writable for drops from a PC) this is
usually fine for a locked-down appliance.

> **Decision: DietPi-RAMlog (i.e. the default) for the shipped image.** The
> overlay is stronger, but it also makes every write to the ext4 root vanish on
> reboot — including a `SAVE` into the bundled library, which we want to stay
> writable, and including the Wi-Fi credentials the applier now stores there.
> See "Hardening and the writable library" in Part A2. Either way, the FAT
> partition remains the user's drop zone for `.prg`/`.bas` files and persists
> under both options.

**Gate (harden):** after enabling, cold-boot the Pi, pull power mid-session a few
times, and confirm it still boots straight to the X16 with no fsck stall or
corruption.

---

## Part A2 — Card layout: 256 MB FAT + bind-mounted drop folder

_Decided 2026-07-25, after testing the X16's host filesystem on hardware._

Owners supply their own card, **4 GB to 32 GB**. That single fact drives the whole
layout, because **the FAT partition's size is fixed when the image is built** —
PiShrink's auto-expand grows the *last* partition (root), never FAT. So FAT must
fit the *smallest* supported card, and every owner gets that same size no matter
how big their card is.

A 4 GB card is ~3.7 GiB usable and the installed system needs ~1.4 GB, so:

| FAT size | Root left on a 4 GB card | Verdict |
|---|---|---|
| 3 GB | ~0.7 GB | **won't boot** |
| 1 GB | ~2.7 GB | works, tight-ish |
| 512 MB | ~3.2 GB | more than anyone needs |
| 256 MB | ~3.4 GB | briefly chosen, then reverted |
| **128 MB** (DietPi stock) | ~3.5 GB | **chosen** — leave it alone |

**Settled 2026-07-29: ship DietPi's stock 128 MB and don't repartition at all.**
The boot files take ~33 MB, leaving ~97 MB free — still thousands of `.PRG`
files, since they are tens of kilobytes each. Nobody hand-copies gigabytes of
them, and every megabyte not given to FAT goes to the root filesystem, which is
the partition that actually runs out on a 4 GB card.

Enlarging it was tried and walked back. It is not free: FAT can only be resized
at build time, by rebuilding the partition table offline, and that rewrite is
what let an unbootable image through — see "the disk identifier" in Part B.
The capability still exists in [`refit-fat.sh`](../scripts/release/refit-fat.sh)
if a future release genuinely needs a bigger drop folder, but the default is now
`-FatMB 0`: no refit, no partition table rewrite, nothing to get wrong.

**Changing it is a build-time job and nothing else.** FAT cannot be grown on a
running Pi — the ext4 root would have to start later, and you cannot move the
start of a mounted root filesystem. [`scripts/release/refit-fat.sh`](../scripts/release/refit-fat.sh)
does it offline, between capture and shrink, preserving the MBR disk identifier,
the root filesystem UUID (raw partition copy) and the FAT volume serial
(`mkfs.vfat -i`) — so `cmdline.txt`'s `root=PARTUUID=` and both `/etc/fstab`
lines keep resolving and need no edits. Verified end to end: 128 MB → 256 MB with
all three identifiers unchanged and 424/424 boot files copied.

### The split

The two kinds of content have different needs, so they live in different places:

- **The bundled community library** (~250 MB) is too big for FAT and does not need
  to be reachable from a PC → **ext4 root**, where space is plentiful.
- **The owner's own programs** are small but *must* be PC-writable → **FAT**.

Note "does not need to be reachable from a PC" — **not** "read-only". The ext4 root
is mounted `rw` and the X16 can `SAVE` anywhere in the library (verified on
hardware). The split is about *size* and *PC visibility*, not about write access.
The only thing that would make the library read-only is the hardening choice
below — see "Hardening and the writable library".

`x16emu` takes only one `-fsroot`, so the FAT folder is **bind-mounted into the
library as a subdirectory**:

```sh
mount --bind /boot/firmware/x16 <fsroot>/FAT-FILES
```

**Put the library in `/mnt/x16`, not `/boot/x16`.** On Bookworm `/boot` is the
ext4 root and the card's FAT partition is `/boot/firmware` — so a path like
`/boot/x16` reads as "on the card, visible from a PC" while being nothing of the
sort. That is precisely the misreading that made the original "drop files on the
card" workflow silently not work. `/mnt/x16` is unambiguous and matches where
DietPi keeps bulk data. (Same partition either way; only the name changes.)

The owner sees one drive on their PC; the X16 sees the library at the root with
their own files in `FAT-FILES`.

### Verified on hardware (r49, 2026-07-25)

Tested headlessly with `x16emu -bas … -run -echo -warp` under
`SDL_VIDEODRIVER=dummy`, so it needs no display:

- `DOS"CD:FAT-FILES"` + `DOS"$"` lists the subdirectory correctly.
- `LOAD"FAT-FILES/SUB.PRG",8` works **without** changing directory first.
- `DOS"CD:FAT-FILES"` then `LOAD"SUB.PRG",8` also works.
- Across the bind mount, the X16 sees files placed on the FAT side from a PC.
- **`SAVE` writes back through the bind mount onto the FAT partition** — so it's
  two-way, and an owner can save their own work and copy it off on a PC.

Gotcha: the `@` shorthand (`@$`, `@CD:NAME`) is **immediate mode only**. Inside a
numbered BASIC program it is a `?SYNTAX ERROR`; use the `DOS"…"` form there. The
`@` form is what to put in user-facing docs, since that's what people type.

`dist/fat-x16-README.TXT` ships in that FAT folder to explain all of this to the
owner — it's the first thing they see when they open the card.

### Implemented in `custom.sh`

`drop_attach()` performs the bind on every loop iteration, after re-reading
`x16.conf`. It is idempotent (re-binding is a no-op), re-binds if `X16_FSROOT`
changes under it, skips itself when the fsroot already *is* the FAT folder, and
rejects a `X16_DROP_DIR` containing `/`, `.` or `..` so the name cannot escape the
fsroot. Crucially it **refuses to bind over a non-empty directory** — a bind mount
hides whatever is underneath, and silently making someone's files disappear is
exactly the kind of quiet failure this project keeps getting bitten by. All six
behaviours were exercised on hardware.

### Hardening and the writable library

This is where "read-only" would stop being a figure of speech. The two options in
Part A are **not** equivalent for this layout:

| Hardening | FAT drop folder | ext4 library |
|---|---|---|
| DietPi-RAMlog (default) | writable, persists | **writable, persists** |
| Read-only overlay | writable, persists | writable, **discarded on reboot** |

Under the overlay, a `SAVE` into the library appears to work and is gone after a
power cycle — the worst possible failure shape. So: **ship the default (DietPi-RAMlog)**, and keep
the overlay as an option for anyone who wants a truly sealed unit and understands
that only `FAT-FILES/` then survives. The user-facing README already tells owners
to save into `FAT-FILES` (it is the only folder their PC can read anyway), so the
common path is safe either way.

## Part B — Capture the distributable image

Turn the working, hardened SD card into a compact `.img` others can flash. All
four steps are scripted in [`scripts/release/`](../scripts/release/) — the prose
below is why, the scripts are what to run.

```powershell
# Windows, one command, drives WSL Ubuntu for the Linux-only parts:
.\scripts\release\make-release.ps1 -FromDevice /dev/sdb     # or -FromSsh x16raspi
```

### B.0 Re-arm the first-boot resize — the step that silently ruins an image

**Do this on the Pi before capturing anything.** DietPi expands the root
filesystem on first boot from `dietpi-fs_partition_resize.service`, and the first
thing that service does is delete its own `WantedBy` symlink:

```sh
rm -Rfv /etc/systemd/system/*.wants/dietpi-fs_partition_resize.service
    # -- /var/lib/dietpi/services/fs_partition_resize.sh
```

So on any Pi that has booted more than once the service reads `disabled`
(verified on the dev Pi: it does), and an image captured from it expands on
nobody's card. The owner just gets a root filesystem the size of *our* build
card, silently, with a 32 GB card mostly unused and no error anywhere.

```bash
sudo scripts/release/prep-image-source.sh            # dry run, lists everything
sudo scripts/release/prep-image-source.sh --apply
sudo poweroff        # NOT reboot — a reboot runs the resize and disarms it again
```

That script also strips what must not travel: our Wi-Fi credentials and the
applier's fingerprint stamp (a shipped stamp makes the owner's first edit look
"unchanged", so it is ignored), the `config.txt.bak-*` / `cmdline.txt.bak-*`
litter this project has accumulated, Windows' `System Volume Information`
folder, logs and shell history.

> Older notes said to reset the state by removing `/var/lib/dietpi/.fs_partition_resize`.
> There is no such file on this DietPi version — the enable symlink *is* the
> state, and `systemctl enable` is what puts it back.

### B.1 Read the card to an image

```bash
scripts/release/capture-image.sh --from-device /dev/sdX   # card in a USB reader
scripts/release/capture-image.sh --from-ssh root@<pi-ip>  # live, over the network
```

Prefer the reader: the filesystem is not mounted, so the capture is a clean
point-in-time copy. The over-SSH route is a snapshot of a live, mounted,
read-write filesystem and lands slightly inconsistent — it survives in practice
only because PiShrink runs `e2fsck -pf` before resizing and repairs it.

The script refuses a partition rather than a whole disk, refuses the machine's
own root disk, checks free space, warns if the resize is not armed, and fails if
the copy comes out shorter than the card. `dd` to the wrong disk is unrecoverable
and there is no undo, so none of those guards are decoration.

> On Windows there is no `dd` or PiShrink — use WSL Ubuntu (already installed on
> this box). Win32DiskImager can *read* a card to `.img` but cannot shrink it.

### B.2 Refit the FAT partition to its shipped size

```bash
scripts/release/refit-fat.sh --fat-mb 256 x16-appliance-r49-raw.img -o x16-appliance-r49.img
```

This has to happen here — not on the Pi, not on the card. Growing FAT means the
ext4 root starts later, and the start of a mounted root filesystem cannot move.
There is no live path for it on any system.

It rebuilds the partition table and copies both partitions into a new image,
preserving the three identifiers that would otherwise need chasing afterwards:
the MBR disk id (so `cmdline.txt`'s `root=PARTUUID=` still resolves), the root
filesystem UUID (the root partition is copied raw, so it *is* the same
filesystem), and the FAT volume serial via `mkfs.vfat -i` (so `/etc/fstab`'s
`UUID=` line still mounts `/boot/firmware`). Nothing inside either filesystem is
touched and no config needs editing. It verifies all three before exiting.

`--label` names the drive too, and now defaults to `X16PI` — a refit does a fresh
`mkfs.vfat`, so without that default it would silently strip a label already set.

### B.2a Name the FAT drive

```bash
scripts/release/set-fat-label.sh --label X16PI x16-appliance-r49.img
```

Needed as its own step because **the refit above is off by default** — FAT stays
at DietPi's stock 128 MB — and `refit-fat.sh` was the only thing that had ever
set a label. So the shipped card came out unlabelled, showing the owner
"Removable Disk (E:)" while `dist/README-end-user.md` told them to look for a
drive named `X16PI`.

Offline, like the refit, but for a different reason: on the Pi `/boot/firmware` is
mounted *and* its `x16/` folder is bind-mounted into the running emulator's
fsroot, so the kernel's cached boot sector can overwrite a live `fatlabel` when it
unmounts. On an image nothing is mounted and the result is deterministic.

It clears the FAT dirty bit first — a capture from a running Pi always has it set,
and `fatlabel` refuses to write to a volume flagged dirty — then refuses to finish
if the **FAT volume serial** changed, because `/etc/fstab` mounts
`/boot/firmware` by it and the image would boot with no boot partition.

### B.3 Check before you shrink

```bash
scripts/release/check-image.sh x16-appliance-r49.img
```

Loop-mounts both partitions read-only and asserts the things that have nearly
shipped wrong: resize armed, autostart index 17, emulator and ROM present,
library non-empty, no Wi-Fi credentials or stamps, no `.bak` litter, no
`System Volume Information`, `x16.conf` and `README.TXT` where the owner will
look. It also prints the FAT partition's label and size, because
`dist/README-end-user.md` makes claims about both to the owner's face.

Run before shrinking — PiShrink replaces the `.img` with a `.img.gz`, and a
failure is much cheaper to find before the shrink than after.

### B.4 Shrink it with PiShrink

```bash
scripts/release/shrink-image.sh x16-appliance-r49.img
# -> x16-appliance-r49.img.gz, ~600 MB from a 32 GB capture
```

PiShrink is **vendored at a pinned commit** in
[`tools/pishrink/`](../tools/pishrink/) rather than `wget`-ed at release time, so
a build is reproducible. It shrinks the last partition — the ext4 root — to its
used size. The FAT partition is untouched, which is the whole reason Part A2 has
to size FAT for the smallest supported card up front.

**We pass `-s`, which disables PiShrink's own first-boot expansion.** That is
deliberate, not an oversight. PiShrink expands by writing its own `/etc/rc.local`
that calls `raspi-config --expand-rootfs` — Raspberry Pi OS's mechanism. This
image is DietPi: it has no `/etc/rc.local` at all (PiShrink says as much:
"An existing /etc/rc.local was not found, autoexpand may fail...") and no
`raspi-config`, leaving only PiShrink's fallback, which drives `fdisk` against a
hard-coded `/dev/mmcblk0` from the end of boot. DietPi's own resizer runs
*before* `local-fs.target`, understands the `/boot/firmware` FAT partition, and
reboots itself once if the kernel needs to re-read the partition table. Confirmed
working on hardware. So DietPi owns the expansion and PiShrink keeps its hands
off — which is exactly why B.0 exists.

### The disk identifier — how an image passed every check and still couldn't boot

_Found the hard way, 2026-07-29._

`cmdline.txt` tells the kernel where its root filesystem is:

```text
root=PARTUUID=6a31ef16-02
```

On an MBR disk a PARTUUID is **derived**, not stored: it is the 4-byte disk
signature from the MBR, plus the partition number. So `6a31ef16-02` means
"partition 2 of the disk whose signature is `0x6a31ef16`". Change the signature
and that string stops resolving — while still looking perfectly correct in every
file you might inspect.

PiShrink shrinks by **deleting and recreating the last partition** with `parted`
([`pishrink.sh` lines 392-399](../tools/pishrink/pishrink.sh)), and the rebuilt
table came back with a different signature. The result:

- the firmware read the FAT fine and ran `start4.elf` (the display even woke up),
- the kernel loaded,
- it looked for `PARTUUID=6a31ef16-02`, found no such partition,
- and `rootwait` did exactly what it says — waited, forever,
- silently, because `cmdline.txt` also carries `quiet loglevel=0`.

A completely black screen and no diagnostic anywhere. The image mounted
perfectly on a PC, every file was byte-identical to a known-good build, and the
first `check-image.sh` reported "no failures".

Two things now prevent it:

1. **`shrink-image.sh` records the disk id before PiShrink and restores it
   after** (`sfdisk --disk-id`), then re-runs the check. Compression moved out of
   PiShrink's hands (`-z` dropped) so the repair happens while the result is
   still a raw image.
2. **`check-image.sh` verifies that the identifiers actually resolve** — that
   `cmdline.txt`'s `root=PARTUUID` matches the image's real MBR signature, and
   that each `UUID=` in `/etc/fstab` matches the real filesystem. This is a
   FAIL, not a warning: nothing else in the audit matters if the machine cannot
   find its root.

The general lesson is worth keeping: **an identifier that is derived from
something else can be invalidated by a tool that never touched the file
containing it.** Verifying that the file says the right thing is not the same as
verifying that what it says is true.

### B.5 Verify the image actually works

The most common packaging failure is shipping an image that boots on *your* card
but not a fresh one. Flash the shrunk image to a **different, blank SD card**,
boot a Pi from it, and re-run the Phase 3 gate:
- powers on to the X16 fullscreen, keyboard + audio work,
- a `.prg` dropped on the FAT `x16/` folder from a PC loads (it appears inside
  the X16 as `FAT-FILES`),
- root partition auto-expanded (`df -h /`), `/var/log` still a tmpfs.

**Gate (package):** the shrunk `.img.gz`, flashed to a blank card, reproduces the
full appliance on a second Pi.

---

## Part C — End-user README (ships with the image)

**Written — see [`dist/README-end-user.md`](../dist/README-end-user.md).** Ship it
alongside `x16-appliance-r49.img.gz`. Re-check it against the final image before
release (especially the FAT drive's label and free space, which the user sees).

It covers only what a user needs:

1. **Flash it** — Raspberry Pi Imager → "Use custom image" → the `.img.gz` → your
   SD card. Pi 3 or Pi 4.
2. **First boot** — plug in HDMI + USB keyboard + power; it boots straight to the
   Commander X16 `READY.` prompt. First boot auto-expands the card (a few extra
   seconds, once).
3. **Add your programs** — power off, put the SD card in your PC, open the small
   FAT drive that appears, drop `.prg`/`.bas` files into the `x16/` folder,
   eject, boot the Pi. Inside the X16 they are in `FAT-FILES`: `@CD:FAT-FILES`,
   `@$`, then `LOAD"NAME.PRG",8` and `RUN`. (There is no `DIR` command — `@$` is
   the list command, and `@` works in immediate mode only.)
4. **Version** — this image is x16-emulator **r49** + matching ROM. To move to a
   newer X16 release, a new image will be published (the appliance is image-based,
   not apt-updatable by design).
5. **Gamepad / audio** — plug a USB controller before boot; sound comes out the
   HDMI display.

---

## Exit criteria (Phase 5 — and Option A — complete)
- SD card hardened (DietPi-RAMlog **or** read-only overlay) and survives power-cut
  testing.
- A shrunk, auto-expanding `x16-appliance-r49.img.gz` exists and has been verified
  by flashing to a **blank** card and booting a second Pi through the Phase 3 gate.
- An end-user README ships with the image.

## Update path (post-1.0)
The X16 is a moving target (ROM/VERA revisions). To cut a new release: bump
`X16_VER` in `scripts/install-x16.sh`, re-run Phases 2→5 on a build card (or
toggle the overlay off, re-run the installer, re-image), and publish a new
`.img.gz`. Re-flashing is heavier than `apt` — the deliberate trade-off for the
sealed-appliance feel (see `02-option-a-plan.md`).

## Troubleshooting
| Symptom | Likely cause / fix |
|---|---|
| `dd` wrote nothing / to the wrong disk | Wrong device — re-check `lsblk`; target the whole card `/dev/sdX`, never a partition. |
| Shrunk image won't boot on a new card | PiShrink auto-expand needs the root to be the last partition; don't manually repartition after shrinking. Re-image from a clean capture. |
| First boot doesn't auto-expand | Confirm you shrank with PiShrink (it installs the expand-on-boot hook); a raw `dd` image won't expand itself. |
| Corruption returns after power cuts | Hardening not actually active — re-check `findmnt /var/log` shows tmpfs, or that the overlay is enabled in `dietpi-config`. |
| Can't edit the appliance after read-only overlay | Expected — toggle the overlay off in `dietpi-config`, change, re-enable, reboot. |
| No `dd`/PiShrink on Windows | Use WSL Ubuntu (already installed), a Linux VM, or the Pi + USB reader. |
