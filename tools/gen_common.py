"""CakeGame asset toolkit - shared primitives.

Zero third-party dependencies on purpose: the project must regenerate every
asset on a clean machine with nothing but CPython installed.

Everything here is DETERMINISTIC. `random` is never imported; a small LCG stands
in for it so re-running a generator produces byte-identical output. Without that
guarantee every rebuild would produce a meaningless diff across hundreds of PNGs.
"""

import math
import os
import struct
import zlib

# ---------------------------------------------------------------------------
# deterministic RNG
# ---------------------------------------------------------------------------


class LCG:
    """Numerical Recipes linear congruential generator (48-bit state)."""

    def __init__(self, seed):
        self.s = (int(seed) ^ 0x5DEECE66D) & ((1 << 48) - 1)

    def next32(self):
        self.s = (self.s * 0x5DEECE66D + 0xB) & ((1 << 48) - 1)
        return self.s >> 16

    def rnd(self):
        return self.next32() / float(1 << 32)

    def randint(self, a, b):
        if b < a:
            a, b = b, a
        return a + self.next32() % (b - a + 1)

    def uniform(self, a, b):
        return a + (b - a) * self.rnd()

    def choice(self, seq):
        return seq[self.next32() % len(seq)]

    def chance(self, p):
        return self.rnd() < p

    def shuffle(self, arr):
        for i in range(len(arr) - 1, 0, -1):
            j = self.next32() % (i + 1)
            arr[i], arr[j] = arr[j], arr[i]


# ---------------------------------------------------------------------------
# colour helpers
# ---------------------------------------------------------------------------


def parse_hex(h):
    """'#rrggbb' or '#rrggbbaa' -> (r, g, b, a)."""
    h = h.lstrip("#")
    if len(h) == 6:
        h += "ff"
    return (
        int(h[0:2], 16),
        int(h[2:4], 16),
        int(h[4:6], 16),
        int(h[6:8], 16),
    )


def hex_at(h, alpha):
    r, g, b, _ = parse_hex(h)
    return (r, g, b, max(0, min(255, int(round(alpha * 255)))))


def shade(color, amount):
    """Lighten (amount > 0) or darken (amount < 0) an RGBA tuple."""
    r, g, b, a = color
    if amount >= 0:
        f = amount
        r = int(r + (255 - r) * f)
        g = int(g + (255 - g) * f)
        b = int(b + (255 - b) * f)
    else:
        f = 1.0 + amount
        r = int(r * f)
        g = int(g * f)
        b = int(b * f)
    return (max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b)), a)


def mix(c1, c2, t):
    t = max(0.0, min(1.0, t))
    return tuple(int(round(c1[i] + (c2[i] - c1[i]) * t)) for i in range(4))


def with_alpha(c, a):
    """Force an alpha on a colour. Accepts either '#rrggbb[aa]' or an RGBA tuple,
    because both forms read naturally at call sites."""
    if isinstance(c, str):
        c = parse_hex(c)
    return (c[0], c[1], c[2], max(0, min(255, int(round(a * 255)))))


# ---------------------------------------------------------------------------
# canvas
# ---------------------------------------------------------------------------


