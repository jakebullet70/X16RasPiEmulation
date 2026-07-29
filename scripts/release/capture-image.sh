#!/bin/bash
#
# capture-image.sh — read the appliance SD card into a raw .img.
#
# Runs on Linux. On this box that means WSL Ubuntu ("wsl" in a terminal), not
# PowerShell — Windows has no dd, and Win32DiskImager can read a card but the
# shrink step (scripts/release/shrink-image.sh) needs Linux loop devices anyway.
#
# Two sources:
#
#   --from-device /dev/sdX    The card in a USB reader. PREFERRED: the
#                             filesystem is not mounted, so the capture is a
#                             clean point-in-time copy. Attach the reader to
#                             WSL first, from an ADMIN PowerShell:
#                                 wsl --mount \\.\PHYSICALDRIVE2 --bare
#                             (find the number with: wmic diskdrive list brief)
#                             then in WSL:  lsblk
#
#   --from-ssh USER@HOST      dd the card out of a RUNNING Pi. Convenient — no
#                             physical access, nothing to unplug — but it is a
#                             snapshot of a live, mounted, read-write
#                             filesystem, so the image lands slightly
#                             inconsistent. In practice this survives because
#                             PiShrink runs `e2fsck -pf` before resizing and
#                             repairs it. Stop the emulator and sync first
#                             (this script asks the Pi to sync).
#
# The image comes out the full size of the card — 32 GB of mostly nothing. That
# is expected: shrink-image.sh cuts it down to the used size afterwards.
#
set -euo pipefail

OUT=x16-appliance-r49.img
SRC_KIND=""
SRC=""
CARD_DEV=/dev/mmcblk0
SSH_PORT=22
SSH_KEY=""
TRANSPORT_GZIP=0
ASSUME_YES=0
FORCE=0

# Print this file's own header block, however long it grows.
usage() { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --from-device) SRC_KIND=device; SRC="$2"; shift 2 ;;
    --from-ssh)    SRC_KIND=ssh;    SRC="$2"; shift 2 ;;
    --card-device) CARD_DEV="$2"; shift 2 ;;
    --ssh-port)    SSH_PORT="$2"; shift 2 ;;
    --ssh-key)     SSH_KEY="$2"; shift 2 ;;
    --transport-gzip) TRANSPORT_GZIP=1; shift ;;
    -o|--output)   OUT="$2"; shift 2 ;;
    -y|--yes)      ASSUME_YES=1; shift ;;
    --force)       FORCE=1; shift ;;
    -h|--help)     usage 0 ;;
    *) echo "unknown option: $1" >&2; usage 2 ;;
  esac
done

[ -n "$SRC_KIND" ] || { echo "give --from-device /dev/sdX or --from-ssh user@host" >&2; usage 2; }
command -v dd >/dev/null || { echo "no dd — are you in WSL/Linux?" >&2; exit 1; }

if [ -e "$OUT" ] && [ "$FORCE" != 1 ]; then
  echo "$OUT exists (delete it, or pass --force)." >&2
  exit 1
fi

human() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "$1 bytes"; }

# ---- work out the source size, and refuse the obviously wrong device --------
if [ "$SRC_KIND" = device ]; then
  [ -b "$SRC" ] || { echo "$SRC is not a block device." >&2; exit 1; }
  [ "$(lsblk -ndo TYPE "$SRC")" = disk ] || {
    echo "$SRC is a partition, not the whole card. Capture the whole disk." >&2; exit 1; }
  ROOT_DISK=$(lsblk -ndo PKNAME "$(findmnt -no SOURCE / 2>/dev/null || echo /dev/null)" 2>/dev/null || true)
  [ -n "$ROOT_DISK" ] && [ "/dev/$ROOT_DISK" = "$SRC" ] && {
    echo "$SRC holds this machine's root filesystem. Refusing." >&2; exit 1; }
  if lsblk -nro MOUNTPOINT "$SRC" | grep -q .; then
    echo "warning: partitions of $SRC are mounted:"
    lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT "$SRC"
    echo "         unmount them first — a mounted card gives an inconsistent image."
  fi
  SRC_BYTES=$(blockdev --getsize64 "$SRC")
  lsblk -o NAME,SIZE,FSTYPE,LABEL,MODEL "$SRC"
