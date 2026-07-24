#!/bin/bash
#
# appliance-quiet.sh — make the Pi boot silently straight into the X16.
#
# Applies every rootfs/systemd tweak we found on real hardware so power-on shows
# ONLY: brief black -> COMMANDER X16 splash -> the X16. Idempotent; safe to re-run.
# Run as root on the Pi (over SSH or a console).
#
# NOTE: the BOOT-PARTITION pieces live in the config snippets (apply those too):
#   config/config.txt.snippet   -> dtoverlay=disable-bt (+disable-wifi), disable_splash=1
#   config/cmdline.txt.snippet  -> quiet loglevel=0 logo.nologo vt.global_cursor_default=0
#                                  consoleblank=0 plymouth.enable=0 systemd.show_status=0
#                                  rd.systemd.show_status=0  + the edid_firmware token
#   config/dietpi.txt(.snippet) -> AUTO_SETUP_BOOT_WAIT_FOR_NETWORK=0
# This script does the rootfs + systemd side.
#
set -e
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }

echo "== mask bluetooth service =="
systemctl mask bluetooth.service 2>/dev/null || true

echo "== silence DietPi preboot/postboot console narration =="
for svc in dietpi-preboot dietpi-postboot; do
  d="/etc/systemd/system/${svc}.service.d"
  mkdir -p "$d"
  printf '[Service]\nStandardOutput=null\nStandardError=null\n' > "$d/quiet.conf"
done

echo "== blank pre/post-login banners =="
for f in /etc/issue /etc/issue.net /etc/motd; do : > "$f"; done
[ -d /etc/update-motd.d ] && chmod -x /etc/update-motd.d/* 2>/dev/null || true

echo "== suppress DietPi ASCII banner on the appliance shell =="
touch /root/.hushlogin

echo "== run custom.sh directly on tty1 (no login layer, no 'automatic login' text) =="
GD=/etc/systemd/system/getty@tty1.service.d
mkdir -p "$GD"
cat > "$GD/dietpi-autologin.conf" <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --skip-login -J --noissue --nohostname --nonewline -l /var/lib/dietpi/dietpi-autostart/custom.sh %I $TERM
EOF

systemctl daemon-reload
echo "== done. reboot to see the clean boot. =="
