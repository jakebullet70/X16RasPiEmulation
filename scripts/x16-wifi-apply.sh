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
# CONSUME-AND-CLEAR (2026-07-29, replaces the fingerprint stamp).
# The card is read on every boot. When a join SUCCEEDS, the credentials are
# cleared from x16-wifi.conf and only the copy on ext4 (wpa_supplicant.conf,
# mode 0600) remains. So:
#   * the Wi-Fi password does not sit in plain text on a partition every PC can
#     read, for the entire life of the machine;
#   * blank is the steady state, and blank means "do nothing" — so deferring to
#     dietpi-config falls out for free, with no stamp file to get out of sync;
#   * nothing can ship a stale stamp that makes an owner's first edit look
#     "unchanged" and get ignored. That failure is now structurally impossible.
# A FAILED join deliberately leaves the file alone, so a typo'd passphrase stays
# on screen to be corrected, and x16-wifi-status.txt on the card says what went
# wrong. The owner never needs a shell to see why.
#
# The pristine template lives at /opt/x16/x16-wifi.conf.original — on ext4, ON
# PURPOSE. It must never be something the owner can edit, and the card holds
# exactly one Wi-Fi file. If it is missing it is derived, once, from whatever
# x16-wifi.conf is present, so the shipped comments survive and the reset can
# never fail for want of a template.
#
# X16_WIFI_COUNTRY is carried across the reset and is NEVER left blank: DietPi
# prints a boot-time warning when no country code is set, and this appliance's
# whole Phase 4 premise is that nothing but the X16 is ever on screen.
#
# Known trade of dropping the stamp: if an SSID that never associates is left on
# the card AND the owner then disables Wi-Fi in dietpi-config, the next boot
# re-enables the radio and reboots once, undoing that. It cannot loop (removing
# the overlay is persistent) and it cannot happen at all once a join succeeds,
# because the card is blank from then on.
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
INTERFACES=/etc/network/interfaces
ORIGINAL=/opt/x16/x16-wifi.conf.original
LASTBODY=/opt/x16/.x16-wifi-status.last

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
STATUS="${BOOT_FAT}/x16-wifi-status.txt"

# Vestigial fingerprint stamp from the pre-2026-07-29 design. Harmless, but an
# owner finding a mystery dotfile on their card deserves better.
rm -f "${BOOT_FAT}/.x16-wifi.state" 2>/dev/null

# --- the status file the owner reads on their PC ------------------------------
# CRLF, like dist/fat-x16-README.TXT: this is opened in Windows Notepad by people
# who have never seen a Pi, and LF-only renders as one run-on line.
# Written on EVERY path, including "nothing to do" — dist/README-end-user.md
# tells the owner to read this file to find out what happened, and a file that
# only materialises once Wi-Fi has been attempted reads as a broken card to
# someone whose first instinct is to look.
#
# Idempotent on purpose. This is an appliance people switch off at the wall, so
# an avoidable FAT write is an avoidable chance of being mid-write when the
# power goes. The previous body is kept on ext4 rather than parsed back out of
# the card, so the comparison never depends on how the file is formatted.
status() {
  body="$(cat)"
  if [ -f "$STATUS" ] && [ -f "$LASTBODY" ] &&
     [ "$body" = "$(cat "$LASTBODY" 2>/dev/null)" ]; then
    log "status unchanged; leaving ${STATUS} alone"
    return 0
  fi
  {
    printf 'COMMANDER X16 - WI-FI STATUS\r\n'
    printf '============================\r\n\r\n'
    # fake-hwclock means the clock can be nonsense this early in boot; a
    # confidently wrong 1970 timestamp is worse than none.
    case "$(date '+%Y' 2>/dev/null)" in
      2[0-9][0-9][0-9]) [ "$(date '+%Y')" -ge 2025 ] && printf '%s\r\n\r\n' "$(date '+%Y-%m-%d %H:%M')" ;;
    esac
    printf '%s\n' "$body" | while IFS= read -r line; do printf '%s\r\n' "$line"; done
    printf '\r\n(This file is written by the Pi. Editing it does nothing.)\r\n'
  } > "$STATUS" 2>/dev/null
  sync 2>/dev/null
  printf '%s\n' "$body" > "$LASTBODY" 2>/dev/null
}

