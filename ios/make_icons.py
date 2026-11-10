#!/usr/bin/env python3
"""Generate the app icons for ImGuiOverlayIOS.

Pure stdlib PNG writer: iOS refuses icons with an alpha channel, so every file
is RGB (color type 2), 8-bit, no transparency. Run once and commit the PNGs;
no Pillow / ImageMagick needed on the CI runner.

    python3 make_icons.py
"""
import os
import struct
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "icons")
os.makedirs(OUT, exist_ok=True)

BG = (16, 20, 28)
CYAN = (55, 198, 244)
ORANGE = (255, 138, 61)
DIM = (46, 58, 74)


def make(size):
    """Draw a simple 'overlay frame + HUD bars' icon at an arbitrary size."""
    s = size / 1024.0
    rows = []
    for y in range(size):
        row = bytearray()
        for x in range(size):
            c = BG

            # Outer rounded-ish frame (a HUD/overlay window).
            ix, iy = 140 * s, 140 * s
            ox, oy = size - 140 * s, size - 140 * s
            t = 34 * s
            if ix <= x <= ox and iy <= y <= oy:
                # chamfer corners
                corner = 90 * s
                dx = min(x - ix, ox - x)
                dy = min(y - iy, oy - y)
                chamfered = dx < corner and dy < corner and (corner - dx) + (corner - dy) > corner
                if not chamfered and (x - ix < t or ox - x < t or y - iy < t or oy - y < t):
                    c = CYAN

            # Title bar of the fake window.
            if 210 * s <= y <= 330 * s and 230 * s <= x <= size - 230 * s:
                c = DIM
            if 250 * s <= y <= 290 * s and 265 * s <= x <= 620 * s:
                c = CYAN

            # Three HUD rows: a coloured chip and a light-grey bar.
            for i, frac in enumerate((0.0, 0.19, 0.38)):
                top = (410 + frac * 1024) * s
                if top <= y <= top + 74 * s and 265 * s <= x <= size - 265 * s:
                    c = DIM
                if top + 12 * s <= y <= top + 62 * s and 265 * s <= x <= 355 * s:
                    c = ORANGE if i == 1 else CYAN
                if top + 26 * s <= y <= top + 48 * s and 400 * s <= x <= (760 - i * 110) * s:
                    c = (150, 168, 190)

            row += bytes(c)
        rows.append(b"\x00" + bytes(row))
    return b"".join(rows)


def chunk(tag, data):
    return (struct.pack(">I", len(data)) + tag + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))


def write_png(path, size):
    raw = make(size)
    ihdr = struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", ihdr)
           + chunk(b"IDAT", zlib.compress(raw, 9))
           + chunk(b"IEND", b""))
    with open(path, "wb") as f:
        f.write(png)
    print(f"{path}: {size}x{size}, {len(png)} bytes, RGB (no alpha)")


if __name__ == "__main__":
    write_png(os.path.join(OUT, "Icon-1024.png"), 1024)
    write_png(os.path.join(OUT, "Icon-60@3x.png"), 180)
    write_png(os.path.join(OUT, "Icon-60@2x.png"), 120)
