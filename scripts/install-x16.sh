#!/usr/bin/env bash
#
# Phase 2 (primary path) — install the prebuilt x16emu + matching ROM on DietPi.
# Deployment target: Raspberry Pi 3 / 4, 64-bit DietPi (Debian Bookworm, aarch64).
#
# Arch-aware: it auto-detects the host and downloads the matching prebuilt zip
# (aarch64 for the Pi; x86_64 for a DietPi/Debian x86 VM or container used to
# smoke-test this script; armhf for 32-bit). All prebuilt binaries need
# glibc >= 2.35 (DietPi Bookworm has 2.36 — OK). On an older/32-bit-glibc image,
# use build-x16-from-source.sh instead.
#
# Emulator and ROM are version-locked: bump X16_VER and they move together.

set -euo pipefail

# ---- config -----------------------------------------------------------------
X16_VER="r49"                                   # bump to update (keep emu+ROM in lockstep)
INSTALL_DIR="/opt/x16"                           # where x16emu + rom.bin live

# The user-program dir (-fsroot) MUST live on the FAT boot partition, so the
# owner can add .prg/.bas files by popping the SD card into any PC. Bookworm
# mounts that partition at /boot/firmware; older images use /boot. NB: /boot on
# Bookworm is plain ext4 root — invisible to Windows — which is why we probe for
# the real FAT mount instead of hard-coding a path.
boot_fat() {
  for d in /boot/firmware /boot; do
    case "$(stat -f -c %T "$d" 2>/dev/null)" in
      msdos|vfat|exfat) printf '%s\n' "$d"; return 0 ;;
    esac
  done
  printf '%s\n' /boot                            # last resort (VM/container test beds)
}
BOOT_FAT="$(boot_fat)"
USER_PROG_DIR="${X16_FSROOT:-${BOOT_FAT}/x16}"   # drop .prg/.bas here from any PC
EMU_BASE="https://github.com/X16Community/x16-emulator/releases/download/${X16_VER}"
ROM_BASE="https://github.com/X16Community/x16-rom/releases/download/${X16_VER}"
ROM_ZIP="Release.${X16_VER^^}.ROM.Image.zip"     # e.g. Release.R49.ROM.Image.zip
# -----------------------------------------------------------------------------

echo ">> [1/6] Detecting architecture..."
case "$(uname -m)" in
  aarch64|arm64) ARCH_TAG="aarch64" ;;          # <- the real Pi 3/4 target
  x86_64|amd64)  ARCH_TAG="x86_64"  ;;          # <- x86 VM / container test bed
  armv7l|armv6l) ARCH_TAG="armhf"   ;;          # <- 32-bit
  *) echo "!! Unsupported arch '$(uname -m)'. Use build-x16-from-source.sh."; exit 1 ;;
esac
EMU_ZIP="x16emu_linux-${ARCH_TAG}-${X16_VER}.zip"
echo "   $(uname -m) -> ${EMU_ZIP}"

# Use $SUDO only when not already root (root containers/CI usually lack sudo).
SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"

echo ">> [2/6] Installing runtime dependencies (SDL2, unzip, curl)..."
$SUDO apt-get update
$SUDO apt-get install -y libsdl2-2.0-0 unzip curl

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo ">> [3/6] Downloading emulator ${EMU_ZIP}..."
curl -fL "${EMU_BASE}/${EMU_ZIP}" -o "${tmp}/x16.zip"

echo ">> [4/6] Installing to ${INSTALL_DIR}..."
$SUDO rm -rf "${INSTALL_DIR}"
$SUDO mkdir -p "${INSTALL_DIR}"
$SUDO unzip -jo "${tmp}/x16.zip" -d "${INSTALL_DIR}"
$SUDO chmod +x "${INSTALL_DIR}/x16emu"

echo ">> [5/6] Ensuring a matching rom.bin is present..."
if [ ! -f "${INSTALL_DIR}/rom.bin" ]; then
  echo "   rom.bin not bundled in the emulator zip; fetching ROM ${X16_VER}..."
  if curl -fL "${ROM_BASE}/${ROM_ZIP}" -o "${tmp}/rom.zip"; then
    $SUDO unzip -o "${tmp}/rom.zip" -d "${tmp}/rom"
    romfile="$(find "${tmp}/rom" -iname 'rom.bin' | head -n1 || true)"
    if [ -n "${romfile}" ]; then
      $SUDO cp "${romfile}" "${INSTALL_DIR}/rom.bin"
    else
      echo "!! rom.bin not found inside ${ROM_ZIP}. Place a matching rom.bin at"
      echo "   ${INSTALL_DIR}/rom.bin manually (from the x16-rom ${X16_VER} release)."
      exit 1
    fi
  else
    echo "!! Could not download ${ROM_ZIP}. Place a matching rom.bin at"
    echo "   ${INSTALL_DIR}/rom.bin manually (from the x16-rom ${X16_VER} release)."
    exit 1
  fi
else
  echo "   rom.bin already bundled — good."
fi

echo ">> [6/6] Creating user program dir and launcher symlink..."
$SUDO mkdir -p "${USER_PROG_DIR}"
$SUDO ln -sf "${INSTALL_DIR}/x16emu" /usr/local/bin/x16emu

# Migrate from the pre-FAT layout: earlier revisions used /boot/x16 on the ext4
# root, which a PC cannot see. Move any programs left there to the new fsroot.
OLD_PROG_DIR="/boot/x16"
if [ "${OLD_PROG_DIR}" != "${USER_PROG_DIR}" ] && [ -d "${OLD_PROG_DIR}" ] &&
   [ -n "$(ls -A "${OLD_PROG_DIR}" 2>/dev/null)" ]; then
  echo "   migrating existing programs from ${OLD_PROG_DIR} -> ${USER_PROG_DIR}"
  $SUDO cp -an "${OLD_PROG_DIR}/." "${USER_PROG_DIR}/" 2>/dev/null || true
  echo "   (originals left in ${OLD_PROG_DIR}; delete them once you've checked)"
fi

if [ "${USER_PROG_DIR#/boot}" = "${USER_PROG_DIR}" ]; then
  echo "!! WARNING: ${USER_PROG_DIR} is not on the FAT boot partition, so programs"
  echo "   cannot be added by putting the SD card in a PC. Expected /boot/firmware/x16."
fi

echo
echo ">> Installed x16emu ${X16_VER} to ${INSTALL_DIR}"
echo ">> Test it fullscreen from a console (tty), NOT over SSH, with:"
echo "     ~/scripts/run-x16.sh"
echo "   or manually:"
echo "     SDL_VIDEODRIVER=kmsdrm ${INSTALL_DIR}/x16emu -fullscreen \\"
echo "       -rom ${INSTALL_DIR}/rom.bin -fsroot ${USER_PROG_DIR}"
