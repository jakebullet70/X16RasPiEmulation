#!/bin/bash
#
# prep-image-source.sh — get a working Pi into a state worth capturing as the
# shipped image. Run as root ON THE PI, immediately before capturing the card.
#
# DRY RUN by default. Pass --apply to change anything.
#
# Two jobs:
#
#  1. RE-ARM THE FIRST-BOOT RESIZE — the one that silently ruins an image.
#     DietPi expands the root filesystem on first boot from
#     dietpi-fs_partition_resize.service, and the very first thing that service
#     does is delete its own WantedBy symlink:
#
#         rm -Rfv /etc/systemd/system/*.wants/dietpi-fs_partition_resize.service
#           -- /var/lib/dietpi/services/fs_partition_resize.sh
#
#     So on any Pi that has booted more than once the service reads `disabled`,
#     and an image captured from it expands on nobody's card. The owner just
#     gets a root filesystem the size of OUR build card, with no error anywhere.
#     `systemctl enable` puts the symlink back; that symlink IS the state.
#     (There is no /var/lib/dietpi/.fs_partition_resize flag file on this DietPi
#     version — removing one, as older notes suggested, does nothing.)
#
#  2. STRIP DEV-PI STATE that must not ship: our Wi-Fi credentials and the
#     applier's fingerprint stamp (a shipped stamp makes the owner's first edit
#     look "unchanged", so it is ignored — see DOC/README.md), the config.txt /
#     cmdline.txt backups this project has accumulated, Windows' System Volume
#     Information folder, logs and shell history.
#
# ! Do NOT reboot between running this and capturing the card. The resize
#   service would run on OUR card, find nothing to expand, and disable itself
#   again — leaving you exactly where you started, invisibly.
#
set -euo pipefail

APPLY=0
RESET_HOST_KEYS=0
for a in "$@"; do
  case "$a" in
    --apply) APPLY=1 ;;
    --reset-host-keys) RESET_HOST_KEYS=1 ;;
    -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

[ "$(id -u)" = 0 ] || { echo "Run as root on the Pi."; exit 1; }

# Same FAT probe as the rest of the appliance: Bookworm puts the card's FAT
# partition at /boot/firmware and leaves /boot on ext4 root.
boot_fat() {
  for d in /boot/firmware /boot; do
    case "$(stat -f -c %T "$d" 2>/dev/null)" in
      msdos|vfat|exfat) printf '%s\n' "$d"; return 0 ;;
    esac
  done
  printf '%s\n' /boot
}
FAT="$(boot_fat)"

# The regulatory domain every owner gets unless they edit x16-wifi.conf. It has
# to be the same in all four places or DietPi can change it under a shipped unit
# (see the country block below); check-image.sh asserts the agreement.
SHIP_COUNTRY="US"
# The name Windows shows for the card's drop drive. Set on the IMAGE rather than
# here — /boot/firmware is mounted and bind-mounted into the running emulator, so
# relabelling it live is not reliably persistent. scripts/release/set-fat-label.sh.
SHIP_FAT_LABEL="X16PI"

CHANGES=0
run() {
  CHANGES=$((CHANGES + 1))
  if [ "$APPLY" = 1 ]; then
    printf '  + %s\n' "$*"
    "$@"
  else
    printf '  would: %s\n' "$*"
  fi
}
note() { printf '    %s\n' "$*"; }

echo "FAT boot partition: $FAT"
[ "$APPLY" = 1 ] || echo "DRY RUN — nothing will be changed. Re-run with --apply."
echo

# ---- 1. re-arm DietPi's first-boot filesystem expansion ---------------------
echo "[1] first-boot partition resize"
LINK=/etc/systemd/system/local-fs.target.wants/dietpi-fs_partition_resize.service
if [ ! -f /var/lib/dietpi/services/fs_partition_resize.sh ]; then
  note "!! DietPi's resize service is not installed on this system — an image"
  note "   from it will never expand. Investigate before shipping."
elif [ -L "$LINK" ]; then
  note "already armed ($LINK)"
