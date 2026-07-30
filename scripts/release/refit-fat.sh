#!/bin/bash
#
# refit-fat.sh — rebuild a captured .img with a larger FAT boot partition.
#
# Runs on Linux (WSL Ubuntu), offline, on an image file.
#
# WHY OFFLINE: growing FAT means the ext4 root has to START LATER, and you cannot
# move the start of a mounted root filesystem. There is no live path for this,
# on the Pi or anywhere else — it has to happen to an image, between capture and
# shrink. PiShrink's expansion only ever grows the LAST partition, so FAT's size
# is fixed for good at the moment the shipped image is built (DOC/07 Part A2).
#
# WHAT IT PRESERVES — this is the whole trick, and it is why nothing needs
# editing afterwards:
#
#   * the MBR disk identifier, so PARTUUIDs are unchanged. cmdline.txt says
#     root=PARTUUID=<diskid>-02, which is derived from disk id + partition
#     number — keep both and it still resolves.
#   * the root filesystem's UUID, because the root partition is copied RAW,
#     sector for sector. /etc/fstab mounts / by UUID; a raw copy is the same
#     filesystem at a different offset.
#   * the FAT volume serial, set explicitly with mkfs.vfat -i. fstab mounts
#     /boot/firmware by UUID too, and a fresh mkfs would otherwise invent a new
#     one and leave the boot partition unmountable.
#
# So TODO.md's warning — "repartitioning changes PARTUUID/UUIDs, update
# cmdline.txt and both fstab lines or it won't boot" — is avoidable rather than
# unavoidable. Nothing inside either filesystem is touched.
#
# Pi boot needs no bootloader in the MBR: the firmware reads bootcode.bin and
# start.elf as FILES from the FAT partition, so a fresh partition table with the
# same files is a complete boot device.
#
set -euo pipefail

FAT_MB=256
# Sectors per cluster for the new FAT32. NOT left to mkfs.vfat's default, and
# this is not a tuning knob — it is a boot-or-not setting.
#
# Auto-selection gave 1 sector (512 B) clusters on a 256 MB partition: 522,205
# clusters and a 2 MB FAT table, far outside what any stock Pi image looks like.
# The Pi firmware then could not read the partition at all — no rainbow splash,
# no start4.elf, dead before Linux. The image was otherwise byte-identical to a
# known-good one.
#
# 4 sectors (2 KB clusters) is what Raspberry Pi's own pi-gen forces
# ("mkdosfs -F 32 -s 4"), and DietPi's stock 128 MB boot partition uses 2.
# At 256 MB this gives ~131k clusters and a 512 KB FAT — comfortably normal.
# Keep it >= 65,525 clusters or the volume stops being valid FAT32.
CLUSTER_SECTORS=4
# The shipped volume label. mkfs.vfat here creates a fresh FAT, so without this
# a refit would strip a label that set-fat-label.sh had already applied.
LABEL="X16PI"
OUT=""
IMG=""

usage() { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --fat-mb)  FAT_MB="$2"; shift 2 ;;
    --cluster-sectors) CLUSTER_SECTORS="$2"; shift 2 ;;
    --label)   LABEL="$2"; shift 2 ;;
    -o|--output) OUT="$2"; shift 2 ;;
    -h|--help) usage 0 ;;
    -*) echo "unknown option: $1" >&2; usage 2 ;;
    *)  IMG="$1"; shift ;;
  esac
done

[ -n "$IMG" ] || usage 2
[ -f "$IMG" ] || { echo "no such image: $IMG" >&2; exit 2; }
[ "$(id -u)" = 0 ] || exec sudo -- "$0" "$@"
# sfdisk -d echoes back the path it was given, and the parsing below matches on
# it, so pin it to one canonical form.
IMG=$(readlink -f "$IMG")
[ -n "$OUT" ] || OUT="${IMG%.img}-fat${FAT_MB}.img"

for t in sfdisk losetup blkid mkfs.vfat e2fsck fsck.vfat; do
  command -v "$t" >/dev/null || { echo "missing tool: $t (sudo apt-get install -y dosfstools util-linux e2fsprogs)" >&2; exit 1; }
done

human() { numfmt --to=iec --suffix=B "$1"; }

SRC_LOOP=""; DST_LOOP=""; SRC_P1=""; DST_P1=""
M_SRC=$(mktemp -d); M_DST=$(mktemp -d)
cleanup() {
  mountpoint -q "$M_SRC" && umount "$M_SRC" || true
  mountpoint -q "$M_DST" && umount "$M_DST" || true
  for l in $SRC_P1 $DST_P1 $SRC_LOOP $DST_LOOP; do losetup -d "$l" 2>/dev/null || true; done
  rmdir "$M_SRC" "$M_DST" 2>/dev/null || true
}
trap cleanup EXIT

