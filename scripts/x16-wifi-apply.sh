#!/bin/bash
#
# x16-wifi-apply — make the FAT-resident x16-wifi.conf actually take effect.
# Runs at boot from x16-wifi-apply.service. Install as /usr/local/bin/x16-wifi-apply.
#
# WHY: on a shipped appliance the owner has no shell and no network — so the only
# way in is a file on the FAT partition, the one thing a PC can edit with the SD
# card inserted. Nothing else works:
#   * /etc/wpa_supplicant/wpa_supplicant.conf is on ext4, mode 0600 — needs the
#     SSH access they're trying to obtain.
#   * dietpi-wifi.txt is on FAT but is only consumed by dietpi-firstboot (a
#     one-shot that disables itself) and by dietpi-config interactively. On a
#     PiShrink clone first-boot has already run, so edits do nothing.
# This script closes that hole: edit a file on the card, boot, connected.
#
# Pi 3 notes (we support Pi 3 and Pi 4):
#   * brcmfmac firmware loads noticeably slower on a Pi 3, so we WAIT for the
#     interface instead of assuming it exists.
#   * the radio comes up rfkill-soft-blocked until a regulatory country is set;
#     without one a Pi 3B+/4 will not touch 5 GHz at all. Hence the mandatory
#     X16_WIFI_COUNTRY and the explicit unblock.
#
set -u

LOG=/var/log/x16-appliance.log
WPA_CONF=/etc/wpa_supplicant/wpa_supplicant.conf

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') x16-wifi-apply: $*" >> "$LOG" 2>/dev/null; }

# --- locate the FAT boot partition (same probe the other scripts use) ---------
boot_fat() {
  for d in /boot/firmware /boot; do
    case "$(stat -f -c %T "$d" 2>/dev/null)" in
      msdos|vfat|exfat) printf '%s\n' "$d"; return 0 ;;
    esac
  done
  printf '%s\n' /boot
}
BOOT_FAT="$(boot_fat)"
CONF="${BOOT_FAT}/x16-wifi.conf"
CONFIG_TXT="${BOOT_FAT}/config.txt"

[ -f "$CONF" ] || { log "no ${CONF}; nothing to do"; exit 0; }

X16_WIFI_SSID=""; X16_WIFI_PSK=""; X16_WIFI_COUNTRY="GB"; X16_WIFI_HIDDEN=0
# shellcheck disable=SC1090
. "$CONF" 2>/dev/null

if [ -z "${X16_WIFI_SSID}" ]; then
  log "no SSID set; staying on Ethernet"
  exit 0
fi

# --- act ONLY when the card's config has changed ------------------------------
# COEXISTENCE WITH DIETPI'S OWN TOOLS. dietpi-config (Network Options) and
# dietpi-wifi.txt also own wpa_supplicant.conf and the disable-wifi overlay. If
# this script re-asserted the card's settings on every boot it would silently
# revert anything configured that way — and worse, re-enable the radio (with a
# reboot) after someone had deliberately turned it off in dietpi-config.
#
# So: the card is authoritative only at the moment it CHANGES. An unchanged
# config means we touch nothing at all — not wpa_supplicant.conf, not the
# overlay — and whatever dietpi-config did stands.
#
# The stamp lives on the FAT partition, NOT under /var/lib, for two reasons: it
# sits with the config it describes, and it survives the Phase 5 read-only root
# overlay. Under that overlay a /var/lib stamp would vanish every boot, making
# this look "changed" forever and rewriting the supplicant config each time.
FINGERPRINT="$(printf '%s|%s|%s|%s' "$X16_WIFI_SSID" "$X16_WIFI_PSK" \
                 "$X16_WIFI_COUNTRY" "$X16_WIFI_HIDDEN" | md5sum | cut -d' ' -f1)"
