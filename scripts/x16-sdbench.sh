#!/bin/bash
#
# x16-sdbench.sh -- measure SD card speed, boot read cost, and card integrity.
# Run as root ON THE PI. Read-only: it never writes to the card.
#
#   x16-sdbench.sh <tag>      # tag names the output, e.g. "baseline" or "oc100"
#                             # result also saved to /root/sdbench-<tag>.txt
#
# WHY IT REPORTS INTEGRITY ALONGSIDE SPEED: the setting this exists to evaluate,
# dtparam=sd_overclock=N, runs the bus past the card's rated clock, and the
# documented failure mode is SILENT corruption rather than a clean refusal. So a
# speed number on its own cannot justify keeping it -- the mmc CRC/timeout count
# and the ext4 error count have to be zero too.
#
# WHAT THE PI 4 RESULT WAS (2026-07-30): sd_overclock does NOT reach the Pi 4's
# card at all. The card is on the brcm,bcm2711-emmc2 controller, whose DT node has
# no overclock property; the dtparam lands on /soc/mmc@7e202000, which is
# disabled. Verify with the "ACTUAL bus clock" section below -- if it still reads
# 50000000 Hz, the setting did nothing, whatever config.txt says. On a Pi 3 the
# card is on a bcm2835 controller and it is expected to take effect, which is why
# this script exists rather than a one-off command.
#
# READING THE NUMBERS:
#  * "read_wait" is the honest headline -- ms the block layer spent waiting on
#    reads. On the Pi 4 dev card it was 15.2-15.6 s of a 17.0 s boot, i.e. the
#    card dominates boot. It OVERLAPS with CPU work, so treat it as an upper bound
#    on what a faster card could save, never as a subtraction.
#  * Capture the boot figures BEFORE running this, or the benchmark's own reads
#    inflate the counters. The script prints them first for that reason, but a
#    long-running box has already polluted them -- reboot for a clean baseline.
#  * Sequential read is stable to about +/-1% WITHIN a boot but moves ~5% ACROSS
#    boots. Do not call a 5% across-boot difference a result.
#  * The p1 sha256 is a corruption check, and it is only valid if nothing edited
#    the FAT partition between runs -- config.txt lives there, so editing the
#    setting under test changes the hash for innocent reasons.
#
set -u
TAG="${1:-run}"
OUT="/root/sdbench-$TAG.txt"
DEV=/dev/mmcblk0

exec > >(tee "$OUT") 2>&1

echo "===== sdbench: $TAG ====="
date -Is
echo "model:  $(tr -d '\0' < /proc/device-tree/model)"
echo "uptime: $(cut -d' ' -f1 /proc/uptime)s"
echo

echo "-- the setting under test --"
grep -nE "sd_overclock|sdtweak|sd_poll_once|sdio_overclock" /boot/firmware/config.txt || echo "(no sd_overclock in config.txt)"
echo

echo "-- ACTUAL bus clock (this is what proves the setting took effect) --"
mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug 2>/dev/null
grep -E "^(clock|actual clock|timing spec|bus width)" /sys/kernel/debug/mmc0/ios 2>/dev/null
echo

echo "-- card identity (an old card is a marginal card) --"
printf 'manfid=%s oemid=%s date=%s\n' \
  "$(cat /sys/block/mmcblk0/device/manfid 2>/dev/null)" \
  "$(cat /sys/block/mmcblk0/device/oemid 2>/dev/null)" \
  "$(cat /sys/block/mmcblk0/device/date  2>/dev/null)"
echo

echo "-- boot timing --"
systemd-analyze 2>/dev/null
echo
echo "kernel-only (display-independent, so valid even with no TV attached):"
systemd-analyze 2>/dev/null | sed -n 's/.*in \([0-9.]*s\) (kernel).*/  kernel = \1/p'
echo

echo "-- how much of boot was spent WAITING ON THE CARD --"
# field 3 = sectors read, field 4 = ms spent reading. Read before any benchmark
# below inflates it.
awk '{printf "  sectors_read=%s (%.1f MB)   read_wait=%s ms (%.1f s)\n  reads_completed=%s\n", $3, $3*512/1048576, $4, $4/1000, $1}' /sys/block/mmcblk0/stat
echo

echo "-- INTEGRITY: does the card return the same bytes at this clock? --"
# The FAT boot partition is a fixed region nothing writes during normal running,
# so its hash must be identical across clock settings. A changed hash at a higher
# clock is corruption, full stop, and means revert immediately.
sync
echo 3 > /proc/sys/vm/drop_caches
echo -n "  sha256(p1, 131MB): "
dd if=${DEV}p1 bs=1M iflag=direct 2>/dev/null | sha256sum | cut -d' ' -f1
echo

echo "-- INTEGRITY: filesystem error counters --"
dumpe2fs -h ${DEV}p2 2>/dev/null | grep -iE "^(FS Error|Filesystem state|Free blocks:|Mount count|Last error)" | sed 's/^/  /'
echo

echo "-- INTEGRITY: mmc-layer errors (CRC/timeout = the overclock is too much) --"
n=$(dmesg 2>/dev/null | grep -icE "mmc0.*(error|timeout|crc|retrying|failed)")
echo "  mmc0 error/timeout/crc lines in dmesg: $n"
[ "$n" != 0 ] && dmesg | grep -iE "mmc0.*(error|timeout|crc|retrying|failed)" | tail -12 | sed 's/^/    /'
echo "  ext4 errors in dmesg: $(dmesg 2>/dev/null | grep -ic 'EXT4-fs error')"
echo

echo "-- SPEED: sequential read, direct I/O, cache dropped, 3 runs --"
for i in 1 2 3; do
  sync; echo 3 > /proc/sys/vm/drop_caches
  printf '  run %s: ' "$i"
  dd if=$DEV of=/dev/null bs=1M count=256 iflag=direct 2>&1 | tail -1 | sed 's/.*copied, //'
done
echo

echo "-- SPEED: 4K random-ish read, which is what boot actually pays --"
sync; echo 3 > /proc/sys/vm/drop_caches
printf '  4k x2000 @1GB in: '
dd if=$DEV of=/dev/null bs=4k count=2000 iflag=direct skip=250000 2>&1 | tail -1 | sed 's/.*copied, //'
echo

echo "===== end $TAG (saved to $OUT) ====="
