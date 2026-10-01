"""CakeGame sprite generator.

Produces, deterministically and with zero third-party dependencies:

  assets/sprites/fighter_cyan.png    human-team character atlas (8 facings x 9 anims)
  assets/sprites/fighter_ember.png   bot-team character atlas
  assets/sprites/tiles.png           terrain + prop tiles (16x16)
  assets/sprites/fx.png              bullets, muzzle flashes, impacts, hook, rings
  assets/source_svg/*.svg            editable vector sources (repo-only)
  src/data/sprite_manifest.json      atlas layout consumed by AtlasLibrary.gd

Art direction: **directly-overhead** pixel art. The body is drawn as seen from
above and the whole figure rotates with the aim direction. That is the only
style in which "the character always faces the mouse" actually reads, and it
makes facing legible to the opponent - which the AI depends on, since reading
your muzzle direction is exactly how a bot dodges a shot you have not fired yet.

Run:  python tools/gen_sprites.py
"""

import json
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from gen_common import (  # noqa: E402
    Atlas,
    Canvas,
    LCG,
    canvas_to_svg,
    ensure_dir,
    hex_at,  # noqa: F401  (re-exported convenience)
    log,
    parse_hex,
    shade,
    with_alpha,
    write_png,
)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SPRITE_DIR = os.path.join(ROOT, "assets", "sprites")
SVG_DIR = os.path.join(ROOT, "assets", "source_svg")
DATA_DIR = os.path.join(ROOT, "src", "data")

# ---------------------------------------------------------------------------
# atlas geometry
# ---------------------------------------------------------------------------

FW, FH = 24, 24          # fighter frame
CX, CY = 12.0, 12.0      # frame centre in pixel-centre coordinates
FCOLS = 6                # widest animation has 6 frames

TILE = 16
TCOLS, TROWS = 6, 4

FXW, FXH = 24, 24        # fx frame
FXCOLS, FXROWS = 6, 6

FACINGS = 8

## (name, frame_count, mode)   mode: loop | once | hold
ANIMS = [
    ("idle", 2, "loop"),
    ("run", 6, "loop"),
    ("melee", 4, "once"),
    ("gun_idle", 2, "loop"),
    ("gun_fire", 3, "once"),
    ("roll", 5, "once"),
    ("hook", 3, "once"),
    ("hurt", 2, "once"),
    ("dead", 5, "hold"),
]
ANIM_FRAMES = {a[0]: a[1] for a in ANIMS}

PALETTES = {
    "cyan": {
        "outline": "#08131a",
        "primary": "#4fd6f0",
        "secondary": "#2e93b8",
        "dark": "#134956",
        "skin": "#e6f6fb",
        "visor": "#0f3240",
        "accent": "#c8f6ff",
        "metal": "#a8bcc4",
        "blood": "#7d1f30",
        "bot_plate": "#5f7f8c",
        "eye": "#ffd35c",
    },
    "ember": {
        "outline": "#190a05",
        "primary": "#f0714f",
        "secondary": "#b8492c",
        "dark": "#5f2a18",
        "skin": "#ffd9c6",
        "visor": "#3a1206",
        "accent": "#ffc9a3",
        "metal": "#9a9aa4",
        "blood": "#7d1f30",
        "bot_plate": "#8a6a5c",
        "eye": "#ffd35c",
    },
}

TILE_INDEX = {
    # row 0 - high-contrast hazard tiles and floor decals
    "hazard_h": (0, 0),
    "hazard_v": (1, 0),
    "decal_crack": (2, 0),
    "decal_dot": (3, 0),
    "decal_stripe": (4, 0),
    "decal_warn": (5, 0),
    # row 1 - walls; three vertical variants per material so that a multi-tile
    # tall wall does not repeat its bevel into a stack of "wooden planks"
    "wall_top": (0, 1),
    "wall_mid": (1, 1),
    "wall_bot": (2, 1),
    "wall_dark_top": (3, 1),
    "wall_dark_mid": (4, 1),
    "wall_dark_bot": (5, 1),
    # row 2 - floors
    "floor_a": (0, 2),
    "floor_b": (1, 2),
    "floor_c": (2, 2),
    "floor_d": (3, 2),
    "floor_plate": (4, 2),
    "floor_grate": (5, 2),
    # row 3 - props
    "crate": (0, 3),
    "barrel": (1, 3),
    "pillar": (2, 3),
    "spawn_human": (3, 3),
    "spawn_bot": (4, 3),
    "vent": (5, 3),
}

FX_INDEX = {
    "bullet": (0, 0),
    "bullet_heavy": (0, 1),
    "muzzle": (0, 2),
    "spark": (0, 3),
    "blood": (0, 4),
    "hook_head": (0, 5),
}
FX_COUNTS = {
    "bullet": 3,
    "bullet_heavy": 2,
    "muzzle": 4,
    "spark": 6,
    "blood": 6,
    "hook_head": 3,
}


