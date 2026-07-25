#!/usr/bin/env bash
#
# gamepad-test.sh — will this USB pad actually work with x16emu on the appliance?
#
# Run on the Pi with the pad plugged in. Read-only: it inspects, it changes
# nothing.
#
#   curl -fsSL https://raw.githubusercontent.com/jakebullet70/X16RasPiEmulation/main/scripts/gamepad-test.sh | bash
#
# WHY THIS IS NOT JUST "IS IT PLUGGED IN":
#   x16emu r49 only binds a pad that SDL reports via SDL_IsGameController(),
#   i.e. one that has a GAME CONTROLLER MAPPING. A pad can enumerate perfectly
#   as a joystick (/dev/input/js0 present, buttons register in jstest) and still
#   be invisible to the emulator because SDL has no mapping for it.
#
#   SDL builds each device's GUID from the kernel's bus/vendor/product/version
#   and looks it up in a mapping table COMPILED INTO libSDL2. So we can compute
#   the same GUID and grep the shared object for it — no compiler, no X, no
#   guessing.
#
#   The other half is the -joyN flag: r49 leaves all four SNES ports disabled
#   unless asked (Joystick_slots_enabled[] starts all-false), so a mapped pad in
#   a disabled port is still ignored. We check that the appliance passes it.
#
set -uo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/x16}"
DEVS=/proc/bus/input/devices
found_pad=0
mapped_pad=0

say()  { printf '%s\n' "$*"; }
rule() { printf '%s\n' "----------------------------------------------------------------"; }

say "== Commander X16 gamepad check =="
say

# ---------------------------------------------------------------- 1. USB level
rule
say "1. What the USB bus sees"
rule
if command -v lsusb >/dev/null 2>&1; then
  lsusb | grep -iE 'game|joy|pad|contro|xbox|sony|nintendo|logitech|8bitdo' ||
    say "   (nothing obviously controller-shaped in lsusb -- full list:)"
  command -v lsusb >/dev/null && lsusb | sed 's/^/     /'
else
  say "   lsusb not installed (apt-get install usbutils) -- skipping."
fi
say

# ------------------------------------------------------- 2. kernel input layer
rule
say "2. What the kernel input layer sees"
rule
if [ ! -r "$DEVS" ]; then
  say "   FAIL: cannot read ${DEVS} -- is this a Linux box?"
  exit 1
fi

# SDL's Linux GUID is 8 little-endian uint16s:
#   bus, crc16(name), vendor, 0, product, 0, version, 0
# The CRC field is zero in essentially every built-in mapping, and SDL matches
# with the CRC masked off, so the zero-CRC form is the one to look up.
guid_from() {           # $1=bus $2=vendor $3=product $4=version (4 hex chars each)
  le() { printf '%s%s' "${1:2:2}" "${1:0:2}"; }
  printf '%s0000%s0000%s0000%s0000' "$(le "$1")" "$(le "$2")" "$(le "$3")" "$(le "$4")"
}

# Find the SDL2 shared object whose built-in mapping table we'll search.
SDL_SO="$(ldconfig -p 2>/dev/null | awk '/libSDL2-2\.0\.so\.0/ {print $NF; exit}')"
[ -z "$SDL_SO" ] && SDL_SO="$(find /usr/lib -name 'libSDL2-2.0.so.0*' -print -quit 2>/dev/null)"