class Canvas:
    """Tiny RGBA raster with the handful of primitives pixel art needs.

    Coordinates are pixel centres at (x + 0.5, y + 0.5) so that rotations and
    ellipses are symmetric about the true centre of a pixel.
    """

    def __init__(self, w, h, fill=(0, 0, 0, 0)):
        self.w = int(w)
        self.h = int(h)
        self.px = [fill] * (self.w * self.h)

    def clone(self):
        c = Canvas(self.w, self.h)
        c.px = list(self.px)
        return c

    def get(self, x, y):
        if 0 <= x < self.w and 0 <= y < self.h:
            return self.px[y * self.w + x]
        return (0, 0, 0, 0)

    def set(self, x, y, color):
        """Hard write (replaces, does not blend)."""
        if 0 <= x < self.w and 0 <= y < self.h:
            self.px[y * self.w + x] = color

    def blend(self, x, y, color):
        if not (0 <= x < self.w and 0 <= y < self.h):
            return
        i = y * self.w + x
        d = self.px[i]
        a = color[3] / 255.0
        if a >= 0.999:
            self.px[i] = color
            return
        if a <= 0.001:
            return
        na = a + (d[3] / 255.0) * (1.0 - a)
        if na <= 0.0:
            self.px[i] = (0, 0, 0, 0)
            return
        r = (color[0] * a + d[0] * (d[3] / 255.0) * (1.0 - a)) / na
        g = (color[1] * a + d[1] * (d[3] / 255.0) * (1.0 - a)) / na
        b = (color[2] * a + d[2] * (d[3] / 255.0) * (1.0 - a)) / na
        self.px[i] = (int(r + 0.5), int(g + 0.5), int(b + 0.5), int(na * 255 + 0.5))

    def fill_all(self, color):
        self.px = [color] * (self.w * self.h)

    def blit(self, src, dx=0, dy=0):
        """Copy every non-transparent pixel of `src` at an offset (hard copy)."""
        for y in range(src.h):
            for x in range(src.w):
                c = src.get(x, y)
                if c[3] == 0:
                    continue
                self.set(dx + x, dy + y, c)

    # --- primitives --------------------------------------------------------

    def rect(self, x, y, w, h, color):
        for yy in range(int(y), int(y + h)):
            for xx in range(int(x), int(x + w)):
                self.set(xx, yy, color)

    def rect_blend(self, x, y, w, h, color):
        for yy in range(int(y), int(y + h)):
            for xx in range(int(x), int(x + w)):
                self.blend(xx, yy, color)

    def frame_rect(self, x, y, w, h, color):
        for xx in range(int(x), int(x + w)):
            self.set(xx, int(y), color)
            self.set(xx, int(y + h) - 1, color)
        for yy in range(int(y), int(y + h)):
            self.set(int(x), yy, color)
            self.set(int(x + w) - 1, yy, color)

    def hline(self, x0, x1, y, color):
        if x1 < x0:
            x0, x1 = x1, x0
        for xx in range(int(x0), int(x1) + 1):
            self.set(xx, int(y), color)

    def vline(self, x, y0, y1, color):
        if y1 < y0:
            y0, y1 = y1, y0
        for yy in range(int(y0), int(y1) + 1):
            self.set(int(x), yy, color)

    def circle(self, cx, cy, r, color, blend=False):
        self.ellipse(cx, cy, r, r, 0.0, color, blend)

    def ring(self, cx, cy, r, color, thickness=1.0):
        self.ellipse(cx, cy, r, r, 0.0, color, False, 0.0, thickness)

    def ellipse(self, cx, cy, rx, ry, angle=0.0, color=(0, 0, 0, 255),
                blend=True, inner=0.0, ring=None):
        """Rotated ellipse.

        `inner` > 0 carves a hole of that relative radius (donut).
        `ring` (thickness, in px) draws only the outer band of that width.
        """
        if rx <= 0 or ry <= 0:
            return
        ca, sa = math.cos(angle), math.sin(angle)
        # conservative axis-aligned bounding box of the rotated ellipse
        ex = math.sqrt((rx * ca) ** 2 + (ry * sa) ** 2)
        ey = math.sqrt((rx * sa) ** 2 + (ry * ca) ** 2)
        x0 = int(math.floor(cx - ex - 1))
        x1 = int(math.ceil(cx + ex + 1))
        y0 = int(math.floor(cy - ey - 1))
        y1 = int(math.ceil(cy + ey + 1))
        put = self.blend if blend else self.set
        for yy in range(y0, y1 + 1):
            for xx in range(x0, x1 + 1):
                dx = xx + 0.5 - cx
                dy = yy + 0.5 - cy
                lx = dx * ca + dy * sa
                ly = -dx * sa + dy * ca
                t = (lx / rx) ** 2 + (ly / ry) ** 2
                if t > 1.0:
                    continue
                if inner > 0.0 and t < inner * inner:
                    continue
                if ring is not None and ring > 0.0:
                    # keep only the outer band: normalise radii down by `ring`
                    irx = max(0.001, rx - ring)
                    iry = max(0.001, ry - ring)
                    if (lx / irx) ** 2 + (ly / iry) ** 2 < 1.0:
                        continue
                put(xx, yy, color)

    def capsule(self, cx, cy, length, radius, angle, color, blend=True):
        """Rotated capsule: a line segment of `length` with `radius` ends.

        This is the workhorse for limbs and weapons.
        """
        ca, sa = math.cos(angle), math.sin(angle)
        half = max(0.0, length * 0.5 - radius)
        ax, ay = cx - ca * half, cy - sa * half
        bx, by = cx + ca * half, cy + sa * half
        ex = max(abs(ax - cx), abs(bx - cx)) + radius + 1
        ey = max(abs(ay - cy), abs(by - cy)) + radius + 1
        put = self.blend if blend else self.set
        for yy in range(int(cy - ey), int(cy + ey) + 1):
            for xx in range(int(cx - ex), int(cx + ex) + 1):
                px, py = xx + 0.5, yy + 0.5
                vx, vy = bx - ax, by - ay
                wx, wy = px - ax, py - ay
                vv = vx * vx + vy * vy
                if vv < 1e-6:
                    t = 0.0
                else:
                    t = max(0.0, min(1.0, (wx * vx + wy * vy) / vv))
                qx, qy = ax + vx * t, ay + vy * t
                if (px - qx) ** 2 + (py - qy) ** 2 <= radius * radius:
                    put(xx, yy, color)

    def arc(self, cx, cy, r, a0, a1, color, thickness=1.0, blend=True):
        steps = max(6, int(abs(a1 - a0) * r * 1.6))
        for i in range(steps + 1):
            t = i / float(steps)
            a = a0 + (a1 - a0) * t
            self.circle(cx + math.cos(a) * r, cy + math.sin(a) * r,
                        thickness * 0.5, color, blend)

    def outline(self, color, alpha=1.0, only_alpha_edges=True):
        """Add a 1px outline around every opaque region.

        Done as a post-pass so shapes can be drawn naively and still come out
        with a readable silhouette - the single biggest readability win in
        pixel art at this size.
        """
        solid = [[self.get(x, y)[3] > 40 for x in range(self.w)] for y in range(self.h)]
        col = with_alpha(color, alpha)
        for y in range(self.h):
            for x in range(self.w):
                if solid[y][x]:
                    continue
                touching = False
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < self.w and 0 <= ny < self.h and solid[ny][nx]:
                        touching = True
                        break
                if touching:
                    self.set(x, y, col)

    def outline_solid(self, color):
        """Outline that also closes diagonal gaps (used for thin weapons)."""
        solid = [[self.get(x, y)[3] > 40 for x in range(self.w)] for y in range(self.h)]
        for y in range(self.h):
            for x in range(self.w):
                if solid[y][x]:
                    continue
                hit = False
                for dx in (-1, 0, 1):
                    for dy in (-1, 0, 1):
                        if dx == 0 and dy == 0:
                            continue
                        nx, ny = x + dx, y + dy
                        if 0 <= nx < self.w and 0 <= ny < self.h and solid[ny][nx]:
                            hit = True
                if hit:
                    self.set(x, y, color)

    def tint(self, color, amount):
        """Blend every opaque pixel toward `color` by `amount`."""
        for i in range(len(self.px)):
            c = self.px[i]
            if c[3] > 0:
                self.px[i] = mix(c, color, amount)

    def multiply_alpha(self, factor):
        for i in range(len(self.px)):
            c = self.px[i]
            if c[3] > 0:
                self.px[i] = (c[0], c[1], c[2], int(c[3] * factor))

    def is_empty(self):
        return all(c[3] == 0 for c in self.px)


