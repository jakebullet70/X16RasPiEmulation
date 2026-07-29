#!/bin/bash
#
# check-image.sh — read-only ship-readiness audit of a captured .img.
#
# Runs on Linux (WSL Ubuntu). Loop-mounts both partitions READ-ONLY and asserts
# the things that have shipped wrong, or nearly shipped wrong, before. Every
# check here exists because the failure it catches is silent: the image boots,
# nothing errors, and the owner just gets a machine that is subtly not the one
# we meant to send.
#
# Run it on the RAW capture, before shrinking — PiShrink replaces the .img with
# a .img.gz, and a failure is cheaper to find before the ten minutes of shrink.
#
#   FAIL  do not ship
#   WARN  judgement call
#   INFO  numbers to check the end-user README against
#
set -euo pipefail

IMG="${1:-}"
[ -n "$IMG" ] || { awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; exit 2; }
[ -f "$IMG" ] || { echo "no such image: $IMG" >&2; exit 2; }
[ "$(id -u)" = 0 ] || exec sudo -- "$0" "$@"

FAILED=0; WARNED=0
fail() { printf 'FAIL  %s\n' "$*"; FAILED=$((FAILED + 1)); }
warn() { printf 'WARN  %s\n' "$*"; WARNED=$((WARNED + 1)); }
pass() { printf 'PASS  %s\n' "$*"; }
info() { printf 'INFO  %s\n' "$*"; }

MNT_FAT=$(mktemp -d); MNT_ROOT=$(mktemp -d); LOOP=""
cleanup() {
  mountpoint -q "$MNT_FAT"  && umount "$MNT_FAT"  || true
  mountpoint -q "$MNT_ROOT" && umount "$MNT_ROOT" || true
  [ -n "$LOOP" ] && losetup -d "$LOOP" || true
  rmdir "$MNT_FAT" "$MNT_ROOT" 2>/dev/null || true
}
trap cleanup EXIT

LOOP=$(losetup -rPf --show "$IMG")   # -r: read-only, so nothing here can damage the image
sleep 0.3
mount -o ro "${LOOP}p1" "$MNT_FAT"
# A capture taken from a live Pi has a dirty journal, and a read-only loop
# device cannot replay it. noload skips recovery — fine, we only read.
mount -o ro "${LOOP}p2" "$MNT_ROOT" 2>/dev/null || mount -o ro,noload "${LOOP}p2" "$MNT_ROOT"

echo "image:  $IMG ($(numfmt --to=iec --suffix=B "$(stat -c %s "$IMG")"))"
echo "loop:   $LOOP"
echo

# ---- 0. the identifiers must actually resolve -------------------------------
# This exists because an image passed every other check here and still could not
# boot: PiShrink deletes and recreates the last partition with parted, and the
# rebuilt table carried a different MBR disk signature. cmdline.txt pins
# root=PARTUUID=<signature>-NN, so the kernel loaded, found no such partition,
# sat on rootwait and hung on a black screen — silently, because cmdline also
# carries quiet/loglevel=0. Nothing in the boot output says why.
echo "-- identifiers resolve --"
DISK_ID=$(sfdisk -d "$IMG" 2>/dev/null | sed -n 's/^label-id: *//p' | sed 's/^0x//')
ROOT_SPEC=$(tr ' ' '\n' < "$MNT_FAT/cmdline.txt" 2>/dev/null | sed -n 's/^root=//p' | head -1)
case "$ROOT_SPEC" in
  PARTUUID=*)
    WANT="${ROOT_SPEC#PARTUUID=}"; WANT_ID="${WANT%-*}"; WANT_PART="${WANT##*-}"
    if [ "$WANT_ID" = "$DISK_ID" ]; then
      pass "cmdline.txt root=PARTUUID=$WANT matches the image (disk id 0x$DISK_ID)"
    else
      fail "THIS IMAGE CANNOT BOOT. cmdline.txt says root=PARTUUID=$WANT but the
      image's MBR disk signature is 0x$DISK_ID. The kernel will load, fail to
      find that partition, and hang on rootwait behind a black screen with no
      message. Fix: sfdisk --disk-id <image> 0x$WANT_ID"
    fi
    [ "$WANT_PART" = 02 ] || warn "root=PARTUUID points at partition $WANT_PART, not 02"
    ;;
  "") warn "no root= in cmdline.txt" ;;
  *)  info "root spec is '$ROOT_SPEC' (not PARTUUID-based)" ;;
