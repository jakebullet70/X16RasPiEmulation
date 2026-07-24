# Feasibility Research — Running the Commander X16 Emulator on a Raspberry Pi

_Research date: 2026-07-22_

## The question

There is a bare-metal Commodore 64 emulator for the Raspberry Pi — **BMC64**
(<https://github.com/randyrossi/bmc64>) — that runs with no Linux desktop /
no OS at all. Can the same approach be applied to the **Commander X16 emulator**
(<https://github.com/X16Community/x16-emulator>) to produce a Raspberry Pi
"distro" that boots straight into the X16?

**Short answer:** Yes, it's feasible — and the required building blocks already
exist — but it's a real porting project, not a recompile. There are two very
different ways to read "a Pi distro that runs the X16," and they differ
enormously in effort.

## How BMC64 actually works

BMC64 is not magic. It takes **VICE** (the standard Commodore emulator) and
satisfies all of VICE's OS-level needs (file I/O, memory, threads, timers) using
**circle-stdlib** (<https://github.com/smuehlst/circle-stdlib>), which sits on
top of **Circle** (<https://github.com/rsta2/circle>) — a C++ bare-metal
environment for the Pi.

- There is no Linux. The emulator **is** the kernel.
- Power on → straight into the emulator. That's what buys the low input latency
  and true 50/60 Hz vsync-locked smooth scrolling.
- Randy Rossi did significant custom work to graft VICE onto Circle and to write
  a bare-metal video / input / UI layer.
- Language mix: ~72% C++, ~11% C, plus Java tooling and shell.
- Supports Pi 0/1/2/3 with model-specific kernels. The actively maintained fork
  **Maverick-Shark/bmc64** (<https://github.com/Maverick-Shark/bmc64>) extends
  this to Pi 4/5.

## How x16-emulator is built

The X16 emulator is clean, portable C (~85%) whose one big external dependency is
**SDL2** (video, audio, input).

- CPU: 65C02 (default) or experimental 65C816.
- Video: VERA — mostly cycle-exact, dual layers, sprites, VSYNC/raster/sprite
  IRQs, 128 KiB VRAM.
- Audio: PCM, PSG, and YM2151 (FM) synthesis.
- Builds and runs today on macOS / Windows / Linux, **including Raspberry Pi OS**
  — there is even a snap package (`x16emu` on Raspbian).
- The emulation core (CPU + VERA) is self-contained. **The core is not the
  problem** — the problem on bare metal is that there is no SDL2, no window
  system, and no OS.

## The two ways to build "a Pi distro that runs the X16"

### Option A — Minimal Linux "appliance" image (EASY, doable today)

Take a stripped, headless Linux (DietPi / Raspberry Pi OS Lite), autologin, and
boot straight into `x16emu` fullscreen via SDL2's KMSDRM backend (no desktop).

- ~90% configuration work, essentially **zero emulator porting**.
- Works on any Pi that runs the OS today.
- Near-instant boot, kiosk feel.
- Won't perfectly match BMC64's sub-frame latency, but close enough for most
  people and shippable quickly.
- **This is the chosen first approach.** See `02-option-a-plan.md`.

### Option B — True bare-metal, BMC64-style (HARD, but not blocked)

The hardest dependency, SDL2, has **already been ported to Circle bare-metal** by
others:

- CommanderCoder/raspberry-pi-sdl — <https://github.com/CommanderCoder/raspberry-pi-sdl>
- paulwratt/raspberry-pi-sdl2 — <https://github.com/paulwratt/raspberry-pi-sdl2>
- Precedents: Faux86 (bare-metal x86 emulator on Circle,
  <https://github.com/jhhoward/Faux86>), mt32-pi (<https://github.com/dwhinham/mt32-pi>).

Theoretical path:

1. Build x16-emulator against a Circle / circle-stdlib toolchain.
2. Either link a bare-metal SDL2 port, **or** replace x16emu's SDL2 calls with
   direct Circle framebuffer / audio / USB-HID calls (cleaner, more BMC64-like,
   more work).
3. Handle boot glue, SD-card file access (ROM + `.prg` files), and frame timing
   to lock VERA's output to HDMI vsync.

Effort: weeks-to-months of one-person work. None of it is novel — all pieces have
precedent — but integration is the cost.

## Feasibility factors (honest assessment)

| Factor | Notes |
|---|---|
| Circle Pi support | Pi Zero, 1, 2, 3, 4, 400, 5 (not Pico). Good coverage. |
| Performance | X16 is more demanding than a C64: 8 MHz 65C02 + VERA rendering ~640×480 with two layers + sprites. Pi Zero/1 marginal; Pi 3/4/5 have ample headroom. |
| Timing | VERA's native VGA-style 60 Hz output maps naturally onto HDMI 60 Hz — actually a cleaner vsync story than the C64's PAL 50 Hz. |
| Existing port | None found. You'd be first for bare metal. X16 community has discussed running it on a Pi (e.g. RetroPie thread, <https://cx16forum.com/forum/viewtopic.php?t=1295>). |
| Moving target | The X16 is still evolving (ROM/VERA revisions change), whereas the C64 is frozen. A bare-metal image is harder to update than an apt/snap install — factor in maintenance. |

## Recommendation

Do **Option A** first — low-risk, validates the appliance idea, shippable
quickly. Pursue **Option B** only if the specific goal is BMC64-grade latency and
instant boot as a product/hobby milestone.

## Sources

- randyrossi/bmc64 — <https://github.com/randyrossi/bmc64>
- Maverick-Shark/bmc64 (Pi 4/5 fork) — <https://github.com/Maverick-Shark/bmc64>
- X16Community/x16-emulator — <https://github.com/X16Community/x16-emulator>
- x16emu snap for Pi — <https://snapcraft.io/install/x16emu/raspbian>
- Circle — <https://github.com/rsta2/circle>
- circle-stdlib — <https://github.com/smuehlst/circle-stdlib>
- Circle projects list — <https://github.com/rsta2/circle/issues/127>
- raspberry-pi-sdl (Circle) — <https://github.com/CommanderCoder/raspberry-pi-sdl>
- raspberry-pi-sdl2 — <https://github.com/paulwratt/raspberry-pi-sdl2>
- Faux86 — <https://github.com/jhhoward/Faux86>
- Commander X16 in RetroPie? (forum) — <https://cx16forum.com/forum/viewtopic.php?t=1295>
