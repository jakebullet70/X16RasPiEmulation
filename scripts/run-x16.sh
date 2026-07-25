#!/usr/bin/env bash
#
# Phase 2 — manual fullscreen launch to confirm the emulator works.
# RUN THIS FROM A CONSOLE (tty on the HDMI display), not over SSH — the KMSDRM
# backend needs to become DRM master, which it can't do from an SSH session.
#
# This mirrors what the appliance autostart (custom.sh) does, minus the loop and
# the EDID override: same video/renderer env, same display-sizing from x16.conf.
# For the full forced-EDID behaviour, use the appliance loop (custom.sh) — this
# manual launcher just brings the emulator up for a quick Phase-2 sanity check.

set -euo pipefail

INSTALL_DIR="/opt/x16"

# -fsroot lives on the FAT boot partition (Bookworm: /boot/firmware, older
# images: /boot) so programs can be added from any PC via the SD card.
boot_fat() {
  for d in /boot/firmware /boot; do
    case "$(stat -f -c %T "$d" 2>/dev/null)" in
      msdos|vfat|exfat) printf '%s\n' "$d"; return 0 ;;
    esac
  done
  printf '%s\n' /boot
}
USER_PROG_DIR="${X16_FSROOT:-$(boot_fat)/x16}"
mkdir -p "${USER_PROG_DIR}" 2>/dev/null || true

# Optional shared config (same file the appliance reads). Defaults follow.
X16_DISPLAY="widescreen"
X16_SCALE="3"
X16_JOYSTICKS="1"
for c in /boot/firmware/x16.conf /boot/x16.conf; do
  if [ -r "$c" ]; then
    # shellcheck disable=SC1090
    . "$c"
    break
  fi
done

# Defaults suit the real Pi appliance (render straight to HDMI, no X/desktop).
# Overridable for testing, e.g. on a VM/container:
#   SDL_VIDEODRIVER=x11    ~/scripts/run-x16.sh   # desktop VM with X
#   SDL_VIDEODRIVER=dummy  ~/scripts/run-x16.sh   # headless smoke (no window)
export SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-kmsdrm}"
export SDL_AUDIODRIVER="${SDL_AUDIODRIVER:-alsa}"
# Force the GLES2 renderer — the desktop-GL default scans out BLACK on Pi4 KMS.
export SDL_RENDER_DRIVER="${SDL_RENDER_DRIVER:-opengles2}"

# Display sizing from config (authentic 4:3 pillarbox vs stretch-to-fill 16:9).
DISPLAY_ARGS=(-scale "${X16_SCALE}")
if [ "${X16_DISPLAY}" = "widescreen" ]; then
  DISPLAY_ARGS=(-widescreen "${DISPLAY_ARGS[@]}")
fi

# r49 will NOT bind a plugged-in gamepad unless the port is enabled with -joyN
# (Joystick_slots_enabled[] defaults to all-false), so pass one per port wanted.
# Keep this in step with custom.sh so manual and appliance launches behave alike.
JOY_ARGS=()
case "${X16_JOYSTICKS}" in
  1|2|3|4) for ((n = 1; n <= X16_JOYSTICKS; n++)); do JOY_ARGS+=("-joy${n}"); done ;;
  *) ;;                    # 0 or unset -> gamepads ignored
esac

exec "${INSTALL_DIR}/x16emu" \
  -fullscreen \
  -rom "${INSTALL_DIR}/rom.bin" \
  -fsroot "${USER_PROG_DIR}" \
  "${DISPLAY_ARGS[@]}" \
  ${JOY_ARGS[@]+"${JOY_ARGS[@]}"} \
  "$@"
