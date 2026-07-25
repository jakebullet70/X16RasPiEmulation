#!/usr/bin/env bash
#
# Headless smoke test — proves x16emu is installed, correct-arch, its libraries
# resolve, the ROM is present, and it starts without crashing. Needs NO display,
# so it runs in Docker / a headless VM / CI. This validates SCRIPT LOGIC and that
# the emulator launches — it does NOT validate the KMS/HDMI/latency path, which
# only a real Pi can. Run install-x16.sh first.

set -uo pipefail

INSTALL_DIR="/opt/x16"
RUN_SECS="${RUN_SECS:-5}"
fail=0

echo "== x16 headless smoke test =="

# 1. binary present + executable
if [ -x "${INSTALL_DIR}/x16emu" ]; then
  echo "PASS: x16emu binary present"
else
  echo "FAIL: x16emu missing at ${INSTALL_DIR} (run install-x16.sh first)"; exit 1
fi

# 2. report binary arch (sanity vs host)
if command -v file >/dev/null 2>&1; then
  echo "INFO: $(file -b "${INSTALL_DIR}/x16emu")"
fi

# 3. dynamic dependencies resolve (catches a missing libSDL2)
if command -v ldd >/dev/null 2>&1; then
  if ldd "${INSTALL_DIR}/x16emu" 2>/dev/null | grep -qi 'not found'; then
    echo "FAIL: unresolved shared libraries:"
    ldd "${INSTALL_DIR}/x16emu" | grep -i 'not found'
    fail=1
  else
    echo "PASS: shared libraries resolve"
  fi
fi

# 4. matching ROM present
if [ -f "${INSTALL_DIR}/rom.bin" ]; then
  echo "PASS: rom.bin present ($(stat -c%s "${INSTALL_DIR}/rom.bin" 2>/dev/null || echo '?') bytes)"
else
  echo "FAIL: rom.bin missing at ${INSTALL_DIR}"; fail=1
fi

# 5. the -fsroot resolves where the scripts think it does.
# Regression guard: -fsroot used to be /boot/x16, which on Bookworm is the ext4
# ROOT, not the FAT boot partition — so "drop programs on the card from a PC"
# silently didn't work. On a real Pi the resolved path MUST be on FAT; in a
# VM/container there is no FAT partition, so that half is skipped.
boot_fat() {
  for d in /boot/firmware /boot; do
    case "$(stat -f -c %T "$d" 2>/dev/null)" in
      msdos|vfat|exfat) printf '%s\n' "$d"; return 0 ;;
    esac
  done
  return 1
}
if FAT_MNT="$(boot_fat)"; then
  FSROOT="${X16_FSROOT:-${FAT_MNT}/x16}"
  if [ -d "$FSROOT" ]; then
    case "$(stat -f -c %T "$FSROOT" 2>/dev/null)" in
      msdos|vfat|exfat) echo "PASS: fsroot ${FSROOT} is on the FAT boot partition" ;;
      *) echo "FAIL: fsroot ${FSROOT} is NOT on FAT — a PC won't see it"; fail=1 ;;
    esac
    FREE_MB=$(df -Pm "$FSROOT" 2>/dev/null | awk 'NR==2 {print $4}')
    echo "INFO: fsroot has ${FREE_MB:-?} MB free for user programs"
  else
    echo "FAIL: fsroot ${FSROOT} does not exist (run install-x16.sh)"; fail=1
  fi
else
  FSROOT="${X16_FSROOT:-$(mktemp -d)}"
  echo "SKIP: no FAT boot partition here (VM/container) — using ${FSROOT}"
fi

# 6. every setting the appliance reads survives an x16-display save().
# x16-display rewrites x16.conf wholesale, so a key it doesn't know about gets
# erased the first time someone opens the menu. This caught exactly that bug.
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
DISP="${SCRIPT_DIR}/x16-display.sh"
if [ -f "$DISP" ]; then
  missing=""
  for key in $(grep -ho 'X16_[A-Z_]\+' "${SCRIPT_DIR}/custom.sh" "${SCRIPT_DIR}/run-x16.sh" 2>/dev/null |
               sort -u); do
    [ "$key" = "X16_FSROOT" ] && continue          # env-only override, not a conf key
    grep -q "^${key}=\$${key}\$" "$DISP" || missing="${missing} ${key}"
  done
  if [ -z "$missing" ]; then
    echo "PASS: x16-display save() preserves every setting the appliance reads"
  else
    echo "FAIL: x16-display save() would erase:${missing}"; fail=1
  fi
else
  echo "SKIP: x16-display.sh not alongside this script — cannot check config round-trip"
fi

# 7. launches headless without an immediate crash — with the same -fsroot and
# -joyN flags the appliance uses, so a bad flag fails here instead of on the TV.
# (r49 ignores gamepads unless -joyN enables the port, so custom.sh always passes it.)
echo "INFO: launching headless for ${RUN_SECS}s (dummy video/audio)..."
SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
  timeout "${RUN_SECS}" "${INSTALL_DIR}/x16emu" -rom "${INSTALL_DIR}/rom.bin" \
  -fsroot "${FSROOT}" -joy1 \
  >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 124 ]; then
  echo "PASS: ran ${RUN_SECS}s with no crash (killed by timeout, as expected)"
elif [ "$rc" -eq 0 ]; then
  echo "PASS: started and exited cleanly"
else
  echo "FAIL: exited early with code ${rc} (crash, bad flag, or missing dependency)"
  echo "      retrying without -joy1 to see if that flag is the problem..."
  SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
    timeout "${RUN_SECS}" "${INSTALL_DIR}/x16emu" -rom "${INSTALL_DIR}/rom.bin" \
    -fsroot "${FSROOT}" >/dev/null 2>&1
  rc2=$?
  if [ "$rc2" -eq 124 ] || [ "$rc2" -eq 0 ]; then
    echo "      -> ran fine WITHOUT -joy1: this x16emu build rejects the flag."
    echo "         Check 'x16emu --help' and update custom.sh + run-x16.sh."
  fi
  fail=1
fi

echo "== result: $( [ $fail -eq 0 ] && echo PASS || echo FAIL ) =="
exit $fail