esac
# /etc/fstab mounts by filesystem UUID, which survives a raw copy but not a mkfs.
for ent in "/:${LOOP}p2" "/boot/firmware:${LOOP}p1"; do
  mp="${ent%%:*}"; dev="${ent#*:}"
  want=$(awk -v m="$mp" '$2==m && $1 ~ /^UUID=/ {sub(/^UUID=/,"",$1); print $1}' "$MNT_ROOT/etc/fstab" 2>/dev/null | head -1)
  [ -n "$want" ] || continue
  got=$(blkid -o value -s UUID "$dev" 2>/dev/null)
  [ "$want" = "$got" ] \
    && pass "fstab $mp UUID=$want matches the filesystem" \
    || fail "fstab mounts $mp by UUID=$want but the filesystem's UUID is '$got' —
      that mount will fail at boot"
done

# ---- 1. first-boot expansion ------------------------------------------------
echo
echo "-- first-boot expansion --"
if [ -L "$MNT_ROOT/etc/systemd/system/local-fs.target.wants/dietpi-fs_partition_resize.service" ]; then
  pass "dietpi-fs_partition_resize is armed"
else
  fail "dietpi-fs_partition_resize is NOT armed — the root filesystem will stay
      the size of the build card on every machine this is flashed to.
      Fix on the Pi: scripts/release/prep-image-source.sh --apply (then
      poweroff, do not reboot) and re-capture."
fi
[ -e "$MNT_ROOT/dietpi_skip_partition_resize" ] \
  && fail "/dietpi_skip_partition_resize present — the resize would skip repartitioning" \
  || pass "no leftover /dietpi_skip_partition_resize"
if [ -f "$MNT_ROOT/etc/rc.local" ] && grep -q PiShrink "$MNT_ROOT/etc/rc.local" 2>/dev/null; then
  fail "PiShrink's autoexpand rc.local is in this image — it calls raspi-config,
      which DietPi does not have. Shrink with -s (shrink-image.sh does)."
fi

# ---- 2. the appliance itself ------------------------------------------------
echo
echo "-- appliance --"
[ -x "$MNT_ROOT/var/lib/dietpi/dietpi-autostart/custom.sh" ] \
  && pass "custom.sh installed as the autostart target" \
  || fail "no /var/lib/dietpi/dietpi-autostart/custom.sh — this boots to a shell"
IDX=$(grep -oE '^AUTO_SETUP_AUTOSTART_TARGET_INDEX=[0-9]+' "$MNT_FAT/dietpi.txt" 2>/dev/null | cut -d= -f2 || true)
[ "$IDX" = 17 ] && pass "dietpi.txt autostart index 17" \
                || fail "dietpi.txt autostart index is '${IDX:-unset}', expected 17"
[ -x "$MNT_ROOT/opt/x16/x16emu" ] && pass "x16emu present" || fail "no /opt/x16/x16emu"
# serial-getty@ttyS0 waited out a full 90 s device timeout on every boot until
# trim-boot.sh disabled it. Shipping it enabled would silently hand every owner
# that stall back.
SGETTY=$(find "$MNT_ROOT/etc/systemd/system" -name 'serial-getty@*.service' -path '*.wants/*' 2>/dev/null | head -1)
[ -n "$SGETTY" ] \
  && fail "serial-getty is enabled ($(basename "$(dirname "$SGETTY")")/$(basename "$SGETTY")) —
      on a Pi 4 ttyS0 is a not-ready mini-UART, so the unit waits out a 90 s
      device timeout every single boot" \
  || pass "no serial-getty enabled"
# The unit being off is not enough: DietPi's own setting is what dietpi-config
# and DietPi updates act on, so a stale =1 can turn the getty back on later.
SC=$(grep -oE '^CONFIG_SERIAL_CONSOLE_ENABLE=[0-9]+' "$MNT_FAT/dietpi.txt" 2>/dev/null | cut -d= -f2)
case "$SC" in
  0) pass "dietpi.txt agrees: CONFIG_SERIAL_CONSOLE_ENABLE=0" ;;
  "") warn "CONFIG_SERIAL_CONSOLE_ENABLE not set in dietpi.txt" ;;
  *) warn "dietpi.txt still says CONFIG_SERIAL_CONSOLE_ENABLE=$SC while the getty
      is off — the two disagree, and dietpi-config or a DietPi update will act on
      the setting, bringing the 90 s boot stall back on a shipped unit" ;;
esac
[ -f "$MNT_ROOT/opt/x16/rom.bin" ] && pass "rom.bin present" || fail "no /opt/x16/rom.bin"
if [ -d "$MNT_ROOT/mnt/x16" ] && [ -n "$(ls -A "$MNT_ROOT/mnt/x16" 2>/dev/null)" ]; then
  pass "library at /mnt/x16 ($(du -sh "$MNT_ROOT/mnt/x16" 2>/dev/null | cut -f1))"
else
  warn "/mnt/x16 is empty or missing — the bundled library would not be there"