# ---- read the source layout --------------------------------------------------
DUMP=$(sfdisk -d "$IMG")
DISK_ID=$(printf '%s\n' "$DUMP" | sed -n 's/^label-id: *//p')
printf '%s\n' "$DUMP" | grep -q '^label: dos' || { echo "not an MBR image — refusing" >&2; exit 1; }

NPARTS=$(printf '%s\n' "$DUMP" | grep -c "^${IMG}[0-9]")
[ "$NPARTS" = 2 ] || {
  echo "expected exactly 2 partitions (FAT boot + ext4 root), found $NPARTS." >&2
  echo "Moving the root partition is only safe when it is the last one." >&2
  exit 1; }

# sfdisk -d lines look like:  /path/img1 : start=  2048, size=  262144, type=c, bootable
get() { printf '%s\n' "$DUMP" | awk -v p="${IMG}$1" -v k="$2" -F, '
  index($0, p " ") == 1 {
    for (i = 1; i <= NF; i++) {
      n = split($i, a, "="); if (n < 2) continue
      gsub(/[ \t]/, "", a[1]); gsub(/[ \t]/, "", a[2])
      if (a[1] == k || a[1] ~ ":" k "$") print a[2]
    }
  }'; }
P1_START=$(get 1 start); P1_SIZE=$(get 1 size); P1_TYPE=$(get 1 type)
P2_START=$(get 2 start); P2_SIZE=$(get 2 size); P2_TYPE=$(get 2 type)
for v in P1_START P1_SIZE P1_TYPE P2_START P2_SIZE P2_TYPE; do
  [ -n "${!v}" ] || { echo "could not read $v from the partition table" >&2; exit 1; }
done
BOOTABLE=""
printf '%s\n' "$DUMP" | grep "^${IMG}1" | grep -q 'bootable' && BOOTABLE=", bootable"

# ---- identity we must carry across -------------------------------------------
SRC_P1=$(losetup -rf --show -o $((P1_START * 512)) --sizelimit $((P1_SIZE * 512)) "$IMG")
FAT_UUID=$(blkid -o value -s UUID "$SRC_P1" || true)       # e.g. 3075-27E1
SRC_LABEL=$(blkid -o value -s LABEL "$SRC_P1" || true)
[ -n "$LABEL" ] || LABEL="$SRC_LABEL"
FAT_SERIAL=$(printf '%s' "$FAT_UUID" | tr -d '-')          # mkfs.vfat -i wants 8 hex digits
[ -n "$FAT_SERIAL" ] || { echo "could not read the FAT volume serial — refusing to invent one" >&2; exit 1; }

NEW_P1_SIZE=$((FAT_MB * 1024 * 1024 / 512))
NEW_P2_START=$((P1_START + NEW_P1_SIZE))
# Keep the root partition on a 4 MiB boundary; SD cards erase in large blocks
# and a misaligned filesystem pays for it on every write.
ALIGN=8192
NEW_P2_START=$(( (NEW_P2_START + ALIGN - 1) / ALIGN * ALIGN ))
NEW_P1_SIZE=$((NEW_P2_START - P1_START))
NEW_TOTAL=$(( (NEW_P2_START + P2_SIZE) * 512 ))

# Any size is allowed — bigger, same, or smaller — as long as what is on the FAT
# still fits with room to spare. The real constraint was never the old partition
# size, it is the boot files. Same size is how you rebuild the cluster geometry
# without re-capturing; smaller is how you walk a decision back.
M_TMP=$(mktemp -d)
mount -o ro "$SRC_P1" "$M_TMP"
FAT_USED=$(( $(du -sk --apparent-size "$M_TMP" | cut -f1) * 1024 ))
umount "$M_TMP"; rmdir "$M_TMP"
NEED=$(( FAT_USED + FAT_USED / 5 + 16777216 ))   # contents + 20% + 16 MB headroom
if [ $((NEW_P1_SIZE * 512)) -lt "$NEED" ]; then
  echo "--fat-mb $FAT_MB is too small: the boot partition holds $(human "$FAT_USED")," >&2
  echo "which needs at least $(human "$NEED") once headroom is allowed for." >&2
  exit 1
fi

cat <<EOF

source:      $IMG ($(human "$(stat -c %s "$IMG")"))
  disk id:   $DISK_ID          -> PARTUUIDs preserved
  FAT:       $((P1_SIZE / 2048)) MiB, UUID $FAT_UUID${SRC_LABEL:+, label '$SRC_LABEL'}
  root:      $((P2_SIZE / 2048)) MiB at sector $P2_START

target:      $OUT ($(human "$NEW_TOTAL"))
  FAT:       $((NEW_P1_SIZE / 2048)) MiB, same UUID${LABEL:+, label '$LABEL'}
  root:      unchanged, moved to sector $NEW_P2_START (raw copy, same filesystem UUID)

EOF

# ---- build the new image -----------------------------------------------------
rm -f "$OUT"
truncate -s "$NEW_TOTAL" "$OUT"
sfdisk -q "$OUT" >/dev/null <<EOF
label: dos
label-id: $DISK_ID
start=$P1_START, size=$NEW_P1_SIZE, type=$P1_TYPE$BOOTABLE
start=$NEW_P2_START, size=$P2_SIZE, type=$P2_TYPE
EOF

DST_P1=$(losetup -f --show -o $((P1_START * 512)) --sizelimit $((NEW_P1_SIZE * 512)) "$OUT")
MKFS=(mkfs.vfat -F 32 -s "$CLUSTER_SECTORS" -i "$FAT_SERIAL")
[ -n "$LABEL" ] && MKFS+=(-n "$LABEL")
"${MKFS[@]}" "$DST_P1" >/dev/null
CLUSTERS=$(fsck.vfat -v -n "$DST_P1" 2>/dev/null | sed -n 's/^ *\([0-9]*\) data clusters.*/\1/p')
echo "created FAT32: $((CLUSTER_SECTORS * 512)) B clusters, ${CLUSTERS:-?} of them, serial $FAT_SERIAL${LABEL:+, label '$LABEL'}"
# Below 65,525 clusters a volume is no longer FAT32 by definition, and mkfs will
# have quietly made something the firmware reads differently than intended.
if [ -n "$CLUSTERS" ] && [ "$CLUSTERS" -lt 65525 ]; then
  echo "!! only $CLUSTERS clusters — too few for valid FAT32. Lower --cluster-sectors." >&2
  exit 1
fi

# FAT carries no ownership or permissions, so a plain recursive copy is a
# complete reproduction. System Volume Information is Windows' own litter and is
# never wanted; prep-image-source.sh removes it too.
mount -o ro "$SRC_P1" "$M_SRC"
mount "$DST_P1" "$M_DST"
( cd "$M_SRC" && tar -cf - --exclude='./System Volume Information' . ) | ( cd "$M_DST" && tar -xf - )
sync
SRC_FILES=$(find "$M_SRC" -type f -not -path '*System Volume Information*' | wc -l)
DST_FILES=$(find "$M_DST" -type f | wc -l)
umount "$M_SRC"; umount "$M_DST"
echo "copied boot files: $SRC_FILES -> $DST_FILES"
[ "$SRC_FILES" = "$DST_FILES" ] || { echo "!! file count mismatch on the FAT partition" >&2; exit 1; }

# Raw copy of root: this is what keeps the ext4 UUID, and with it the fstab
# entry, without touching a single byte inside the filesystem.
echo "copying the root partition ($(human $((P2_SIZE * 512))))..."
SRC_LOOP=$(losetup -rf --show -o $((P2_START * 512)) --sizelimit $((P2_SIZE * 512)) "$IMG")
DST_LOOP=$(losetup -f  --show -o $((NEW_P2_START * 512)) --sizelimit $((P2_SIZE * 512)) "$OUT")
dd if="$SRC_LOOP" of="$DST_LOOP" bs=4M status=progress conv=fsync
sync

# ---- verify ------------------------------------------------------------------
echo
echo "== verify =="
fsck.vfat -n "$DST_P1" >/dev/null 2>&1 && echo "PASS  new FAT is clean" || echo "WARN  fsck.vfat reported issues"
NEW_FAT_UUID=$(blkid -o value -s UUID "$DST_P1")
[ "$NEW_FAT_UUID" = "$FAT_UUID" ] \
  && echo "PASS  FAT UUID preserved ($NEW_FAT_UUID) — /etc/fstab still mounts /boot/firmware" \
  || { echo "FAIL  FAT UUID changed: $FAT_UUID -> $NEW_FAT_UUID"; exit 1; }
SRC_ROOT_UUID=$(blkid -o value -s UUID "$SRC_LOOP")
NEW_ROOT_UUID=$(blkid -o value -s UUID "$DST_LOOP")
[ "$SRC_ROOT_UUID" = "$NEW_ROOT_UUID" ] \
  && echo "PASS  root UUID preserved ($NEW_ROOT_UUID) — /etc/fstab still mounts /" \
  || { echo "FAIL  root UUID changed"; exit 1; }
e2fsck -fn "$DST_LOOP" >/dev/null 2>&1 \
  && echo "PASS  root filesystem is clean" \
  || echo "WARN  e2fsck found issues (expected on a live capture; PiShrink repairs it next)"
NEW_ID=$(sfdisk -d "$OUT" | sed -n 's/^label-id: *//p')
[ "$NEW_ID" = "$DISK_ID" ] \
  && echo "PASS  disk id preserved ($NEW_ID) — cmdline.txt root=PARTUUID still resolves" \
  || { echo "FAIL  disk id changed"; exit 1; }

echo
sfdisk -lq "$OUT"
echo
echo "source left alone: $IMG"
echo "Next: scripts/release/check-image.sh $OUT   then shrink-image.sh $OUT"