STAMP="${BOOT_FAT}/.x16-wifi.state"
if [ -f "$STAMP" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$FINGERPRINT" ]; then
  log "x16-wifi.conf unchanged; leaving networking alone (dietpi-config settings, if any, stand)"
  exit 0
fi
log "x16-wifi.conf changed (or first run) — applying SSID '${X16_WIFI_SSID}'"

# --- the radio has to exist at all -------------------------------------------
# dtoverlay is read by the FIRMWARE, long before this script runs, so we cannot
# switch the radio on for the boot we are already in. If someone filled in the
# SSID while the overlay is still present, re-arm and reboot ONCE.
#
# No loop guard is needed and none is used: removing the line from config.txt is
# itself persistent, so on the next boot this branch is simply false. We only
# reboot if the edit is verified to have stuck — on a read-only or full card the
# write could fail, and rebooting then WOULD loop.
if grep -qE '^[[:space:]]*dtoverlay=disable-wifi' "$CONFIG_TXT" 2>/dev/null; then
  log "SSID set but the radio is disabled in config.txt; re-arming"
  cp "$CONFIG_TXT" "${CONFIG_TXT}.bak-x16wifi" 2>/dev/null
  sed -i 's/^\([[:space:]]*\)dtoverlay=disable-wifi/#\1dtoverlay=disable-wifi   # auto-removed: x16-wifi.conf has an SSID/' \
    "$CONFIG_TXT" 2>/dev/null
  sync
  if grep -qE '^[[:space:]]*dtoverlay=disable-wifi' "$CONFIG_TXT" 2>/dev/null; then
    log "ERROR: could not edit ${CONFIG_TXT} (read-only or full?). NOT rebooting."
    exit 1
  fi
  log "radio enabled in config.txt; rebooting once to load the driver"
  systemctl reboot
  exit 0
fi

# --- wait for the interface (Pi 3 is slow to load brcmfmac firmware) ----------
find_wifi_iface() {
  for n in /sys/class/net/*/wireless; do
    [ -e "$n" ] || continue
    basename "$(dirname "$n")"; return 0
  done
  return 1
}
# A Pi 3 can take several seconds to load brcmfmac firmware, so allow 20s. But
# don't pay that on EVERY boot of a machine that simply has no Wi-Fi hardware
# (an SSID set on a Pi with no radio would otherwise add 20s to each boot, and
# the emulator waits behind network.target). Once we've concluded there's no
# hardware, later boots re-check briefly instead.
# On FAT for the same reason as the fingerprint stamp: /var/lib does not survive
# the Phase 5 read-only root overlay, so a stamp there would be lost every boot
# and every boot would pay the full 20s wait again.
NOHW="${BOOT_FAT}/.x16-wifi.nohardware"
WAIT=20
[ -f "$NOHW" ] && WAIT=5
IFACE=""
i=0
while [ $i -lt $WAIT ]; do
  IFACE="$(find_wifi_iface)" && [ -n "$IFACE" ] && break
  i=$((i + 1)); sleep 1
done
if [ -z "$IFACE" ]; then
  log "no wireless interface after ${i}s — no Wi-Fi hardware, or the driver failed"
  : > "$NOHW" 2>/dev/null
  # Stamp even though we achieved nothing. The stamp means "this config version
  # has been dealt with", NOT "it worked". Without it a machine that bails here
  # looks permanently changed, and the next boot re-arms the overlay again — so
  # turning the radio off in dietpi-config would be undone by a surprise reboot,
  # forever. Caught in testing 2026-07-25 by doing exactly that.
  printf '%s' "$FINGERPRINT" > "$STAMP" 2>/dev/null
  sync 2>/dev/null
  exit 1
fi
rm -f "$NOHW" 2>/dev/null
log "using interface ${IFACE} (appeared after ${i}s)"

# --- regulatory domain + rfkill ----------------------------------------------
# Must come before association: a soft-blocked radio silently never associates.
iw reg set "${X16_WIFI_COUNTRY}" 2>/dev/null && log "regulatory domain: ${X16_WIFI_COUNTRY}"
if command -v rfkill >/dev/null 2>&1; then
  rfkill unblock wifi 2>/dev/null
  rfkill unblock all 2>/dev/null
fi
ip link set "$IFACE" up 2>/dev/null

# --- write wpa_supplicant.conf ------------------------------------------------
# We only get here because the card's config changed, so overwriting whatever is
# present is the user's explicit intent. Keep a backup regardless.
mkdir -p "$(dirname "$WPA_CONF")"
[ -f "$WPA_CONF" ] && cp "$WPA_CONF" "${WPA_CONF}.bak-x16wifi"
{
  echo "ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev"
  echo "update_config=1"
  echo "country=${X16_WIFI_COUNTRY}"
  echo
  if [ -n "${X16_WIFI_PSK}" ]; then
    # wpa_passphrase emits the hashed psk; strip its plaintext comment line.
    wpa_passphrase "${X16_WIFI_SSID}" "${X16_WIFI_PSK}" 2>/dev/null |
      grep -v '^[[:space:]]*#psk=' |
      { if [ "${X16_WIFI_HIDDEN}" = 1 ]; then sed 's/^}/\tscan_ssid=1\n}/'; else cat; fi; }
  else
    printf 'network={\n\tssid="%s"\n\tkey_mgmt=NONE\n' "${X16_WIFI_SSID}"
    [ "${X16_WIFI_HIDDEN}" = 1 ] && printf '\tscan_ssid=1\n'
    printf '}\n'
  fi
} > "$WPA_CONF"
chmod 600 "$WPA_CONF"
log "wrote ${WPA_CONF} for SSID '${X16_WIFI_SSID}' (country ${X16_WIFI_COUNTRY})"

# --- apply --------------------------------------------------------------------
if ! wpa_cli -i "$IFACE" reconfigure >/dev/null 2>&1; then
  systemctl restart "wpa_supplicant@${IFACE}" >/dev/null 2>&1 ||
    systemctl restart wpa_supplicant >/dev/null 2>&1 ||
    ifup "$IFACE" >/dev/null 2>&1
fi

# Give it a moment, then make sure we have an address (DHCP).
i=0
while [ $i -lt 15 ]; do
  ssid_now="$(iw dev "$IFACE" link 2>/dev/null | sed -n 's/^[[:space:]]*SSID:[[:space:]]*//p')"
  [ -n "$ssid_now" ] && break
  i=$((i + 1)); sleep 1
done
# Record what we applied, whether or not association succeeded THIS boot.
#
# Deliberately not gated on success: wpa_supplicant keeps retrying on its own
# with the config we just wrote, so an AP that is merely down or out of range
# will connect later without our help. Re-running this every boot instead would
# cost ~35s of boot time each time (the emulator waits behind network.target)
# and achieve nothing the supplicant isn't already doing. A genuine mistake —
# wrong password or country — is fixed by editing the card, which changes the
# fingerprint and re-triggers us anyway.
printf '%s' "$FINGERPRINT" > "$STAMP" 2>/dev/null
sync 2>/dev/null

# Keep DietPi's own view consistent, so dietpi-config shows the same network
# rather than stale or empty values if someone opens it later.
if [ -n "${DIETPI_WIFI:-}" ] && [ -f "${DIETPI_WIFI}" ]; then
  sed -i "s|^aWIFI_SSID\[0\]=.*|aWIFI_SSID[0]='${X16_WIFI_SSID}'|" "$DIETPI_WIFI" 2>/dev/null
  sed -i "s|^aWIFI_KEY\[0\]=.*|aWIFI_KEY[0]='${X16_WIFI_PSK}'|" "$DIETPI_WIFI" 2>/dev/null
fi

if [ -n "${ssid_now:-}" ]; then
  ip -4 addr show "$IFACE" 2>/dev/null | grep -q 'inet ' || {
    dhclient "$IFACE" >/dev/null 2>&1 || udhcpc -i "$IFACE" -n >/dev/null 2>&1 || true
  }
  addr="$(ip -4 -brief addr show "$IFACE" 2>/dev/null | awk '{print $3}')"
  log "associated with '${ssid_now}'${addr:+ address ${addr}}"
  exit 0
fi
log "did NOT associate with '${X16_WIFI_SSID}' — wrong passphrase, wrong country, or out of range."
log "wpa_supplicant will keep retrying; edit x16-wifi.conf on the card to change the settings."
exit 1