def pal(name):
    return {k: parse_hex(v) for k, v in PALETTES[name].items()}


# ===========================================================================
# fighter
# ===========================================================================


def _anim_params(anim, fi, nf, is_bot):
    """Derive the per-frame pose scalars so the drawing code stays declarative.

    Geometry note: this is a strictly overhead view, so the anatomy that actually
    reads on screen is HEAD -> SHOULDERS -> ARMS -> WEAPON. A torso is almost
    entirely hidden under the head from directly above, and feet only become
    visible once they swing out past the head radius - which is exactly why the
    run cycle below swings them that far.
    """
    p = fi / float(nf) if nf > 0 else 0.0
    q = fi / float(nf - 1) if nf > 1 else 0.0

    d = {
        "bob": 0.0,          # whole-body offset along the forward axis
        "lateral": 0.0,      # whole-body offset along the side axis
        "legs": True,
        "leg_fwd": -2.0,     # base forward offset of the feet
        "leg_swing": 0.0,    # how far the feet kick along forward
        "leg_spread": 3.4,   # half distance between the two feet
        "arm_r": 2.0,        # right hand forward extension (px)
        "arm_l": 2.0,        # left hand forward extension (px)
        "gun_out": is_bot,
        "recoil": 0.0,
        "muzzle": 0.0,
        "slash": 0.0,
        "spin": 0.0,
        "scale": 1.0,
        "alpha": 1.0,
        "flatten": 0.0,      # >0 squashes the head (roll squash / corpse)
        "tint_white": 0.0,
        "ant_angle": 0.0,
        "blood": 0.0,
        "head_tilt": 0.0,
    }

    if anim == "idle":
        breathe = math.sin(p * math.tau)
        d["bob"] = 0.28 * breathe
        d["arm_r"] = 2.2 + 0.40 * breathe
        d["arm_l"] = 2.2 + 0.40 * breathe
        d["leg_fwd"] = -1.8
    elif anim == "run":
        sw = math.sin(p * math.tau)
        d["leg_fwd"] = 1.6
        d["leg_swing"] = 3.9 * sw
        d["bob"] = 0.55 * abs(math.sin(p * math.tau)) - 0.18
        d["arm_r"] = 2.6 - 1.0 * sw
        d["arm_l"] = 2.6 + 1.0 * sw
        d["ant_angle"] = 0.28 * sw
    elif anim == "melee":
        # frames: 0-1 windup, 2 strike, 3 recover
        d["arm_r"] = [1.0, -0.4, 7.2, 4.0][fi]
        d["arm_l"] = [1.8, 0.9, 3.6, 2.8][fi]
        d["slash"] = [0.0, 0.28, 1.0, 0.38][fi]
        d["bob"] = [0.7, 1.4, -1.6, -0.7][fi]
        d["gun_out"] = False
        d["leg_fwd"] = [0.2, 0.0, 1.6, 0.8][fi]
        d["ant_angle"] = -0.4 * d["slash"]
    elif anim == "gun_idle":
        breathe = math.sin(p * math.tau)
        d["arm_r"] = 5.0
        d["arm_l"] = 4.2
        d["gun_out"] = True
        d["bob"] = 0.18 * breathe
        d["leg_fwd"] = -1.6
    elif anim == "gun_fire":
        d["gun_out"] = True
        d["muzzle"] = [3.4, 2.2, 0.0][fi]
        d["recoil"] = [-1.8, -0.7, 0.0][fi]
        d["arm_r"] = [5.4, 5.0, 5.0][fi]
        d["arm_l"] = [4.4, 4.2, 4.2][fi]
        d["bob"] = [-0.8, -0.4, 0.0][fi]
        d["leg_fwd"] = -2.2
    elif anim == "roll":
        # a tumble reads as: squash the silhouette, spin a marker on the back,
        # then pop back out. Limbs tuck in hard so the shape is unmistakable
        # (a rolling target must LOOK invulnerable or the i-frames feel broken).
        d["scale"] = [1.0, 0.82, 0.72, 0.82, 1.0][fi]
        d["flatten"] = [0.0, 0.25, 0.36, 0.22, 0.0][fi]
        d["spin"] = q * math.tau * 1.15
        d["legs"] = False
        d["leg_fwd"] = -0.5
        d["leg_spread"] = 2.0
        d["arm_r"] = -0.6
        d["arm_l"] = -0.6
        d["gun_out"] = is_bot and fi == 4
    elif anim == "hook":
        d["arm_r"] = [6.4, 7.4, 3.4][fi]
        d["arm_l"] = [1.6, 2.0, 1.8][fi]
        d["gun_out"] = fi == 0 and is_bot
        d["bob"] = [0.9, 1.3, 0.2][fi]
        d["leg_fwd"] = -1.2
    elif anim == "hurt":
        d["bob"] = [-1.5, -1.0][fi]
        d["tint_white"] = [0.75, 0.32][fi]
        d["arm_r"] = [0.4, 1.0][fi]
        d["arm_l"] = [0.4, 1.0][fi]
        d["lateral"] = [0.7, 0.35][fi]
        d["head_tilt"] = [-0.35, -0.18][fi]
        d["leg_fwd"] = -3.0
    elif anim == "dead":
        # a corpse: splayed limbs, flattened head, a pool that keeps growing
        d["flatten"] = 0.42 + 0.12 * fi
        d["leg_fwd"] = -0.4
        d["leg_spread"] = 4.4
        d["leg_swing"] = 0.0
        d["arm_r"] = -2.6
        d["arm_l"] = -2.6
        d["gun_out"] = False
        d["blood"] = min(1.0, 0.25 + 0.22 * fi)
        d["alpha"] = [1.0, 1.0, 0.95, 0.90, 0.85][fi]
        d["head_tilt"] = [0.2, 0.5, 0.8, 1.0, 1.1][fi]
    return d


