"""Render upscaled contact sheets so generated pixel art can be eyeballed.

Nothing here ships: it exists so a human (or an agent reading the PNG) can
verify that the procedural art is actually legible, which a byte-size number
can never tell you.

Run:  python tools/preview.py
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from gen_common import Canvas, ensure_dir, read_png_rgba, write_png  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "_check")


def upscale(src, scale, bg):
    dst = Canvas(src.w * scale, src.h * scale, bg)
    for y in range(src.h):
        for x in range(src.w):
            c = src.get(x, y)
            if c[3] == 0:
                c = bg
            for dy in range(scale):
                for dx in range(scale):
                    dst.set(x * scale + dx, y * scale + dy, c)
    return dst


def crop(atlas, col, row, fw, fh):
    c = Canvas(fw, fh)
    for y in range(fh):
        for x in range(fw):
            c.set(x, y, atlas.get(col * fw + x, row * fh + y))
    return c


def sheet_from_rows(atlas, fw, fh, rows, cols, scale, bg):
    """rows/cols describe the sub-grid to pull out of the atlas."""
    sheet = Canvas(fw * cols, fh * len(rows))
    for ri, row in enumerate(rows):
        for ci in range(cols):
            sheet.blit(crop(atlas, ci, row, fw, fh), ci * fw, ri * fh)
    return upscale(sheet, scale, bg)


def main():
    ensure_dir(OUT)
    bg = (18, 18, 22, 255)

    # --- fighter: every facing of idle + run, plus all anims facing East ------
    atlas = read_png_rgba(os.path.join(ROOT, "assets", "sprites",
                                       "fighter_cyan.png"))
    rows = list(range(0, 8)) + list(range(8, 16))
    s = sheet_from_rows(atlas, 24, 24, rows, 6, 4, bg)
    write_png(os.path.join(OUT, "preview_fighter_facing.png"), s)

    anim_rows = {"idle": 0, "run": 8, "melee": 16, "gun_idle": 24,
                 "gun_fire": 32, "roll": 40, "hook": 48, "hurt": 56, "dead": 64}
    sheet = Canvas(24 * 6, 24 * len(anim_rows))
    for ri, (name, base) in enumerate(anim_rows.items()):
        for ci in range(6):
            sheet.blit(crop(atlas, ci, base, 24, 24), ci * 24, ri * 24)
    s = upscale(sheet, 4, bg)
    write_png(os.path.join(OUT, "preview_fighter_anim.png"), s)

    # --- ember (bot team) ----------------------------------------------------
    e = read_png_rgba(os.path.join(ROOT, "assets", "sprites", "fighter_ember.png"))
    s = sheet_from_rows(e, 24, 24, list(range(0, 8)), 6, 4, bg)
    write_png(os.path.join(OUT, "preview_bot_facing.png"), s)

    # --- tiles --------------------------------------------------------------
    t = read_png_rgba(os.path.join(ROOT, "assets", "sprites", "tiles.png"))
    s = upscale(t, 12, bg)
    write_png(os.path.join(OUT, "preview_tiles.png"), s)

    # --- fx -----------------------------------------------------------------
    f = read_png_rgba(os.path.join(ROOT, "assets", "sprites", "fx.png"))
    s = upscale(f, 6, bg)
    write_png(os.path.join(OUT, "preview_fx.png"), s)


    # --- dedicated direction check: 8 facings, gun out, large ---------------
    for tag, path in (("cyan", "fighter_cyan.png"), ("ember", "fighter_ember.png")):
        a = read_png_rgba(os.path.join(ROOT, "assets", "sprites", path))
        big = Canvas(24 * 8, 24)
        for f in range(8):
            big.blit(crop(a, 0, 24 + f, 24, 24), f * 24, 0)
        s2 = upscale(big, 8, bg)
        write_png(os.path.join(OUT, "preview_dir_%s.png" % tag), s2)

    print("[preview] wrote contact sheets to _check/")


if __name__ == "__main__":
    main()