else
  note "currently: $(systemctl is-enabled dietpi-fs_partition_resize.service 2>&1)"
  run systemctl enable dietpi-fs_partition_resize.service
fi
# Set by the service itself when it needs an intermediate reboot to reload the
# partition table. Left behind, it makes the next run skip the partition step.
[ -f /dietpi_skip_partition_resize ] && run rm -f /dietpi_skip_partition_resize

# ---- 2. Wi-Fi: ship with no credentials and no stamp ------------------------
echo
echo "[2] Wi-Fi state"
# .x16-wifi.state is obsolete (the applier clears the card on a successful join
# rather than stamping it); .x16-wifi.nohardware would wrongly shorten the
# owner's first-boot interface wait. x16-wifi-status.txt reports OUR last join.
for stamp in "$FAT/.x16-wifi.state" "$FAT/.x16-wifi.nohardware" "$FAT/x16-wifi-status.txt"; do
  [ -e "$stamp" ] && run rm -f "$stamp"
done
if [ -f "$FAT/x16-wifi.conf" ]; then
  if grep -qE '^X16_WIFI_(SSID|PSK)=.+' "$FAT/x16-wifi.conf"; then
    run sed -i -e 's/^X16_WIFI_SSID=.*/X16_WIFI_SSID=/' \
               -e 's/^X16_WIFI_PSK=.*/X16_WIFI_PSK=/' "$FAT/x16-wifi.conf"
  else
    note "x16-wifi.conf already blank"
  fi
  # Deliberately NOT blanked: DietPi prints a boot warning with no country code,
  # and this appliance's whole premise is that only the X16 is ever on screen.
  # It ships as the owner's default, so it is a decision: SHIP_COUNTRY, below.
  cc=$(sed -n 's/^X16_WIFI_COUNTRY=//p' "$FAT/x16-wifi.conf" | head -1 | tr -d '\r')
  if [ "$cc" = "$SHIP_COUNTRY" ]; then
    note "shipping country code '$cc' as the default"
  else
    note "country is '${cc:-empty}', shipping '$SHIP_COUNTRY'"
    run sed -i "s/^X16_WIFI_COUNTRY=.*/X16_WIFI_COUNTRY=${SHIP_COUNTRY}/" "$FAT/x16-wifi.conf"
  fi
else
  note "!! $FAT/x16-wifi.conf missing — the owner's Wi-Fi route depends on it"
fi
# The applier resets the card from this after a successful join. It can mint one
# itself, but only from whatever is on the card at that moment — shipping the
# pristine copy is what guarantees the owner-facing comments survive the reset.
make_wifi_template() {
  mkdir -p /opt/x16
  sed -e 's/^X16_WIFI_SSID=.*/X16_WIFI_SSID=/' \
      -e 's/^X16_WIFI_PSK=.*/X16_WIFI_PSK=/' \
      "$FAT/x16-wifi.conf" > /opt/x16/x16-wifi.conf.original
}
if [ -f /opt/x16/x16-wifi.conf.original ]; then
  note "reset template present (/opt/x16/x16-wifi.conf.original)"
elif [ -f "$FAT/x16-wifi.conf" ]; then
  note "no reset template yet — will build it from the (blanked) card copy"
  run make_wifi_template
fi
# The country has to agree in every place that can write it, not just on the card.
# It shipped split once — card and template 'US', both dietpi.txt copies 'GB' —
# and that is not cosmetic: the applier reads the card, but dietpi-config and any
# DietPi update read dietpi.txt and run dietpi-set_hardware, so the regulatory
# domain can change on a unit already in an owner's hands. The symptom is
# indistinguishable from a wrong passphrase.
#
# The template matters for a second reason: the applier rebuilds the card from it
# after a successful join, so a stale country here reappears later, not now.
tcc=$(sed -n 's/^X16_WIFI_COUNTRY=//p' /opt/x16/x16-wifi.conf.original 2>/dev/null | head -1 | tr -d '\r')
if [ -f /opt/x16/x16-wifi.conf.original ] && [ "$tcc" != "$SHIP_COUNTRY" ]; then
  note "reset template says '${tcc:-empty}' — the card would revert to it after a join"
  run sed -i "s/^X16_WIFI_COUNTRY=.*/X16_WIFI_COUNTRY=${SHIP_COUNTRY}/" /opt/x16/x16-wifi.conf.original
