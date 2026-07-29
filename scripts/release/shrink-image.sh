#!/bin/bash
#
# shrink-image.sh — turn a captured .img into the shippable .img.gz.
#
# Runs on Linux (WSL Ubuntu) via the vendored tools/pishrink/pishrink.sh.
# Shrinks the ext4 root to its used size, then gzips — a 32 GB capture comes out
# around 600 MB. The FAT partition is NOT touched and NOT resized, by anyone,
# ever: its size was fixed when the image was built (DOC/07 Part A2).
#
# PiShrink is always invoked with -s -n. Both matter:
#
#   -s   Skip PiShrink's own first-boot expansion. It works by writing an
#        /etc/rc.local that calls `raspi-config --expand-rootfs` — Raspberry Pi
#        OS's mechanism, and this image is DietPi: no rc.local, no raspi-config.
#        DietPi's dietpi-fs_partition_resize.service does the job properly and
#        much earlier in boot. See tools/pishrink/VENDORED.md.
#        The catch: that service disarms itself after it runs, so the capture
#        must be taken from a Pi where it was re-armed. check-image.sh verifies
#        this, which is why it runs first.
#
#   -n   No update check — a release build shouldn't need github.com to be up.
#
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PISHRINK="$HERE/../../tools/pishrink/pishrink.sh"
IMG=""
OUT=""
ZIP=-z            # gzip; --xz switches to -Z
RUN_CHECK=1

usage() { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -o|--output) OUT="$2"; shift 2 ;;
    --xz)        ZIP=-Z; shift ;;
    --no-check)  RUN_CHECK=0; shift ;;
    -h|--help)   usage 0 ;;
    -*) echo "unknown option: $1" >&2; usage 2 ;;
    *)  IMG="$1"; shift ;;
  esac
done

[ -n "$IMG" ] || usage 2
[ -f "$IMG" ] || { echo "no such image: $IMG" >&2; exit 2; }
[ -f "$PISHRINK" ] || { echo "vendored PiShrink missing at $PISHRINK" >&2; exit 1; }
[ "$(id -u)" = 0 ] || exec sudo -- "$0" "$@"

# PiShrink's own REQUIRED_TOOLS, checked here so the failure is one line rather
# than one line per missing tool halfway through.
MISSING=""
for t in parted losetup tune2fs md5sum e2fsck resize2fs; do
  command -v "$t" >/dev/null || MISSING="$MISSING $t"
done
command -v gzip >/dev/null || [ "$ZIP" = -Z ] || MISSING="$MISSING gzip"
if [ -n "$MISSING" ]; then
  echo "missing tools:$MISSING" >&2
  echo "  sudo apt-get install -y parted e2fsprogs util-linux gzip" >&2
  exit 1
fi

if [ "$ZIP" = -z ] && ! command -v pigz >/dev/null; then
  echo "note: install pigz for a much faster gzip (sudo apt-get install -y pigz)"
fi

if [ "$RUN_CHECK" = 1 ]; then
  echo "== ship-readiness check =="
  "$HERE/check-image.sh" "$IMG" || {
    echo
    echo "check-image.sh failed. Fix the image and re-capture, or re-run with" >&2
    echo "--no-check if you know why you are shipping it anyway." >&2
    exit 1
  }
  echo
fi

BEFORE=$(stat -c %s "$IMG")
# PiShrink shrinks by DELETING and RECREATING the last partition with parted
# (pishrink.sh:392-399), and the rebuilt table can carry a different MBR disk
# signature. cmdline.txt pins root=PARTUUID=<signature>-02, so a new signature
# is an image that loads the kernel and then hangs forever on rootwait behind a
# black screen. Record it now; restore it after.
DISK_ID_BEFORE=$(sfdisk -d "$IMG" 2>/dev/null | sed -n 's/^label-id: *//p')
echo "MBR disk id before shrink: ${DISK_ID_BEFORE:-unknown}"

echo
echo "== shrink =="
chmod +x "$PISHRINK"
# Compression is done here rather than by PiShrink's -z: the disk id has to be
# repaired while the result is still a raw image, not a .gz.
if [ -n "$OUT" ]; then
  # PiShrink copies to the new name first, so this needs room for BOTH images.
  "$PISHRINK" -s -n "$IMG" "$OUT"
  RESULT="$OUT"
else
  # In place: the raw capture is consumed. Re-capturing is cheaper than the disk.
  "$PISHRINK" -s -n "$IMG"
  RESULT="$IMG"
fi

DISK_ID_AFTER=$(sfdisk -d "$RESULT" 2>/dev/null | sed -n 's/^label-id: *//p')
if [ -n "$DISK_ID_BEFORE" ] && [ "$DISK_ID_AFTER" != "$DISK_ID_BEFORE" ]; then
  echo "!! PiShrink changed the MBR disk id: $DISK_ID_BEFORE -> $DISK_ID_AFTER"
  echo "   restoring it, or root=PARTUUID in cmdline.txt would never resolve"
  sfdisk --disk-id "$RESULT" "$DISK_ID_BEFORE"
  DISK_ID_AFTER=$(sfdisk -d "$RESULT" | sed -n 's/^label-id: *//p')
  [ "$DISK_ID_AFTER" = "$DISK_ID_BEFORE" ] \
    && echo "   restored: $DISK_ID_AFTER" \
    || { echo "   FAILED to restore the disk id — do not ship this" >&2; exit 1; }
else
  echo "MBR disk id after shrink:  ${DISK_ID_AFTER:-unknown} (unchanged)"
fi

# Re-assert that the image can actually boot, now that the partition table has
# been rewritten. This is the check whose absence shipped an unbootable image.
if [ "$RUN_CHECK" = 1 ]; then
  echo
  echo "== post-shrink identifier re-check =="
  "$HERE/check-image.sh" "$RESULT" >/dev/null 2>&1 || {
    echo "post-shrink check FAILED — re-running it visibly:" >&2
    "$HERE/check-image.sh" "$RESULT" >&2 || true
    exit 1
  }
  echo "identifiers still resolve"
fi

echo
echo "== compress =="
if [ "$ZIP" = -Z ]; then
  xz -T0 -f "$RESULT"
elif command -v pigz >/dev/null; then
  pigz -f -9 "$RESULT"
else
  gzip -f -9 "$RESULT"
fi

EXT=gz; [ "$ZIP" = -Z ] && EXT=xz
FINAL="$RESULT.$EXT"
if [ ! -f "$FINAL" ]; then
  echo "expected $FINAL, not found — check pishrink.log" >&2
  # An interrupted PiShrink leaves its loop devices attached, and a loop holding
  # a deleted image file keeps that disk space allocated with nothing to show
  # for it. There are usually several by the time anyone notices.
  echo "stale loop devices from the failed run, if any:" >&2
  losetup -a >&2 || true
  echo "  detach with: sudo losetup -d /dev/loopN   (or losetup -D for all)" >&2
  exit 1
fi

AFTER=$(stat -c %s "$FINAL")
echo
echo "$FINAL"
echo "  $(numfmt --to=iec --suffix=B "$BEFORE") captured -> $(numfmt --to=iec --suffix=B "$AFTER") shipped"
echo "  sha256: $(sha256sum "$FINAL" | cut -d' ' -f1)"
echo
echo "Gate 5 is not passed until this has been flashed to a BLANK card and booted"
echo "a second Pi through Gate 3 — including 'df -h /' showing the root expanded."
