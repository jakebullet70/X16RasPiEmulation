#!/usr/bin/env python3
"""
gen_splash.py — render the X16 appliance boot splash to a raw framebuffer blob.

The Pi's KMS console framebuffer (/dev/fb0) is RGB565, 1920x1080, stride 3840
(16bpp, no line padding). The appliance shows the splash by simply writing this
raw blob straight to /dev/fb0 (persists as a static image, no viewer process
needed) — see scripts/x16-splash.sh and the x16-splash systemd service.

Outputs:
  splash.png                       — human preview (RGB)
  x16-splash-1920x1080-rgb565.raw  — the exact bytes cat'd to /dev/fb0

Regenerate:  python gen_splash.py
Custom size/order:  python gen_splash.py --width 1280 --height 720 [--bgr]

RGB565 packing (little-endian): (R>>3)<<11 | (G>>2)<<5 | (B>>3).
If red/blue look swapped on the real panel, pass --bgr (some fbdevs are BGR565).
"""
import argparse
import struct

from PIL import Image, ImageDraw, ImageFont

# Candidate bold fonts (first that exists wins). Windows + common Linux paths.
FONT_CANDIDATES = [
    r"C:\Windows\Fonts\arialbd.ttf",
    r"C:\Windows\Fonts\segoeuib.ttf",
    r"C:\Windows\Fonts\consolab.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
]


def load_font(size):
    for path in FONT_CANDIDATES:
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            continue
    return ImageFont.load_default()


# The Commander X16's own blue: VERA default palette entry 6 is 0x00a in 12-bit
# RGB444, i.e. #0000AA (the C64 blue the X16 inherits) — taken from
# default_palette[] in the r49 emulator's src/video.c.
#
# Snapped to #0000A8 because that is what RGB565 can actually represent: blue
# gets 5 bits, so 0xAA (170) rounds to 21 << 3 = 168. Using the exact
# representable value means the flat background quantises with ZERO error, so
# the dither in to_rgb565() adds no noise to it. Feeding 0xAA instead would
# leave a half-step of error and dither it into a faint checkerboard across the
# whole screen.
X16_BLUE = (0x00, 0x00, 0xA8)


def solid(w, h, color):
    """Flat background — no gradient.

    A gradient is what produced the banded 'rainbow stripes' on the real panel:
    RGB565 simply has too few levels for a dark, low-contrast fade (see the note
    in to_rgb565). A flat colour cannot band, by construction.
    """
    return Image.new("RGB", (w, h), color)


def centered(draw, text, font, cx, y, fill):
    l, t, r, b = draw.textbbox((0, 0), text, font=font)
    draw.text((cx - (r - l) / 2, y), text, font=font, fill=fill)
    return b - t


def render(w, h):
    img = solid(w, h, X16_BLUE)                       # the X16's own blue
    d = ImageDraw.Draw(img)
    cx = w // 2

    title_f = load_font(int(h * 0.13))
    sub_f = load_font(int(h * 0.045))
    foot_f = load_font(int(h * 0.032))

    # Title
    ty = int(h * 0.34)
    centered(d, "COMMANDER X16", title_f, cx, ty, (232, 240, 255))

    # Accent underline (amber). Swap here if you want a different brand color.
    aw = int(w * 0.34)
    ay = int(h * 0.52)
    d.rectangle([cx - aw // 2, ay, cx + aw // 2, ay + max(3, h // 240)],
                fill=(255, 176, 32))

    # Subtitle + footer. The X16's light blue (VERA palette 14 = 0x08f), snapped
    # to an RGB565-representable value. The previous grey-blues were chosen for a
    # near-black background and wash out badly against X16_BLUE.
    centered(d, "Raspberry Pi Appliance", sub_f, cx, int(h * 0.57),
             (0x00, 0x88, 0xF8))
    centered(d, "starting\u2026", foot_f, cx, int(h * 0.88), (0x00, 0x88, 0xF8))

    return img


# 8x8 Bayer matrix, values 0..63. Used for ordered dithering (see to_rgb565).
BAYER8 = [
    [0, 32, 8, 40, 2, 34, 10, 42],
    [48, 16, 56, 24, 50, 18, 58, 26],
    [12, 44, 4, 36, 14, 46, 6, 38],
    [60, 28, 52, 20, 62, 30, 54, 22],
    [3, 35, 11, 43, 1, 33, 9, 41],
    [51, 19, 59, 27, 49, 17, 57, 25],
    [15, 47, 7, 39, 13, 45, 5, 37],
    [63, 31, 55, 23, 61, 29, 53, 21],
]


def to_rgb565(img, bgr=False, dither=True):
    """Pack an RGB image into little-endian RGB565 (or BGR565) bytes.

    Ordered (Bayer) dithering is on by default and matters a lot here. RGB565
    gives red/blue only 32 levels and green 64, so a dark low-contrast gradient
    like this splash collapses to a handful of flat bands — measured on the
    undithered blob: 11 unique values over 1080 rows. Worse, the three channels
    cross their quantisation thresholds at DIFFERENT rows, so each band shifts
    hue slightly and the result reads as coloured stripes rather than a smooth
    fade. Observed on real hardware 2026-07-25; the 24-bit PNG preview looks
    perfect, so this only ever shows up on the Pi.

    Dithering spreads each pixel's rounding error over an 8x8 cell, trading a
    little high-frequency noise (invisible at normal viewing distance) for a
    gradient that stays smooth.
    """
    out = bytearray()
    w, _h = img.size
    for i, (r, g, b) in enumerate(img.getdata()):
        if bgr:
            r, b = b, r
        if dither:
            # Offset in [0,1) of a quantisation step, then floor — NOT a
            # centred [-0.5,0.5) offset. With a centred offset an exactly
            # representable value (a multiple of its step) gets pushed DOWN a
            # level by every negative threshold, so even a flat colour picks up
            # a checkerboard. floor(v/step + [0,1)) leaves exact values alone
            # and dithers only the genuine residual.
            t = BAYER8[(i // w) & 7][(i % w) & 7] / 64.0
            r5 = min(31, int(r / 8.0 + t))
            g6 = min(63, int(g / 4.0 + t))
            b5 = min(31, int(b / 8.0 + t))
        else:
            r5, g6, b5 = r >> 3, g >> 2, b >> 3
        v = (r5 << 11) | (g6 << 5) | b5
        out += struct.pack("<H", v)
    return bytes(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--width", type=int, default=1920)
    ap.add_argument("--height", type=int, default=1080)
    ap.add_argument("--bgr", action="store_true", help="pack BGR565 (if R/B swapped)")
    ap.add_argument("--png", default="splash.png")
    ap.add_argument("--raw", default=None)
    args = ap.parse_args()

    img = render(args.width, args.height)
    img.save(args.png)
    raw = args.raw or f"x16-splash-{args.width}x{args.height}-rgb565.raw"
    with open(raw, "wb") as f:
        f.write(to_rgb565(img, args.bgr))
    print(f"wrote {args.png} and {raw} "
          f"({args.width}x{args.height}, {'BGR565' if args.bgr else 'RGB565'}, "
          f"{args.width * args.height * 2} bytes)")


if __name__ == "__main__":
    main()