# --- the pristine template ----------------------------------------------------
# Derived from the card's own file the first time, so the owner-facing comments
# in the shipped x16-wifi.conf are preserved verbatim rather than reinvented here.
ensure_original() {
  [ -f "$ORIGINAL" ] && return 0
  [ -f "$CONF" ] || return 1
  mkdir -p "$(dirname "$ORIGINAL")" 2>/dev/null
  sed -e 's/^X16_WIFI_SSID=.*/X16_WIFI_SSID=/' \
      -e 's/^X16_WIFI_PSK=.*/X16_WIFI_PSK=/' "$CONF" > "$ORIGINAL" 2>/dev/null &&
    log "created ${ORIGINAL} from the card's x16-wifi.conf"
}

# Put the card back to blank, carrying the owner's country and hidden-network
# choice forward. Built in /tmp and copied once, so the FAT partition takes a
# single write — this is an appliance people switch off at the wall.
scrub_conf() {
  [ -f "$ORIGINAL" ] || { log "no ${ORIGINAL}; NOT clearing the card"; return 1; }
  country="$1"; hidden="$2"
  case "$country" in
    [A-Za-z][A-Za-z]) : ;;
    # Never write a blank or malformed country: DietPi warns on screen at boot
    # without one. Fall back to whatever the template ships with.
    *) country="$(sed -n 's/^X16_WIFI_COUNTRY=//p' "$ORIGINAL" | head -1)" ;;
  esac
  case "$hidden" in 0|1) : ;; *) hidden=0 ;; esac
  tmp="$(mktemp)" || return 1
  sed -e "s/^X16_WIFI_COUNTRY=.*/X16_WIFI_COUNTRY=${country}/" \
      -e "s/^X16_WIFI_HIDDEN=.*/X16_WIFI_HIDDEN=${hidden}/" "$ORIGINAL" > "$tmp" 2>/dev/null
  if cp "$tmp" "$CONF" 2>/dev/null; then
    sync 2>/dev/null
    log "cleared the credentials from ${CONF} (country ${country} kept)"
  else
    log "WARNING: could not rewrite ${CONF} — the password is still on the card"
  fi
  rm -f "$tmp" 2>/dev/null
}

[ -f "$CONF" ] || { log "no ${CONF}; nothing to do"; exit 0; }

X16_WIFI_SSID=""; X16_WIFI_PSK=""; X16_WIFI_COUNTRY="US"; X16_WIFI_HIDDEN=0
# Source a CR-STRIPPED COPY, never the card's file directly.
#
# This file exists to be edited on a Windows PC, and an editor that saves CRLF
# leaves a trailing \r inside every value. Debian's bash keeps it. (A dev box
# will NOT reproduce this: git-bash/MSYS strips CR when sourcing, so the bug
# looks absent everywhere except on the appliance.)
#
# Measured on hardware 2026-07-29: the SSID becomes "MyNetwork\r", and
# wpa_passphrase then dies with "Invalid passphrase character" — so
# wpa_supplicant.conf is written with a header and NO network block, the Pi
# never associates, the card is never cleared, and the owner is told to go and
# check a password that was correct all along. That is precisely the silent,
# undiagnosable failure this whole design exists to eliminate, reached by the
# single most likely thing an owner can do.
#
# Sourcing a copy rather than parsing keeps shell quoting working, so an SSID
# with spaces can still be written as X16_WIFI_SSID="My Network".
if _tmpconf="$(mktemp 2>/dev/null)" && sed 's/\r$//' "$CONF" > "$_tmpconf" 2>/dev/null; then
  # shellcheck disable=SC1090
  . "$_tmpconf" 2>/dev/null
  rm -f "$_tmpconf"
else
  # /tmp not up yet — a CRLF risk beats no configuration at all.
  # shellcheck disable=SC1090
  . "$CONF" 2>/dev/null
fi

ensure_original

# Blank is the normal, post-success state and costs ~16ms, so an Ethernet-only
# machine pays nothing for this script existing.
if [ -z "${X16_WIFI_SSID}" ]; then
  # A blank card means one of TWO opposite things, and they must not be reported
  # the same way:
  #   1. never configured — Ethernet only, which is how every card ships;
  #   2. configured and then cleared by a SUCCESSFUL join, which is the whole
  #      point of consume-and-clear. Wi-Fi works; the card is blank BECAUSE it
  #      worked.
  # Telling case 2 "Wi-Fi is not set up" would overwrite the "Connected to ..."
  # message with a flat contradiction, on the boot right after it succeeded.
  # The saved network on ext4 is what tells them apart.
  saved="$(sed -n 's/^[[:space:]]*ssid="\(.*\)"[[:space:]]*$/\1/p' "$WPA_CONF" 2>/dev/null | head -1)"
  if [ -n "${saved:-}" ]; then
    log "no SSID on the card; Wi-Fi already saved for '${saved}'"
    # Deliberately NOT phrased as "connected": this runs early in boot, before
    # association, so claiming a live connection here would be a guess.
    status <<EOF
