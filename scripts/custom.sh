#!/bin/dash
#
# Phase 3 — Commander X16 DietPi appliance loop.
# Install at: /var/lib/dietpi/dietpi-autostart/custom.sh   (autostart index 17)
# Runs on tty1 as root after autologin, before any login shell, so SDL's KMSDRM
# backend can become DRM master and render straight to HDMI (no desktop).
#
# POSIX /bin/dash — keep it portable.
#
# Display settings live in /boot/firmware/x16.conf and are RE-READ every loop,
# so `x16-display` (the SSH tool) only has to edit the conf and `pkill x16emu`.

INSTALL_DIR="/opt/x16"
USER_PROG_DIR="/boot/x16"
LOG="/var/log/x16-appliance.log"
CONF="/boot/firmware/x16.conf"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') x16-appliance: $*" >> "$LOG"; }

# Wipe the console immediately so the DietPi-login "[ INFO ] Starting..." line and
# any residual boot text vanish the instant we take over tty1. (The DietPi ASCII
# banner itself is suppressed separately via /root/.hushlogin.)
clear 2>/dev/null
printf '\033[?25l' 2>/dev/null   # hide cursor early too

# Render straight to HDMI via SDL2's KMSDRM backend.
export SDL_VIDEODRIVER=kmsdrm
# CRITICAL: on Pi4 KMS, SDL's default desktop-GL renderer draws a BLACK frame.
# The GLES2 renderer (same path kmscube uses) is the one that actually shows.
export SDL_RENDER_DRIVER=opengles2

# Locate the connected HDMI connector and its DRM card minor (Pi3/Pi4 safe).
CONN_SYS=""; CONN_NAME=""; CARD=""
find_hdmi() {
  for s in /sys/class/drm/card*-HDMI-A-*; do
    [ -e "$s/status" ] || continue
    [ "$(cat "$s/status" 2>/dev/null)" = connected ] || continue
    CONN_SYS="$s"
    CONN_NAME=$(basename "$s" | sed 's/^card[0-9]*-//')
    CARD=$(basename "$s" | sed 's/^card\([0-9]*\)-.*/\1/')
    return 0
  done
  return 1
}

# Wait for the KMS display node + a connected HDMI so x16emu doesn't crash-loop
# "SDL_Init failed: kmsdrm not available" during early boot.
i=0
while [ $i -lt 30 ]; do
  { [ -e /dev/dri/card0 ] || [ -e /dev/dri/card1 ]; } && find_hdmi && break
  i=$((i + 1)); sleep 1
done

# Force a TV-compatible mode via EDID override. Most TVs REJECT the X16's native
# 640x480 VGA/DMT signal (blank screen even though EDID reads "connected"); we
# advertise only a CEA mode (1080p/720p) so SDL uses it and scales the X16 into it.
#
# NOTE: this runtime debugfs override forces VIDEO but does NOT rebuild the audio
# ELD, so vc4-hdmi returns ENOTSUPP (-524) and there is no HDMI sound. The FULL
# fix (video + audio) is to force the EDID via the kernel cmdline instead:
#   drm_kms_helper.edid_firmware=HDMI-A-1:edid/x16-1080p.edid   (+ dtparam=audio=on)
# When that cmdline token is present the connector probe already forces the mode
# AND feeds drm_edid_to_eld, so we MUST skip this override (double-forcing would
# reset the ELD and kill audio). This runtime path stays only as a fallback for
# images that have not baked in the cmdline token yet.
apply_edid() {
  [ "${X16_FORCE_EDID:-1}" = 1 ] || return 0
  # cmdline firmware EDID already forces mode + audio ELD -> don't fight it.
  grep -q "drm_kms_helper.edid_firmware=" /proc/cmdline 2>/dev/null && return 0
  find_hdmi || return 0
  ov="/sys/kernel/debug/dri/${CARD}/${CONN_NAME}/edid_override"
  [ -e "$ov" ] || return 0
  case "${X16_OUTPUT:-1080p}" in
    720p)  ef="${INSTALL_DIR}/x16-720p.edid" ;;
    *)     ef="${INSTALL_DIR}/x16-1080p.edid" ;;
  esac
  [ -f "$ef" ] || return 0
  cat "$ef" > "$ov" 2>/dev/null
  echo detect > "${CONN_SYS}/status" 2>/dev/null
  sleep 1
}

# Low input latency: pin CPU governor to performance (best-effort).
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  [ -w "$g" ] && echo performance > "$g" 2>/dev/null
done

# Hide the console cursor / disable blanking so nothing shows between launches.
command -v setterm >/dev/null 2>&1 && setterm --cursor off --blank 0 --powersave off 2>/dev/null
printf '\033[?25l' 2>/dev/null
clear 2>/dev/null

# Paint the boot splash right before launch (the console/KMS is stable here, so
# this is the reliable draw — the early x16-splash.service is just a bonus). Hold
# it briefly so it is actually visible before x16emu's KMS modeset paints over it.
# Tunable via X16_SPLASH_SECONDS in x16.conf (0 = no splash/hold).
X16_SPLASH_SECONDS="${X16_SPLASH_SECONDS:-3}"
if [ "$X16_SPLASH_SECONDS" != 0 ] && [ -x /usr/local/bin/x16-splash ]; then
  /usr/local/bin/x16-splash 2>/dev/null
  sleep "$X16_SPLASH_SECONDS"
fi

AUDIO_DRIVER_DEFAULT="${SDL_AUDIODRIVER:-alsa}"

# Appliance relaunch loop. Re-reads config + re-asserts EDID every iteration so
# the SSH tool can apply changes by just restarting x16emu (pkill -x x16emu).
while true; do
  # ---- defaults, then user config ----
  X16_DISPLAY=widescreen   # widescreen (fill 16:9) | authentic (4:3 pillar-box)
  X16_SCALE=3              # integer render scale 1..4
  X16_OUTPUT=1080p         # 1080p | 720p
  X16_FORCE_EDID=1         # 1 = force TV mode; 0 = real EDID (VGA monitor)
  [ -f "$CONF" ] && . "$CONF" 2>/dev/null

  apply_edid

  VIDEO_ARGS="-fullscreen -scale ${X16_SCALE}"
  [ "$X16_DISPLAY" = widescreen ] && VIDEO_ARGS="${VIDEO_ARGS} -widescreen"

  AUDIO_DRIVER="$AUDIO_DRIVER_DEFAULT"
  log "launch: display=${X16_DISPLAY} scale=${X16_SCALE} out=${X16_OUTPUT} args='${VIDEO_ARGS}'"

  START=$(cut -d. -f1 /proc/uptime)
  SDL_AUDIODRIVER="$AUDIO_DRIVER" "${INSTALL_DIR}/x16emu" \
    ${VIDEO_ARGS} \
    -rom "${INSTALL_DIR}/rom.bin" \
    -fsroot "${USER_PROG_DIR}" \
    >> "$LOG" 2>&1
  rc=$?
  END=$(cut -d. -f1 /proc/uptime)
  ran=$((END - START))
  log "x16emu exited rc=${rc} after ${ran}s (audio=${AUDIO_DRIVER})"

  # Guard against a busy crash-loop; retry ALSA->dummy once on instant audio death.
  if [ "$ran" -lt 3 ]; then
    if [ "$AUDIO_DRIVER_DEFAULT" = alsa ]; then
      AUDIO_DRIVER_DEFAULT=dummy
      log "fast exit; falling back to SDL_AUDIODRIVER=dummy (no sound)"
      continue
    fi
    sleep 3
  fi
done
