# Parked — 2026-07-30

The Pi 4 appliance image is **built, verified on hardware, and finished**. This
page is for picking the project back up cold. Open items live in
[TODO.md](TODO.md); what was decided and why lives in [DOC/README.md](DOC/README.md).

## The artifact — where it actually is

**GitHub release [v1.0.0](https://github.com/jakebullet70/X16RasPiEmulation/releases/tag/v1.0.0)**,
asset `x16-appliance-r49.zip` (594,901,777 bytes). It is a bundle, not a bare
image — four entries:

```text
        2,016  fat-x16-README.TXT
        9,087  README-end-user.md
          809  RELEASE.md
  599,756,211  x16-appliance-r49.img.gz     crc32 BACF9534
```

The inner `.img.gz` was verified bit-for-bit against the local build on
2026-07-30 — identical size and identical CRC32. Its own hash:

```text
sha256  5d5d4323d09bd03f0068112608ace54993176a3b0dea815e82caacdc499d3d10
```

The image is **not** in the repo — it is gitignored, and GitHub rejects files
over 100 MB in a tree. Release *assets* are a different limit (2 GB), which is
why it lives there. A NAS copy alongside the other retro images
(`\\NASTOWER\retro\`) is worth having as a second copy.

Check the sha256 after any move. A silently truncated image is the exact failure
this project has already lost a day to.

> **The zip cannot be handed to Raspberry Pi Imager as-is.** Its first entry is
> `fat-x16-README.TXT`, and the image inside is doubly compressed (`.gz` within
> `.zip`). Extract the zip first, then point Imager at `x16-appliance-r49.img.gz`.
> See the note in [TODO.md](TODO.md) about attaching the `.img.gz` as a second
> asset so it can be flashed straight from the download.

**Do not rely on the SD card as the archive.** The dev card's value is its
post-`prep` state, and a single boot consumes the first-boot resize arming — the
one failure that produces an image which silently never expands on the owner's
card. Once the `.img.gz` is stored, the card is disposable.

## What was true when it was parked

Verified on a Pi 4 with a freshly flashed **4 GB** card:

| Check | Result |
| --- | --- |
| First-boot resize | 2.3 G → 3.6 G, `df` 3.5 G / 2.0 G free |
| Screen on cold boot | clean — `/dev/vcs1` 0 non-blank chars |
| Scrolling | no tearing |
| Drop folder | `@CD:FAT-FILES` → `@$` → `LOAD` → `RUN` works |
| Kernel errors | 0 |
| Boot | 15.42 s (1.62 kernel + 13.80 userspace) |
| `check-image.sh` | 30 PASS, 0 FAIL, 1 WARN |

The one WARN is baked-in SSH host keys. Accepted on purpose, along with
`/root/.ssh/authorized_keys` shipping the builder's key, no FAT free-space
credential scrub, Pi 4 only (no Pi 5), and testing on a single Pi.

## What you need to resume

**Hardware** — a Pi 4, a card 4 GB or larger, HDMI to a TV, USB keyboard.

**Host** — Windows with WSL Ubuntu. Install `e2fsprogs dosfstools pigz util-linux`.
PiShrink is vendored at `tools/pishrink/pishrink.sh`, so it is not a dependency.

**Access** — `ssh x16raspi` (an alias in `~/.ssh/config` on the Windows box,
pointing at the Pi's **eth0** address, key `id_ed25519_x16raspi`). That config is
*not* in the repo. If it is lost, the image still accepts `root` / `dietpi` over
SSH, so you are not locked out.

## How to rebuild from nothing

The shipped image **is** the build source — it round-trips.

```powershell
# 1. Flash dist\x16-appliance-r49.img.gz to a card and boot it.
#    This consumes the first-boot resize. That is expected; step 3 re-arms it.

# 2. Make your changes on the running Pi.

# 3. Strip dev state and re-arm the resize. Copy the script over first,
#    stripping CR — the repo is CRLF and /bin/dash will not run it otherwise:
#      ssh x16raspi "tr -d '\r' > /tmp/prep.sh" < scripts/release/prep-image-source.sh
#      ssh x16raspi 'bash /tmp/prep.sh'            # dry run, read it
#      ssh x16raspi 'bash /tmp/prep.sh --apply'
#    !! DO NOT REBOOT between this and the capture.

# 4. Capture, label, check, shrink, and copy the artifact back:
.\scripts\release\make-release.ps1 -FromSsh x16raspi -OutDir dist
```

Then flash to a **blank** card and re-run the hardware checks in the table above.
`check-image.sh` gates the build automatically; it runs inside `shrink-image.sh`.

## Traps that will have faded in three months

- **DietPi keeps its own copy of settings somewhere else.** Three separate days
  were lost to this: `dtoverlay=disable-wifi` *plus* a module blacklist; the
  serial-getty unit *plus* `dietpi.txt`; and cmdline `loglevel` *plus*
  `/etc/sysctl.d/97-dietpi.conf`. When a setting appears ignored, go looking for
  DietPi's duplicate before doubting the setting.
- **`console=tty3` does not keep kernel messages off screen.** The kernel writes
  printk to the *foreground* VT whatever you name. `config/98-x16-console.conf`
  is what does it (98 sorts after DietPi's 97). `console=tty3` is kept only to
  redirect *userspace* `/dev/console` writes — which is load-bearing: the
  first-boot resize dumps a screenful there.
- **`/dev/vcsN` is the plain-text buffer of VT N.** It answers "what is actually
  on screen" without a human at the TV. Use it.
- **MBR PARTUUIDs are derived from the disk signature**, not stored — a tool that
  recreates the partition table invalidates `cmdline.txt` with no error anywhere.
- **The resize service ends first boot `failed`.** It runs twice; run 1 does the
  whole job, run 2 dies at a no-op import. Harmless, self-clears, output goes to
  VT3. Do not go hunting.
- **`systemctl reboot` over SSH prints `Failed to connect to bus`** — this image
  has no dbus. It reboots anyway via the direct syscall fallback.
- Host-side quirks are in memory, not here: PowerShell expands `$(...)` before
  bash sees it, and the Bash tool mangles `/mnt/c` paths.

## Nice-to-haves, none of them blocking

A modern UHS-I A1/A2 card (the dev card is a Samsung dated 07/2011 and reads at
5.8 MB/s — it is the boot-time bottleneck, and no overclock helps: the Pi 4's
`sd_overclock` parameter lands on a disabled node). Bundling `x16-gamepad-test`
and `x16-wifi` helpers. The wrong-passphrase Wi-Fi path is still untested.