fi

# ---- 3. hardening -----------------------------------------------------------
echo
echo "-- hardening --"
# DietPi ships its own RAMlog and has it on by default — /var/log is a tmpfs
# from /etc/fstab. That is the same job log2ram does, so log2ram is redundant
# here and actively unwanted: both want to own /var/log.
RAMLOG=0
grep -qE '^tmpfs[[:space:]]+/var/log[[:space:]]+tmpfs' "$MNT_ROOT/etc/fstab" 2>/dev/null && RAMLOG=1
[ -L "$MNT_ROOT/etc/systemd/system/multi-user.target.wants/dietpi-ramlog.service" ] && RAMLOG=1
if [ "$RAMLOG" = 1 ]; then
  pass "DietPi-RAMlog active — /var/log is a tmpfs, so the wear-heavy writes never reach the card"
else
  fail "/var/log is NOT in RAM — DietPi-RAMlog is the hardening this image relies
      on (the read-only overlay is deliberately not the choice: it discards
      SAVEs into the library). Re-enable it rather than installing log2ram."
fi
[ -f "$MNT_ROOT/etc/log2ram.conf" ] \
  && warn "log2ram is installed as well as DietPi-RAMlog — two things owning
      /var/log. Pick one; on DietPi that means removing log2ram"

# ---- 4. dev-Pi state that must not travel -----------------------------------
echo
echo "-- dev-Pi state --"
STAMPS=""
for s in .x16-wifi.state .x16-wifi.nohardware; do
  [ -e "$MNT_FAT/$s" ] && STAMPS="$STAMPS $s"
done
[ -n "$STAMPS" ] \
  && fail "Wi-Fi applier state file(s) present:$STAMPS — .x16-wifi.state is
      obsolete entirely (the applier clears the card instead of stamping it) and
      .x16-wifi.nohardware would wrongly shorten the owner's first-boot wait" \
  || pass "no Wi-Fi applier state files"
if grep -qE '^X16_WIFI_(SSID|PSK)=.+' "$MNT_FAT/x16-wifi.conf" 2>/dev/null; then
  fail "x16-wifi.conf still holds credentials"
else
  pass "x16-wifi.conf blank"
fi
[ -e "$MNT_FAT/x16-wifi-status.txt" ] \
  && fail "x16-wifi-status.txt would ship — it reports OUR last join attempt,
      and it names the network we were on" \
  || pass "no stale x16-wifi-status.txt"
grep -qE "^aWIFI_(SSID|KEY)\[0\]='.+'" "$MNT_FAT/dietpi-wifi.txt" 2>/dev/null \
  && fail "dietpi-wifi.txt still holds credentials" \
  || pass "dietpi-wifi.txt blank"
# The credential that matters is on ext4, not the card. The stored PSK is a
# hash, which is NOT reassuring: wpa_supplicant joins with the hash directly.
WPA_LEAK=""
for f in "$MNT_ROOT"/etc/wpa_supplicant/wpa_supplicant*.conf*; do
  [ -f "$f" ] || continue
  grep -q '^network={' "$f" 2>/dev/null && WPA_LEAK="$WPA_LEAK $(basename "$f")"
done
[ -n "$WPA_LEAK" ] \
  && fail "our Wi-Fi credentials are inside the image:$WPA_LEAK — the stored PSK
      is a working credential for that network, hashed or not" \
  || pass "no Wi-Fi credentials on ext4"
if grep -qE '^[[:space:]]*dtoverlay=disable-wifi' "$MNT_FAT/config.txt" 2>/dev/null; then
  pass "Ethernet-only by default (dtoverlay=disable-wifi)"
else
  warn "no active dtoverlay=disable-wifi — the image ships with the radio on,
      which the README says it doesn't. A Wi-Fi test on the build Pi does this"
fi
# The SECOND off-switch. The overlay keeps the chip off the SDIO bus; this
# blacklist stops the driver binding even when it is present. Checked separately
# because they fail separately: an image with the overlay but no blacklist looks
# Ethernet-only here and is not, on any board where that overlay is a no-op.
# The applier renames this file when an owner enables Wi-Fi, which is exactly how
# a build Pi loses it — see DOC/release-no-AI.md, "disabled in TWO places".
if grep -qE '^[[:space:]]*blacklist[[:space:]]+brcmfmac' \
     "$MNT_ROOT/etc/modprobe.d/dietpi-disable_wifi.conf" 2>/dev/null; then
  pass "Wi-Fi module blacklist present (the other half of Ethernet-only)"
elif [ -f "$MNT_ROOT/etc/modprobe.d/dietpi-disable_wifi.conf.bak-x16wifi" ]; then
  warn "the Wi-Fi module blacklist is still renamed to .bak-x16wifi — a Wi-Fi
      test on the build Pi did this and prep-image-source.sh did not run"
