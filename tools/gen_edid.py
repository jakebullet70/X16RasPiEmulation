#!/usr/bin/env python3
"""
gen_edid.py — generate a forced 1080p60 CEA EDID for the X16 appliance.

WHY THIS EXISTS (the "black screen" saga, real Pi 4, 2026-07-23):
  Many TVs only sync CEA/HDMI timings and refuse VESA/DMT ones. The Commander
  X16 outputs 640x480 (VGA/DMT), which those TVs show as BLACK even though the
  connector reports "connected". The fix is to feed the Pi a synthetic EDID that
  advertises ONLY 1920x1080@60 (CEA VIC 16) — no 640x480 anywhere — so the KMS
  connector offers just the one mode the TV is guaranteed to display, and SDL
  scales the X16 picture into it.

  Bonus: forcing the EDID also removes the cold-boot race where the connector
  waited ~15 min on a slow TV EDID read (the "card1 appears at 926s" delay) —
  with a firmware EDID the connector comes up instantly.

WHAT IT EMITS:
  A 256-byte EDID = 128-byte EDID 1.4 base block + 128-byte CEA-861 extension.
    * Established-timings bytes zeroed  -> no 640x480@60 advertised
    * Standard-timing slots unused
    * One 148.5 MHz 1920x1080@60 detailed timing (base block + CEA DTD)
    * CEA Video Data Block listing VIC 16 (1080p60) as the native format
  Both mandatory checksums are computed.

USAGE:
  python3 gen_edid.py            # writes x16-1080p.edid next to this script
  python3 gen_edid.py OUT.edid   # write to a chosen path

DEPLOY ON THE PI (persist the forced EDID across reboots):
  1. Copy the file to the kernel firmware EDID dir:
       sudo install -D -m 0644 x16-1080p.edid /lib/firmware/edid/x16-1080p.edid
  2. Point the DRM helper at it via cmdline.txt (single line, append token):
       drm_kms_helper.edid_firmware=HDMI-A-1:edid/x16-1080p.edid
     (connector name is usually HDMI-A-1 on Pi4; confirm with
      `ls /sys/class/drm/`. Use HDMI-A-2 for the 2nd Pi4 port.)
  3. Keep a copy in /opt/x16 as a backup / for the runtime debugfs override.
  4. reboot; verify only 1080p is offered:
       cat /sys/class/drm/card1-HDMI-A-1/modes    # should list ONLY 1920x1080
"""
import sys

# --- 148.5 MHz 1920x1080@60 detailed timing descriptor (18 bytes) ---
# pixclock 14850 (x10kHz) LE; H/V active+blank; porches; sync; image size; flags
# flags 0x1E = digital separate sync, HSYNC+ VSYNC+ (standard for CEA 1080p).
DTD_1080P = bytes([
    0x02, 0x3A, 0x80, 0x18, 0x71, 0x38, 0x2D, 0x40, 0x58,
    0x2C, 0x45, 0x00, 0x40, 0x84, 0x63, 0x00, 0x00, 0x1E,
])

# --- 74.25 MHz 1280x720@60 detailed timing descriptor (CEA VIC 4) ---
DTD_720P = bytes([
    0x01, 0x1D, 0x00, 0x72, 0x51, 0xD0, 0x1E, 0x20, 0x6E,
    0x28, 0x55, 0x00, 0x40, 0x84, 0x63, 0x00, 0x00, 0x1E,
])

# Per-mode parameters: detailed timing + CEA VIC.
MODES = {
    "1080p": {"dtd": DTD_1080P, "vic": 16, "name": "X16-1080p"},
    "720p":  {"dtd": DTD_720P,  "vic": 4,  "name": "X16-720p"},
}

# --- CEA Short Audio Descriptor: LPCM, 2ch, 32/44.1/48 kHz, 16-bit ---------
# WITHOUT this, the sink's ELD is empty and vc4-hdmi refuses to open the audio
# device (ALSA "Couldn't open audio device: Unknown error 524" = ENOTSUPP).
# byte0 = (format<<3)|(channels-1): LPCM(1), 2ch -> 0x09
# byte1 = sample-rate bitmask: 32k|44.1k|48k -> 0x07
# byte2 = LPCM bit depths: 16-bit -> 0x01
SAD_LPCM_2CH = bytes([0x09, 0x07, 0x01])


