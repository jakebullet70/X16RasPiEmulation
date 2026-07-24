#!/bin/bash
#
# setup-samba.sh — share the X16 -fsroot (/boot/x16) over the network so you can
# drag-drop .PRG/.BAS files from a Windows/macOS/Linux file manager.
#
# WHY: /boot/x16 is on the ext4 ROOT partition (not the FAT boot partition), so it
# is NOT reachable by popping the SD card into a PC. Samba exposes it on the LAN.
#
# Run as root on the Pi. AUTHENTICATED share (login x16 / dietpi) — Windows 10/11
# Pro DISABLE guest SMB by default, so guest shares just prompt-and-deny; and
# Samba treats 'root' specially, so DON'T use root. A dedicated 'x16' user is the
# reliable cross-Windows answer. Share appears as \\<pi-ip-or-hostname>\X16.
#
set -e
export DEBIAN_FRONTEND=noninteractive
SMB_USER="${SMB_USER:-x16}"
SMB_PASS="${SMB_PASS:-dietpi}"
apt-get update -qq >/dev/null 2>&1 || true
apt-get install -y -qq samba >/dev/null 2>&1

SMB=/etc/samba/smb.conf
cp "$SMB" "${SMB}.bak-x16" 2>/dev/null || true

# Dedicated Samba user (system account, no shell), with a Samba password.
id "$SMB_USER" >/dev/null 2>&1 || useradd -M -s /usr/sbin/nologin "$SMB_USER"
(echo "$SMB_PASS"; echo "$SMB_PASS") | smbpasswd -s -a "$SMB_USER" >/dev/null 2>&1
smbpasswd -e "$SMB_USER" >/dev/null 2>&1 || true

# Disable the default per-user [homes] share (not wanted on an appliance).
sed -i 's/^\[homes\]/#[homes]/' "$SMB" 2>/dev/null || true

if ! grep -q '^\[X16\]' "$SMB"; then
cat >> "$SMB" <<EOF

[X16]
   comment = Commander X16 SD-card files (drop .PRG/.BAS here)
   path = /boot/x16
   browseable = yes
   read only = no
   guest ok = no
   valid users = ${SMB_USER}
   force user = root
   create mask = 0644
   directory mask = 0755
EOF
fi

testparm -s >/dev/null 2>&1 && echo "smb.conf OK"
systemctl enable --now smbd
systemctl restart smbd
echo "Share ready:  \\\\<pi-ip-or-hostname>\\X16   (login: ${SMB_USER} / ${SMB_PASS})"
