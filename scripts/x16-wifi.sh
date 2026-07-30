#!/bin/bash
#
# x16-wifi — turn the Pi's Wi-Fi on/off and join a network, from SSH or a VT.
# Companion to x16-display. Install as /usr/local/bin/x16-wifi.
#
# WHY THIS EXISTS: the appliance ships Ethernet-only, with
# `dtoverlay=disable-wifi` in config.txt removing the radio at the device-tree
# level (quieter + slightly faster boot; the emulator needs no network). The
# failure mode that costs people an evening is that filling in credentials while
# that overlay is still present does NOTHING and says nothing: wlan0 never
# exists, so there is no interface for the credentials to apply to. This tool
# always shows the radio state first, and refuses to pretend it can join a
# network while the radio is off.
#
# Credentials go to BOTH places on purpose:
#   /etc/wpa_supplicant/wpa_supplicant.conf  - what actually connects, now
#   /boot/firmware/dietpi-wifi.txt           - what DietPi re-applies on rebuild,
#                                              and editable from any PC via the card
#
set -u

CONFIG_TXT=""
for c in /boot/firmware/config.txt /boot/config.txt; do
  [ -f "$c" ] && { CONFIG_TXT="$c"; break; }
done
DIETPI_TXT=""
for d in /boot/firmware/dietpi.txt /boot/dietpi.txt; do
  [ -f "$d" ] && { DIETPI_TXT="$d"; break; }
done
DIETPI_WIFI=""
for d in /boot/firmware/dietpi-wifi.txt /boot/dietpi-wifi.txt; do
  [ -f "$d" ] && { DIETPI_WIFI="$d"; break; }
done
WPA_CONF=/etc/wpa_supplicant/wpa_supplicant.conf
IFACE="${X16_WIFI_IFACE:-wlan0}"

[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo x16-wifi)."; exit 1; }
[ -n "$CONFIG_TXT" ] || { echo "Cannot find config.txt — is this a Pi?"; exit 1; }

# ---------------------------------------------------------------- state probes
radio_disabled() { grep -qE '^[[:space:]]*dtoverlay=disable-wifi' "$CONFIG_TXT"; }
iface_exists()   { [ -e "/sys/class/net/${IFACE}" ]; }

current_ssid() {
  iw dev "$IFACE" link 2>/dev/null | sed -n 's/^[[:space:]]*SSID:[[:space:]]*//p'
}
current_ip() {
  ip -4 -brief addr show "$IFACE" 2>/dev/null | awk '{print $3}'
}
current_signal() {
  iw dev "$IFACE" link 2>/dev/null | sed -n 's/^[[:space:]]*signal:[[:space:]]*//p'
}

# ------------------------------------------------------------------ operations
enable_radio() {
  if ! radio_disabled; then
    echo "Radio is already enabled in ${CONFIG_TXT}."
  else
    cp "$CONFIG_TXT" "${CONFIG_TXT}.bak-x16wifi"
    # Comment it rather than delete, so the choice stays visible and reversible.
    sed -i 's/^\([[:space:]]*\)dtoverlay=disable-wifi/#\1dtoverlay=disable-wifi   # disabled by x16-wifi/' "$CONFIG_TXT"
    echo "Removed dtoverlay=disable-wifi (backup: ${CONFIG_TXT}.bak-x16wifi)."
  fi
  if [ -n "$DIETPI_TXT" ] && grep -q '^AUTO_SETUP_NET_WIFI_ENABLED=' "$DIETPI_TXT"; then
    sed -i 's/^AUTO_SETUP_NET_WIFI_ENABLED=.*/AUTO_SETUP_NET_WIFI_ENABLED=1/' "$DIETPI_TXT"
    echo "Set AUTO_SETUP_NET_WIFI_ENABLED=1 in ${DIETPI_TXT}."
  fi
  echo
  echo "A REBOOT is required before ${IFACE} appears — the radio is removed in the"
  echo "device tree, which is only read at boot."
}

disable_radio() {
  if radio_disabled; then
    echo "Radio is already disabled."; return
  fi
  cp "$CONFIG_TXT" "${CONFIG_TXT}.bak-x16wifi"
  if grep -q '^#[[:space:]]*dtoverlay=disable-wifi' "$CONFIG_TXT"; then
    sed -i 's/^#[[:space:]]*\(dtoverlay=disable-wifi\).*/\1/' "$CONFIG_TXT"
  else
    printf '\ndtoverlay=disable-wifi\n' >> "$CONFIG_TXT"
  fi
  echo "Added dtoverlay=disable-wifi. Reboot to take effect."
  echo "Make sure Ethernet works first, or you will lose network access."
}

scan_networks() {
  if ! iface_exists; then
    echo "No ${IFACE} — the radio is off. Enable it and reboot first."; return 1
  fi
  ip link set "$IFACE" up 2>/dev/null
  echo "Scanning..."
  iw dev "$IFACE" scan 2>/dev/null |
    awk '/^BSS/ {sig=""; ssid=""} /signal:/ {sig=$2} /^\tSSID: / {sub(/^\tSSID: /,""); if (length($0)) printf "  %-32s %s dBm\n", $0, sig}' |
    sort -u | head -25
  [ "${PIPESTATUS[0]}" -ne 0 ] && echo "  (scan failed — is the interface up?)"
}