else
  warn "no dietpi-disable_wifi.conf — the driver will bind wherever the chip is
      reachable, so this image is not Ethernet-only in the way the README says"
fi
# The applier's cache of its own last status text; records OUR join, not theirs.
[ -f "$MNT_ROOT/opt/x16/.x16-wifi-status.last" ] \
  && warn "/opt/x16/.x16-wifi-status.last would ship — it holds the build Pi's
      last Wi-Fi status message"
BAKS=$(find "$MNT_FAT" -maxdepth 1 -name '*.bak*' -printf '%f ' 2>/dev/null || true)
[ -n "$BAKS" ] && fail "config backups would ship on the FAT partition: $BAKS" \
              || pass "no .bak files on FAT"
[ -d "$MNT_FAT/System Volume Information" ] \
  && fail "Windows 'System Volume Information' folder on FAT" \
  || pass "no System Volume Information folder"
[ -s "$MNT_ROOT/root/.bash_history" ] && warn "/root/.bash_history is not empty"
[ -s "$MNT_ROOT/var/log/x16-appliance.log" ] \
  && warn "x16-appliance.log carries the dev Pi's boots ($(stat -c %s "$MNT_ROOT/var/log/x16-appliance.log") bytes)"
if ls "$MNT_ROOT"/etc/dropbear/dropbear_*_host_key >/dev/null 2>&1; then
  warn "SSH host keys are baked in — every unit flashed from this image shares
      the dev Pi's identity (prep-image-source.sh --reset-host-keys)"
fi

# ---- 5. what the owner sees first -------------------------------------------
echo
echo "-- the owner's first look --"
[ -f "$MNT_FAT/x16.conf" ] && pass "x16.conf on FAT (display settings, editable from a PC)" \
                           || fail "no x16.conf on the FAT partition"
# The applier resets x16-wifi.conf from this after a successful join. It can
# self-heal if absent, but only by deriving from whatever is on the card at the
# time — shipping the pristine one is how the owner-facing comments are
# guaranteed to survive the first reset.
[ -f "$MNT_ROOT/opt/x16/x16-wifi.conf.original" ] \
  && pass "Wi-Fi reset template at /opt/x16/x16-wifi.conf.original" \
  || warn "no /opt/x16/x16-wifi.conf.original — the applier will mint one from
      the card on first boot, so a mangled x16-wifi.conf becomes the template"
# A missing country code makes DietPi print a warning at boot, which breaks the
# "nothing but the X16 is ever on screen" rule Phase 4 exists to enforce.
WIFI_CC=$(sed -n 's/^X16_WIFI_COUNTRY=//p' "$MNT_FAT/x16-wifi.conf" 2>/dev/null | head -1)
case "$WIFI_CC" in
  [A-Za-z][A-Za-z]) pass "x16-wifi.conf ships country '$WIFI_CC'" ;;
  *) fail "x16-wifi.conf has no valid country code ('${WIFI_CC:-empty}') — DietPi
      prints a boot-time warning without one, on a machine whose whole point is
      that only the X16 is ever on screen" ;;
esac
[ -f "$MNT_FAT/x16/README.TXT" ] && pass "x16/README.TXT in the drop folder" \
                                 || fail "no README.TXT in the FAT x16/ folder (ship dist/fat-x16-README.TXT)"
LABEL=$(lsblk -no LABEL "${LOOP}p1" 2>/dev/null || true)
FATSZ=$(df -B1 --output=size "$MNT_FAT" | tail -1)
FATAV=$(df -B1 --output=avail "$MNT_FAT" | tail -1)
info "FAT drive label: '${LABEL:-none}'  size $(numfmt --to=iec --suffix=B "$FATSZ")  free $(numfmt --to=iec --suffix=B "$FATAV")"
info "  ^ dist/README-end-user.md tells the owner roughly this much. Check it."
# 128 MB is DietPi's stock size and the shipped choice: ~97 MB free still holds
# thousands of .PRG files, and the space is worth more to the root filesystem on
# a 4 GB card. Only complain if it is small enough to actually cramp an owner.
if [ "$((FATSZ / 1024 / 1024))" -lt 100 ]; then
  warn "FAT is only $((FATSZ / 1024 / 1024)) MB. This is fixed at BUILD time —
      nothing expands it on the owner's card, whatever size card they use.
      scripts/release/refit-fat.sh --fat-mb N <image> changes it, before shrinking."
fi

echo
if [ "$FAILED" -gt 0 ]; then
  echo "$FAILED failure(s), $WARNED warning(s) — do not ship this image."
  exit 1
fi
echo "no failures, $WARNED warning(s)."