# Walk the device blocks. Each block: N: Name=..., I: Bus=.. Vendor=.., H: Handlers=..
block=""
while IFS= read -r line || [ -n "$line" ]; do
  if [ -n "$line" ]; then block="${block}${line}"$'\n'; continue; fi

  case "$block" in
    *Handlers=*js*)
      found_pad=1
      name=$(printf '%s' "$block" | sed -n 's/^N: Name="\(.*\)"$/\1/p')
      ids=$(printf '%s' "$block" | sed -n 's/^I: Bus=\([0-9a-f]*\) Vendor=\([0-9a-f]*\) Product=\([0-9a-f]*\) Version=\([0-9a-f]*\).*/\1 \2 \3 \4/p')
      handlers=$(printf '%s' "$block" | sed -n 's/^H: Handlers=\(.*\)$/\1/p')
      # shellcheck disable=SC2086
      set -- $ids
      say "   Pad: ${name:-<unnamed>}"
      say "        bus=$1 vendor=$2 product=$3 version=$4"
      say "        handlers: ${handlers}"

      if [ "$2" = "0000" ] && [ "$3" = "0000" ]; then
        say "        NOTE: no USB vendor/product -- SDL derives the GUID from the"
        say "              name instead, so this lookup can't be done offline."
      else
        guid="$(guid_from "$1" "$2" "$3" "$4")"
        say "        SDL GUID: ${guid}"
        if [ -z "$SDL_SO" ]; then
          say "        -> can't check: libSDL2 not found (is SDL2 installed?)"
        elif ! command -v strings >/dev/null 2>&1; then
          say "        -> can't check: 'strings' missing (apt-get install binutils)"
        elif strings -a "$SDL_SO" 2>/dev/null | grep -qi "$guid"; then
          say "        -> MAPPED: libSDL2 has a built-in game-controller mapping."
          mapped_pad=1
        else
          say "        -> NOT in libSDL2's built-in table. x16emu will ignore it"
          say "           unless you supply a mapping (see section 4)."
        fi
      fi
      say
      ;;
  esac
  block=""
done < "$DEVS"

if [ "$found_pad" = 0 ]; then
  say "   No device with a 'js' handler found."
  say "   -> The kernel isn't seeing a joystick at all. Re-plug it, try another"
  say "      USB port, and check 'dmesg | tail' for what appeared."
  say
fi

# --------------------------------------------------- 3. does the appliance ask
rule
say "3. Does the appliance actually enable a port?"
rule
CONF=""
for c in /boot/firmware/x16.conf /boot/x16.conf; do [ -r "$c" ] && { CONF="$c"; break; }; done
if [ -n "$CONF" ]; then
  joy=$(sed -n 's/^X16_JOYSTICKS=\([0-9]*\).*/\1/p' "$CONF" | tail -1)
  say "   ${CONF}: X16_JOYSTICKS=${joy:-<unset, defaults to 1>}"
  [ "${joy:-1}" = 0 ] &&
    say "   -> ZERO: pads are deliberately ignored. Set it to 1 (or run x16-display)."
else
  say "   No x16.conf found -- the launcher defaults to one port (-joy1)."
fi
LOOP=/var/lib/dietpi/dietpi-autostart/custom.sh
if [ -r "$LOOP" ]; then
  if grep -q 'joy' "$LOOP"; then
    say "   Deployed appliance loop passes -joyN: yes"
  else
    say "   Deployed appliance loop passes -joyN: NO -- it predates the gamepad fix."
    say "   -> redeploy: sudo install -m 0755 ~/scripts/custom.sh ${LOOP}"
  fi
else
  say "   (appliance loop not deployed at ${LOOP})"
fi
say

# ------------------------------------------------------------------ 4. verdict
rule
say "4. Verdict / what to do next"
rule
if [ "$found_pad" = 1 ] && [ "$mapped_pad" = 1 ]; then
  say "   Looks good. Test it for real AT THE CONSOLE (not over SSH):"
  say
  say "       sudo pkill -f custom.sh; sudo pkill -x x16emu"
  say "       sudo ${INSTALL_DIR}/x16emu -rom ${INSTALL_DIR}/rom.bin -joy1 \\"
  say "            -fullscreen -scale 3"
  say
  say "   In BASIC, read joystick 1 and move the stick:"
  say "       10 J=JOY(1) : PRINT J : GOTO 10"
elif [ "$found_pad" = 1 ]; then
  say "   The pad works as a joystick but SDL has no built-in mapping, so"
  say "   x16emu will ignore it. Give SDL a mapping:"
  say
  say "     1. Grab the community database:"
  say "          curl -fLo /opt/x16/gamecontrollerdb.txt \\"
  say "            https://raw.githubusercontent.com/mdqinc/SDL_GameControllerDB/master/gamecontrollerdb.txt"
  say "     2. Find your GUID (printed above) in that file."
  say "     3. Export the matching line for the appliance, e.g. in custom.sh"
  say "        before the loop:"
  say "          export SDL_GAMECONTROLLERCONFIG=\"<the line from the db>\""
  say
  say "   If the GUID isn't in the database either, generate a mapping by hand"
  say "   with SDL's 'controllermap' utility on any desktop machine."
else
  say "   Nothing to test yet -- the kernel isn't seeing a joystick."
fi
say
say "== end =="
