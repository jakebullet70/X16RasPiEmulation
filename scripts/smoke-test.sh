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

# 5. launches headless without an immediate crash
echo "INFO: launching headless for ${RUN_SECS}s (dummy video/audio)..."
SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
  timeout "${RUN_SECS}" "${INSTALL_DIR}/x16emu" -rom "${INSTALL_DIR}/rom.bin" \
  >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 124 ]; then
  echo "PASS: ran ${RUN_SECS}s with no crash (killed by timeout, as expected)"
elif [ "$rc" -eq 0 ]; then
  echo "PASS: started and exited cleanly"
else
  echo "FAIL: exited early with code ${rc} (crash or missing dependency)"; fail=1
fi

echo "== result: $( [ $fail -eq 0 ] && echo PASS || echo FAIL ) =="
exit $fail
