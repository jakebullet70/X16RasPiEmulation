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
- **Phase 3** (autostart appliance) deployed.
- **Phase 4** essentially complete — 60 Hz locked, boot silenced and trimmed to
  ~23 s power-on to `READY.`, gamepad working. Only the eyeball checks remain.
- **Phase 5** is where the work is now: the release is scripted end to end
  ([scripts/release/](scripts/release/)) and PiShrink is vendored. Hardening turned
  out to be already done (DietPi-RAMlog keeps `/var/log` in RAM by default — the
  earlier plan to install `log2ram` was wrong). What's left is cutting the image
  with a 256 MB FAT partition and the second-Pi flash test.
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
DOC/               phase runbooks, research, and the display-fixes post-mortem
config/            boot-partition snippets + appliance settings and systemd units
scripts/           install / launch / autostart / maintenance shell scripts
scripts/release/   cutting the shippable image: prep, capture, check, shrink
tools/             EDID and splash-image generators (Python) and their output
tools/pishrink/    PiShrink, vendored at a pinned commit
dist/              what ships to end users alongside the .img.gz
```

### `scripts/`

| Script | What it does |
| --- | --- |
| [install-x16.sh](scripts/install-x16.sh) | Primary install: arch-aware prebuilt `x16emu` + matching ROM |
| [build-x16-from-source.sh](scripts/build-x16-from-source.sh) | Compile fallback when the prebuilt binary won't run |
| [run-x16.sh](scripts/run-x16.sh) | Manual fullscreen launch for the Phase 2 sanity check |
| [custom.sh](scripts/custom.sh) | The appliance autostart loop (DietPi autostart index 17) |
| [x16-display.sh](scripts/x16-display.sh) | Interactive SSH tool: aspect / scale / resolution / forced EDID, live |
| [x16-wifi.sh](scripts/x16-wifi.sh) | Interactive SSH tool: turn the radio on/off, scan, join a network |
| [gamepad-test.sh](scripts/gamepad-test.sh) | Diagnose a USB pad — asks libSDL2 directly whether it's usable |
| [appliance-quiet.sh](scripts/appliance-quiet.sh) | Silences the boot so only the X16 is ever on screen |
| [x16-splash.sh](scripts/x16-splash.sh) | Paints the boot splash straight to `/dev/fb0` |
| [fetch-sdcard.sh](scripts/fetch-sdcard.sh) | Populates the `-fsroot` with the community SD-card tree (games, demos, BASIC) |
| [setup-samba.sh](scripts/setup-samba.sh) | Shares the program folder on the LAN so you can drag-drop `.PRG`/`.BAS` files without pulling the card |
| [smoke-test.sh](scripts/smoke-test.sh) | Headless install/launch check for a VM, container, or CI |

### `scripts/release/`

Cutting the distributable image. Windows entry point:
`.\scripts\release\make-release.ps1 -FromDevice /dev/sdb` (or `-FromSsh <host>`),
which runs the rest inside WSL Ubuntu.

| Script | Runs on | What it does |
| --- | --- | --- |
| [prep-image-source.sh](scripts/release/prep-image-source.sh) | the Pi | Re-arms DietPi's first-boot resize (it disarms itself after every run) and strips Wi-Fi credentials, `.bak` litter, logs. Dry-run by default |
| [capture-image.sh](scripts/release/capture-image.sh) | WSL / Linux | Reads the card to a raw `.img` — from a USB reader, or over SSH from a running Pi |
| [refit-fat.sh](scripts/release/refit-fat.sh) | WSL / Linux | Rebuilds the capture with a bigger FAT partition — impossible on a live card, since the root's start has to move. Preserves PARTUUIDs and both filesystem UUIDs, so no `cmdline.txt`/`fstab` edits |
| [check-image.sh](scripts/release/check-image.sh) | WSL / Linux | Read-only audit of a capture before it ships: resize armed, no credentials on either partition, autostart index, `/var/log` in RAM, FAT size and label |
| [shrink-image.sh](scripts/release/shrink-image.sh) | WSL / Linux | Shrink + gzip through the vendored PiShrink (`-s -n`) |

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
  appears. Inside the X16 that folder is `FAT-FILES` (bind-mounted into the
  library, which is the `-fsroot`): `@CD:FAT-FILES`, `@$` to list, then
  `LOAD"NAME.PRG",8`. There is no `DIR` command. To add programs without pulling
  the card, `setup-samba.sh` exposes the same folder as `\\<pi>\X16`.
  On the Pi that folder is `/boot/firmware/x16` — note that on Bookworm
  `/boot/firmware` is the FAT partition and plain `/boot` is ext4 root, so the
  scripts probe for the real FAT mount rather than assuming. It's small
  (256 MB in the shipped image), sized for a personal selection rather than the whole community
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

### Wi-Fi

The appliance is **Ethernet-only by default**. [config.txt.snippet](config/config.txt.snippet)
sets `dtoverlay=disable-wifi`, which removes the radio at the device-tree level —
quieter and slightly faster to boot, and the emulator needs no network at all.

**On a shipped image the owner just edits a file.**
[x16-wifi.conf](config/x16-wifi.conf) sits on the FAT partition next to
`x16.conf`; [x16-wifi-apply.sh](scripts/x16-wifi-apply.sh) (run at boot by
[x16-wifi-apply.service](config/x16-wifi-apply.service)) reads it, and if an SSID
is set while the radio is still disabled it removes the overlay and reboots once
to load the driver. No loop is possible: removing the line from `config.txt` is
persistent, so the condition is false next boot — and it only reboots after
verifying the edit stuck, since on a read-only or full card the write could fail.
With no SSID set it exits in ~16 ms, so Ethernet-only machines pay nothing.

**The credentials are consumed, not stored.** Once a join actually succeeds, the
applier clears `X16_WIFI_SSID` and `X16_WIFI_PSK` from the card and the only
remaining copy is `wpa_supplicant.conf` on ext4, mode 0600. So the Wi-Fi password
does not sit in plain text on a partition every PC can read for the life of the
machine, and the owner's card returns to blank — which is also the "do nothing"
state, so `dietpi-config`'s settings stand untouched from then on. A **failed**
join deliberately leaves the file alone, so a typo'd passphrase stays on screen
to be corrected. `X16_WIFI_COUNTRY` is always carried across the reset and never
left blank: DietPi prints a boot-time warning without one, and the whole Phase 4
premise is that nothing but the X16 is ever on screen.

This replaced a fingerprint stamp (`.x16-wifi.state`) that had to be reasoned
about at every turn — it could ship stale and make an owner's first edit look
"unchanged" and be silently ignored. Blank-means-idle removes the failure mode
rather than guarding against it. One accepted trade: an SSID that never
associates, left on the card while Wi-Fi is *then* disabled in `dietpi-config`,
gets the radio re-enabled and one reboot. It cannot loop, and cannot happen at
all once a join has succeeded.

**Either way it tells you what happened.** After any attempt the Pi writes
`x16-wifi-status.txt` next to the config — plain language, CRLF for Notepad —
saying it connected and on what address, or why it couldn't and what to check.
That is the only feedback an owner with no shell can get.

> The consume-and-clear design is **incompatible with the Phase 5 read-only
> overlay** option: credentials would live only on ext4, be discarded at reboot,
> and the card would already be blank — leaving Wi-Fi permanently unsettable.
> The shipped image keeps the root writable (DietPi-RAMlog), where this is not an issue.

Easiest route on a running Pi is `sudo x16-wifi`
([x16-wifi.sh](scripts/x16-wifi.sh)) — it shows the radio state up front, toggles
the overlay for you, scans, and joins. It deliberately **refuses** to save
credentials while the radio is off, rather than letting them silently do nothing.

Doing it by hand instead, all three of these are required:

1. **Delete `dtoverlay=disable-wifi`** from `config.txt`. Miss this and the rest
   does nothing — `wlan0` never appears, so correct credentials simply have no
   interface to use, with no error to tell you.
2. Fill in `dietpi-wifi.txt` on the FAT boot partition (SSID + key; editable from
   any PC with the card inserted).
3. Set `AUTO_SETUP_NET_WIFI_ENABLED=1` in `dietpi.txt`.

Then reboot. On a running Pi, `sudo dietpi-config` → *Network Options: Adapters*
does the same interactively. Check with `ip -brief addr` — you want a `wlan0`
line with an address.

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
| [09](DOC/09-bare-metal-review.md) | Bare metal revisited: what it would and wouldn't have saved us |

## Credits

The Commander X16 is David "the 8-Bit Guy" Murray's project. The emulator and ROM
are built by the [X16Community](https://github.com/X16Community) developers; the
community SD-card contents come from [cx16forum/sdcard](https://github.com/cx16forum/sdcard).
This repo is only the Raspberry Pi appliance packaging around them — it downloads
those upstream releases at install time rather than redistributing them, and they
remain under their own licenses.

One exception, deliberately: [PiShrink](https://github.com/Drewsif/PiShrink) by
Drew Bonasera is **vendored** in [tools/pishrink/](tools/pishrink/) at a pinned
commit, MIT-licensed, with its `LICENSE` alongside. A release build should be
reproducible, and `wget`-ing a script off `master` at release time is not.

## License

[MIT](LICENSE).
