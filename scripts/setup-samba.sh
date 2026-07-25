#!/bin/bash
#
# setup-samba.sh — share the X16 -fsroot over the network so you can drag-drop
# .PRG/.BAS files from a Windows/macOS/Linux file manager.
#
# WHY: the fsroot lives on the FAT boot partition, so the SD card already works as
# a drop zone in any PC — but that means powering the appliance down and pulling
# the card. This share is the convenient alternative: add programs over the LAN
# while the X16 is running (restart the emulator to see them).
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

# Share whatever the emulator actually uses as -fsroot (same probe as the other
# scripts): the FAT boot partition, Bookworm at /boot/firmware, older at /boot.
boot_fat() {
  for d in /boot/firmware /boot; do
    case "$(stat -f -c %T "$d" 2>/dev/null)" in
      msdos|vfat|exfat) printf '%s\n' "$d"; return 0 ;;
    esac
  done
  printf '%s\n' /boot
}
SHARE_PATH="${X16_FSROOT:-$(boot_fat)/x16}"
mkdir -p "$SHARE_PATH"
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
   path = ${SHARE_PATH}
   browseable = yes
   read only = no
   guest ok = no
   valid users = ${SMB_USER}
   force user = root
   create mask = 0644
   directory mask = 0755
EOF
else
  # Re-running after the fsroot moved onto the FAT partition: repoint the share.
  sed -i "/^\[X16\]/,/^\[/ s|^   path = .*|   path = ${SHARE_PATH}|" "$SMB"
fi

testparm -s >/dev/null 2>&1 && echo "smb.conf OK"
systemctl enable --now smbd
systemctl restart smbd
echo "Share ready:  \\\\<pi-ip-or-hostname>\\X16  ->  ${SHARE_PATH}   (login: ${SMB_USER} / ${SMB_PASS})"