def limb(cv, p0, p1, radius, color):
    """Capsule spanning two points (my Capsule is centre+length based)."""
    dx, dy = p1[0] - p0[0], p1[1] - p0[1]
    dd = math.hypot(dx, dy)
    cv.capsule((p0[0] + p1[0]) * 0.5, (p0[1] + p1[1]) * 0.5, dd + 2.0 * radius,
               radius, math.atan2(dy, dx), color)


def draw_fighter(anim, fi, nf, facing, P, is_bot):
    """Render one frame of one facing.

    Body and overlays are drawn on separate canvases on purpose: the outline
    pass must see the body only, otherwise the ground shadow and the blood pool
    each pick up a hard 1px outline and stop reading as shadows.
    """
    ang = facing * math.pi / 4.0
    ca, sa = math.cos(ang), math.sin(ang)
    d = _anim_params(anim, fi, nf, is_bot)

    def L(lx, ly):
        return (CX + ca * lx - sa * ly, CY + sa * lx + ca * ly)

    s = d["scale"]
    flat = d["flatten"]
    base_head = P["bot_plate"] if is_bot else P["skin"]
    body = Canvas(FW, FH)

    # --- feet (under the head, so only the swing shows) ---------------------
    if d["legs"]:
        for sign in (-1.0, 1.0):
            flx = d["leg_fwd"] + d["leg_swing"] * sign
            lx, ly = L(flx * s, d["leg_spread"] * sign * s)
            body.capsule(lx, ly, 6.8 * s, 1.90 * s, ang,
                         shade(P["primary"], -0.48))
            toe = (lx + ca * 2.5 * s, ly + sa * 2.5 * s)
            body.circle(toe[0], toe[1], 1.15 * s, shade(P["primary"], -0.14))

    # --- shoulder mass: a thin rim of team colour around the head ----------
    head_r = 5.0 * s * (1.0 - flat * 0.30)
    body.circle(*L(-0.5 * s + d["bob"], d["lateral"]), head_r * 1.14,
                shade(P["primary"], -0.18))

    # --- shoulders + arms + hands ------------------------------------------
    shoulder_side = 5.0 * s
    for sign, ext in ((1.0, d["arm_r"]), (-1.0, d["arm_l"])):
        sx, sy = L(d["bob"] - 0.8 * s, shoulder_side * sign)
        body.circle(sx, sy, 2.75 * s, shade(P["secondary"], -0.06))
        hx, hy = L(d["bob"] + (ext + d["recoil"]) * s, 4.3 * sign * s)
        limb(body, (sx, sy), (hx, hy), 1.55 * s, shade(P["secondary"], -0.24))
        body.circle(hx, hy, 1.55 * s, shade(base_head, 0.08))

    # --- gun ----------------------------------------------------------------
    if d["gun_out"]:
        gx, gy = L(d["bob"] + (6.0 + d["recoil"]) * s, 4.3 * s)
        body.capsule(gx, gy, 9.4 * s, 1.45 * s, ang, P["metal"])
        grip = L(d["bob"] + (3.0 + d["recoil"]) * s, 4.3 * s)
        body.circle(grip[0], grip[1], 1.9 * s, shade(P["metal"], -0.45))

    # --- head: the dominant shape, and the team identity --------------------
    # The head carries the TEAM COLOUR directly. An earlier pass used a near
    # white head, which looked fine in isolation and was useless in play: at
    # this size a white head loses all team identity and both sides read as
    # "grey blob" the moment they overlap.
    hx, hy = L(d["bob"], d["lateral"])
    if d["head_tilt"] > 0.0:
        # corpses tilt the head off-axis so the silhouette stops looking alive
        ha = ang + d["head_tilt"]
        hx += math.cos(ha) * 1.8 - ca * 1.8
        hy += math.sin(ha) * 1.8 - sa * 1.8
    head_base = shade(P["primary"], -0.14)
    body.circle(hx, hy, head_r, head_base)
    # dome highlight, offset toward the back so the front reads as a down-slope
    body.circle(hx - ca * 1.05 * s, hy - sa * 1.05 * s, head_r * 0.84, P["primary"])
    body.circle(hx - ca * 1.70 * s, hy - sa * 1.70 * s, head_r * 0.50,
                shade(P["primary"], 0.28))
    if is_bot:
        # a visible power core so the teams differ in SILHOUETTE, not just hue -
        # colour alone is a colour-blindness failure
        body.circle(hx - ca * 2.9 * s, hy - sa * 2.9 * s, 1.6 * s, P["accent"])

    # --- visor: THE facing tell -------------------------------------------
    # A wide dark goggle band across the leading edge, a bright rim on its
    # leading side, two eye lights, and a nose that pokes past the head outline.
    # This is the most gameplay-critical cluster of pixels in the game: humans
    # and bots both read it to know where the opponent is aiming, which is what
    # makes "predictive dodging" a legitimate mechanic rather than a cheat.
    vx, vy = L(d["bob"] + head_r * 0.46, d["lateral"])
    body.ellipse(vx, vy, head_r * 0.52, head_r * 1.00, ang, P["visor"])
    rim = L(d["bob"] + head_r * 0.86, d["lateral"])
    body.ellipse(rim[0], rim[1], head_r * 0.13, head_r * 0.94, ang, P["accent"])

    if is_bot:
        ex, ey = L(d["bob"] + head_r * 0.52, d["lateral"])
        body.circle(ex, ey, 1.70 * s, parse_hex("#ff5a3c"))
        body.circle(ex, ey, 0.85 * s, parse_hex("#ffe6d2"))
        if anim in ("gun_fire", "melee", "hook", "roll"):
            body.circle(ex, ey, 2.6 * s, with_alpha("#ff8a5c", 0.40))
    else:
        for sign in (-1.0, 1.0):
            ex, ey = L(d["bob"] + head_r * 0.54,
                       d["lateral"] + sign * head_r * 0.50)
            body.circle(ex, ey, 1.45 * s, P["accent"])
            body.circle(ex, ey, 0.70 * s, (255, 255, 255, 255))

    # forward chevron: the cheapest unambiguous "this way" signal there is.
    # Rendered on top of the visor so it survives even at 1x zoom.
    tip = L(d["bob"] + head_r * 1.10, d["lateral"])
    for sign in (-1.0, 1.0):
        wing = L(d["bob"] + head_r * 0.20, d["lateral"] + sign * head_r * 0.86)
        limb(body, (tip[0], tip[1]), (wing[0], wing[1]), 0.95 * s,
             shade(P["visor"], 0.10))
    nose = L(d["bob"] + head_r * 1.20, d["lateral"])
    body.circle(nose[0], nose[1], 1.30 * s, P["accent"])

    # --- bot antenna -------------------------------------------------------
    if is_bot:
        a2 = ang + d["ant_angle"]
        bx, by = L(d["bob"] - 3.4 * s, d["lateral"])
        body.capsule(bx, by, 4.0 * s, 0.80 * s, a2, shade(base_head, -0.30))
        body.circle(bx - math.cos(a2) * 2.0 * s, by - math.sin(a2) * 2.0 * s,
                    1.05 * s, P["accent"])

    # --- roll tumble marker -------------------------------------------------
    if anim == "roll":
        for k in range(3):
            a = ang + d["spin"] + k * math.tau / 3.0
            px, py = L(0.0, 0.0)
            body.capsule(px + math.cos(a) * 2.8 * s, py + math.sin(a) * 2.8 * s,
                         3.4 * s, 0.95 * s, a, shade(P["accent"], -0.10))

    body.outline_solid(with_alpha(P["outline"], 1.0))
    if d["tint_white"] > 0.0:
        body.tint((255, 255, 255, 255), d["tint_white"])
    if d["alpha"] < 1.0:
        body.multiply_alpha(d["alpha"])

    # --- composite: shadow + pool underneath, glows on top -------------------
    cv = Canvas(FW, FH)
    sh_r = 6.4 * s if anim != "dead" else 6.8 * s
    cv.ellipse(CX + 0.4, CY + 0.9, sh_r, sh_r * 0.90, 0.0,
               with_alpha(P["outline"], 0.24 if anim == "dead" else 0.30))
    if d["blood"] > 0.0:
        br = 2.4 * s + 6.4 * s * d["blood"]
        cv.ellipse(CX, CY + 0.5, br, br * 0.86, 0.0,
                   with_alpha(P["blood"], 0.55 * d["blood"]))
    cv.blit(body)

    # --- muzzle flash -------------------------------------------------------
    if d["muzzle"] > 0.0:
        mx, my = L(d["bob"] + (10.4 + d["recoil"]) * s, 4.3 * s)
        rr = d["muzzle"] * s
        cv.circle(mx, my, rr, with_alpha("#fff4c2", 0.95))
        cv.circle(mx, my, rr * 0.55, with_alpha("#ffffff", 1.0))
        for k in range(4):
            a = ang + k * math.pi / 2.0 + 0.4
            cv.capsule(mx + math.cos(a) * rr * 0.7, my + math.sin(a) * rr * 0.7,
                       rr * 1.5, 0.85 * s, a, with_alpha("#ffd777", 0.85))

    # --- melee slash --------------------------------------------------------
    if d["slash"] > 0.0:
        t = d["slash"]
        base = L(1.5, 0.0)
        spread = 1.15
        cv.arc(base[0], base[1], 7.2 * s + 2.4 * (1.0 - t),
               ang - spread * 0.5, ang + spread * 0.5,
               with_alpha("#ffffff", 0.30 + 0.65 * t), 2.3 + 1.7 * t)
        cv.arc(base[0], base[1], 7.2 * s + 4.6 * (1.0 - t),
               ang - spread * 0.34, ang + spread * 0.34,
               with_alpha("#cfeeff", 0.35 + 0.45 * t), 1.2 + 1.0 * t)

    # --- hook rope ----------------------------------------------------------
    if anim == "hook" and fi >= 1:
        ln = 13.0 if fi == 1 else 6.0
        h0 = L(d["bob"] + 5.0, 4.3)
        cv.capsule(h0[0] + ca * ln * 0.5, h0[1] + sa * ln * 0.5, ln, 0.70,
                   ang, with_alpha("#dfe6ea", 0.9))

    return cv