fi
# Both filesystems carry a dietpi.txt on Bookworm: /boot is the ext4 root and
# /boot/firmware is the card. Fix whichever exist.
for dt in "$FAT/dietpi.txt" /boot/dietpi.txt; do
  [ -f "$dt" ] || continue
  dcc=$(sed -n 's/^AUTO_SETUP_NET_WIFI_COUNTRY_CODE=//p' "$dt" | head -1 | tr -d '\r')
  [ -n "$dcc" ] || continue
  if [ "$dcc" = "$SHIP_COUNTRY" ]; then
    note "$dt already agrees ('$dcc')"
  else
    note "$dt says '$dcc' — DietPi would act on that, not on the card"
    run sed -i "s/^AUTO_SETUP_NET_WIFI_COUNTRY_CODE=.*/AUTO_SETUP_NET_WIFI_COUNTRY_CODE=${SHIP_COUNTRY}/" "$dt"
  fi
done
# Reported, not done here: see SHIP_FAT_LABEL above for why it is an image step.
lbl=$(findmnt -no SOURCE "$FAT" 2>/dev/null | xargs -r blkid -o value -s LABEL 2>/dev/null || true)
if [ "$lbl" = "$SHIP_FAT_LABEL" ]; then
  note "FAT drive label is '$lbl'"
else
  note "FAT drive label is '${lbl:-none}', want '$SHIP_FAT_LABEL' — applied to the
    IMAGE after capture by scripts/release/set-fat-label.sh, not on this Pi.
    check-image.sh fails the image if it is missing."
fi
if [ -f "$FAT/dietpi-wifi.txt" ] && grep -qE "^aWIFI_(SSID|KEY)\[0\]='.+'" "$FAT/dietpi-wifi.txt"; then
  run sed -i -e "s/^aWIFI_SSID\[0\]=.*/aWIFI_SSID[0]=''/" \
             -e "s/^aWIFI_KEY\[0\]=.*/aWIFI_KEY[0]=''/" "$FAT/dietpi-wifi.txt"
fi

# The credentials that actually matter are on EXT4, not the card. Clearing
# x16-wifi.conf alone is security theatre: wpa_supplicant.conf holds a working
# credential (the stored PSK is the 256-bit hash, and wpa_supplicant joins with
# the hash directly — it does not need the plaintext), and the applier's own
# .bak-x16wifi copy holds another. All three shipped inside x16RasPi4-try6.gz.
# Deleting is right rather than editing: the applier recreates the file from the
# card when an owner sets up Wi-Fi.
for f in /etc/wpa_supplicant/wpa_supplicant.conf \
         /etc/wpa_supplicant/wpa_supplicant-*.conf \
         /etc/wpa_supplicant/*.bak-x16wifi; do
  [ -f "$f" ] || continue
  grep -q '^network={' "$f" 2>/dev/null && run rm -f "$f"
done

# The shipped appliance is Ethernet-only by design (config.txt.snippet sets the
# overlay: quieter, slightly faster to boot, and the emulator needs no network).
# Testing Wi-Fi on this Pi removes it, so put it back — otherwise every shipped
# unit powers up with a radio on, which is not what the README promises.
if grep -qE '^[[:space:]]*dtoverlay=disable-wifi' "$FAT/config.txt" 2>/dev/null; then
  note "Ethernet-only: dtoverlay=disable-wifi present  OK"
elif grep -qE '^[[:space:]]*#[[:space:]]*dtoverlay=disable-wifi' "$FAT/config.txt" 2>/dev/null; then
  note "dtoverlay=disable-wifi is commented out (a Wi-Fi test did this) — restoring"
  run sed -i 's/^[[:space:]]*#[[:space:]]*\(dtoverlay=disable-wifi\).*/\1/' "$FAT/config.txt"
