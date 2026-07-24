#!/bin/bash
#
# fetch-sdcard.sh — populate the X16 appliance's -fsroot with the community
# SD-card contents from GitHub (games, demos, music, BASIC examples, apps).
#
# Source repo (default): https://github.com/cx16forum/sdcard
#   Its `sdcard_root/` folder IS the X16 SD-card tree; we drop its contents into
#   the emulator's -fsroot so DIR / LOAD show real programs out of the box.
#
# Runs on the Pi (needs curl OR wget + GNU tar — no git required). Pulls a
# tarball of the default branch and extracts only `sdcard_root/*`.
#
# INSTALL:  sudo install -m 0755 ~/scripts/fetch-sdcard.sh /usr/local/bin/x16-fetch-sd
#
# USAGE:
#   x16-fetch-sd                 # merge repo contents into /boot/x16 (keeps your files)
#   x16-fetch-sd --clean         # wipe /boot/x16 first, then fresh copy
#   x16-fetch-sd --dest DIR      # target a different fsroot
#   x16-fetch-sd --repo USER/REPO [--branch BR]   # a different GitHub source
#
set -euo pipefail

REPO="cx16forum/sdcard"
BRANCH="HEAD"            # HEAD = the repo's default branch (no need to know its name)
DEST="/boot/x16"        # the emulator -fsroot (matches custom.sh USER_PROG_DIR)
SUBDIR="sdcard_root"    # the folder inside the repo that maps to the SD root
CLEAN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --clean)  CLEAN=1; shift ;;
    --dest)   DEST="${2:?}"; shift 2 ;;
    --repo)   REPO="${2:?}"; shift 2 ;;
    --branch) BRANCH="${2:?}"; shift 2 ;;
    --subdir) SUBDIR="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

URL="https://codeload.github.com/${REPO}/tar.gz/${BRANCH}"
echo "Source : ${REPO}@${BRANCH}  (${SUBDIR}/)"
echo "Dest   : ${DEST}"

mkdir -p "$DEST"

# Download to a temp file on the SAME filesystem as DEST (avoids filling a small
# tmpfs /tmp with a ~300 MB tarball). Verify it's actually a gzip before extract.
TMP="$(mktemp "${DEST}/.fetch.XXXXXX.tgz")"
cleanup() { rm -f "$TMP"; }
trap cleanup EXIT

echo "Downloading tarball..."
if command -v curl >/dev/null 2>&1; then
  curl -fL --retry 3 -# -o "$TMP" "$URL"
elif command -v wget >/dev/null 2>&1; then
  wget -q --show-progress -O "$TMP" "$URL"
else
  echo "ERROR: need curl or wget." >&2; exit 1
fi

# Sanity: gzip magic 1f 8b (use od — available everywhere; the Pi has no xxd).
MAGIC="$(head -c2 "$TMP" | od -An -tx1 | tr -d ' \n')"
if [ "$MAGIC" != "1f8b" ]; then
  echo "ERROR: download is not a gzip tarball (bad repo/branch, or rate-limited?)." >&2
  head -c200 "$TMP"; echo; exit 1
fi

if [ "$CLEAN" = 1 ]; then
  echo "Cleaning ${DEST} (--clean)..."
  find "$DEST" -mindepth 1 -maxdepth 1 ! -name '.fetch.*' -exec rm -rf {} +
fi

echo "Extracting ${SUBDIR}/ into ${DEST}..."
# The tarball's top dir is "<repo>-<ref>/"; strip that + the SUBDIR (2 comps) so
# files land directly in DEST. --wildcards limits extraction to the payload.
tar -xz --wildcards --strip-components=2 -C "$DEST" -f "$TMP" "*/${SUBDIR}/*"

COUNT=$(find "$DEST" -type f ! -name '.fetch.*' | wc -l)
SIZE=$(du -sh "$DEST" 2>/dev/null | cut -f1)
echo "Done. ${DEST} now has ${COUNT} files (${SIZE})."
echo "Top-level entries:"
ls "$DEST" | sed 's/^/  /'
echo
echo "Restart the X16 to see them:  pkill -x x16emu   (or reboot)"
