#!/bin/dash
#
# x16-splash — paint the appliance boot splash onto the console framebuffer.
#
# The Pi's KMS console fb (/dev/fb0) is RGB565 1920x1080; we just write a
# pre-rendered raw blob straight to it. The image then persists as a static
# picture (no viewer process) until x16emu's KMS modeset paints over it.
#
# Model-agnostic: Pi 3 and Pi 4 both expose /dev/fb0 via vc4-kms-v3d. If the
# panel runs at 720p, regenerate the blob at that size (tools/gen_splash.py
# --width 1280 --height 720) and point RAW at it — a size mismatch is skipped
# safely rather than drawn garbled.
#
# Run early via the x16-splash systemd service, and again from custom.sh right
# before launch so the freshest frame is the splash.
#
# INSTALL: sudo install -m 0755 x16-splash.sh /usr/local/bin/x16-splash
#
FB=/dev/fb0
RAW="${X16_SPLASH_RAW:-/opt/x16/x16-splash.raw}"

# Wait up to ~12s for the KMS framebuffer to appear (it comes up with vc4).
i=0
while [ ! -e "$FB" ] && [ "$i" -lt 48 ]; do
  i=$((i + 1)); sleep 0.25
done
[ -e "$FB" ] || exit 0
[ -f "$RAW" ] || exit 0

# Only draw if the blob matches the current fb size (bytes = stride * yres).
stride=$(cat /sys/class/graphics/fb0/stride 2>/dev/null || echo 0)
yres=$(cut -d, -f2 /sys/class/graphics/fb0/virtual_size 2>/dev/null || echo 0)
want=$(( stride * yres ))
have=$(stat -c %s "$RAW" 2>/dev/null || echo -1)
if [ "$want" -gt 0 ] && [ "$have" -ne "$want" ]; then
  # size mismatch (e.g. 720p panel with a 1080p blob) — skip rather than garble
  exit 0
fi

cat "$RAW" > "$FB" 2>/dev/null || true
