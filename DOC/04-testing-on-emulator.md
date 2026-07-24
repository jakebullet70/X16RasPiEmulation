# Testing the Scripts on x86 (VM / Container)

_Written: 2026-07-22_

Idea: validate the install/launch scripts on x86 (a DietPi x86 VM, or a Debian
container) before touching real Pi hardware. **Good idea — with a clear scope.**

## What this does and does NOT prove

| Validated on x86 VM/container | NOT validated (needs a real Pi) |
|---|---|
| DietPi first-boot automation (`dietpi.txt`) → console | KMSDRM full-KMS path on the `vc4` driver |
| `apt` deps, download/unzip/ROM fallback, paths, symlink | Forced HDMI 60 Hz, vsync smoothness, latency |
| `x16emu` + matching ROM launch to `READY.` | Audio over HDMI |
| `-fsroot` file loading, keyboard input | Real Pi 3/4 performance |
| Correct-arch binary, resolvable libs (smoke test) | Firmware `config.txt` (`vc4-kms-v3d`, `gpu_mem`) |

Bottom line: this is a **script-logic + "does the emulator run" smoke test**, not
an appliance sign-off. The KMS/HDMI/latency behaviour — the entire point of
Option A — can only be verified on the Pi.

## Scripts are now arch-aware
`install-x16.sh` auto-detects the host and pulls the matching prebuilt zip:
`x86_64` (VM/container), `aarch64` (the Pi), or `armhf` (32-bit). `run-x16.sh`
defaults to `kmsdrm` but honours `SDL_VIDEODRIVER`/`SDL_AUDIODRIVER` overrides so
it works in a VM. Both scripts route privilege through `$SUDO`, so they also run
as root in a container.

---

## Path A — Docker container (fastest logic test)

Best for a quick, repeatable check of the install logic + that the x86 emulator
binary runs headless. Requires Docker Desktop running. From the repo root:

```bash
docker run --rm -v "$PWD/scripts:/scripts:ro" debian:bookworm-slim bash -c '
  set -e
  apt-get update && apt-get install -y ca-certificates >/dev/null
  cp -r /scripts /work && chmod +x /work/*.sh
  /work/install-x16.sh          # downloads x86_64 r49 + ROM, installs deps
  /work/smoke-test.sh           # headless: arch, libs, ROM, launches w/o crash
'
```
Expected tail: `== result: PASS ==`.

> Note: this proves the emulator **starts and runs headless**. It uses the SDL
> `dummy` video driver — there is no window and no KMS. Don't read anything into
> the absence of visible output; that's Path B / real hardware territory.

Optional — sanity-check the **actual aarch64 Pi binary** on this x86 host via
emulation (needs `docker run --privileged --rm tonistiigi/binfmt --install arm64`
once):
```bash
docker run --rm --platform linux/arm64 -v "$PWD/scripts:/scripts:ro" \
  debian:bookworm-slim bash -c '
    apt-get update && apt-get install -y ca-certificates >/dev/null
    cp -r /scripts /work && chmod +x /work/*.sh
    /work/install-x16.sh && /work/smoke-test.sh'
```
This runs the real aarch64 build under QEMU user-mode emulation — slow, but it
confirms the exact binary that ships to the Pi loads its libs and starts.

