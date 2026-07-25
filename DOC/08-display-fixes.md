# Display Fixes — the "black screen" saga (real Pi 4)

_Diagnosed on hardware: 2026-07-23 · Pi 4 · DietPi arm64 (Bookworm) · x16emu r49_

Phases 1 & 2 passed and the Phase 3 autostart **ran**, yet the appliance booted to
a **black screen**. It turned out to be **five stacked, independent causes** — each
one alone is enough to produce "connector says *connected* but nothing on screen."
This doc is the field guide so we never re-derive it. The fixes are now baked into
the repo (`scripts/custom.sh`, `scripts/run-x16.sh`, `config/*.snippet`,
`tools/gen_edid.py`).

> **Before anything else — rule out the cable.** An earlier "no video" turned out
> to be a **bad micro-HDMI cable**: the low-speed DDC/EDID line worked (so the TV
> showed "connected" + a mode list) while the high-speed TMDS pairs were dead, so
> no picture. **"connected + enabled + fb created but blank" ⇒ suspect the
> cable/adapter or wrong TV input before touching config.** Swapping the cable fixed it.

---

## The five causes (all now fixed)

### 1. Boot race — emulator launched before the KMS device existed
`custom.sh` started `x16emu` before `/dev/dri/card1` (the vc4 connector) appeared,
so SDL died with `SDL_Init failed: kmsdrm not available` and the loop crash-spun.

**Fix:** `custom.sh` now polls for `/dev/dri/card*` (up to ~15 s) before the first
launch. Forcing the EDID (cause 3) makes the connector appear almost instantly, so
this guard rarely has to wait.

### 2. Mesa GL/EGL/GLES userspace was never installed
The system had only `libgbm.so.1`, `libglapi`, `mesa-libgallium`; `libSDL2` was
hand-bundled, not from apt. SDL's kmsdrm backend modesets fine via libdrm but
**renders through EGL/GLES** — with no `libEGL`/`libGLESv2`/`v3d_dri.so`, the
result is a blank frame.

**Fix (Phase 2 install step):**
```bash
apt install libgl1-mesa-dri libegl1 libgles2 libglx-mesa0 libgbm1
```

### 3. The TV only syncs CEA/HDMI timings, not VESA/DMT
The Commander X16 is **640×480 (VGA / DMT)**. This TV shows **BLACK** for DMT modes
even with EDID "connected", `SETCRTC=0`, and a buffer on the plane. Proven on the
bench: **1920×1080 & 1280×720 (CEA) = visible; 640×480 & 1280×960 (DMT) = blank.**