# ---------------------------------------------------------------------------
# atlas
# ---------------------------------------------------------------------------


class Atlas:
    def __init__(self, frame_w, frame_h, cols, rows, fill=(0, 0, 0, 0)):
        self.frame_w = frame_w
        self.frame_h = frame_h
        self.cols = cols
        self.rows = rows
        self.w = frame_w * cols
        self.h = frame_h * rows
        self.canvas = Canvas(self.w, self.h, fill)

    def blit(self, src, col, row, dx=0, dy=0):
        ox = col * self.frame_w + dx
        oy = row * self.frame_h + dy
        for y in range(src.h):
            for x in range(src.w):
                c = src.get(x, y)
                if c[3] == 0:
                    continue
                self.canvas.set(ox + x, oy + y, c)

    def frame(self, col, row):
        """Extract one frame as a standalone Canvas."""
        c = Canvas(self.frame_w, self.frame_h)
        ox, oy = col * self.frame_w, row * self.frame_h
        for y in range(self.frame_h):
            for x in range(self.frame_w):
                c.set(x, y, self.canvas.get(ox + x, oy + y))
        return c


# ---------------------------------------------------------------------------
# writers
# ---------------------------------------------------------------------------


def write_png(path, canvas):
    """Minimal RGBA PNG encoder (filter type 0, single IDAT)."""
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
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9))
    png += chunk(b"IEND", b"")
    ensure_dir(path)
    with open(path, "wb") as f:
        f.write(png)
    return len(png)


