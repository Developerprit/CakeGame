"""CakeGame bitmap font generator.

Builds a 5x7 hand-written pixel font and emits an AngelCode BMFont (`.fnt` text
+ PNG page), which Godot 4 imports natively as a `FontFile`.

Why hand-write the glyphs instead of thresholding a system TTF: rasterising an
antialiased outline font and then thresholding gives glyphs that are fuzzy,
uneven in weight, and different on every machine depending on which fonts are
installed. A hand-authored dot matrix is crisp, uniform, and reproducible.

CJK note: this atlas is ASCII only. Chinese text is rendered through a
`SystemFont` fallback configured at runtime in `PixelTheme`. Assigning
`fallbacks` REPLACES Godot's implicit chain, so it must be given a complete
CJK-capable list or Chinese turns into tofu boxes.

Run:  python tools/gen_font.py
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from gen_common import Canvas, LCG, ensure_dir, log, parse_hex, write_png  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FONT_DIR = os.path.join(ROOT, "assets", "fonts")

GW, GH = 5, 7          # glyph cell
PAD = 1                # 1px gutter prevents bleeding between glyphs
COLS = 16

FONT_NAME = "CakeGame Pixel"
FONT_SIZE = 8          # must equal the Theme's default_font_size
LINE_HEIGHT = 8
BASELINE = 7

G = {
    " ": "00000|00000|00000|00000|00000|00000|00000",
    "!": "00100|00100|00100|00100|00100|00000|00100",
    '"': "01010|01010|00000|00000|00000|00000|00000",
    "#": "01010|01010|11111|01010|11111|01010|01010",
    "$": "00100|01111|10100|01110|00101|11110|00100",
    "%": "11000|11001|00010|00100|01000|10011|00011",
    "&": "01100|10010|10100|01000|10101|10010|01101",
    "'": "00100|00100|00000|00000|00000|00000|00000",
    "(": "00010|00100|01000|01000|01000|00100|00010",
    ")": "01000|00100|00010|00010|00010|00100|01000",
    "*": "00000|00100|10101|01110|10101|00100|00000",
    "+": "00000|00100|00100|11111|00100|00100|00000",
    ",": "00000|00000|00000|00000|00110|00100|01000",
    "-": "00000|00000|00000|11111|00000|00000|00000",
    ".": "00000|00000|00000|00000|00000|00110|00110",
    "/": "00001|00010|00010|00100|01000|01000|10000",
    "0": "01110|10001|10011|10101|11001|10001|01110",
    "1": "00100|01100|00100|00100|00100|00100|01110",
    "2": "01110|10001|00001|00010|00100|01000|11111",
    "3": "11111|00010|00100|00010|00001|10001|01110",
    "4": "00010|00110|01010|10010|11111|00010|00010",
    "5": "11111|10000|11110|00001|00001|10001|01110",
    "6": "00110|01000|10000|11110|10001|10001|01110",
    "7": "11111|00001|00010|00100|01000|01000|01000",
    "8": "01110|10001|10001|01110|10001|10001|01110",
    "9": "01110|10001|10001|01111|00001|00010|01100",
    ":": "00000|00110|00110|00000|00110|00110|00000",
    ";": "00000|00110|00110|00000|00110|00100|01000",
    "<": "00010|00100|01000|10000|01000|00100|00010",
    "=": "00000|00000|11111|00000|11111|00000|00000",
    ">": "01000|00100|00010|00001|00010|00100|01000",
    "?": "01110|10001|00001|00010|00100|00000|00100",
    "@": "01110|10001|10111|10101|10111|10000|01110",
    "A": "01110|10001|10001|11111|10001|10001|10001",
    "B": "11110|10001|10001|11110|10001|10001|11110",
    "C": "01110|10001|10000|10000|10000|10001|01110",
    "D": "11100|10010|10001|10001|10001|10010|11100",
    "E": "11111|10000|10000|11110|10000|10000|11111",
    "F": "11111|10000|10000|11110|10000|10000|10000",
    "G": "01110|10001|10000|10111|10001|10001|01111",
    "H": "10001|10001|10001|11111|10001|10001|10001",
    "I": "01110|00100|00100|00100|00100|00100|01110",
    "J": "00111|00010|00010|00010|00010|10010|01100",
    "K": "10001|10010|10100|11000|10100|10010|10001",
    "L": "10000|10000|10000|10000|10000|10000|11111",
    "M": "10001|11011|10101|10101|10001|10001|10001",
    "N": "10001|10001|11001|10101|10011|10001|10001",
    "O": "01110|10001|10001|10001|10001|10001|01110",
    "P": "11110|10001|10001|11110|10000|10000|10000",
    "Q": "01110|10001|10001|10001|10101|10010|01101",
    "R": "11110|10001|10001|11110|10100|10010|10001",
    "S": "01111|10000|10000|01110|00001|00001|11110",
    "T": "11111|00100|00100|00100|00100|00100|00100",
    "U": "10001|10001|10001|10001|10001|10001|01110",
    "V": "10001|10001|10001|10001|10001|01010|00100",
    "W": "10001|10001|10001|10101|10101|11011|10001",
    "X": "10001|10001|01010|00100|01010|10001|10001",
    "Y": "10001|10001|01010|00100|00100|00100|00100",
    "Z": "11111|00001|00010|00100|01000|10000|11111",
    "[": "01110|01000|01000|01000|01000|01000|01110",
    "\\": "10000|01000|01000|00100|00010|00010|00001",
    "]": "01110|00010|00010|00010|00010|00010|01110",
    "^": "00100|01010|10001|00000|00000|00000|00000",
    "_": "00000|00000|00000|00000|00000|00000|11111",
    "`": "01000|00100|00000|00000|00000|00000|00000",
    "a": "00000|00000|01110|00001|01111|10001|01111",
    "b": "10000|10000|11110|10001|10001|10001|11110",
    "c": "00000|00000|01111|10000|10000|10000|01111",
    "d": "00001|00001|01111|10001|10001|10001|01111",
    "e": "00000|00000|01110|10001|11111|10000|01110",
    "f": "00110|01001|01000|11110|01000|01000|01000",
    "g": "00000|01111|10001|10001|01111|00001|01110",
    "h": "10000|10000|11110|10001|10001|10001|10001",
    "i": "00100|00000|01100|00100|00100|00100|01110",
    "j": "00010|00000|00110|00010|00010|10010|01100",
    "k": "10000|10000|10010|10100|11000|10100|10010",
    "l": "01100|00100|00100|00100|00100|00100|01110",
    "m": "00000|00000|11010|10101|10101|10101|10101",
    "n": "00000|00000|11110|10001|10001|10001|10001",
    "o": "00000|00000|01110|10001|10001|10001|01110",
    "p": "00000|11110|10001|10001|11110|10000|10000",
    "q": "00000|01111|10001|10001|01111|00001|00001",
    "r": "00000|00000|10110|11001|10000|10000|10000",
    "s": "00000|00000|01111|10000|01110|00001|11110",
    "t": "01000|01000|11110|01000|01000|01001|00110",
    "u": "00000|00000|10001|10001|10001|10011|01101",
    "v": "00000|00000|10001|10001|10001|01010|00100",
    "w": "00000|00000|10101|10101|10101|10101|01010",
    "x": "00000|00000|10001|01010|00100|01010|10001",
    "y": "00000|10001|10001|10001|01111|00001|01110",
    "z": "00000|00000|11111|00010|00100|01000|11111",
    "{": "00010|00100|00100|01000|00100|00100|00010",
    "|": "00100|00100|00100|00100|00100|00100|00100",
    "}": "01000|00100|00100|00010|00100|00100|01000",
    "~": "00000|00000|01000|10101|00010|00000|00000",
}

# In-game extras. Kept out of the ASCII range so they never collide with text.
EXTRA = {
    0x2190: "00000|00100|00010|11111|00010|00100|00000",   # left arrow
    0x2191: "00100|01110|10101|00100|00100|00100|00000",   # up arrow
    0x2192: "00000|00100|01000|11111|01000|00100|00000",   # right arrow
    0x2193: "00000|00100|00100|00100|10101|01110|00100",   # down arrow
    0x25B6: "01000|01100|01110|01111|01110|01100|01000",   # play
    0x25A0: "00000|11111|11111|11111|11111|11111|00000",   # block
    0x2022: "00000|00000|01110|01110|01110|00000|00000",   # bullet dot
}

# Per-glyph advance tweaks: narrow punctuation should not eat a full 5px cell.
NARROW = set("!.,;:'\"|`[]()")
WIDE_ADVANCE = {"m": 6, "w": 6, "M": 6, "W": 6}


def glyph_rows(bits):
    return bits.split("|")


def glyph_width(bits, ch):
    rows = glyph_rows(bits)
    if ch == " ":
        return 0
    last = 0
    for r in rows:
        for x in range(GW):
            if r[x] == "1":
                last = max(last, x + 1)
    if ch in NARROW:
        last = min(last, 3)
    return last


def main():
    print("=== CakeGame font generator ===")
    ensure_dir(os.path.join(FONT_DIR, "x"))

    codes = sorted([ord(c) for c in G.keys()] + list(EXTRA.keys()))
    allbits = dict(G)
    for cp, bits in EXTRA.items():
        allbits[chr(cp)] = bits

    # pack into a grid, one row per COLS glyphs
    rows = (len(codes) + COLS - 1) // COLS
    cell_w = GW + PAD
    cell_h = GH + PAD
    atlas = Canvas(COLS * cell_w, rows * cell_h)

    ink = (235, 244, 250, 255)
    records = []
    for i, cp in enumerate(codes):
        ch = chr(cp)
        bits = allbits[ch]
        col = i % COLS
        row = i // COLS
        gx = col * cell_w
        gy = row * cell_h
        for yy, r in enumerate(glyph_rows(bits)):
            for xx in range(GW):
                if r[xx] == "1":
                    atlas.set(gx + xx, gy + yy, ink)
        w = glyph_width(bits, ch)
        adv = w + 1
        if ch in WIDE_ADVANCE:
            adv = WIDE_ADVANCE[ch]
        if ch == " ":
            adv = 4
        records.append({
            "id": cp,
            "x": gx,
            "y": gy,
            "w": w,
            "h": GH,
            "xoff": 0,
            "yoff": BASELINE - GH,
            "adv": adv,
        })

    png_path = os.path.join(FONT_DIR, "pixel_font.png")
    write_png(png_path, atlas)

    lines = []
    lines.append('info face="%s" size=%d bold=0 italic=0 charset="" unicode=1 '
                 'stretchH=100 smooth=0 aa=1 padding=0,0,0,0 spacing=0,0 outline=0'
                 % (FONT_NAME, FONT_SIZE))
    lines.append('common lineHeight=%d base=%d scaleW=%d scaleH=%d pages=1 packed=0'
                 % (LINE_HEIGHT, BASELINE + 1, atlas.w, atlas.h))
    lines.append('page id=0 file="pixel_font.png"')
    lines.append("chars count=%d" % len(records))
    for r in records:
        lines.append(
            "char id=%d x=%d y=%d width=%d height=%d xoffset=%d yoffset=%d "
            "xadvance=%d page=0 chnl=15"
            % (r["id"], r["x"], r["y"], r["w"], r["h"], r["xoff"], r["yoff"], r["adv"])
        )
    lines.append("kernings count=0")

    fnt_path = os.path.join(FONT_DIR, "pixel_font.fnt")
    with open(fnt_path, "w", encoding="ascii", newline="\n") as f:
        f.write("\n".join(lines) + "\n")

    log("pixel_font.fnt  %d glyphs, atlas %dx%d" % (len(records), atlas.w, atlas.h))

    # A preview strip so the font can be eyeballed without launching Godot.
    preview = Canvas(atlas.w * 3, atlas.h * 3, parse_hex("#12141a"))
    for y in range(atlas.h):
        for x in range(atlas.w):
            c = atlas.get(x, y)
            if c[3] == 0:
                continue
            for dy in range(3):
                for dx in range(3):
                    preview.set(x * 3 + dx, y * 3 + dy, c)
    write_png(os.path.join(ROOT, "_check", "preview_font.png"), preview)
    print("=== done ===")


if __name__ == "__main__":
    main()
