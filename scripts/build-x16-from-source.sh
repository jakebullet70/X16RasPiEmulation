#!/usr/bin/env bash
#
# Phase 2 (fallback path) — build x16emu from source + install matching ROM.
# Use this only if the prebuilt aarch64 binary won't run (e.g. 32-bit image,
# older glibc, or you want a locally compiled build). Slow on a Pi 3 but works.

set -euo pipefail

# ---- config -----------------------------------------------------------------
X16_VER="r49"                                    # git tag; keep emu+ROM in lockstep
INSTALL_DIR="/opt/x16"

# -fsroot on the FAT boot partition (Bookworm: /boot/firmware, older: /boot) so
# programs can be added from any PC via the SD card. See install-x16.sh.
boot_fat() {
  for d in /boot/firmware /boot; do
    case "$(stat -f -c %T "$d" 2>/dev/null)" in
      msdos|vfat|exfat) printf '%s\n' "$d"; return 0 ;;
    esac
  done
  printf '%s\n' /boot
}
USER_PROG_DIR="${X16_FSROOT:-$(boot_fat)/x16}"
ROM_BASE="https://github.com/X16Community/x16-rom/releases/download/${X16_VER}"
ROM_ZIP="Release.${X16_VER^^}.ROM.Image.zip"
# -----------------------------------------------------------------------------

# Use $SUDO only when not already root (root containers/CI usually lack sudo).
SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"

echo ">> [1/5] Installing build + runtime dependencies..."
$SUDO apt-get update
$SUDO apt-get install -y build-essential libsdl2-dev git curl unzip

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo ">> [2/5] Cloning x16-emulator @ ${X16_VER}..."
git clone --depth 1 --branch "${X16_VER}" \
  https://github.com/X16Community/x16-emulator.git "${tmp}/src"

echo ">> [3/5] Building (this can take a while on a Pi 3)..."
make -C "${tmp}/src" -j"$(nproc)"

echo ">> [4/5] Installing binary to ${INSTALL_DIR}..."
$SUDO mkdir -p "${INSTALL_DIR}"
$SUDO cp "${tmp}/src/x16emu" "${INSTALL_DIR}/x16emu"
$SUDO chmod +x "${INSTALL_DIR}/x16emu"
$SUDO ln -sf "${INSTALL_DIR}/x16emu" /usr/local/bin/x16emu

echo ">> [5/5] Fetching matching rom.bin (${X16_VER})..."
if curl -fL "${ROM_BASE}/${ROM_ZIP}" -o "${tmp}/rom.zip"; then
  $SUDO unzip -o "${tmp}/rom.zip" -d "${tmp}/rom"
  romfile="$(find "${tmp}/rom" -iname 'rom.bin' | head -n1 || true)"
  if [ -n "${romfile}" ]; then
    $SUDO cp "${romfile}" "${INSTALL_DIR}/rom.bin"
  else
    echo "!! rom.bin not found inside ${ROM_ZIP}; place one at ${INSTALL_DIR}/rom.bin"
    exit 1
  fi
else
  echo "!! Could not download the ROM; place a matching rom.bin at ${INSTALL_DIR}/rom.bin"
  exit 1
fi

$SUDO mkdir -p "${USER_PROG_DIR}"
echo
echo ">> Built + installed x16emu ${X16_VER}. Test with:  ~/scripts/run-x16.sh"