def build_fighter_atlas(pal_name, is_bot):
    rows = len(ANIMS) * FACINGS
    at = Atlas(FW, FH, FCOLS, rows)
    P = pal(pal_name)
    for ai, (anim, nf, _mode) in enumerate(ANIMS):
        for facing in range(FACINGS):
            row = ai * FACINGS + facing
            for fi in range(nf):
                at.blit(draw_fighter(anim, fi, nf, facing, P, is_bot), fi, row)
    return at


# ===========================================================================
# tiles
# ===========================================================================


def _floor_tile(kind, rng):
    cv = Canvas(TILE, TILE)
    base = parse_hex("#414856")
    if kind == "floor_a":
        cv.fill_all(base)
    elif kind == "floor_b":
        cv.fill_all(shade(base, 0.03))
    elif kind == "floor_c":
        cv.fill_all(shade(base, -0.03))
    elif kind == "floor_d":
        cv.fill_all(shade(base, 0.06))
    elif kind == "floor_plate":
        cv.fill_all(shade(base, 0.02))
        cv.frame_rect(1, 1, TILE - 2, TILE - 2, shade(base, 0.12))
        cv.frame_rect(3, 3, TILE - 6, TILE - 6, shade(base, -0.14))
    elif kind == "floor_grate":
        cv.fill_all(shade(base, -0.12))
        for y in range(2, TILE - 1, 4):
            cv.hline(2, TILE - 3, y, shade(base, 0.12))
        for x in range(2, TILE - 1, 4):
            cv.vline(x, 2, TILE - 3, shade(base, 0.06))

    # deterministic speckle, so large floors are not flat colour
    for _ in range(rng.randint(6, 11)):
        x = rng.randint(0, TILE - 1)
        y = rng.randint(0, TILE - 1)
        c = cv.get(x, y)
        if c[3] > 0:
            cv.set(x, y, shade(c, 0.09 if rng.chance(0.5) else -0.09))
    return cv