**Fix — force a synthetic 1080p CEA EDID** that advertises **only** 1920×1080@60
(exact 148.5 MHz timing, CEA **VIC 16**, no 640×480 anywhere). The connector then
offers just the one mode the TV is guaranteed to sync, and SDL scales the X16 into
it. This also cures the cause-1 race (connector comes up instantly instead of
waiting ~15 min on this TV's slow EDID read — the infamous "card1 appears at 926 s").
- Generator: [`tools/gen_edid.py`](../tools/gen_edid.py) → `x16-1080p.edid` /
  `x16-720p.edid` (256 bytes each), installed to `/opt/x16/` on the Pi.
- **Primary mechanism (what is deployed & confirmed working):** the appliance loop
  [`scripts/custom.sh`](../scripts/custom.sh) applies it **at runtime** every launch
  via `apply_edid()` — it writes the EDID to the connector's `edid_override` debugfs
  node and pokes `status=detect`, picking `x16-1080p.edid` or `x16-720p.edid` from
  `X16_OUTPUT`, and skips entirely when `X16_FORCE_EDID=0` (real-EDID / VGA-monitor
  mode). This needs no reboot and auto-detects the connected HDMI connector + card
  minor (Pi 3/Pi 4 safe), so it does **not** depend on a hardcoded `HDMI-A-1`.
- **Optional belt-and-suspenders:** also persist via `/lib/firmware/edid/` + cmdline
  `drm.edid_firmware=HDMI-A-1:edid/x16-1080p.edid` (forces the mode even
  earlier, before `custom.sh` runs). Not required given the runtime override, but
  harmless. Confirm the connector name with `ls /sys/class/drm/` first.

> ### Three traps in the forced-EDID path — all hit on real hardware 2026-07-25
>
> **1. The parameter is `drm.edid_firmware`, not `drm_kms_helper.edid_firmware`.**
> It moved into the DRM core. On the Pi's 6.12 kernel the old name is rejected:
> `drm_kms_helper: unknown parameter 'edid_firmware' ignored`. This fails
> *silently* on screen — the picture still comes up via the `video=` token — so
> the appliance had been running for days with no EDID forcing at all, and
> `custom.sh` was additionally skipping its own runtime fallback because it saw
> the (dead) token on the cmdline. The guard now reads
> `/sys/module/drm/parameters/edid_firmware` instead of parsing cmdline text.
> Verify with: `cat /sys/class/drm/card1-HDMI-A-1/modes` — a long list including
> `640x480` means the TV's real EDID is still in use; forced looks like three
> lines of `1920x1080`.
>
> **2. A synthetic EDID needs an HDMI Vendor Specific Data Block or you lose
> sound.** The kernel decides a sink is HDMI rather than DVI by finding the HDMI
> Licensing IEEE registration `00-0C-03` in a CEA vendor-specific block
> (`drm_detect_hdmi_monitor()`). A DVI sink has no audio path, so vc4-hdmi refuses
> to open the device and SDL reports
> `ALSA: Couldn't open audio device: Unknown error 524` (ENOTSUPP) — the appliance
> loop then falls back to `SDL_AUDIODRIVER=dummy` and runs *silently*. Setting
> basic-audio and an LPCM SAD is **not** sufficient on its own. `gen_edid.py` now
> emits the VSDB; the moment it did, ALSA opened first try with the EDID still
> forced.
>
> **3. The firmware can override your forced EDID with 640x480.** The Pi's
> firmware builds the kernel's `video=` token by reading the TV's EDID *before*
> Linux starts — it knows nothing about `drm.edid_firmware`, which only fixes the
> KERNEL's view. If the TV is off, asleep or slow to answer at power-on, the
> firmware falls back to `video=HDMI-A-1:640x480M@60`, and the kernel injects
> that as a cmdline mode which **outranks** the forced EDID. Caught on hardware
> 2026-07-25 with the appliance scanning out 640x480 — the very DMT mode this
> whole document exists to avoid. It is silent on a tolerant TV.
> Fix: `hdmi_force_hotplug=1` + `hdmi_group=1` + `hdmi_mode=16`, **and**
> `disable_fw_kms_setup=1` (on Pi 4 under full-KMS the firmware ignores the first
> three otherwise). Verify with `grep -o 'video=[^ ]*' /proc/cmdline`, which
> should print nothing at all.
>

### 4. Black screen while the GPU was actually rendering
`kmscube -D /dev/dri/card1` (a spinning-cube GLES test) **worked** — so GLES →
scanout was fine and the problem was x16emu-specific. Cause: `libglx-mesa0` got
pulled in, and SDL then defaulted to the **desktop-GL** renderer, which draws
**black** on Pi 4 KMS.

**Fix:** force the GLES2 renderer —
```sh
export SDL_RENDER_DRIVER=opengles2
```
Now set in both `custom.sh` and `run-x16.sh`.

### 5. Sizing — a user toggle, not a bug
Once it painted, how the 4:3 picture fills the 16:9 TV is a preference:
- `-scale 3` → authentic pixel-correct 4:3, pillarbox bars (fills height).
- `-widescreen -scale 3` → stretch to fill the whole 16:9 panel (**this TV's pick**).

**Fix:** exposed as `X16_DISPLAY` (`authentic`|`widescreen`), `X16_SCALE`,
`X16_OUTPUT` (`1080p`|`720p`) and `X16_FORCE_EDID` in
[`config/x16.conf`](../config/x16.conf) on the boot partition, re-read by
`custom.sh` every relaunch. Change it live over SSH with the interactive
[`scripts/x16-display.sh`](../scripts/x16-display.sh) tool (installed as
`/usr/local/bin/x16-display`) — it edits the conf and `pkill -x x16emu`, and the
appliance loop relaunches with the new look, no reboot.

### 6. No HDMI audio — ALSA error 524 (ENOTSUPP)

Once video worked, x16emu still hard-exited (`rc=255`) with
`SDL_OpenAudioDevice failed: ALSA: Couldn't open audio device: Unknown error 524`,
and `custom.sh` fell back to silent `dummy` audio. **Three stacked causes:**

1. **`dtparam=audio=off`** — DietPi ships headless with HDMI audio off, so the
   connected port had **no sound card** (`dmesg`: `'dmas' … no HDMI audio`), and the
   only ALSA card belonged to the *disconnected* port. Fix: **`dtparam=audio=on`**
   in `config.txt` → both HDMI ports get a `vc4-hdmi` card.
2. **Empty audio ELD** — with a card present, the vc4-hdmi driver still returned
   ENOTSUPP because the connector's **ELD had no audio descriptors**. The synthetic
   EDID advertised video only. Fix: `gen_edid.py` now bakes an **LPCM Short Audio
   Descriptor** (2ch, 32/44.1/48 kHz, 16-bit) into the CEA extension.
3. **Wrong force mechanism** — the runtime **debugfs `edid_override`** forces video
   but never rebuilds the audio ELD (`drm_edid_to_eld` isn't re-run), so the ELD
   stayed empty and audio stayed broken **even with the SAD in the EDID**. Fix:
   force the EDID via the kernel cmdline instead —
   `drm.edid_firmware=HDMI-A-1:edid/x16-1080p.edid` — which runs through
   the normal connector probe and **does** feed the ELD. `custom.sh` now **skips**
   its debugfs override when this cmdline token is present (double-forcing resets
   the ELD and re-breaks audio).

**Confirmed working:** x16emu holds `/dev/snd/pcmC0D0p`, the PCM substream shows
`state: RUNNING owner_pid=<x16emu>`, and a manual `speaker-test -D hw:0,0` returns
`-16` (EBUSY) because the emulator owns the device — all reboot-persistent.

---

## Golden diagnostic path (blank but "connected")

1. **Who owns the scanout plane?**
   `cat /sys/kernel/debug/dri/1/state` — `[fbcon]` = the app isn't showing;
   the app's name = it *is* on the plane (look elsewhere, e.g. GLES/renderer).
2. **Is KMS itself healthy?**
   `strace -f -e trace=ioctl <launch>` and look for `SET_MASTER`, `SETCRTC`,
   `PAGE_FLIP` all returning **0** — if so KMS is fine; the fault is upstream
   (GLES/renderer, cause 4) not modeset.
3. **Does the TV sync this mode at all?**
   `modetest -M vc4 -s 33:<mode>` (keep stdin open: `sleep 999 | modetest …`)
   paints a test pattern — if *that's* black, it's a cause-3 timing issue.
4. **Is it GLES or the app?**
   `kmscube -D /dev/dri/card1` — if the cube shows, GLES→scanout works and the
   problem is app/renderer-specific (cause 4).
5. **What modes does the connector actually offer?**
   `cat /sys/class/drm/card1-HDMI-A-1/modes` — after forcing the EDID this must
   list **only** 1920×1080.

---

## Deploying the whole fix stack (the resume checklist)

1. `custom.sh` — carries the renderer export, KMS wait-guard, connector
   auto-detect, and the runtime `apply_edid()` override. Deploy to
   `/var/lib/dietpi/dietpi-autostart/custom.sh` (see 05-phase3-appliance.md).
2. **Mesa userspace** installed (cause 2) — already present on the Pi 4.
3. **EDID files** in `/opt/x16/` (the runtime override reads them there):
   ```bash
   python3 tools/gen_edid.py x16-1080p.edid   # (and x16-720p.edid)
   sudo cp x16-1080p.edid x16-720p.edid /opt/x16/
   # OPTIONAL early-boot persistence (belt-and-suspenders, not required):
   sudo install -D -m 0644 x16-1080p.edid /lib/firmware/edid/x16-1080p.edid
   # then append to the single cmdline.txt line (confirm connector name first):
   #   drm.edid_firmware=HDMI-A-1:edid/x16-1080p.edid
   ```
4. **`x16.conf`** on the boot partition (`/boot/firmware/x16.conf`).
5. **`x16-display`** tool installed for live changes:
   `sudo install -m 0755 scripts/x16-display.sh /usr/local/bin/x16-display`.
6. **Set autostart to Custom (17)** and **reboot; confirm power-on → X16 visible** —
   the real acceptance test. Then verify `…/HDMI-A-1/modes` shows only 1080p and
   `/var/log/x16-appliance.log` shows a clean launch line.