def checksum(block128):
    """Return the byte that makes the 128-byte block sum to 0 mod 256."""
    return (256 - (sum(block128) % 256)) % 256


def descriptor_name(text):
    """0xFC monitor-name descriptor, text padded to 13 bytes (0x0A + spaces)."""
    raw = text.encode("ascii")[:13]
    raw = raw + b"\x0a" + b"\x20" * (13 - len(raw) - 1) if len(raw) < 13 else raw
    return bytes([0x00, 0x00, 0x00, 0xFC, 0x00]) + raw


def descriptor_range():
    """0xFD monitor-range-limits: V 50-60Hz, H 30-80kHz, max 150MHz pixel clock."""
    return bytes([0x00, 0x00, 0x00, 0xFD, 0x00,
                  50, 60, 30, 80, 15, 0x00,
                  0x0A, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20])


def descriptor_dummy():
    return bytes([0x00, 0x00, 0x00, 0x10, 0x00] + [0x00] * 13)


def base_block(mode):
    m = MODES[mode]
    b = bytearray()
    b += bytes([0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00])  # header
    b += bytes([0x31, 0xD8])            # mfr id "LNX"
    b += bytes([0x01, 0x00])            # product code
    b += bytes([0x00, 0x00, 0x00, 0x00])  # serial
    b += bytes([0x01, 33])              # week 1, year 2023 (1990+33)
    b += bytes([0x01, 0x04])            # EDID 1.4
    b += bytes([0x80])                  # digital input
    b += bytes([16, 9])                 # screen size 16x9 cm-ish
    b += bytes([0x78])                  # gamma 2.2
    b += bytes([0x02])                  # features: preferred timing is native
    # chromaticity (sRGB-ish; irrelevant to mode acceptance)
    b += bytes([0xEE, 0x91, 0xA3, 0x54, 0x4C, 0x99, 0x26, 0x0F, 0x50, 0x54])
    b += bytes([0x00, 0x00, 0x00])      # established timings — NONE (no 640x480!)
    b += bytes([0x01, 0x01] * 8)        # standard timings — all unused
    # four 18-byte descriptors
    b += m["dtd"]
    b += descriptor_name(m["name"])
    b += descriptor_range()
    b += descriptor_dummy()
    b += bytes([0x01])                  # one extension block follows
    assert len(b) == 127, len(b)
    b.append(checksum(b))
    return bytes(b)


def cea_extension(mode):
    m = MODES[mode]
    b = bytearray()
    # Data block collection: Video Data Block then Audio Data Block.
    # VDB: tag 2, length 1; the mode's VIC with the native bit set (0x80).
    vdb = bytes([(2 << 5) | 1, m["vic"] | 0x80])
    # ADB: tag 1, length 3; one LPCM Short Audio Descriptor (fills the ELD so
    # vc4-hdmi will actually open the audio device).
    adb = bytes([(1 << 5) | len(SAD_LPCM_2CH)]) + SAD_LPCM_2CH
    collection = vdb + adb
    dtd_offset = 4 + len(collection)    # header(4) + data block collection
    b += bytes([0x02, 0x03, dtd_offset, 0x41])  # tag, rev3, d, basic-audio+1 DTD
    b += collection
    b += m["dtd"]
    b += bytes([0x00] * (127 - len(b)))  # pad to 127
    b.append(checksum(b))
    return bytes(b)


def build(mode):
    edid = base_block(mode) + cea_extension(mode)
    assert len(edid) == 256, len(edid)
    return edid


def write_edid(out, mode):
    edid = build(mode)
    with open(out, "wb") as f:
        f.write(edid)
    print(f"wrote {out} ({len(edid)} bytes, {mode}) "
          f"base_ok={sum(edid[:128]) % 256 == 0} cea_ok={sum(edid[128:]) % 256 == 0}")


def main():
    # gen_edid.py                       -> both x16-1080p.edid and x16-720p.edid
    # gen_edid.py OUT.edid [1080p|720p] -> a single file (mode defaults to 1080p)
    if len(sys.argv) > 1:
        out = sys.argv[1]
        mode = sys.argv[2] if len(sys.argv) > 2 else "1080p"
        write_edid(out, mode)
    else:
        write_edid("x16-1080p.edid", "1080p")
        write_edid("x16-720p.edid", "720p")


if __name__ == "__main__":
    main()
