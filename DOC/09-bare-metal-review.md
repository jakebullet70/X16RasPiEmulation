# Bare-metal (BMC64-style) — review after building the Linux appliance

_Written: 2026-07-25 · Revisits [`01-feasibility-research.md`](01-feasibility-research.md)
Option B, with the benefit of having actually shipped Option A on hardware._

The original feasibility doc judged Option B "hard, but not blocked", weeks-to-
months, integration being the cost. Having now debugged the Linux appliance on
real hardware, that estimate holds — but **the risk sits somewhere different than
we assumed**, and some of the arguments for bare metal turn out to be stronger
than expected while the headline one is weaker.

## The display bugs, sorted by whether bare metal would have helped

The tempting reading of [`08-display-fixes.md`](08-display-fixes.md) is "Linux was
the problem; bare metal avoids it." Sorting the eight real display/audio faults we
actually hit says otherwise:

| Fault | On bare metal |
|---|---|
| Missing Mesa userspace (`libGLESv2`) | **Gone** — no GL stack at all |
| SDL desktop-GL renderer drew a black frame | **Gone** — but only if you *don't* link SDL |
| Boot race: SDL started before DRM was ready | **Gone** — no init system to race |
| `drm.edid_firmware` vs `drm_kms_helper.edid_firmware` | **Gone** — no DRM |
| SDL sizing / logical-scale toggle | Inherited, if you link SDL-on-Circle |
| **TV refuses the X16's native 640x480 DMT signal** | **Stays** |
| **Missing HDMI VSDB → sink read as DVI → no audio** | **Stays** |
| **Firmware injected `video=HDMI-A-1:640x480M@60`** | **Stays** — Circle uses the same VideoCore firmware |

Five vanish. Three don't — and the three that remain are the ones that cost the
most time, because they failed *silently*.

That is the crux of the whole assessment: **you would re-solve the hardest bugs
with none of the tools that solved them.** Every one was cracked with `ssh`,
`/sys`, `dmesg`, and headless `x16emu` runs under `SDL_VIDEODRIVER=dummy`. On
Circle you get a serial UART and an LED. This project's own history is the
evidence — almost nothing failed loudly.

## What genuinely gets better (more than we credited)

- **Storage collapses into something simpler.** The entire 512 MB-FAT / ext4 /
  bind-mount / `FAT-FILES` design in [`07`](07-phase5-harden-package.md) Part A2
  exists *only* because a Linux root needs ext4. Bare metal uses FatFs: one FAT32
  partition up to 32 GB, the whole card visible from a PC, library and user files
  together. No bind mount, no partition-sizing compromise, no `X16_FSROOT`, and
  the end-user README gets shorter.
- **Power-cut hardening mostly evaporates.** Nothing writes unless the user types
  `SAVE`. The whole log2ram-vs-read-only-overlay question disappears, along with
  its trap (an overlay silently discarding writes to the library).
- Boot in ~2-3 s, and deterministic frame timing.

## What gets thrown away

Everything that is not the emulator: `custom.sh`, the DietPi config, systemd
units, Samba, the Wi-Fi applier, `x16-display`, `x16-gamepad-test`, the smoke
test. That is most of this repo's actual engineering. It transfers as *knowledge*
(the 60 Hz decision, EDID/VSDB structure, the `-joyN` discovery) but not as code.

Two specific losses worth weighing:

- The ~250 MB library currently arrives over Samba. That would not exist — you'd
  copy it onto the card instead. Arguably better, but it is a workflow change.
- r49's gamepad handling is gated by `SDL_IsGameController()` and SDL's mapping
  database (see [`06`](06-phase4-tune.md) §4.4). A non-SDL backend means
  rewriting that path, not just recompiling it.

## Revised estimate

Weeks-to-months still looks right, but **invert the risk weighting**: the port is
the predictable part; the *debugging* is what blows up. Add the maintenance
asymmetry the original doc already flagged — BMC64 targets a frozen C64, while
the X16 is still moving, so every emulator release is a re-port rather than an
`X16_VER` bump.

Two things to check before committing, which cannot be settled from here:

- whether anyone has since published an X16 bare-metal port, or whether
  `x16-emulator` has gained a non-SDL backend;
- how far Circle's Wi-Fi support now extends on Pi 3 / Pi 4 (it was limited).

## Recommendation

**Don't — unless instant boot and sub-frame latency *are* the product.** Option A
delivers ~90% of the felt experience for a fraction of the risk.

If boot time is the real motivation, the untried middle path is far better value:
**strip the Linux boot instead of replacing it.** Measured on the dev Pi
2026-07-25, boot-to-X16 is 20.3 s, and 14.9 s of that is `ifup@eth0` waiting on
the router's DHCP reply while `getty@tty1` is ordered behind `network.target`.
The appliance does not need the network to draw a screen. Decoupling that, and
replacing the getty/autologin chain with a direct unit, plausibly lands around
4-6 s — while keeping every diagnostic tool. That is days of work, not months.

Bare metal buys the last ~3 s at roughly 50x the cost.