def read_png_rgba(path):
    """Minimal PNG reader for 8-bit non-interlaced RGBA.

    Only used by the offline preview tooling, never by the game. Supports all
    five filter types so it also copes with files written by other tools.
    """
    with open(path, "rb") as f:
        data = f.read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG: %s" % path)
    pos = 8
    w = h = 0
    idat = bytearray()
    while pos + 12 <= len(data):
        ln = struct.unpack(">I", data[pos:pos + 4])[0]
        tag = data[pos + 4:pos + 8]
        chunk = data[pos + 8:pos + 8 + ln]
        pos += 12 + ln
        if tag == b"IHDR":
            w, h, depth, ctype, _c, _f, inter = struct.unpack(">IIBBBBB", chunk)
            if depth != 8 or ctype != 6 or inter != 0:
                raise ValueError("unsupported PNG format: %s" % path)
        elif tag == b"IDAT":
            idat += chunk
        elif tag == b"IEND":
            break

    raw = zlib.decompress(bytes(idat))
    stride = w * 4
    cv = Canvas(w, h)
    prev = bytearray(stride)
    p = 0
    for y in range(h):
        ft = raw[p]
        p += 1
        line = bytearray(raw[p:p + stride])
        p += stride
        if ft == 1:
            for i in range(4, stride):
                line[i] = (line[i] + line[i - 4]) & 0xFF
        elif ft == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif ft == 3:
            for i in range(stride):
                a = line[i - 4] if i >= 4 else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 0xFF
        elif ft == 4:
            for i in range(stride):
                a = line[i - 4] if i >= 4 else 0
                b = prev[i]
                c = prev[i - 4] if i >= 4 else 0
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                if pa <= pb and pa <= pc:
                    pr = a
                elif pb <= pc:
                    pr = b
                else:
                    pr = c
                line[i] = (line[i] + pr) & 0xFF
        for x in range(w):
            i = x * 4
            cv.set(x, y, (line[i], line[i + 1], line[i + 2], line[i + 3]))
        prev = line
    return cv


def canvas_to_svg(canvas, path, scale=1, title=""):
    """Serialise a canvas as SVG using run-length <rect> rows.

    This is the *editable vector source* that ships in the repo. It is NOT
    loaded at runtime - ThorVG rasterisation can antialias and blur pixel
    edges, so the PNG is the runtime texture.
    """
    w, h = canvas.w, canvas.h
    parts = []
    parts.append(
        '<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" '
        'viewBox="0 0 %d %d" shape-rendering="crispEdges">'
        % (w * scale, h * scale, w, h)
    )
    if title:
        parts.append("<title>%s</title>" % title)
    for y in range(h):
        x = 0
        while x < w:
            c = canvas.get(x, y)
            if c[3] == 0:
                x += 1
                continue
            run = 1
            while x + run < w and canvas.get(x + run, y) == c:
                run += 1
            op = "" if c[3] == 255 else ' fill-opacity="%.3f"' % (c[3] / 255.0)
            parts.append(
                '<rect x="%d" y="%d" width="%d" height="1" fill="#%02x%02x%02x"%s/>'
                % (x, y, run, c[0], c[1], c[2], op)
            )
            x += run
    parts.append("</svg>")
    ensure_dir(path)
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(parts))
    return sum(len(p) for p in parts)


def ensure_dir(path):
    d = os.path.dirname(os.path.abspath(path))
    if d and not os.path.isdir(d):
        os.makedirs(d)


def log(msg):
    print("[gen] " + msg)