def _wall_tile(material, variant, rng):
    cv = Canvas(TILE, TILE)
    if material == "concrete":
        top = parse_hex("#8d97a8")
        side = parse_hex("#6b7484")
        face = parse_hex("#575f6e")
    else:
        top = parse_hex("#5f6675")
        side = parse_hex("#4b515e")
        face = parse_hex("#3c424d")

    cv.fill_all(face)
    for y in range(0, TILE, 4):
        off = 0 if (y // 4) % 2 == 0 else 4
        cv.hline(0, TILE - 1, y, shade(face, -0.18))
        for x in range(off, TILE, 8):
            cv.vline(x, y, min(TILE - 1, y + 3), shade(face, -0.14))

    if variant == "top":
        # lit lip: ONLY the top slice of a wall run gets this. If every tile in a
        # tall wall carried the highlight the bevel would repeat and read as a
        # stack of planks rather than one wall.
        cv.rect(0, 0, TILE, 3, top)
        cv.hline(0, TILE - 1, 3, shade(top, -0.25))
        cv.hline(0, TILE - 1, 0, shade(top, 0.22))
    elif variant == "bot":
        cv.rect(0, TILE - 4, TILE, 4, side)
        cv.hline(0, TILE - 1, TILE - 4, shade(side, 0.10))
        cv.hline(0, TILE - 1, TILE - 1, shade(side, -0.35))
    else:
        cv.rect(0, 0, TILE, 2, shade(face, 0.06))
        cv.rect(0, TILE - 2, TILE, 2, shade(face, -0.10))

    for _ in range(rng.randint(3, 7)):
        x = rng.randint(1, TILE - 2)
        y = rng.randint(1, TILE - 2)
        cv.set(x, y, shade(cv.get(x, y), 0.07))
    return cv


def _prop_tile(kind):
    cv = Canvas(TILE, TILE)
    dark = parse_hex("#15171d")
    if kind == "crate":
        wood = parse_hex("#8a6a3f")
        cv.rect(1, 1, TILE - 2, TILE - 2, wood)
        cv.frame_rect(1, 1, TILE - 2, TILE - 2, shade(wood, -0.35))
        cv.hline(2, TILE - 3, 7, shade(wood, -0.20))
        cv.vline(7, 2, TILE - 3, shade(wood, -0.20))
        cv.hline(2, TILE - 3, 3, shade(wood, 0.25))
    elif kind == "barrel":
        body = parse_hex("#59636e")
        cv.ellipse(8.0, 8.0, 6.0, 6.4, 0.0, body)
        cv.ellipse(8.0, 8.0, 5.0, 5.4, 0.0, shade(body, 0.12))
        cv.ellipse(8.0, 8.0, 2.6, 2.9, 0.0, shade(body, -0.28))
        cv.circle(6.0, 6.0, 1.5, shade(body, 0.30))
        cv.outline_solid(dark)
    elif kind == "pillar":
        body = parse_hex("#6b7280")
        cv.rect(4, 0, 8, TILE, body)
        cv.rect(4, 0, 2, TILE, shade(body, -0.28))
        cv.rect(10, 0, 2, TILE, shade(body, -0.16))
        cv.rect(3, 0, 10, 2, shade(body, 0.22))
        cv.rect(3, TILE - 2, 10, 2, shade(body, -0.34))
    elif kind == "spawn_human":
        cv.ring(8.0, 8.0, 6.0, with_alpha("#4fd6f0", 0.85), 1.0)
        cv.ring(8.0, 8.0, 3.0, with_alpha("#4fd6f0", 0.45), 1.0)
        cv.circle(8.0, 8.0, 1.2, parse_hex("#4fd6f0"))
    elif kind == "spawn_bot":
        cv.ring(8.0, 8.0, 6.0, with_alpha("#f0714f", 0.85), 1.0)
        cv.ring(8.0, 8.0, 3.0, with_alpha("#f0714f", 0.45), 1.0)
        cv.circle(8.0, 8.0, 1.2, parse_hex("#f0714f"))
    elif kind == "vent":
        base = parse_hex("#3a4049")
        cv.fill_all(base)
        cv.frame_rect(0, 0, TILE, TILE, shade(base, -0.25))
        for y in range(3, TILE - 2, 3):
            cv.hline(2, TILE - 3, y, shade(base, 0.18))
    elif kind.startswith("hazard"):
        a = parse_hex("#e0b23c")
        b = parse_hex("#2a2b31")
        cv.fill_all(b)
        hz = kind == "hazard_h"
        for x in range(0, TILE, 8):
            for i in range(8):
                for y in range(TILE):
                    phase = (x + i + y) if hz else (x + y + i)
                    if phase % 8 < 4:
                        cv.set(x + i, y, a)
    elif kind.startswith("decal"):
        base = parse_hex("#414856")
        cv.fill_all(base)
        line = shade(base, -0.28)
        if kind == "decal_crack":
            pts = [(2, 3), (5, 6), (4, 9), (8, 12), (12, 11)]
            for i in range(len(pts) - 1):
                mid = ((pts[i][0] + pts[i + 1][0]) / 2.0,
                       (pts[i][1] + pts[i + 1][1]) / 2.0)
                ln = math.dist(pts[i], pts[i + 1]) + 1.0
                a = math.atan2(pts[i + 1][1] - pts[i][1], pts[i + 1][0] - pts[i][0])
                cv.capsule(mid[0], mid[1], ln, 0.55, a, line)
        elif kind == "decal_dot":
            cv.circle(5.0, 5.0, 1.1, line)
            cv.circle(11.0, 9.0, 1.1, line)
            cv.circle(7.0, 12.0, 0.9, line)
        elif kind == "decal_stripe":
            for x in range(-TILE, TILE, 5):
                for i in range(5):
                    for y in range(TILE):
                        px = x + i + y
                        if 0 <= px < TILE:
                            cv.set(px, y, shade(base, 0.05))
        elif kind == "decal_warn":
            cv.frame_rect(1, 1, TILE - 2, TILE - 2, with_alpha("#e0b23c", 0.55))
    return cv


def build_tiles():
    at = Atlas(TILE, TILE, TCOLS, TROWS)
    rng = LCG(0xC0FFEE)
    for name, (col, row) in TILE_INDEX.items():
        if name.startswith("wall_dark_"):
            cv = _wall_tile("dark", name.replace("wall_dark_", ""), rng)
        elif name.startswith("wall_"):
            cv = _wall_tile("concrete", name.replace("wall_", ""), rng)
        elif name.startswith("floor_"):
            cv = _floor_tile(name, rng)
        else:
            cv = _prop_tile(name)
        at.blit(cv, col, row)
    return at


# ===========================================================================
# fx
# ===========================================================================


def build_fx():
    at = Atlas(FXW, FXH, FXCOLS, FXROWS)
    cx, cy = FXW / 2.0, FXH / 2.0

    # --- bullet: a tracer that stretches as it ages -------------------------
    for i in range(FX_COUNTS["bullet"]):
        t = i / float(FX_COUNTS["bullet"] - 1)
        cv = Canvas(FXW, FXH)
        cv.capsule(cx - 1.0, cy, 6.0 + 6.0 * t, 1.7 - 0.5 * t, 0.0,
                   with_alpha("#ffd98a", 0.85 - 0.35 * t))
        cv.circle(cx + 3.0, cy, 1.6 - 0.4 * t, (255, 255, 255, 255))
        at.blit(cv, i, 0)

    # --- heavy bullet -------------------------------------------------------
    for i in range(FX_COUNTS["bullet_heavy"]):
        cv = Canvas(FXW, FXH)
        cv.capsule(cx - 1.0, cy, 9.0 + 6.0 * i, 2.6, 0.0,
                   with_alpha("#ffb47a", 0.95))
        cv.circle(cx + 4.0, cy, 2.2, (255, 255, 255, 255))
        at.blit(cv, i, 1)

    # --- muzzle flash -------------------------------------------------------
    for i in range(FX_COUNTS["muzzle"]):
        t = i / float(FX_COUNTS["muzzle"] - 1)
        cv = Canvas(FXW, FXH)
        r = 5.0 * (1.0 - 0.45 * t)
        cv.circle(cx, cy, r, with_alpha("#fff1b8", 0.95 - 0.5 * t))
        cv.circle(cx, cy, r * 0.55, (255, 255, 255, 250))
        for k in range(6):
            a = k * math.tau / 6.0 + 0.3
            cv.capsule(cx + math.cos(a) * r, cy + math.sin(a) * r,
                       r * (1.2 - 0.3 * t), 1.1, a,
                       with_alpha("#ffcf6a", 0.85 - 0.5 * t))
        at.blit(cv, i, 2)

    # --- impact spark -------------------------------------------------------
    spark_dirs = [(math.cos(k * math.tau / 6.0 + 0.2),
                   math.sin(k * math.tau / 6.0 + 0.2)) for k in range(6)]
    for i in range(FX_COUNTS["spark"]):
        t = i / float(FX_COUNTS["spark"] - 1)
        cv = Canvas(FXW, FXH)
        dd = 2.0 + 8.0 * t
        for dx, dy in spark_dirs:
            cv.capsule(cx + dx * dd * 0.5, cy + dy * dd * 0.5, dd * 0.9,
                       1.4 * (1.0 - 0.7 * t), math.atan2(dy, dx),
                       with_alpha("#ffe9a0", 0.95 - 0.75 * t))
        cv.circle(cx, cy, 2.6 * (1.0 - t * 0.8),
                  with_alpha("#ffffff", 0.90 - 0.80 * t))
        at.blit(cv, i, 3)

    # --- blood --------------------------------------------------------------
    rng = LCG(0x5EED)
    for i in range(FX_COUNTS["blood"]):
        t = i / float(FX_COUNTS["blood"] - 1)
        cv = Canvas(FXW, FXH)
        for k in range(5):
            a = k * math.tau / 5.0 + 0.7
            dist = (1.0 + 7.0 * t) * (0.6 + 0.4 * rng.rnd())
            rr = 1.6 * (1.0 - 0.6 * t)
            if rr > 0.4:
                cv.circle(cx + math.cos(a) * dist, cy + math.sin(a) * dist, rr,
                          with_alpha("#a8283f", 0.95 - 0.6 * t))
        cv.circle(cx, cy, 2.2 * (1.0 - 0.7 * t),
                  with_alpha("#c8384f", 0.90 - 0.70 * t))
        at.blit(cv, i, 4)

    # --- hook head ----------------------------------------------------------
    for i in range(FX_COUNTS["hook_head"]):
        cv = Canvas(FXW, FXH)
        spin = i * 0.5
        for k in range(3):
            a = spin + k * math.tau / 3.0
            cv.capsule(cx + math.cos(a) * 3.0, cy + math.sin(a) * 3.0, 6.0, 1.6,
                       a, with_alpha("#cdd8de", 1.0))
        cv.circle(cx, cy, 2.4, with_alpha("#8f9aa1", 1.0))
        cv.circle(cx, cy, 1.2, with_alpha("#e8f0f4", 1.0))
        at.blit(cv, i, 5)

    return at


# ===========================================================================
# main
# ===========================================================================


def write_manifest():
    man = {
        "fighter": {
            "frame_w": FW,
            "frame_h": FH,
            "cols": FCOLS,
            "rows": len(ANIMS) * FACINGS,
            "facings": FACINGS,
            "atlas": {
                "cyan": "res://assets/sprites/fighter_cyan.png",
                "ember": "res://assets/sprites/fighter_ember.png",
            },
            "anim_rows": {a[0]: i * FACINGS for i, a in enumerate(ANIMS)},
            "anim_frames": {a[0]: a[1] for a in ANIMS},
            "anim_mode": {a[0]: a[2] for a in ANIMS},
        },
        "tiles": {
            "frame_w": TILE,
            "frame_h": TILE,
            "cols": TCOLS,
            "rows": TROWS,
            "atlas": "res://assets/sprites/tiles.png",
            "index": {k: [v[0], v[1]] for k, v in TILE_INDEX.items()},
        },
        "fx": {
            "frame_w": FXW,
            "frame_h": FXH,
            "cols": FXCOLS,
            "rows": FXROWS,
            "atlas": "res://assets/sprites/fx.png",
            "index": {k: [v[0], v[1]] for k, v in FX_INDEX.items()},
            "counts": FX_COUNTS,
        },
    }
    ensure_dir(os.path.join(DATA_DIR, "x"))
    path = os.path.join(DATA_DIR, "sprite_manifest.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(man, f, indent=2)
        f.write("\n")
    return path


def main():
    print("=== CakeGame sprite generator ===")
    ensure_dir(os.path.join(SPRITE_DIR, "x"))
    ensure_dir(os.path.join(SVG_DIR, "x"))

    summary = []
    for pal_name, is_bot in (("cyan", False), ("ember", True)):
        at = build_fighter_atlas(pal_name, is_bot)
        path = os.path.join(SPRITE_DIR, "fighter_%s.png" % pal_name)
        n = write_png(path, at.canvas)
        summary.append(("fighter_%s.png" % pal_name, at.w, at.h, n))

    # Editable vector source: one representative pose sheet rather than all 72
    # rows, because a full-fidelity SVG would be tens of megabytes for no gain.
    poses = [("idle", 0), ("idle", 1), ("run", 0), ("run", 3),
             ("melee", 2), ("gun_fire", 0), ("roll", 2), ("hook", 1),
             ("hurt", 0), ("dead", 4), ("gun_idle", 0), ("run", 5)]
    sheet = Atlas(FW, FH, 6, 2)
    P = pal("cyan")
    for i, (anim, fi) in enumerate(poses):
        src = draw_fighter(anim, fi, ANIM_FRAMES[anim], 0, P, False)
        sheet.blit(src, i % 6, i // 6)
    canvas_to_svg(sheet.canvas, os.path.join(SVG_DIR, "fighter_pose_sheet.svg"), 1,
                  "CakeGame fighter pose sheet (facing East)")

    tiles = build_tiles()
    n = write_png(os.path.join(SPRITE_DIR, "tiles.png"), tiles.canvas)
    summary.append(("tiles.png", tiles.w, tiles.h, n))
    canvas_to_svg(tiles.canvas, os.path.join(SVG_DIR, "tiles.svg"), 1,
                  "CakeGame terrain tiles")

    fx = build_fx()
    n = write_png(os.path.join(SPRITE_DIR, "fx.png"), fx.canvas)
    summary.append(("fx.png", fx.w, fx.h, n))
    canvas_to_svg(fx.canvas, os.path.join(SVG_DIR, "fx.svg"), 1, "CakeGame effects")

    man_path = write_manifest()

    for name, w, h, n in summary:
        log("%-22s %4dx%-5d %7.1f KB" % (name, w, h, n / 1024.0))
    log("manifest -> %s" % os.path.relpath(man_path, ROOT))
    print("=== done ===")


if __name__ == "__main__":
    main()
