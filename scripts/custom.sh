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
LOG="/var/log/x16-appliance.log"

# Both the config and the user-program dir (-fsroot) live on the FAT boot
# partition so they are editable by putting the SD card in any PC. Bookworm
# mounts it at /boot/firmware; older images use /boot. (Plain /boot on Bookworm
# is ext4 root — invisible to Windows — so probe rather than hard-code.)
boot_fat() {
  for d in /boot/firmware /boot; do
    case "$(stat -f -c %T "$d" 2>/dev/null)" in
      msdos|vfat|exfat) printf '%s\n' "$d"; return 0 ;;
    esac
  done
  printf '%s\n' /boot
}
BOOT_FAT="$(boot_fat)"
CONF="${BOOT_FAT}/x16.conf"

# Default fsroot is on FAT so programs can be added from any PC. But the FAT
# partition is only ~128 MB: a big library (the community SD-card tree is ~250 MB)
# cannot live there. Such a machine sets X16_FSROOT in x16.conf to point at the
# roomy ext4 root instead, reachable over the Samba share rather than the card.
X16_FSROOT=""
X16_DROP_DIR=FAT-FILES
[ -f "$CONF" ] && . "$CONF" 2>/dev/null
USER_PROG_DIR="${X16_FSROOT:-${BOOT_FAT}/x16}"
mkdir -p "$USER_PROG_DIR" 2>/dev/null

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') x16-appliance: $*" >> "$LOG"; }

# Seconds since kernel start. The wall clock is useless for boot analysis here:
# it jumps when timesyncd corrects it, which made an early measurement come out
# negative. Everything boot-related is logged against the monotonic clock.
up() { cut -d' ' -f1 /proc/uptime; }
log "custom.sh entered at $(up)s since boot"

# ---- PC-visible drop folder -------------------------------------------------
# The FAT partition is small (256 MB in the shipped image); the bundled library
# is ~250 MB and lives on the roomy ext4 root. x16emu accepts only ONE -fsroot,
# so when the fsroot is on ext4 the FAT folder is bind-mounted INTO it as a
# subdirectory: the owner's PC sees one small drive, the X16 sees the library at
# its root with the owner's own files in FAT-FILES/.
#
# Verified on hardware (r49, 2026-07-25): CD / $ / LOAD all work in the
# subdirectory, and SAVE writes back through the bind mount onto the FAT
# partition — so the drop folder is two-way, not just read-in.
#
# Set X16_DROP_DIR= (empty) in x16.conf to disable the bind entirely.
DROP_SRC="${BOOT_FAT}/x16"
DROP_CUR=""                     # target currently bound, "" = nothing bound

# Exact-target match against /proc/mounts (mountpoint(1) isn't guaranteed here).
is_mounted() {
  awk -v t="$1" '$2 == t { found = 1 } END { exit !found }' /proc/mounts 2>/dev/null
}

