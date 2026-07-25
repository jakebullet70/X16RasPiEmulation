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

### Option 1 — `log2ram` (light; keeps the system writable)
Keeps the root filesystem writable but moves the chatty, wear-heavy `/var/log`
into RAM, flushing to disk periodically. Cuts the write rate dramatically without
the constraints of a fully read-only root.

```bash
# DietPi ships log2ram in dietpi-software (recommended path):
sudo dietpi-software install 137     # 137 = Log2Ram  (verify the ID in the menu)
# or upstream:
#   echo "deb [signed-by=...] https://azlux.fr/repo/debian/ bookworm main" ...
#   sudo apt-get update && sudo apt-get install -y log2ram
sudo reboot
# After reboot, confirm /var/log is a tmpfs mount:
mount | grep -i log2ram   # or: df -h /var/log  -> tmpfs
```

Good enough for most; the appliance's own log (`/var/log/x16-appliance.log`) then
lives in RAM too (fine — it's diagnostic, not precious).

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

> **Pick one.** `log2ram` for a unit you'll tweak occasionally; read-only overlay
> for a truly sealed appliance. Either way, the `/boot` FAT partition remains the
> user's drop zone for `.prg`/`.bas` files.

**Gate (harden):** after enabling, cold-boot the Pi, pull power mid-session a few
times, and confirm it still boots straight to the X16 with no fsck stall or
corruption.

---

## Part B — Capture the distributable image

Turn the working, hardened SD card into a compact `.img` others can flash.

### B.1 Read the card to an image (on a Linux box or the Pi itself via USB reader)
```bash
# Identify the card device FIRST (do NOT guess — dd to the wrong disk is fatal):
lsblk -o NAME,SIZE,MODEL,TRAN
# Say it's /dev/sdX (the whole card, not a partition like /dev/sdX1):
sudo dd if=/dev/sdX of=x16-appliance-r49.img bs=4M status=progress conv=fsync
sync
```
> On Windows there's no `dd`/PiShrink natively — do this step from WSL (Ubuntu is
> already installed on this box), a Linux VM, or the Pi itself with a USB card
> reader. Win32DiskImager can *read* a card to `.img` but won't shrink it (B.2).

### B.2 Shrink it with PiShrink (so the download isn't the whole card size)
A full `dd` image is as large as the SD card. **PiShrink**
(<https://github.com/Drewsif/PiShrink>) shrinks the root partition to its used
size and makes it **auto-expand on first boot** on whatever card the user flashes.
```bash
wget https://raw.githubusercontent.com/Drewsif/PiShrink/master/pishrink.sh
chmod +x pishrink.sh
sudo ./pishrink.sh -z x16-appliance-r49.img   # -z also gzips the result
# Produces x16-appliance-r49.img.gz — the shippable artifact.
```

### B.3 Verify the image actually works
The most common packaging failure is shipping an image that boots on *your* card
but not a fresh one. Flash the shrunk image to a **different, blank SD card**,
boot a Pi from it, and re-run the Phase 3 gate:
- powers on to the X16 fullscreen, keyboard + audio work,
- a `.prg` dropped on `/boot/firmware/x16` from a PC loads,
- root partition auto-expanded (`df -h /`), overlay/log2ram still active.

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
   FAT drive that appears (`boot`), drop `.prg`/`.bas` files into the `x16/`
   folder, eject, boot the Pi. Inside the X16: `DIR`, then `LOAD"NAME"` and `RUN`.
4. **Version** — this image is x16-emulator **r49** + matching ROM. To move to a
   newer X16 release, a new image will be published (the appliance is image-based,
   not apt-updatable by design).
5. **Gamepad / audio** — plug a USB controller before boot; sound comes out the
   HDMI display.

---

## Exit criteria (Phase 5 — and Option A — complete)
- SD card hardened (`log2ram` **or** read-only overlay) and survives power-cut
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
| Corruption returns after power cuts | Hardening not actually active — re-check `mount | grep log2ram` or that the overlay is enabled in `dietpi-config`. |
| Can't edit the appliance after read-only overlay | Expected — toggle the overlay off in `dietpi-config`, change, re-enable, reboot. |
| No `dd`/PiShrink on Windows | Use WSL Ubuntu (already installed), a Linux VM, or the Pi + USB reader. |
