#!/bin/bash
#
# make-splash-assets.sh — generate every splash blob the appliance can need.
#
# The blobs are build artifacts (6.4 MB total) and are deliberately NOT in git.
# Run this on a machine with Python + Pillow, then copy the .raw files to
# /opt/x16 on the Pi. All three belong in the shipped image: x16-splash picks
# by framebuffer geometry, and a missing blob means a black screen instead of a
# splash on that hardware — silently, by design, since drawing a mismatched
# blob would garble the display.
#
#   1920x1080  HDMI default, Pi 3 and Pi 4
#   1280x720   Pi 3 on a TV that needs the lighter mode (hdmi_mode=4)
#    640x480   Pi 3 + VGA HAT (DPI output — no HDMI connector at all)
#
# Usage:  tools/make-splash-assets.sh [outdir]     (default: ./splash-out)
#
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-splash-out}"
mkdir -p "$OUT"

gen() {  # gen <width> <height> <rawname>
  python3 tools/gen_splash.py --width "$1" --height "$2" \
    --png "${OUT}/splash-${1}x${2}.png" --raw "${OUT}/$3"
  # bytes must equal width*height*2 (RGB565) or x16-splash will skip it
  want=$(( $1 * $2 * 2 ))
  have=$(stat -c %s "${OUT}/$3" 2>/dev/null || stat -f %z "${OUT}/$3")
  [ "$have" = "$want" ] || { echo "SIZE MISMATCH: $3 is $have, expected $want" >&2; exit 1; }
  echo "  ok  $3  ${have} bytes"
}

gen 1920 1080 x16-splash.raw
gen 1280 720  x16-splash-1280x720.raw
gen 640  480  x16-splash-640x480.raw

cat <<EOF

Written to ${OUT}/. Install on the Pi with:
  for f in ${OUT}/*.raw; do ssh <pi> "cat > /opt/x16/\$(basename \$f)" < "\$f"; done
  ssh <pi> 'chmod 644 /opt/x16/x16-splash*.raw'
EOF
