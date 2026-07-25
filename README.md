# Commander X16 on Raspberry Pi

Turn a Raspberry Pi 3 or 4 into a **Commander X16 appliance**: power on, and the
machine goes straight to the X16's `READY.` prompt fullscreen on your TV — no
desktop, no login, no shell. Pull the plug when you're done.

This repo holds everything needed to build one: the provisioning scripts, the
boot-partition config snippets, the display/EDID tooling, and phase-by-phase
runbooks written against real hardware.

> **What this is not:** a bare-metal emulator like BMC64. This is a *Linux
> appliance* — a stripped DietPi arm64 image where `x16emu` renders directly to
> KMS/DRM with no desktop in the way. See
> [DOC/01-feasibility-research.md](DOC/01-feasibility-research.md) for the
> bare-metal comparison and why this route was chosen.

---

## Target stack

| Piece | Version / choice |
| --- | --- |
| Hardware | Raspberry Pi 3 or Pi 4, HDMI display, USB keyboard |
| OS | DietPi arm64, Debian Bookworm (`DietPi_RPi234-ARMv8-Bookworm.img.xz`) |
| Emulator | [x16-emulator](https://github.com/X16Community/x16-emulator) **r49** |
| ROM | [x16-rom](https://github.com/X16Community/x16-rom) **r49** (version-locked to the emulator) |
| Graphics | SDL2 KMSDRM backend, `vc4-kms-v3d` full KMS, forced 1080p60 |

The DietPi `.img.xz` is **not** in this repo (too large for git) — download it
from [dietpi.com](https://dietpi.com/#download) and drop it in the repo root.

## Status

- **Phases 1 & 2 passed on real Pi 4 hardware** (2026-07-23): KMS up, `x16emu`
  r49 + ROM installed to `/opt/x16`, X16 boots fullscreen with a working keyboard.
- **Phase 3** (autostart appliance) deployed;
- **Phases 4 & 5** authored and ready, in testing.
- The **black-screen saga is solved** — five stacked display causes diagnosed on
  hardware, with the fixes baked into the scripts and config here. If your screen
  is ever blank, read [DOC/08-display-fixes.md](DOC/08-display-fixes.md) first.
- Phase 5's output (`x16-appliance-r49.img.gz` + end-user README) is the
  shippable distro image.

## Quick start

The condensed bench sheet is
[DOC/00-hardware-day-runsheet.md](DOC/00-hardware-day-runsheet.md) — print it and
work the five gates. In brief:

### 1. Flash and prep the card (on your PC)

Flash the DietPi `.img.xz`, then edit the FAT boot partition:

- merge [config/dietpi.txt.snippet](config/dietpi.txt.snippet) into `dietpi.txt`
- append [config/config.txt.snippet](config/config.txt.snippet) to `config.txt`
- append the [config/cmdline.txt.snippet](config/cmdline.txt.snippet) tokens to
  the **single line** of `cmdline.txt`

### 2. Install the emulator (on the Pi)

```bash
chmod +x ~/scripts/*.sh
~/scripts/install-x16.sh      # SDL2 + x16emu r49 + rom.bin -> /opt/x16
~/scripts/run-x16.sh          # at the PHYSICAL console, not over SSH
```

### 3. Make it an appliance

```bash
sudo install -m 0755 ~/scripts/custom.sh /var/lib/dietpi/dietpi-autostart/custom.sh
sudo dietpi-autostart               # choose 17 (Custom script, no autologin)
sudo reboot
```

> ⚠️ **Run the emulator from the physical console (tty on HDMI), never over
> SSH.** The KMSDRM backend has to become DRM master, which an SSH session
> cannot do.
>
> **Break-in, if the appliance loop has the console:** SSH in, or press
> `Ctrl+Alt+F2` for a fresh VT, then `sudo pkill -f custom.sh; pkill -f x16emu`.
> **Rollback:** set `AUTO_SETUP_AUTOSTART_TARGET_INDEX=7` and reboot.

## Repo layout

```text
DOC/        phase runbooks, research, and the display-fixes post-mortem
config/     boot-partition snippets + appliance settings and systemd units
scripts/    install / launch / autostart / maintenance shell scripts
tools/      EDID and splash-image generators (Python) and their output
dist/       what ships to end users alongside the .img.gz
```

### `scripts/`

| Script | What it does |
| --- | --- |
| [install-x16.sh](scripts/install-x16.sh) | Primary install: arch-aware prebuilt `x16emu` + matching ROM |
| [build-x16-from-source.sh](scripts/build-x16-from-source.sh) | Compile fallback when the prebuilt binary won't run |
| [run-x16.sh](scripts/run-x16.sh) | Manual fullscreen launch for the Phase 2 sanity check |
| [custom.sh](scripts/custom.sh) | The appliance autostart loop (DietPi autostart index 17) |
| [x16-display.sh](scripts/x16-display.sh) | Interactive SSH tool: aspect / scale / resolution / forced EDID, live |
| [appliance-quiet.sh](scripts/appliance-quiet.sh) | Silences the boot so only the X16 is ever on screen |
| [x16-splash.sh](scripts/x16-splash.sh) | Paints the boot splash straight to `/dev/fb0` |
| [fetch-sdcard.sh](scripts/fetch-sdcard.sh) | Populates the `-fsroot` with the community SD-card tree (games, demos, BASIC) |
| [setup-samba.sh](scripts/setup-samba.sh) | Shares the program folder on the LAN so you can drag-drop `.PRG`/`.BAS` files without pulling the card |
| [smoke-test.sh](scripts/smoke-test.sh) | Headless install/launch check for a VM, container, or CI |

### `config/`

| File | What it does |
| --- | --- |
| [dietpi.txt.snippet](config/dietpi.txt.snippet) | DietPi first-boot automation keys |
| [config.txt.snippet](config/config.txt.snippet) | Full-KMS + forced 60 Hz HDMI firmware config |
| [cmdline.txt.snippet](config/cmdline.txt.snippet) | Quiet-boot kernel params + the forced-EDID token |
| [x16.conf](config/x16.conf) | Appliance display/audio settings — lives on the FAT boot partition, so it's editable from any PC |
| [x16-splash.service](config/x16-splash.service) | Systemd unit that paints the splash early in boot |
| [getty-tty1-x16.conf](config/getty-tty1-x16.conf) | tty1 getty override for the appliance |

### `tools/`

[gen_edid.py](tools/gen_edid.py) builds the synthetic 1080p60-only CEA EDID that
fixes TVs which refuse the X16's native 640×480 DMT timing (the black-screen
bug), and also kills the slow-EDID cold-boot race.
[gen_splash.py](tools/gen_splash.py) renders the boot splash to the raw RGB565
blob that `x16-splash.sh` writes to the framebuffer.

## Using the finished appliance

- **Load your own programs:** power off, put the SD card in any PC, and drop
  `.PRG` / `.BAS` files into the `x16/` folder on the small FAT drive that
  appears. `DIR` and `LOAD` then see them from BASIC. To add programs without
  pulling the card, `setup-samba.sh` exposes the same folder as `\\<pi>\X16`.
  On the Pi that folder is `/boot/firmware/x16` — note that on Bookworm
  `/boot/firmware` is the FAT partition and plain `/boot` is ext4 root, so the
  scripts probe for the real FAT mount rather than assuming. It's small
  (~128 MB), sized for a personal selection rather than the whole community
  library.
- **Change the picture:** `sudo x16-display` over SSH — switch between widescreen
  and authentic 4:3, change scale or output resolution, toggle the forced EDID,
  set the gamepad port count. Changes apply on the emulator's next relaunch, no
  reboot. Same settings are editable as [x16.conf](config/x16.conf) on the FAT
  partition from any PC.
- **Gamepads:** plug in before power-on. r49 ignores a pad unless its port is
  enabled with `-joyN`, so the launchers pass one flag per port, driven by
  `X16_JOYSTICKS` (0–4, default 1).
- **Appliance log:** `/var/log/x16-appliance.log`.

### Getting in

| Access | Address | User | Password |
| --- | --- | --- | --- |
| SSH | `<pi-ip>` or hostname (default `DietPi`) | `root` | `dietpi` |
| Samba share | `\\<pi-ip>\X16` | `dietpi` or `x16` | `dietpi` |

> **These are DietPi's stock defaults, published here for convenience on a
> private LAN — they are not secrets.** Anyone who can reach the Pi can use them.
> Change both before putting the machine on a network you don't control:
> `passwd` for the login, `smbpasswd -a <user>` for the share. `setup-samba.sh`
> honours `SMB_USER` / `SMB_PASS` if you'd rather not use the defaults at all:
>
> ```bash
> sudo SMB_USER=me SMB_PASS='something-better' ~/scripts/setup-samba.sh
> ```
>
> Note `unix password sync` is on in DietPi's `smb.conf`, so changing a Samba
> password can rewrite that account's **login** password as a side effect. Turn
> the setting off for the change if you don't want that.

Browsing to `\\<pi-ip>` needs share *enumeration*, which is a separate permission
from reading the share — if that's denied while `\\<pi-ip>\X16` works, see the
`[homes]` note in [setup-samba.sh](scripts/setup-samba.sh). Windows also caches
failed credentials aggressively; `net use * /delete /y` before retrying.

## Documentation

Full index with per-document summaries: [DOC/README.md](DOC/README.md). The
plain-language README that ships with the finished image is
[dist/README-end-user.md](dist/README-end-user.md).

| Doc | Topic |
| --- | --- |
| [00](DOC/00-hardware-day-runsheet.md) | One-page bench run-sheet, all five gates |
| [01](DOC/01-feasibility-research.md) | Feasibility: bare-metal (BMC64-style) vs Linux appliance |
| [02](DOC/02-option-a-plan.md) | The chosen plan — DietPi appliance, decisions and risks |
| [03](DOC/03-phase1-2-runbook.md) | Phase 1–2: DietPi bring-up, KMS check, emulator install |
| [04](DOC/04-testing-on-emulator.md) | Testing the scripts on x86 (Docker / VM) before hardware |
| [05](DOC/05-phase3-appliance.md) | Phase 3: the autostart appliance loop |
| [06](DOC/06-phase4-tune.md) | Phase 4: lock 60 Hz, silence the boot, trim, gamepad |
| [07](DOC/07-phase5-harden-package.md) | Phase 5: harden the SD card, capture the shippable image |
| [08](DOC/08-display-fixes.md) | The black-screen post-mortem and the golden diagnostic path |

## Credits

The Commander X16 is David "the 8-Bit Guy" Murray's project. The emulator and ROM
are built by the [X16Community](https://github.com/X16Community) developers; the
community SD-card contents come from [cx16forum/sdcard](https://github.com/cx16forum/sdcard).
This repo is only the Raspberry Pi appliance packaging around them — it downloads
those upstream releases at install time rather than redistributing them, and they
remain under their own licenses.

## License

[MIT](LICENSE).
