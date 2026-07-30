#!/bin/bash
#
# set-fat-label.sh — give the captured image's FAT boot partition a volume label.
#
# Runs on Linux (WSL Ubuntu), offline, on an image file. Between capture and
# shrink, like refit-fat.sh.
#
#   set-fat-label.sh [--label X16PI] [--check] <image.img>
#
# WHY THIS EXISTS SEPARATELY FROM refit-fat.sh: the label used to be a side
# effect of the refit (mkfs.vfat -n), and the refit is now OFF by default —
# 128 MB is the size we ship, so nothing rebuilds the partition and nothing set
# the label. A shipped card showed up in Windows as "Removable Disk (E:)", which
# is the owner's very first impression of the machine.
#
# WHY OFFLINE, when fatlabel could run on the Pi: /boot/firmware is mounted
# there, and its x16/ folder is bind-mounted into the running emulator's fsroot.
# Relabelling a live, mounted FAT means the kernel's cached boot sector can win
# on unmount, so the change may or may not stick. On an image nothing is mounted
# and the result is deterministic.
#
# WHAT IT DOES NOT CHANGE — the point, given how much of this repo is about
# identifiers being invalidated by tools that never touched them:
#
#   * the FAT volume serial (its UUID). /etc/fstab mounts /boot/firmware by
#     UUID; fatlabel writes only the label field, so the mount is unaffected.
#   * the MBR disk identifier, so root=PARTUUID=<diskid>-02 still resolves.
#   * the partition table, and every file in either filesystem.
#
# Verified by reading the UUID back and comparing, because "cosmetic change
# quietly breaks the boot" is exactly the failure this project keeps hitting.
#
set -euo pipefail

LABEL="X16PI"
CHECK_ONLY=0
IMG=""

usage() { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --label)   LABEL="$2"; shift 2 ;;
    --check)   CHECK_ONLY=1; shift ;;
    -h|--help) usage 0 ;;
    -*) echo "unknown option: $1" >&2; usage 2 ;;
    *)  IMG="$1"; shift ;;
  esac
done

[ -n "$IMG" ] || usage 2
[ -f "$IMG" ] || { echo "no such image: $IMG" >&2; exit 2; }
[ "$(id -u)" = 0 ] || exec sudo -- "$0" "$@"

# FAT volume labels are 11 bytes, uppercase, no spaces at the start, and a short
# list of punctuation is illegal. Reject rather than let mkfs/fatlabel silently
# truncate — a truncated label ships and nobody notices until a card is in a PC.
if [ "$CHECK_ONLY" = 0 ]; then
  case "$LABEL" in
    "") echo "empty --label: pass a name, or use --check to just report" >&2; exit 2 ;;
    *[!A-Za-z0-9_-]*) echo "label '$LABEL' has characters FAT does not allow (A-Z 0-9 _ -)" >&2; exit 2 ;;
  esac
  [ "${#LABEL}" -le 11 ] || { echo "label '$LABEL' is ${#LABEL} chars; FAT allows 11" >&2; exit 2; }
  LABEL=$(printf '%s' "$LABEL" | tr '[:lower:]' '[:upper:]')
fi

for t in losetup blkid fatlabel fsck.vfat; do
  command -v "$t" >/dev/null || { echo "missing tool: $t (sudo apt-get install -y dosfstools util-linux)" >&2; exit 1; }
done

LOOP=""
cleanup() { [ -n "$LOOP" ] && losetup -d "$LOOP" || true; }
trap cleanup EXIT

LOOP=$(losetup -Pf --show "$IMG")
sleep 0.3
P1="${LOOP}p1"
[ -b "$P1" ] || { echo "no partition 1 on $LOOP — is this a whole-card image?" >&2; exit 1; }

UUID_BEFORE=$(blkid -o value -s UUID "$P1" || true)
LABEL_BEFORE=$(blkid -o value -s LABEL "$P1" || true)
echo "image:  $IMG"
echo "FAT:    $P1  label '${LABEL_BEFORE:-none}'  serial ${UUID_BEFORE:-unknown}"

if [ "$CHECK_ONLY" = 1 ]; then
  [ -n "$LABEL_BEFORE" ] || { echo "no volume label set"; exit 1; }
  echo "label is '$LABEL_BEFORE'"
  exit 0
fi

if [ "$LABEL_BEFORE" = "$LABEL" ]; then
  echo "already labelled '$LABEL' — nothing to do"
  exit 0
fi

# A capture taken from a running Pi has the FAT's dirty bit set, and fatlabel
# refuses to write to a volume flagged dirty. -a repairs without asking; there is
# nothing to lose here, the source of truth is still the card.
fsck.vfat -a "$P1" >/dev/null 2>&1 || true

fatlabel "$P1" "$LABEL"
sync

UUID_AFTER=$(blkid -o value -s UUID "$P1" || true)
LABEL_AFTER=$(blkid -o value -s LABEL "$P1" || true)

if [ "$LABEL_AFTER" != "$LABEL" ]; then
  echo "FAILED: label reads back as '${LABEL_AFTER:-none}', wanted '$LABEL'" >&2
  exit 1
fi
# The whole reason to verify: /etc/fstab mounts /boot/firmware by this UUID, and
# an image whose boot partition cannot be mounted fails late and quietly.
if [ "$UUID_AFTER" != "$UUID_BEFORE" ]; then
  echo "FAILED: the FAT volume serial changed, $UUID_BEFORE -> $UUID_AFTER.
  /etc/fstab mounts /boot/firmware by UUID, so this image would boot with no
  boot partition mounted. Do not ship it." >&2
  exit 1
fi

echo "label set to '$LABEL_AFTER'; volume serial unchanged ($UUID_AFTER)"