Wi-Fi is already set up for "${saved}".

Your password is saved on the Pi itself, which is why this file
looks blank. That is normal, and it means it worked.

To move to a different network, type the new details into
x16-wifi.conf and start the Pi again.
EOF
  else
    log "no SSID set; staying on Ethernet"
    # The state every card ships in, so for most owners this is the only status
    # text they will ever see. It has to read as "working as intended" rather
    # than as an error — and it has to exist at all; see status() above.
    status <<EOF
Wi-Fi is not set up, so the Pi is using the network cable.

Nothing is wrong - this is how a new card comes.

To use Wi-Fi instead, type your network name and password into
x16-wifi.conf on this drive, then start the Pi again.
EOF
  fi
  exit 0
fi
log "x16-wifi.conf has SSID '${X16_WIFI_SSID}' — applying"

# WPA-PSK passphrases are 8-63 characters. Outside that, wpa_passphrase refuses
# and the config below gets a header with no network block — which surfaces as
# the generic "could not join", sending the owner to re-check a password whose
# only fault is its length. Checked here, before the radio-enable reboot, so a
# password that cannot work never costs them a restart to find that out.
if [ -n "${X16_WIFI_PSK}" ]; then
  psk_len=${#X16_WIFI_PSK}
  if [ "$psk_len" -lt 8 ] || [ "$psk_len" -gt 63 ]; then
    log "passphrase is ${psk_len} characters; WPA requires 8-63. Not writing a config."
    status <<EOF
The Wi-Fi password in x16-wifi.conf is ${psk_len} characters long.

Wi-Fi passwords have to be between 8 and 63 characters, so this one
cannot be used. Check the X16_WIFI_PSK line in x16-wifi.conf - the
password may have been cut short, or picked up an extra character.

Your settings have been left on the card so you can correct them.
EOF
    exit 1
  fi
fi

# --- DietPi's module blacklist ------------------------------------------------
# A SECOND, INDEPENDENT off-switch — and the one that actually kept the radio
# dark. `dietpi-set_hardware wifimodules disable` writes
# /etc/modprobe.d/dietpi-disable_wifi.conf blacklisting brcmutil, brcmfmac and
# cfg80211. That is nothing to do with the dtoverlay: removing the overlay puts
# the chip back on the SDIO bus (dmesg: "mmc1: new high speed SDIO card") but
# the driver still never binds, so no interface ever appears and this script
# reported "This Pi does not appear to have Wi-Fi" — on a Pi 4 with perfectly
# good onboard Wi-Fi. Found on hardware 2026-07-29, after the overlay handling
# below had already been proved to work.
#
# Removing the file is exactly what DietPi's own `wifimodules enable` does. It
# is renamed rather than deleted: modprobe.d only reads *.conf, so the backup is
# inert while the owner's original state stays recoverable.
#
# Deliberately BEFORE the reboot branch below: with the blacklist already gone,
# the next boot autoloads the driver from the SDIO modalias before this script
# even runs, so the interface is simply there rather than waited for.
enable_wifi_modules() {
  bl=/etc/modprobe.d/dietpi-disable_wifi.conf
  [ -f "$bl" ] || return 0
  mods="$(sed -n 's/^[[:space:]]*blacklist[[:space:]]\{1,\}//p' "$bl")"
  mv "$bl" "${bl}.bak-x16wifi" 2>/dev/null || rm -f "$bl" 2>/dev/null
  log "removed DietPi's Wi-Fi module blacklist (${bl})"
  # DietPi writes that list dependency-LAST, so load it in reverse — cfg80211
  # before the driver that needs it. Reading the file back instead of hardcoding
  # brcmfmac means a USB adapter's module is handled on the same path.
  rev=""
  for m in $mods; do rev="$m $rev"; done
  for m in $rev; do
    modprobe "$m" 2>/dev/null && log "loaded Wi-Fi module ${m}"
  done
}
enable_wifi_modules

# --- the radio has to exist at all -------------------------------------------
# dtoverlay is read by the FIRMWARE, long before this script runs, so we cannot
# switch the radio on for the boot we are already in. If someone filled in the
# SSID while the overlay is still present, re-arm and reboot ONCE.
#
# No loop guard is needed and none is used: removing the line from config.txt is
# itself persistent, so on the next boot this branch is simply false. We only
# reboot if the edit is verified to have stuck — on a read-only or full card the
# write could fail, and rebooting then WOULD loop.
#
# Nothing is cleared here. The credentials must survive this reboot to be used
# on the far side of it, which is exactly why the clear waits for a real join.
if grep -qE '^[[:space:]]*dtoverlay=disable-wifi' "$CONFIG_TXT" 2>/dev/null; then
  log "SSID set but the radio is disabled in config.txt; re-arming"
  cp "$CONFIG_TXT" "${CONFIG_TXT}.bak-x16wifi" 2>/dev/null
  sed -i 's/^\([[:space:]]*\)dtoverlay=disable-wifi/#\1dtoverlay=disable-wifi   # auto-removed: x16-wifi.conf has an SSID/' \
    "$CONFIG_TXT" 2>/dev/null
  sync
  if grep -qE '^[[:space:]]*dtoverlay=disable-wifi' "$CONFIG_TXT" 2>/dev/null; then
    log "ERROR: could not edit ${CONFIG_TXT} (read-only or full?). NOT rebooting."
    status <<EOF
Could not switch the Wi-Fi radio on.

The Pi was unable to write to the SD card. The card may be full,
write-protected, or worn out.
EOF
    exit 1
  fi
  log "radio enabled in config.txt; rebooting once to load the driver"
  status <<EOF
Switching the Wi-Fi radio on for "${X16_WIFI_SSID}".

The Pi is restarting once by itself to load the Wi-Fi driver -
this is normal and only happens the first time. Give it a minute,
then check this file again.
EOF
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
# don't pay that on EVERY boot of a machine that simply has no Wi-Fi hardware —
# the emulator waits behind network.target. Once we've concluded there's no
# radio, later boots re-check briefly instead.
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
  sync 2>/dev/null
  status <<EOF
This Pi does not appear to have Wi-Fi.

No wireless adapter was found, so "${X16_WIFI_SSID}" could not be
joined. Use a network cable instead.

Your settings have been left in x16-wifi.conf. Clear the
X16_WIFI_SSID line to stop the Pi trying on every start-up.
EOF
  exit 1
fi
rm -f "$NOHW" 2>/dev/null
log "using interface ${IFACE} (appeared after ${i}s)"

# --- regulatory domain + rfkill ----------------------------------------------
# Must come before association: a soft-blocked radio silently never associates.
#
# The rfkill BINARY is not in this image. Bookworm ships it as its own package
# and DietPi does not pull it in, so `command -v rfkill` was always false and the
# unblock that this script's own header calls mandatory never actually ran.
# Confirmed on hardware, 2026-07-29: "rfkill: command not found".
#
# Rather than take a package dependency for two ioctls, drive the same kernel
# interface directly — every rfkill device exposes `soft`, and writing 0 clears
# the soft block. That also works on a card built with no network available.
unblock_radio() {
  if command -v rfkill >/dev/null 2>&1; then
    rfkill unblock all 2>/dev/null && { log "rfkill: unblocked via the rfkill binary"; return 0; }
  fi
  n=0
  for d in /sys/class/rfkill/rfkill*; do
    [ -e "$d/soft" ] || continue          # no match: the glob stays literal
    case "$(cat "$d/type" 2>/dev/null)" in
      wlan|all) echo 0 > "$d/soft" 2>/dev/null && n=$((n + 1)) ;;
    esac
  done
  [ "$n" -gt 0 ] && log "rfkill: cleared the soft block on ${n} device(s) via sysfs"
  # A HARD block is a physical switch and nothing in software can clear it. Say
  # so in the log, because the symptom is identical to a wrong passphrase: the
  # radio is up, the config is right, and it silently never associates.
  for d in /sys/class/rfkill/rfkill*; do
    [ "$(cat "$d/hard" 2>/dev/null)" = 1 ] &&
      log "WARNING: ${d##*/} is HARD-blocked; software cannot enable this radio"
  done
  return 0
}
iw reg set "${X16_WIFI_COUNTRY}" 2>/dev/null && log "regulatory domain: ${X16_WIFI_COUNTRY}"
unblock_radio
ip link set "$IFACE" up 2>/dev/null