else
  # accept-new, not the default "ask": this runs unattended (make-release.ps1
  # drives it through WSL, often as root, whose known_hosts is empty), and an
  # interactive "authenticity of host can't be established" prompt with no
  # terminal to answer it just hangs forever. accept-new still records the key,
  # so a LATER change is still refused — it only skips the first-contact prompt.
  # LogLevel=ERROR silences ssh's informational chatter on stderr. Newer OpenSSH
  # prints "** WARNING: connection is not using a post-quantum key exchange
  # algorithm." on every connection, which is harmless here (a LAN capture from
  # our own Pi) but is not harmless to the caller: make-release.ps1 drives this
  # through wsl.exe, and PowerShell 5.1 turns any stderr line from a native
  # executable into a NativeCommandError — so under $ErrorActionPreference =
  # 'Stop' a cosmetic warning aborted the whole release before it copied a byte.
  # Real problems (host key mismatch, auth failure) are ERROR level and still show.
  SSH_OPTS=(-p "$SSH_PORT" -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR)
  if [ -n "$SSH_KEY" ]; then
    # A key on /mnt/c is world-readable (9p mounts everything 0777) and ssh
    # refuses it outright. Copy to a private temp file rather than making the
    # user care.
    if [ "$(stat -c %a "$SSH_KEY")" != 600 ] && [ "$(stat -c %a "$SSH_KEY")" != 400 ]; then
      TMPKEY=$(mktemp); chmod 600 "$TMPKEY"; cat "$SSH_KEY" > "$TMPKEY"
      trap 'rm -f "$TMPKEY"' EXIT
      SSH_KEY="$TMPKEY"
    fi
    SSH_OPTS+=(-i "$SSH_KEY" -o IdentitiesOnly=yes)
  fi
  echo "checking $SRC ..."
  REMOTE_UID=$(ssh "${SSH_OPTS[@]}" "$SRC" 'id -u')
  SUDO=""; [ "$REMOTE_UID" = 0 ] || SUDO="sudo "
  SRC_BYTES=$(ssh "${SSH_OPTS[@]}" "$SRC" "${SUDO}blockdev --getsize64 $CARD_DEV")
  echo "  $SRC:$CARD_DEV = $(human "$SRC_BYTES")"
  if ssh "${SSH_OPTS[@]}" "$SRC" 'test -L /etc/systemd/system/local-fs.target.wants/dietpi-fs_partition_resize.service'; then
    echo "  first-boot resize: ARMED"
  else
    echo "  !! first-boot resize is NOT armed — this image would never expand on"
    echo "     the owner's card. Run scripts/release/prep-image-source.sh --apply"
    echo "     on the Pi first (and do not reboot afterwards)."
  fi
fi

AVAIL=$(df -B1 --output=avail "$(dirname "$(readlink -f "$OUT" 2>/dev/null || echo "$OUT")")" | tail -1)
echo
echo "source:      $SRC ($(human "$SRC_BYTES"))"
echo "destination: $OUT"
echo "free space:  $(human "$AVAIL")"
if [ "$AVAIL" -lt "$SRC_BYTES" ]; then
  echo "!! not enough room. Write to WSL's own filesystem (~/ ) rather than /mnt/c:" >&2
  echo "   9p is slow and the Windows drive is usually the fuller one." >&2
  exit 1
fi

if [ "$ASSUME_YES" != 1 ]; then
  printf 'Capture now? [y/N] '
  read -r reply
  case "$reply" in y|Y|yes|YES) ;; *) echo "aborted."; exit 1 ;; esac
fi

# ---- the copy ---------------------------------------------------------------
START=$(date +%s)
if [ "$SRC_KIND" = device ]; then
  dd if="$SRC" of="$OUT" bs=4M status=progress conv=fsync
else
  # status=progress writes to stderr, which ssh brings back, so the remote read
  # reports its own progress. iflag=fullblock matters on the receiving end:
  # short reads from a pipe would otherwise produce short output blocks.
  if [ "$TRANSPORT_GZIP" = 1 ]; then
    ssh "${SSH_OPTS[@]}" "$SRC" "${SUDO}sync; ${SUDO}dd if=$CARD_DEV bs=4M status=progress | gzip -1" \
      | gunzip | dd of="$OUT" bs=4M iflag=fullblock conv=fsync
  else
    ssh "${SSH_OPTS[@]}" "$SRC" "${SUDO}sync; ${SUDO}dd if=$CARD_DEV bs=4M status=progress" \
      | dd of="$OUT" bs=4M iflag=fullblock conv=fsync
  fi
fi
sync
ELAPSED=$(( $(date +%s) - START ))

# ---- did we get a whole, plausible card? ------------------------------------
GOT=$(stat -c %s "$OUT")
echo
echo "captured $(human "$GOT") in ${ELAPSED}s -> $OUT"
if [ "$GOT" != "$SRC_BYTES" ]; then
  echo "!! size mismatch: source was $(human "$SRC_BYTES"). The copy is short —" >&2
  echo "   do not ship this. Re-run the capture." >&2
  exit 1
fi

echo
sfdisk -lq "$OUT" 2>/dev/null || fdisk -l "$OUT"
PARTS=$(sfdisk -lqo Device "$OUT" 2>/dev/null | tail -n +2 | grep -c . || echo 0)
[ "$PARTS" -ge 2 ] || echo "!! expected at least 2 partitions (FAT boot + ext4 root)."

echo
echo "Next: scripts/release/shrink-image.sh $OUT"
