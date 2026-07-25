#!/bin/bash
#
# x16-display — adjust the Commander X16 appliance's monitor output over SSH.
# Edits /boot/firmware/x16.conf and restarts the X16 so changes apply live
# (no reboot needed for aspect / scale / resolution).
#
set -u
CONF="/boot/firmware/x16.conf"
[ -w "$(dirname "$CONF")" ] || { echo "Run as root (sudo x16-display)."; exit 1; }

# ---- defaults, then load current config ----
# NB: every key the appliance understands must be defaulted AND written back by
# save(), which rewrites the whole file. A key that is read elsewhere but missing
# here would be silently erased the first time someone opens this menu.
X16_DISPLAY=widescreen; X16_SCALE=3; X16_OUTPUT=1080p; X16_FORCE_EDID=1
X16_JOYSTICKS=1; X16_SPLASH_SECONDS=3; X16_FSROOT=""
[ -f "$CONF" ] && . "$CONF" 2>/dev/null

save() {
  cat > "$CONF" <<EOF
# Commander X16 appliance — settings. Edit here, or run: x16-display
# Sourced by /bin/dash — keep it POSIX (KEY=value, no spaces around '=').

# Aspect: widescreen (fill 16:9) | authentic (true 4:3, pillar-boxed)
X16_DISPLAY=$X16_DISPLAY
# Render scale, 1-4.
X16_SCALE=$X16_SCALE
# Output resolution: 1080p | 720p
X16_OUTPUT=$X16_OUTPUT
# 1 = force a TV-friendly mode via synthetic EDID; 0 = real EDID (VGA monitor).
X16_FORCE_EDID=$X16_FORCE_EDID
# SNES ports accepting a USB gamepad, 0-4 (0 = gamepads ignored).
X16_JOYSTICKS=$X16_JOYSTICKS
# Seconds to hold the boot splash (0 = none).
X16_SPLASH_SECONDS=$X16_SPLASH_SECONDS
# Where the X16's files live. Empty = the x16 folder on this FAT partition, which
# a PC can see. Set a path (e.g. /boot/x16) to use the ext4 root instead, for a
# library too big for this ~128 MB partition — then add files over Samba/scp.
X16_FSROOT=$X16_FSROOT
EOF
}

restart_x16() {
  save
  if pgrep -x x16emu >/dev/null 2>&1; then
    pkill -x x16emu           # the appliance loop re-reads config + relaunches
    echo "Restarting X16… watch your screen."
  else
    echo "Saved. (X16 loop not running here — changes apply on next boot.)"
  fi
}

banner() {
  clear
  cat <<EOF
========================================
   Commander X16 — Display Settings
========================================
  Aspect      : $X16_DISPLAY
  Scale       : $X16_SCALE
  Resolution  : $X16_OUTPUT
  Force TV mode: $([ "$X16_FORCE_EDID" = 1 ] && echo yes || echo "no (VGA/real EDID)")
  Gamepad ports: $([ "$X16_JOYSTICKS" = 0 ] && echo "none" || echo "$X16_JOYSTICKS")
----------------------------------------
  1) Aspect    (widescreen <-> authentic 4:3)
  2) Scale     (1-4)
  3) Resolution(1080p <-> 720p)
  4) Force TV mode on/off  (off = real VGA monitor, needs reboot)
  5) Gamepad ports (0-4)   (0 = ignore pads; r49 needs a port per pad)
  6) Apply now  (restart X16)
  q) Quit
========================================
EOF
}

while true; do
  banner
  printf "select> "
  read -r choice || break
  case "$choice" in
    1) [ "$X16_DISPLAY" = widescreen ] && X16_DISPLAY=authentic || X16_DISPLAY=widescreen ;;
    2) printf "scale 1-4> "; read -r s
       case "$s" in 1|2|3|4) X16_SCALE=$s ;; *) echo "invalid"; sleep 1 ;; esac ;;
    3) [ "$X16_OUTPUT" = 1080p ] && X16_OUTPUT=720p || X16_OUTPUT=1080p ;;
    4) [ "$X16_FORCE_EDID" = 1 ] && X16_FORCE_EDID=0 || X16_FORCE_EDID=1
       [ "$X16_FORCE_EDID" = 0 ] && { echo "Real-EDID mode: reboot for a VGA monitor."; sleep 2; } ;;
    5) printf "gamepad ports 0-4> "; read -r j
       case "$j" in 0|1|2|3|4) X16_JOYSTICKS=$j ;; *) echo "invalid"; sleep 1 ;; esac ;;
    6) restart_x16; sleep 2 ;;
    q|Q) save; echo "Saved to $CONF."; exit 0 ;;
    *) ;;
  esac
  # auto-apply the quick toggles immediately so the change is visible
  case "$choice" in 1|2|3|5) restart_x16; sleep 1 ;; esac
done