# --- write wpa_supplicant.conf ------------------------------------------------
# This is the copy that persists: once the join succeeds the card is cleared and
# this file, mode 0600 on ext4, is the only place the passphrase lives.
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

# systemd's wpa_supplicant@<iface> template reads a PER-INTERFACE file name, not
# the one above. Without this copy the unit starts, fails 260ms later with
# "Failed to open config file .../wpa_supplicant-wlan0.conf", and -- because
# `systemctl restart` still reports success for a unit that dies after starting
# -- the ifup fallback below never ran. Found on hardware: radio up, config
# written, nothing associated.
cp "$WPA_CONF" "/etc/wpa_supplicant/wpa_supplicant-${IFACE}.conf" 2>/dev/null &&
  chmod 600 "/etc/wpa_supplicant/wpa_supplicant-${IFACE}.conf"

# --- let the interface actually come up ---------------------------------------
# ifupdown owns wlan0 here: the /etc/network/interfaces stanza carries the
# `wpa-conf` line. But DietPi COMMENTS OUT `allow-hotplug wlan0` when Wi-Fi is
# disabled, and nothing else un-does it -- so the radio comes up and then
# nothing ever launches wpa_supplicant. Mirrors the disable-wifi overlay
# handling above: the owner edited the card, so this is their explicit intent.
if [ -f "$INTERFACES" ] &&
   grep -qE "^[[:space:]]*#[[:space:]]*allow-hotplug[[:space:]]+${IFACE}" "$INTERFACES"; then
  cp "$INTERFACES" "${INTERFACES}.bak-x16wifi"
  sed -i "s/^[[:space:]]*#[[:space:]]*\(allow-hotplug[[:space:]]\+${IFACE}\)/\1/" "$INTERFACES"
  log "enabled 'allow-hotplug ${IFACE}' in ${INTERFACES}"