else
  note "!! no dtoverlay=disable-wifi in config.txt — the image would ship with the radio on"
fi

# The overlay is only HALF the off-switch, which cost a whole test cycle to find
# out (2026-07-29). DietPi disables Wi-Fi twice over: the dtoverlay above keeps
# the chip off the SDIO bus, and /etc/modprobe.d/dietpi-disable_wifi.conf
# blacklists cfg80211/brcmfmac/brcmutil so the driver never binds even when the
# chip IS present. The applier renames that file when an owner asks for Wi-Fi,
# so a Pi used to TEST Wi-Fi no longer has it — and capturing that Pi would ship
# an image whose radio comes up wherever the overlay does not apply (a USB
# adapter, or any board where that overlay is a no-op). Put it back.
write_wifi_blacklist() {
  # cfg80211 last: DietPi writes it dependency-last so the load order reverses
  # cleanly. Matches `dietpi-set_hardware wifimodules disable` exactly.
  printf 'blacklist brcmutil\nblacklist brcmfmac\nblacklist cfg80211\n' \
    > /etc/modprobe.d/dietpi-disable_wifi.conf
}
BL=/etc/modprobe.d/dietpi-disable_wifi.conf
if [ -f "$BL" ]; then
  note "Wi-Fi module blacklist present  OK"
  [ -f "${BL}.bak-x16wifi" ] && run rm -f "${BL}.bak-x16wifi"
elif [ -f "${BL}.bak-x16wifi" ]; then
  note "Wi-Fi module blacklist was renamed by a Wi-Fi test — restoring"
  run mv "${BL}.bak-x16wifi" "$BL"
else
  note "no Wi-Fi module blacklist — recreating DietPi's"
  run write_wifi_blacklist
fi

# DietPi comments this out while Wi-Fi is off; the applier uncomments it. Left
# uncommented on a shipped card, ifupdown waits at boot on a wlan0 the overlay
# has removed — pure added boot time on a machine whose whole point is to be at
# the READY. prompt fast.
if grep -qE '^[[:space:]]*allow-hotplug[[:space:]]+wlan0' /etc/network/interfaces 2>/dev/null; then
  note "allow-hotplug wlan0 is uncommented (a Wi-Fi test did this) — re-commenting"
  run sed -i 's/^[[:space:]]*\(allow-hotplug[[:space:]]\+wlan0\)/#\1/' /etc/network/interfaces
fi
[ -f /etc/network/interfaces.bak-x16wifi ] && run rm -f /etc/network/interfaces.bak-x16wifi

# The applier's cache of the last status text. Harmless, but it records OUR
# join, and a shipped card should carry none of our network history.
[ -f /opt/x16/.x16-wifi-status.last ] && run rm -f /opt/x16/.x16-wifi-status.last

