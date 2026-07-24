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


def vgradient(w, h, top, bottom):
    """Vertical gradient background."""
    img = Image.new("RGB", (w, h))
    px = img.load()
    for y in range(h):
        t = y / max(1, h - 1)
        r = int(top[0] + (bottom[0] - top[0]) * t)
        g = int(top[1] + (bottom[1] - top[1]) * t)
        b = int(top[2] + (bottom[2] - top[2]) * t)
        for x in range(w):
            px[x, y] = (r, g, b)
    return img


def centered(draw, text, font, cx, y, fill):
    l, t, r, b = draw.textbbox((0, 0), text, font=font)
    draw.text((cx - (r - l) / 2, y), text, font=font, fill=fill)
    return b - t


def render(w, h):
    img = vgradient(w, h, (16, 22, 44), (5, 6, 14))   # navy -> near-black
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

    # Subtitle + footer
    centered(d, "Raspberry Pi Appliance", sub_f, cx, int(h * 0.57),
             (150, 170, 210))
    centered(d, "starting\u2026", foot_f, cx, int(h * 0.88), (110, 130, 170))

    return img


def to_rgb565(img, bgr=False):
    """Pack an RGB image into little-endian RGB565 (or BGR565) bytes."""
    out = bytearray()
    for (r, g, b) in img.getdata():
        if bgr:
            r, b = b, r
        v = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
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