> **⚠ Docker Desktop on Windows gotcha (verified 2026-07-22).** The command above
> works on a Linux Docker host but **fails on Docker Desktop for Windows** — not
> because of a script bug. Under this box's qemu-user emulation, command
> substitution `$(...)` returns **empty** inside the emulated arm64 container:
> `uname -m` prints `aarch64` when run as the container's PID 1, but
> `X=$(uname -m)` yields an empty string. That silently breaks `install-x16.sh`'s
> `case "$(uname -m)"` arch detection (→ "Unsupported arch"), and it breaks any
> `$(...)` in `smoke-test.sh` too. A **real Pi runs natively — no QEMU, no quirk**
> — so `$(uname -m)` is correct there; this is purely an emulation-layer artifact.
>
> Two extra Windows-only capture pitfalls hit while verifying this: streamed
> stdout from a slow QEMU container gets **truncated to the first flushed line**
> in the tool output, and writing to a **bind-mounted output file loses later
> writes** on flush. Both are host plumbing, not the scripts.
>
> **What works on Windows** — verify the aarch64 binary directly, avoiding
> `$(...)`, stdout parsing, and mounted-file capture; signal the result through
> the container **exit code** only. Put this in a file (e.g. `arm64check.sh`) and
> `docker run ... bash /out/arm64check.sh` with the file's dir mounted at `/out`:
>
> ```bash
> #!/bin/bash
> apt-get update >/dev/null 2>&1 || exit 40
> apt-get install -y ca-certificates curl unzip libsdl2-2.0-0 >/dev/null 2>&1 || exit 41
> curl -fsSL "https://github.com/X16Community/x16-emulator/releases/download/r49/x16emu_linux-aarch64-r49.zip" -o /tmp/x16.zip || exit 42
> mkdir -p /opt/x16
> unzip -jo /tmp/x16.zip -d /opt/x16 >/dev/null || exit 43
> chmod +x /opt/x16/x16emu
> if ldd /opt/x16/x16emu 2>/dev/null | grep -qi 'not found'; then exit 50; fi   # 50 = missing libs
> if [ ! -f /opt/x16/rom.bin ]; then exit 51; fi                                # 51 = no ROM
> SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy timeout 8 /opt/x16/x16emu -rom /opt/x16/rom.bin >/dev/null 2>&1
> [ $? -eq 124 ] && exit 0    # ran full 8s, timeout-killed = healthy
> exit 60                     # crashed / exited early
> ```
>
> ```powershell
> docker run --rm --platform linux/arm64 -v "<dir>:/out:ro" debian:bookworm-slim bash /out/arm64check.sh
> "EXIT: $LASTEXITCODE"   # 0 = binary healthy; 40-43 setup; 50 libs; 51 rom; 60 early-exit
> ```
>
> Result on 2026-07-22: **exit 0** — the r49 aarch64 binary's libs resolve, its
> ROM is bundled, and it ran 8s headless without crashing. The x86_64 Path A test
> above (which runs natively, no QEMU) passed the full `install`+`smoke` pipeline
> clean and remains the primary per-`X16_VER`-bump gate.

---

## Path B — DietPi x86 VM (fuller, closer to the real image)

Best for also exercising DietPi's own first-boot automation and a windowed
launch. Heavier and more manual. Needs a hypervisor (VirtualBox / QEMU / VMware);
none is installed on the dev box yet.

1. Download the **DietPi "Native PC (BIOS/UEFI)" x86_64** image from
   <https://dietpi.com/#download>.
2. Boot it in the VM; apply the same `config/dietpi.txt.snippet` keys (the Pi
   firmware `config/config.txt.snippet` is Pi-only — skip it here).
3. Copy `scripts/` in, then:
   ```bash
   ~/scripts/install-x16.sh
   ~/scripts/smoke-test.sh
   ```
4. For a *visible* window (if you installed a minimal desktop/X in the VM):
   ```bash
   SDL_VIDEODRIVER=x11 ~/scripts/run-x16.sh
   ```
   On a pure console VM with no KMS, stick to `smoke-test.sh` (headless).

---

## Recommended sequence
1. **Path A (Docker)** — cheap gate: catches script bugs, missing deps, bad URLs,
   ROM-fallback errors, and confirms the emulator runs. Do this every time you
   bump `X16_VER`.
2. **Path B (DietPi x86 VM)** — optional: adds DietPi automation + windowed run.
3. **Real Pi 3/4** — the only place KMS/HDMI/latency/audio/perf are real. No VM
   substitutes for this step.