# ---- 3. the FAT partition is the first thing an owner sees ------------------
echo
echo "[3] FAT partition tidy"
shopt -s nullglob
for f in "$FAT"/*.bak-* "$FAT"/*.bak; do run rm -f "$f"; done
shopt -u nullglob
[ -d "$FAT/System Volume Information" ] && run rm -rf "$FAT/System Volume Information"
[ -f "$FAT/x16.conf" ] || note "!! $FAT/x16.conf missing — display settings won't be editable from a PC"
[ -f "$FAT/x16/README.TXT" ] || note "!! $FAT/x16/README.TXT missing — install dist/fat-x16-README.TXT there"

# ---- 4. logs and history ----------------------------------------------------
echo
echo "[4] logs and history"
[ -s /var/log/x16-appliance.log ] && run truncate -s 0 /var/log/x16-appliance.log
[ -s /root/.bash_history ] && run rm -f /root/.bash_history

# Hand-made backups from iterating over SSH. The workflow this project actually
# uses — deploy a script to the Pi, keep the previous copy "just in case" — means
# the shipped image quietly accumulates dead copies of its own tooling.
# Found on the 2026-07-29 Wi-Fi test card: x16-wifi-apply.bak-preboottest.
shopt -s nullglob
for f in /usr/local/bin/*.bak* /usr/local/bin/*.old /usr/local/bin/*.new /opt/x16/*.bak*; do
  run rm -f "$f"
done
shopt -u nullglob

# Shader cache built by OUR runs of the emulator. Mesa rebuilds it on demand, so
# this is pure build-machine residue — and it grows with every boot we do here.
[ -d /root/.cache/mesa_shader_cache_db ] && run rm -rf /root/.cache/mesa_shader_cache_db
[ -d /root/.cache/mesa_shader_cache ] && run rm -rf /root/.cache/mesa_shader_cache

# dietpi-ramlog_store is a DIRECTORY, not a log file — it is where DietPi-RAMlog
# persists /var/log across reboots, and the service expects it to exist. Empty
# it; deleting it would be removing part of the hardening to tidy up after it.
clear_ramlog_store() { find /var/lib/dietpi/logs/dietpi-ramlog_store -mindepth 1 -delete; }
shopt -s nullglob
for f in /var/lib/dietpi/logs/*; do
  if [ "$f" = /var/lib/dietpi/logs/dietpi-ramlog_store ]; then
    [ -n "$(ls -A "$f" 2>/dev/null)" ] && run clear_ramlog_store
  elif [ -d "$f" ]; then
    run rm -rf "$f"
  else
    run rm -f "$f"
  fi
done
shopt -u nullglob
run journalctl --rotate -q
run journalctl --vacuum-time=1s -q

# ---- 5. SSH host keys (opt-in) ---------------------------------------------
echo
echo "[5] SSH host keys"
# dropbear here runs without -R (DROPBEAR_EXTRA_ARGS is empty), so it does NOT
# generate a missing host key at startup — deleting these would ship an image
# with no SSH at all. Regenerate in place instead, so at least the dev Pi's
# identity doesn't travel. Every unit flashed from one image still shares them,
# which is true of every consumer Pi image and fine for a LAN appliance.
if [ "$RESET_HOST_KEYS" = 1 ]; then
  for t in rsa ecdsa ed25519; do
    k="/etc/dropbear/dropbear_${t}_host_key"
    [ -f "$k" ] || continue
    run rm -f "$k"
    run dropbearkey -t "$t" -f "$k"
  done
  note "clients that knew this Pi will warn about a changed host key"
else
  note "unchanged (pass --reset-host-keys to regenerate; the dev Pi's keys"
  note "would otherwise ship inside the image)"
fi

# ---- 6. report, don't fix ---------------------------------------------------
echo
echo "[6] checks"
idx=$(grep -oE '^AUTO_SETUP_AUTOSTART_TARGET_INDEX=[0-9]+' "$FAT/dietpi.txt" 2>/dev/null | cut -d= -f2)
[ "$idx" = 17 ] && note "autostart index 17 (appliance)  OK" \
                || note "!! autostart index is '${idx:-unset}', expected 17 — this image would boot to a shell"
# DietPi's own RAMlog is on by default and does log2ram's job; installing
# log2ram on top would be two things owning /var/log.
if findmnt -no FSTYPE /var/log 2>/dev/null | grep -q tmpfs; then
  note "DietPi-RAMlog active (/var/log is tmpfs)  OK"
else
  note "!! /var/log is not in RAM — the card takes every log write. Check"
  note "   'systemctl status dietpi-ramlog' rather than installing log2ram."
fi
[ -f /etc/log2ram.conf ] && note "!! log2ram installed as well as DietPi-RAMlog — both want /var/log"
[ -x /opt/x16/x16emu ] && note "emulator present  OK" || note "!! /opt/x16/x16emu missing"

echo
if [ "$APPLY" = 1 ]; then
  echo "Done — $CHANGES change(s) applied."
  echo "Now: sudo poweroff   (do NOT reboot — that would disarm the resize again)"
  echo "Then capture the card: scripts/release/capture-image.sh --from-device /dev/sdX"
else
  echo "$CHANGES change(s) pending. Re-run with --apply."
fi