# Where the drop folder should be bound right now, or non-zero if it shouldn't.
drop_target() {
  d="${X16_DROP_DIR:-}"
  [ -n "$d" ] || return 1                        # disabled by config
  case "$d" in */*|.|..) return 1 ;; esac        # plain name only — must not escape
  [ "$USER_PROG_DIR" = "$DROP_SRC" ] && return 1 # fsroot already IS the FAT folder
  printf '%s\n' "${USER_PROG_DIR}/${d}"
}

drop_detach() {
  [ -n "$DROP_CUR" ] || return 0
  is_mounted "$DROP_CUR" && umount "$DROP_CUR" 2>/dev/null
  DROP_CUR=""
}

drop_attach() {
  if tgt="$(drop_target)"; then :; else tgt=""; fi
  [ "$tgt" = "$DROP_CUR" ] || drop_detach       # fsroot changed under us
  [ -n "$tgt" ] || return 0
  is_mounted "$tgt" && { DROP_CUR="$tgt"; return 0; }
  [ -d "$DROP_SRC" ] || { log "drop dir: ${DROP_SRC} missing — not binding"; return 0; }
  # A bind mount HIDES whatever is underneath. If someone has real files there,
  # refuse rather than make them vanish.
  if [ -d "$tgt" ] && [ -n "$(ls -A "$tgt" 2>/dev/null)" ]; then
    log "drop dir: ${tgt} exists and is not empty — refusing to bind over it"
    return 0
  fi
  mkdir -p "$tgt" 2>/dev/null
  if mount --bind "$DROP_SRC" "$tgt" 2>>"$LOG"; then
    DROP_CUR="$tgt"
    log "drop dir: bound ${DROP_SRC} -> ${tgt}"
  else
    log "drop dir: bind ${DROP_SRC} -> ${tgt} FAILED"
  fi
}

# Wipe the console immediately so the DietPi-login "[ INFO ] Starting..." line and
# any residual boot text vanish the instant we take over tty1. (The DietPi ASCII
# banner itself is suppressed separately via /root/.hushlogin.)
clear 2>/dev/null
printf '\033[?25l' 2>/dev/null   # hide cursor early too

# Render straight to HDMI via SDL2's KMSDRM backend.
export SDL_VIDEODRIVER=kmsdrm

# Teach SDL about pads that aren't in its built-in mapping table. Without a
# mapping SDL_IsGameController() is false and x16emu ignores the pad entirely,
# even with -joyN — a cheap SNES-style USB pad (0810:e501) hits this. SDL reads
# this file itself (2.0.10+); missing file is harmless.
[ -f "${INSTALL_DIR}/gamecontrollerdb.txt" ] &&
  export SDL_GAMECONTROLLERCONFIG_FILE="${INSTALL_DIR}/gamecontrollerdb.txt"
# CRITICAL: on Pi4 KMS, SDL's default desktop-GL renderer draws a BLACK frame.
# The GLES2 renderer (same path kmscube uses) is the one that actually shows.
export SDL_RENDER_DRIVER=opengles2

# Locate a connected display and its DRM card minor (Pi3/Pi4 safe).
#
# HDMI is listed first so it stays preferred, but ANY connected connector is
# accepted: the Pi 3 + VGA HAT setup drives DPI-1 and has no HDMI connector at
# all. Waiting specifically for HDMI there would burn the full 30s timeout below
# on every boot before the emulator starts. A non-matching glob stays literal
# and fails the -e test, so the fallback costs nothing when HDMI is present.
CONN_SYS=""; CONN_NAME=""; CARD=""
find_display() {
  for s in /sys/class/drm/card*-HDMI-A-* /sys/class/drm/card*-*; do
    [ -e "$s/status" ] || continue
    case "$s" in *Writeback*) continue ;; esac   # not a real output
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
  { [ -e /dev/dri/card0 ] || [ -e /dev/dri/card1 ]; } && find_display && break
  i=$((i + 1)); sleep 1
done

# Force a TV-compatible mode via EDID override. Most TVs REJECT the X16's native
# 640x480 VGA/DMT signal (blank screen even though EDID reads "connected"); we
# advertise only a CEA mode (1080p/720p) so SDL uses it and scales the X16 into it.
#
# NOTE: this runtime debugfs override forces VIDEO but does NOT rebuild the audio
# ELD, so vc4-hdmi returns ENOTSUPP (-524) and there is no HDMI sound. The FULL
# fix (video + audio) is to force the EDID via the kernel cmdline instead:
#   drm.edid_firmware=HDMI-A-1:edid/x16-1080p.edid   (+ dtparam=audio=on)
# When that cmdline token is present the connector probe already forces the mode
# AND feeds drm_edid_to_eld, so we MUST skip this override (double-forcing would
# reset the ELD and kill audio). This runtime path stays only as a fallback for
# images that have not baked in the cmdline token yet.
apply_edid() {
  [ "${X16_FORCE_EDID:-1}" = 1 ] || return 0
  # A kernel-forced EDID already sets the mode AND rebuilds the audio ELD, so
  # re-forcing here would reset the ELD and kill HDMI sound -> skip.
  # Check the MODULE PARAMETER, not the cmdline text: the parameter moved from
  # drm_kms_helper to drm (empty on 6.12 with the old name, which the kernel
  # ignores outright), so a stale cmdline token would wrongly suppress this
  # fallback and leave no EDID forcing at all.
  for p in /sys/module/drm/parameters/edid_firmware \
           /sys/module/drm_kms_helper/parameters/edid_firmware; do
    [ -r "$p" ] || continue
    [ -n "$(cat "$p" 2>/dev/null)" ] && return 0
  done
  find_display || return 0
  # Forcing an EDID only makes sense on HDMI. A VGA HAT drives DPI, which has no
  # EDID at all — the panel takes whatever mode it is given — so skip rather than
  # write into a connector that cannot use it.
  case "$CONN_NAME" in HDMI-A-*) ;; *) return 0 ;; esac
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
log "display ready at $(up)s since boot"
X16_SPLASH_SECONDS="${X16_SPLASH_SECONDS:-1}"
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
  X16_JOYSTICKS=1          # SNES ports accepting a USB gamepad, 0..4
  X16_DROP_DIR=FAT-FILES     # PC-visible folder inside the fsroot ("" = disabled)
  [ -f "$CONF" ] && . "$CONF" 2>/dev/null
  # fsroot may be repointed at the ext4 root for a library too big for FAT.
  USER_PROG_DIR="${X16_FSROOT:-${BOOT_FAT}/x16}"
  mkdir -p "$USER_PROG_DIR" 2>/dev/null

  drop_attach
  apply_edid

  VIDEO_ARGS="-fullscreen -scale ${X16_SCALE}"
  [ "$X16_DISPLAY" = widescreen ] && VIDEO_ARGS="${VIDEO_ARGS} -widescreen"

  # r49 ignores a plugged-in gamepad unless its port is explicitly enabled:
  # Joystick_slots_enabled[] starts all-false and joystick_add() skips disabled
  # slots. So -joyN is REQUIRED, not optional. Harmless when no pad is attached.
  JOY_ARGS=""
  case "$X16_JOYSTICKS" in
    1|2|3|4) n=1
             while [ "$n" -le "$X16_JOYSTICKS" ]; do
               JOY_ARGS="${JOY_ARGS} -joy${n}"; n=$((n + 1))
             done ;;
    *) ;;                  # 0 or garbage -> no gamepad support
  esac

  AUDIO_DRIVER="$AUDIO_DRIVER_DEFAULT"
  log "launch at $(up)s since boot: display=${X16_DISPLAY} scale=${X16_SCALE} out=${X16_OUTPUT} joy=${X16_JOYSTICKS} args='${VIDEO_ARGS}${JOY_ARGS}'"

  START=$(cut -d. -f1 /proc/uptime)
  SDL_AUDIODRIVER="$AUDIO_DRIVER" "${INSTALL_DIR}/x16emu" \
    ${VIDEO_ARGS} \
    ${JOY_ARGS} \
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
