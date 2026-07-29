# Phase 3 — Appliance-ify (power-on straight into the X16)

_Written: 2026-07-22 · Target: Raspberry Pi 3 / 4 · Base: DietPi arm64 (Bookworm)_

Phases 1 & 2 got you a Pi that boots to a **console** where `run-x16.sh` brings up
the X16 fullscreen **by hand**. Phase 3 removes the hand: power-on drops straight
into the X16, no shell visible, and exiting/crashing relaunches instead of
dumping to a prompt.

**Prerequisite gate:** Phase 2 is complete — `~/scripts/run-x16.sh` already brings
up the X16 fullscreen from the physical console with working keyboard and audio.
Do **not** start Phase 3 until that works; the autostart loop runs the exact same
command, so debugging is far easier at the console than through autostart.

Repo artifacts used:
- `scripts/custom.sh` — the DietPi custom-autostart appliance loop (source of truth)
- `config/dietpi.txt.snippet` — where the autostart index gets flipped to 17

---

## What changes vs Phase 2

| | Phase 2 | Phase 3 |
|---|---|---|
| Boot target | console autologin (index **7**) | custom script (index **17**) |
| X16 launch | manual `run-x16.sh` | automatic at boot |
| On exit/crash | back to shell | **relaunch loop** |
| Shell visible | yes | no (unless you break in) |

The launch command itself is identical to `run-x16.sh` — `custom.sh` just wraps
it in env setup, a CPU-governor assertion, console blanking, and a `while` loop.

---

## 3.1 Deploy the appliance script

Copy `scripts/custom.sh` from this repo to DietPi's autostart location and make it
executable. From the Pi (scripts already copied to `~/scripts` in Phase 2):

```bash
sudo install -m 0755 ~/scripts/custom.sh /var/lib/dietpi/dietpi-autostart/custom.sh
```

> `install -m 0755` both copies and sets the exec bit in one step. DietPi invokes
> this file with `/bin/dash`, so it is written POSIX-clean (no bashisms).

Sanity-check it still launches the emulator the same way, straight from a console
tty (**not** SSH — KMSDRM needs to be DRM master):

```bash
sudo /var/lib/dietpi/dietpi-autostart/custom.sh
```

You should get the fullscreen **READY.** prompt exactly as with `run-x16.sh`.
Because of the loop, quitting the emulator (close/kill) will **relaunch** it — that
is correct. To get your shell back, drop to another VT (`Ctrl+Alt+F2`) or SSH in
and stop it (see Rollback below). Confirm the loop works, then move on.

## 3.2 Flip the autostart target to Custom (17)

Two ways — pick one:

**A. `dietpi-autostart` menu (interactive):**
```bash
sudo dietpi-autostart
# choose: 17  Custom script (no autologin)  — or "Custom script" entry
```

**B. Edit `/boot/dietpi.txt` directly** (matches the repo snippet):
```bash
sudo sed -i 's/^AUTO_SETUP_AUTOSTART_TARGET_INDEX=.*/AUTO_SETUP_AUTOSTART_TARGET_INDEX=17/' \
  /boot/dietpi.txt
```

> Index 17 is **"Custom script (no autologin)"** — it runs `custom.sh` on tty1 as
> root without spawning a login shell first, which is exactly what we want: no
> visible prompt, and DRM-master available to KMSDRM. (There is also a
> "Custom script" variant *with* autologin; either runs `custom.sh`, but
> no-autologin is the cleaner appliance.)

## 3.3 Reboot into the appliance (the Phase 3 gate)

```bash
sudo reboot
```

**Gate — power-on to X16, hands-off:**
- Boots straight to the X16 **READY.** prompt fullscreen — no login prompt, no
  desktop, no console text lingering.
- USB keyboard types into BASIC; audio works.
- A `.prg`/`.bas` dropped into the `/boot` partition's `x16/` folder is visible
  inside the X16 (`DIR` / `LOAD"NAME"`) — the `-fsroot` mount.
- Quitting/crashing the emulator **relaunches** it (never lands on a shell).
- Appliance log accumulates at `/var/log/x16-appliance.log` (start/exit lines).

---

## Breaking in (you will need this)

With no shell on tty1, keep one of these handy for updates and debugging:
- **SSH** — still enabled from Phase 1/2 (`AUTO_SETUP_SSH_SERVER_INDEX`). The
  primary service door.
- **Another VT** — `Ctrl+Alt+F2` gives a fresh login tty without disturbing the
  emulator on tty1.

To stop the loop from a break-in shell (so it doesn't relaunch while you work):
```bash
sudo pkill -f x16emu          # kill the running emulator...
# ...but custom.sh's while-loop will relaunch it. To halt the loop itself:
sudo pkill -f custom.sh       # then pkill x16emu again if needed
```

---

## Rollback to a console (undo Phase 3)

If the appliance misbehaves and you want the Phase 2 console back:
```bash
sudo dietpi-autostart          # choose 7 (console autologin)
#   or:
sudo sed -i 's/^AUTO_SETUP_AUTOSTART_TARGET_INDEX=.*/AUTO_SETUP_AUTOSTART_TARGET_INDEX=7/' \
  /boot/dietpi.txt
sudo reboot
```
`custom.sh` can stay in place — index 7 simply doesn't run it.

---

## Exit criteria (Phase 3 complete)
- `AUTO_SETUP_AUTOSTART_TARGET_INDEX=17` and `custom.sh` installed at
  `/var/lib/dietpi/dietpi-autostart/custom.sh`.
- Cold boot lands on the fullscreen X16 with no shell, keyboard + audio working.
- Emulator exit/crash relaunches via the loop; SSH / VT2 still available for admin.

## Next (Phase 4 preview)
Tune the appliance: lock the exact HDMI 60 Hz mode and verify vsync smoothness,
trim boot time (disable unused services, quiet boot / hide the rainbow splash and
boot text so the *only* thing ever on screen is the X16), and map a USB gamepad to
the X16 joystick. Then Phase 5: SD-card hardening (DietPi-RAMlog, already on)
and capturing the shrunk, distributable `.img`. See `02-option-a-plan.md`.

## Troubleshooting
| Symptom | Likely cause / fix |
|---|---|
| Boots to a login/console, not the X16 | Index not actually 17 — `grep AUTOSTART_TARGET_INDEX /boot/dietpi.txt`; re-run `dietpi-autostart`. |
| Black screen, then console text flashes and loops | `x16emu` failing to start — read `/var/log/x16-appliance.log`; usually missing `rom.bin` or a wrong-arch binary. Re-run `install-x16.sh`. |
| CPU pegged, log spamming exit lines | Emulator crash-looping (<3s each) — the `sleep 3` backoff is firing; fix the underlying start failure from the log. |
| Screen has a visible cursor / boot text before X16 | Cosmetic — Phase 4 quiet-boot work; `custom.sh` already blanks the cursor best-effort. |
| Can't get a shell to fix things | `Ctrl+Alt+F2` for a fresh VT, or SSH in; then `pkill -f custom.sh`. |
| Changed `rom.bin`/binary, appliance won't boot | Break in via SSH, run `smoke-test.sh` to isolate, or roll back to index 7. |
