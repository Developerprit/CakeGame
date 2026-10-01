"""CakeGame application icon generator.

Draws the icon ONCE at 16x16 and produces every ICO entry by nearest-neighbour
integer upscaling. That is deliberate: drawing each size independently with
smooth primitives would produce six subtly different artworks, whereas pixel art
must scale by whole multiples or it stops being pixel art.

Godot only accepts `.ico` for the export icon (not .svg or .png), and the file
version fields in `export_presets.cfg` must be four-part, so this pairs with
`icon.ico` + `application/file_version="1.0.0.0"`.

Run:  python tools/gen_ico.py
"""

import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from gen_common import Canvas, ensure_dir, log, parse_hex, write_png  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICON_DIR = os.path.join(ROOT, "assets")
BASE = 16
SIZES = [16, 24, 32, 48, 64, 128, 256]


def tri_fill(cv, apex, left, right, bands, outline):
    """Scanline-fill a triangle, colouring each row from a band table.

    `bands` is a list of (y_from, y_to, color) applied in order, so later bands
    overwrite earlier ones and the last one wins where they overlap.
    """
    ay, ax = apex[1], apex[0]
    ly, lx = left[1], left[0]
    ry, rx = right[1], right[0]
    y0 = int(min(ay, ly, ry))
    y1 = int(max(ay, ly, ry))
    for y in range(y0, y1 + 1):
        # interpolate along both edges
        if ay == ly:
            xl = min(ax, lx)
        else:
            t = (y - ay) / float(ly - ay)
            xl = ax + (lx - ax) * t
        if ay == ry:
            xr = max(ax, rx)
        else:
            t = (y - ay) / float(ry - ay)
            xr = ax + (rx - ax) * t
        if xl > xr:
            xl, xr = xr, xl
        xi0 = int(round(xl))
        xi1 = int(round(xr))
        col = parse_hex("#d8a15f")
        for (bf, bt, bc) in bands:
            if bf <= y <= bt:
                col = parse_hex(bc)
        for x in range(xi0, xi1 + 1):
            cv.set(x, y, col)
    cv.outline_solid(parse_hex(outline))


def draw_icon():
    cv = Canvas(BASE, BASE)

    # background plate
    bg = parse_hex("#171a21")
    cv.fill_all(bg)
    # subtle top-lighter gradient so the icon is not a flat dark square
    for y in range(BASE):
        k = parse_hex("#171a21")
        c = (min(255, k[0] + 10 - y), min(255, k[1] + 11 - y), min(255, k[2] + 14 - y), 255)
        for x in range(BASE):
            cv.set(x, y, c)
    # 1px frame in the human team colour ties the icon to the game's palette
    frame = parse_hex("#4fd6f0")
    cv.frame_rect(0, 0, BASE, BASE, frame)
    for x in range(1, BASE - 1):
        cv.blend(x, 1, parse_hex("#2b6d80"))
        cv.blend(x, BASE - 2, parse_hex("#2b6d80"))

    # plate / shadow under the slice
    cv.ellipse(8.0, 13.2, 6.0, 1.7, 0.0, parse_hex("#0b0d12"))

    # the slice itself
    tri_fill(
        cv,
        apex=(8.0, 4.5),
        left=(3.5, 13.0),
        right=(12.5, 13.0),
        bands=[
            (4, 6, "#fff3e2"),     # frosting tip
            (7, 8, "#e8b877"),     # sponge
            (9, 9, "#cf4a63"),     # jam layer
            (10, 12, "#d09a58"),   # sponge
            (13, 13, "#a9713a"),   # base crust
        ],
        outline="#080a0e",
    )

    # frosting drip detail on the top layer
    cv.set(7, 7, parse_hex("#fff3e2"))
    cv.set(9, 7, parse_hex("#fff3e2"))

    # cherry. Drawn as explicit pixels rather than a circle: at r=1.5 the
    # implicit-equation circle resolves to a plain 3x3 square, which reads as a
    # red box. A hand-placed diamond reads as round at this size.
    cherry = parse_hex("#e8485f")
    cherry_dark = parse_hex("#c93a52")
    cv.set(8, 2, cherry_dark)
    cv.set(7, 3, cherry)
    cv.set(8, 3, cherry)
    cv.set(9, 3, cherry)
    cv.set(7, 4, cherry_dark)
    cv.set(8, 4, cherry)
    cv.set(9, 4, cherry_dark)
    cv.set(7, 3, parse_hex("#ffd9e0"))   # specular highlight

    # Side reticle ticks only. Placing them on all four edges put two of them
    # straight through the cake, which read as noise; left/right alone still
    # says "shooter" and stays clear of the artwork.
    tick = parse_hex("#7de3f8")
    for i in range(2):
        cv.blend(1 + i, 8, tick)
        cv.blend(BASE - 2 - i, 8, tick)

    return cv


def upscale_nearest(src, size):
    k = size // src.w
    dst = Canvas(size, size)
    for y in range(size):
        for x in range(size):
            dst.set(x, y, src.get(min(src.w - 1, x // k), min(src.h - 1, y // k)))
    return dst


def png_bytes(canvas):
    """Encode a canvas to PNG bytes in memory (mirrors gen_common.write_png)."""
    import zlib
    w, h = canvas.w, canvas.h
    rows = []
    for y in range(h):
        row = bytearray()
        base = y * w
        for x in range(w):
            r, g, b, a = canvas.px[base + x]
            row += bytes((r, g, b, a))
        rows.append(bytes(row))
    raw = b"".join(b"\x00" + r for r in rows)

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    out = b"\x89PNG\r\n\x1a\n"
    out += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
    out += chunk(b"IDAT", zlib.compress(raw, 9))
    out += chunk(b"IEND", b"")
    return out


def write_ico(path, entries):
    """entries: list of (size, png_bytes). 256 is encoded as 0 in the header."""
    n = len(entries)
    header = struct.pack("<HHH", 0, 1, n)
    offset = 6 + 16 * n
    dir_entries = b""
    blobs = b""
    for size, data in entries:
        w = 0 if size >= 256 else size
        h = 0 if size >= 256 else size
        dir_entries += struct.pack("<BBBBHHII", w, h, 0, 0, 1, 32, len(data), offset)
        offset += len(data)
        blobs += data
    ensure_dir(path)
    with open(path, "wb") as f:
        f.write(header + dir_entries + blobs)
    return 6 + 16 * n + len(blobs)


def main():
    print("=== CakeGame icon generator ===")
    base = draw_icon()
    entries = []
    for s in SIZES:
        img = base if s == BASE else upscale_nearest(base, s)
        entries.append((s, png_bytes(img)))
    size = write_ico(os.path.join(ICON_DIR, "icon.ico"), entries)
    log("icon.ico  %d sizes (%s)  %.1f KB"
        % (len(entries), ", ".join(str(s) for s in SIZES), size / 1024.0))

    # also drop a png for the landing page / README
    write_png(os.path.join(ICON_DIR, "icon_preview_256.png"),
              upscale_nearest(base, 256))
    write_png(os.path.join(ROOT, "_check", "preview_icon.png"),
              upscale_nearest(base, 256))
    print("=== done ===")


if __name__ == "__main__":
    main()