fi

# --- apply --------------------------------------------------------------------
if ! wpa_cli -i "$IFACE" reconfigure >/dev/null 2>&1; then
  # Backgrounded on purpose. Association takes ~2s but the DHCP lease took 21s
  # on the test AP, and this unit runs before network-pre.target -- blocking
  # here would hold up the emulator for the whole lease negotiation.
  ifdown "$IFACE" >/dev/null 2>&1
  ( ifup "$IFACE" >/dev/null 2>&1 & ) ||
    systemctl restart "wpa_supplicant@${IFACE}" >/dev/null 2>&1
fi

# Give it a moment to associate. This is the decision point for clearing the
# card, so it has to be a real answer rather than an assumption.
i=0
while [ $i -lt 15 ]; do
  ssid_now="$(iw dev "$IFACE" link 2>/dev/null | sed -n 's/^[[:space:]]*SSID:[[:space:]]*//p')"
  [ -n "$ssid_now" ] && break
  i=$((i + 1)); sleep 1
done

if [ -n "${ssid_now:-}" ]; then
  ip -4 addr show "$IFACE" 2>/dev/null | grep -q 'inet ' || {
    dhclient "$IFACE" >/dev/null 2>&1 || udhcpc -i "$IFACE" -n >/dev/null 2>&1 || true
  }
  addr="$(ip -4 -brief addr show "$IFACE" 2>/dev/null | awk '{print $3}')"
  log "associated with '${ssid_now}'${addr:+ address ${addr}}"

  # Success: the credentials are now safely on ext4, so take them off the card.
  # Deliberately NOT mirrored into dietpi-wifi.txt — that lives on FAT too, and
  # copying the passphrase there would put back exactly what we just removed.
  scrub_conf "${X16_WIFI_COUNTRY}" "${X16_WIFI_HIDDEN}"
  status <<EOF
Connected to "${ssid_now}".${addr:+
Address on your network: ${addr%%/*}}

The Pi has saved these settings to itself and cleared them from
x16-wifi.conf, so your password is no longer stored on this card.
Wi-Fi will come up on its own from now on.

To change networks later, just type the new details into
x16-wifi.conf again.
EOF
  exit 0
fi

log "did NOT associate with '${X16_WIFI_SSID}' — wrong passphrase, wrong country, or out of range."
log "wpa_supplicant will keep retrying; edit x16-wifi.conf on the card to change the settings."
status <<EOF
Could not join "${X16_WIFI_SSID}".

Your settings are still in x16-wifi.conf so you can correct them.
Check, in this order:

  1. The password - it is case-sensitive.
  2. The network name - also case-sensitive, and it must match
     exactly.
  3. X16_WIFI_COUNTRY - it must be your own country's two-letter
     code, or the Pi is not allowed to use some channels.
  4. That the Pi is close enough to the router.

The Pi keeps trying in the background, so if the network was
simply switched off it may connect on its own. This file always
shows how the last start-up went.
EOF
exit 1