join_network() {
  if ! iface_exists; then
    echo
    echo "Cannot join: ${IFACE} does not exist, because the radio is disabled in"
    echo "${CONFIG_TXT}. Saving credentials now would appear to work and then"
    echo "silently do nothing. Use option 2 first, reboot, then come back."
    return 1
  fi
  printf 'SSID: '; read -r ssid
  [ -n "$ssid" ] || { echo "No SSID given."; return 1; }
  printf 'Passphrase (leave empty for an open network): '
  read -rs psk; echo

  mkdir -p "$(dirname "$WPA_CONF")"
  [ -f "$WPA_CONF" ] && cp "$WPA_CONF" "${WPA_CONF}.bak-x16wifi"
  if [ ! -s "$WPA_CONF" ]; then
    {
      echo "ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev"
      echo "update_config=1"
      echo "country=${X16_WIFI_COUNTRY:-GB}"
    } > "$WPA_CONF"
  fi
  # Drop any previous block for this SSID so repeats don't stack up.
  if grep -q "ssid=\"${ssid}\"" "$WPA_CONF" 2>/dev/null; then
    awk -v s="ssid=\"${ssid}\"" '
      /^network=\{/ {buf="";inb=1}
      inb {buf=buf $0 ORS; if ($0 ~ /^\}/) {inb=0; if (index(buf,s)==0) printf "%s",buf}; next}
      {print}' "$WPA_CONF" > "${WPA_CONF}.tmp" && mv "${WPA_CONF}.tmp" "$WPA_CONF"
  fi
  if [ -n "$psk" ]; then
    wpa_passphrase "$ssid" "$psk" | grep -v '^\s*#psk=' >> "$WPA_CONF"
  else
    printf 'network={\n\tssid="%s"\n\tkey_mgmt=NONE\n}\n' "$ssid" >> "$WPA_CONF"
  fi
  chmod 600 "$WPA_CONF"

  # Mirror into DietPi's own file so its tooling agrees with reality.
  if [ -n "$DIETPI_WIFI" ]; then
    sed -i "s|^aWIFI_SSID\[0\]=.*|aWIFI_SSID[0]='${ssid}'|" "$DIETPI_WIFI" 2>/dev/null
    sed -i "s|^aWIFI_KEY\[0\]=.*|aWIFI_KEY[0]='${psk}'|" "$DIETPI_WIFI" 2>/dev/null
    chmod 600 "$DIETPI_WIFI" 2>/dev/null
    echo "Mirrored into ${DIETPI_WIFI}."
  fi

  echo "Applying..."
  wpa_cli -i "$IFACE" reconfigure >/dev/null 2>&1 ||
    systemctl restart "wpa_supplicant@${IFACE}" 2>/dev/null ||
    ifup "$IFACE" 2>/dev/null
  sleep 6
  if [ -n "$(current_ssid)" ]; then
    echo "Connected to '$(current_ssid)' — address $(current_ip)"
  else
    echo "Not associated yet. Give it a few seconds, then check option 1."
    echo "Wrong passphrase is the usual cause; 'journalctl -u wpa_supplicant' has detail."
  fi
}

banner() {
  clear 2>/dev/null || printf '\n\n'   # tolerate no TERM (piped/non-tty use)
  local radio ifs ssid ip sig
  radio=$(radio_disabled && echo "DISABLED in config.txt" || echo "enabled")
  ifs=$(iface_exists && echo "${IFACE} present" || echo "no ${IFACE} (needs reboot after enabling)")
  ssid=$(current_ssid); ip=$(current_ip); sig=$(current_signal)
  cat <<EOF
========================================
   Commander X16 — Wi-Fi
========================================
  Radio      : ${radio}
  Interface  : ${ifs}
  Network    : ${ssid:-<not connected>}
  Address    : ${ip:-<none>}
  Signal     : ${sig:-<n/a>}
  Ethernet   : $(ip -4 -brief addr show eth0 2>/dev/null | awk '{print $3}' || echo "<none>")
----------------------------------------
  1) Refresh status
  2) Enable Wi-Fi radio     (needs reboot)
  3) Disable Wi-Fi radio    (needs reboot)
  4) Scan for networks
  5) Join a network
  6) Reboot now
  q) Quit
========================================
EOF
}

while true; do
  banner
  printf "select> "
  read -r choice || break
  case "$choice" in
    1) ;;
    2) enable_radio; printf "\npress enter> "; read -r _ ;;
    3) disable_radio; printf "\npress enter> "; read -r _ ;;
    4) scan_networks; printf "\npress enter> "; read -r _ ;;
    5) join_network; printf "\npress enter> "; read -r _ ;;
    6) echo "Rebooting..."; systemctl reboot; exit 0 ;;
    q|Q) exit 0 ;;
    *) ;;
  esac
done
