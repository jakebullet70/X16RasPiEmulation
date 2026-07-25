#!/bin/bash
#
# trim-boot.sh — take the appliance's boot-to-X16 from ~13s to ~6s.
#
# Three independent fixes, all measured on a Pi 4 (DietPi Bookworm, 2026-07-25).
# Timings are seconds since KERNEL start; firmware/EEPROM time before that, and
# the TV's own sync delay after it, are not included and are not ours to fix.
#
#   1. getty@tty1 — where the X16 actually starts — was ordered behind
#      network.target, which waits for ifup@eth0, which waits for the router's
#      DHCPOFFER. Measured 7.9-14.9s with the Pi completely idle. Nothing about
#      drawing the emulator needs an IP address.
#
#   2. serial-getty@ttyS0 waited out the full 90s device timeout every boot, so
#      multi-user.target / graphical.target did not activate until ~93s. It did
#      not delay the X16, but any unit ordered WantedBy=multi-user.target did,
#      and a shipped image should not contain a guaranteed 90s stall.
#
# Run as root on the Pi. Idempotent. Pass --revert to undo.
#
set -euo pipefail

OVERRIDE=/etc/systemd/system/systemd-user-sessions.service
VENDOR=/lib/systemd/system/systemd-user-sessions.service
CMDLINE=""
for c in /boot/firmware/cmdline.txt /boot/cmdline.txt; do
  [ -f "$c" ] && { CMDLINE="$c"; break; }
done

[ "$(id -u)" = 0 ] || { echo "Run as root."; exit 1; }

if [ "${1:-}" = --revert ]; then
  rm -f "$OVERRIDE"
  rm -f /etc/systemd/system/getty@tty1.service.d/10-no-idle-delay.conf
  rmdir /etc/systemd/system/getty@tty1.service.d 2>/dev/null || true
  systemctl enable serial-getty@ttyS0.service 2>/dev/null || true
  systemctl daemon-reload
  echo "Reverted. (A console=ttyS0 token removed from cmdline.txt is NOT restored;"
  echo "the backup is alongside it as cmdline.txt.bak-serialconsole.)"
  exit 0
fi

# ---- 1. stop the login barrier waiting for the network ----------------------
# This MUST be a full unit override, not a drop-in. systemd registers the
# mirrored Before= edge as it parses each After= line, so a drop-in that resets
# `After=` clears the unit's own list but leaves the reverse edge in place and
# changes nothing. Verified on hardware: the drop-in loaded correctly, and
# getty@tty1 still started behind network.target across a reboot. Replacing the
# whole unit means the offending line is never parsed.
if [ ! -f "$OVERRIDE" ]; then
  sed '/^After=/s/ network\.target//' "$VENDOR" > "$OVERRIDE"
  cat >> "$OVERRIDE" <<'NOTE'

# --- X16 appliance override ---------------------------------------------------
# network.target removed from After=. See scripts/trim-boot.sh for why this is a
# full override rather than a drop-in. Cost: shadows the vendor unit, so it will
# not track systemd updates. Delete this file to restore stock behaviour.
NOTE
  echo "installed: $OVERRIDE"
else
  echo "already present: $OVERRIDE"
fi
grep '^After=' "$OVERRIDE" | sed 's/^/  /'

# ---- 2. kill the 90s serial-getty timeout -----------------------------------
# /dev/ttyS0 exists but udev marks it SYSTEMD_READY=0 (the mini-UART is not
# enabled), so dev-ttyS0.device never activates and the getty waits out the
# whole timeout. Checking readiness rather than existence is the point here.
if [ -e /dev/ttyS0 ] && udevadm info /dev/ttyS0 2>/dev/null | grep -q 'SYSTEMD_READY=0'; then
  echo "note: /dev/ttyS0 exists but udev marks it not-ready — the getty would stall"
fi
if systemctl is-enabled serial-getty@ttyS0.service >/dev/null 2>&1; then
  systemctl disable serial-getty@ttyS0.service
else
  echo "already disabled: serial-getty@ttyS0.service"
fi

# A console=ttyS0 token makes systemd's getty generator re-create it, so drop it.
if [ -n "$CMDLINE" ] && grep -q 'console=ttyS0' "$CMDLINE"; then
  cp -a "$CMDLINE" "${CMDLINE}.bak-serialconsole"
  sed -i 's/[[:space:]]*console=ttyS0,\?[0-9]*//' "$CMDLINE"
  echo "removed console=ttyS0 from ${CMDLINE} (backup: ${CMDLINE}.bak-serialconsole)"
fi

# ---- 3. drop getty@tty1's Type=idle 5s stall -------------------------------
# getty@tty1 ships Type=idle so a login prompt doesn't interleave with boot
# messages: systemd holds ExecStart until the job queue drains or 5s elapse.
# On this appliance tty1 is not a login prompt -- agetty runs custom.sh via -l --
# and the queue never drains early because DHCP runs to ~14s, so it always paid
# the full 5s. Measured: unit active at 3.2s, custom.sh not entered until 9.9s.
# Type is a plain setting, not an ordering dependency, so a drop-in is fine here.
IDLE_DIR=/etc/systemd/system/getty@tty1.service.d
mkdir -p "$IDLE_DIR"
cat > "${IDLE_DIR}/10-no-idle-delay.conf" <<'CONF'
# X16 appliance: tty1 runs the emulator, not a login prompt. Type=idle costs a
# flat 5s here. See scripts/trim-boot.sh.
[Service]
Type=simple
CONF
echo "installed: ${IDLE_DIR}/10-no-idle-delay.conf"

systemctl daemon-reload
echo
echo "Done. Reboot, then check the instrumented log:"
echo "  grep -E 'entered|launch at' /var/log/x16-appliance.log | tail -2"
echo "Expect custom.sh entered at ~5s and x16emu launched at ~6s (was ~13s)."
