"""CakeGame sound effect + music synthesiser.

Zero dependencies, fully deterministic. Every sound is built from a handful of
primitives (oscillator / noise / sweep / AD envelope / one-pole filter), because
a battle game needs punchy, readable transients far more than it needs fidelity,
and shipping WAVs generated from source keeps the repo free of opaque binaries.

Looping music gets a `smpl` chunk so Godot's WAV importer (whose default loop
mode is "Detect From WAV") picks the loop points up automatically. The audio
director additionally loops by hand on the `finished` signal, so a failed
detection still produces correct behaviour.

Run:  python tools/gen_sfx.py
"""

import math
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from gen_common import LCG, ensure_dir, log  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SFX_DIR = os.path.join(ROOT, "assets", "sfx")

SR = 22050          # retro sampling rate: smaller files, and the aliasing is
                    # character rather than a defect for chiptune material


# ---------------------------------------------------------------------------
# primitives (all operate on plain python float lists; speed is irrelevant here)
# ---------------------------------------------------------------------------


def osc(kind, freq, n, phase=0.0, detune=0.0):
    out = [0.0] * n
    ph = phase
    ph2 = phase
    for i in range(n):
        f = freq * (1.0 + detune)
        ph += f / SR
        ph2 += freq / SR
        t = ph % 1.0
        if kind == "sin":
            out[i] = math.sin(t * math.tau)
        elif kind == "sq":
            out[i] = 1.0 if t < 0.5 else -1.0
        elif kind == "saw":
            out[i] = t * 2.0 - 1.0
        elif kind == "tri":
            out[i] = 4.0 * abs(t - 0.5) - 1.0
        elif kind == "pulse":
            out[i] = 1.0 if t < 0.25 else -1.0
        else:
            out[i] = math.sin(t * math.tau)
    del ph2
    return out


def sweep(kind, f0, f1, n, curve=1.0):
    out = [0.0] * n
    ph = 0.0
    for i in range(n):
        t = i / float(max(1, n - 1))
        f = f0 + (f1 - f0) * (t ** curve)
        ph += f / SR
        p = ph % 1.0
        if kind == "sin":
            out[i] = math.sin(p * math.tau)
        elif kind == "sq":
            out[i] = 1.0 if p < 0.5 else -1.0
        elif kind == "saw":
            out[i] = p * 2.0 - 1.0
        elif kind == "tri":
            out[i] = 4.0 * abs(p - 0.5) - 1.0
        else:
            out[i] = math.sin(p * math.tau)
    return out


def noise(n, seed=1, hold=1):
    """White noise; `hold` > 1 gives a cheap sample-and-hold (chunkier, more
    '8-bit') texture."""
    rng = LCG(seed)
    out = [0.0] * n
    v = 0.0
    for i in range(n):
        if i % hold == 0:
            v = rng.uniform(-1.0, 1.0)
        out[i] = v
    return out


def env_ad(n, attack, decay, curve=2.0):
    """Attack/decay envelope. `attack`/`decay` are fractions of n."""
    out = [0.0] * n
    a = max(1, int(n * attack))
    d = max(1, n - a)
    for i in range(n):
        if i < a:
            out[i] = (i / float(a)) ** 0.65
        else:
            x = (i - a) / float(d)
            out[i] = max(0.0, (1.0 - x) ** curve)
    return out


def env_ads(n, attack, sustain, release, curve=2.0):
    out = [0.0] * n
    a = max(1, int(n * attack))
    r = max(1, int(n * release))
    s = max(0, n - a - r)
    for i in range(n):
        if i < a:
            out[i] = (i / float(a)) ** 0.65
        elif i < a + s:
            out[i] = sustain
        else:
            x = (i - a - s) / float(r)
            out[i] = max(0.0, sustain * (1.0 - x) ** curve)
    return out


def lowpass(sig, alpha):
    out = [0.0] * len(sig)
    y = 0.0
    for i, v in enumerate(sig):
        y += alpha * (v - y)
        out[i] = y
    return out


def highpass(sig, alpha):
    out = [0.0] * len(sig)
    y = 0.0
    for i, v in enumerate(sig):
        y += alpha * (v - y)
        out[i] = v - y
    return out


def dist(sig, drive):
    return [math.tanh(v * drive) for v in sig]


def clip(sig, ceiling=0.98):
    return [max(-ceiling, min(ceiling, v)) for v in sig]


def mul(a, b):
    n = min(len(a), len(b))
    return [a[i] * b[i] for i in range(n)]


def gain(sig, g):
    return [v * g for v in sig]


def add(*sigs):
    n = max(len(s) for s in sigs)
    out = [0.0] * n
    for s in sigs:
        for i, v in enumerate(s):
            out[i] += v
    return out


def mix_into(dst, src, offset, g=1.0):
    need = offset + len(src)
    if need > len(dst):
        dst.extend([0.0] * (need - len(dst)))
    for i, v in enumerate(src):
        dst[offset + i] += v * g


def silence(n):
    return [0.0] * n


def normalize(sig, peak=0.92):
    m = max((abs(v) for v in sig), default=0.0)
    if m < 1e-9:
        return sig
    k = peak / m
    return [v * k for v in sig]


def fade_edges(sig, ms=3.0):
    n = len(sig)
    f = max(1, int(SR * ms / 1000.0))
    f = min(f, n // 2)
    out = list(sig)
    for i in range(f):
        t = i / float(f)
        out[i] *= t
        out[n - 1 - i] *= t
    return out


def make_loop(sig, ms=45):
    """Cross-fade the tail into the head.

    Do NOT fade both ends of a looping sound: that puts an audible volume dip at
    every wrap. Wrapping the tail onto the head keeps the loop seamless.
    """
    f = max(1, int(SR * ms / 1000.0))
    f = min(f, len(sig) // 4)
    out = list(sig)
    n = len(sig)
    for i in range(f):
        t = i / float(f)
        out[i] = out[i] * t + sig[n - f + i] * (1.0 - t)
    return out[:n - f]


# ---------------------------------------------------------------------------
# note helpers
# ---------------------------------------------------------------------------

_NOTE_OFFSET = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}


def note(name):
    """'A2' / 'C#4' / 'Eb3' -> frequency in Hz."""
    name = name.strip()
    letter = name[0].upper()
    idx = 1
    semi = _NOTE_OFFSET[letter]
    while idx < len(name) and name[idx] in "#b":
        semi += 1 if name[idx] == "#" else -1
        idx += 1
    octave = int(name[idx:])
    midi = 12 * (octave + 1) + semi
    return 440.0 * (2.0 ** ((midi - 69) / 12.0))


def seconds(t):
    return int(SR * t)


# ---------------------------------------------------------------------------
# WAV writer
# ---------------------------------------------------------------------------


def write_wav(path, sig, loop=False):
    sig = clip(normalize(sig, 0.90 if not loop else 0.78))
    n = len(sig)
    pcm = bytearray()
    for v in sig:
        pcm += struct.pack("<h", int(v * 32767))

    fmt = struct.pack("<HHIIHH", 1, 1, SR, SR * 2, 2, 16)
    body = b"fmt " + struct.pack("<I", len(fmt)) + fmt

    if loop:
        header = struct.pack("<9I", 0, 0, int(1e9 / SR), 60, 0, 0, 0, 1, 0)
        loopinfo = struct.pack("<6I", 0, 0, 0, n - 1, 0, 0)
        smpl = header + loopinfo
        body += b"smpl" + struct.pack("<I", len(smpl)) + smpl

    body += b"data" + struct.pack("<I", len(pcm)) + bytes(pcm)
    riff = b"WAVE" + body
    out = b"RIFF" + struct.pack("<I", len(riff)) + riff

    ensure_dir(path)
    with open(path, "wb") as f:
        f.write(out)
    return len(out)


# ===========================================================================
# individual sounds
# ===========================================================================


def s_melee_swing():
    n = seconds(0.17)
    a = mul(sweep("sin", 900, 180, n, 1.6), env_ad(n, 0.06, 0.94, 2.2))
    b = mul(highpass(noise(n, 11), 0.55), env_ad(n, 0.02, 0.98, 2.8))
    return add(gain(a, 0.30), gain(b, 0.72))


def s_melee_hit():
    n = seconds(0.22)
    thump = mul(sweep("sin", 210, 55, n, 1.9), env_ad(n, 0.005, 0.995, 2.6))
    crack = mul(highpass(noise(n, 23), 0.42), env_ad(n, 0.002, 0.998, 4.0))
    return add(gain(dist(thump, 2.0), 0.95), gain(crack, 0.60))


def s_gun_shot():
    n = seconds(0.11)
    body = mul(sweep("sq", 1100, 130, n, 1.5), env_ad(n, 0.002, 0.998, 3.2))
    crack = mul(highpass(noise(n, 7), 0.62), env_ad(n, 0.001, 0.999, 5.0))
    return add(gain(dist(body, 1.7), 0.55), gain(crack, 0.85))


def s_gun_empty():
    n = seconds(0.05)
    a = mul(osc("sq", 1500, n), env_ad(n, 0.001, 0.999, 5.0))
    b = mul(noise(n, 31), env_ad(n, 0.001, 0.999, 6.0))
    return add(gain(a, 0.35), gain(b, 0.30))


def s_reload_start():
    n = seconds(0.20)
    out = silence(n)
    for k, (off, f) in enumerate(((0.0, 900), (0.055, 1250))):
        m = seconds(0.045)
        mix_into(out, mul(osc("sq", f, m), env_ad(m, 0.001, 0.999, 4.5)),
                 seconds(0.01 + off), 0.32 + k * 0.04)
    return out


def s_reload_done():
    n = seconds(0.24)
    out = silence(n)
    for k, (off, f) in enumerate(((0.0, 780), (0.06, 1040), (0.12, 1560))):
        m = seconds(0.06)
        mix_into(out, mul(osc("sq", f, m), env_ad(m, 0.001, 0.999, 4.0)),
                 int(off * SR), 0.30 + k * 0.03)
    return out


def s_hook_fire():
    n = seconds(0.20)
    a = mul(sweep("saw", 260, 1500, n, 1.2), env_ad(n, 0.04, 0.96, 2.4))
    b = mul(highpass(noise(n, 43), 0.7), env_ad(n, 0.01, 0.99, 3.2))
    return add(gain(a, 0.5), gain(b, 0.5))


def s_hook_attach():
    n = seconds(0.30)
    a = mul(osc("sin", 1750, n), env_ad(n, 0.002, 0.998, 3.0))
    b = mul(osc("sin", 2620, n), env_ad(n, 0.002, 0.998, 4.0))
    c = mul(noise(n, 57), env_ad(n, 0.001, 0.999, 6.0))
    return add(gain(a, 0.55), gain(b, 0.35), gain(c, 0.35))


def s_hook_miss():
    n = seconds(0.12)
    return mul(sweep("sin", 700, 260, n, 1.4), env_ad(n, 0.01, 0.99, 3.0))


def s_hook_release():
    n = seconds(0.14)
    return add(
        gain(mul(sweep("saw", 900, 200, n, 1.5), env_ad(n, 0.01, 0.99, 3.0)), 0.45),
        gain(mul(highpass(noise(n, 61), 0.6), env_ad(n, 0.01, 0.99, 3.0)), 0.4),
    )


def s_roll():
    n = seconds(0.32)
    body = mul(lowpass(noise(n, 73), 0.20), env_ads(n, 0.10, 0.55, 0.55, 2.0))
    tail = mul(sweep("sin", 320, 140, n, 1.3), env_ad(n, 0.05, 0.95, 2.5))
    return add(gain(body, 0.75), gain(tail, 0.25))


def s_hit_flesh():
    n = seconds(0.13)
    thump = mul(sweep("sin", 300, 90, n, 1.8), env_ad(n, 0.003, 0.997, 2.8))
    slap = mul(lowpass(noise(n, 83), 0.45), env_ad(n, 0.002, 0.998, 3.6))
    return add(gain(thump, 0.7), gain(slap, 0.6))


def s_hit_wall():
    n = seconds(0.14)
    a = mul(highpass(noise(n, 89), 0.72), env_ad(n, 0.001, 0.999, 5.0))
    b = mul(osc("sin", 1450, n), env_ad(n, 0.001, 0.999, 6.0))
    return add(gain(a, 0.55), gain(b, 0.45))


def s_death_human():
    n = seconds(0.65)
    a = mul(sweep("saw", 420, 70, n, 1.4), env_ad(n, 0.02, 0.98, 1.8))
    b = mul(lowpass(noise(n, 97), 0.25), env_ad(n, 0.01, 0.99, 2.2))
    return add(gain(dist(a, 1.4), 0.65), gain(b, 0.55))


def s_death_bot():
    n = seconds(0.75)
    parts = [
        gain(mul(sweep("sq", 780, 120, n, 1.3), env_ad(n, 0.01, 0.99, 1.7)), 0.45),
        gain(mul(noise(n, 101, hold=6), env_ad(n, 0.01, 0.99, 2.6)), 0.35),
    ]
    glitch = silence(n)
    rng = LCG(0xB07)
    t = 0.10
    while t < 0.62:
        m = seconds(rng.uniform(0.012, 0.035))
        f = rng.uniform(200, 1400)
        g = rng.uniform(0.12, 0.30)
        mix_into(glitch, mul(osc("sq", f, m), env_ad(m, 0.01, 0.99, 3.0)),
                 seconds(t), g)
        t += rng.uniform(0.035, 0.09)
    parts.append(glitch)
    return add(*parts)


def s_spawn():
    n = seconds(0.42)
    out = silence(n)
    for i, nm in enumerate(("A3", "C4", "E4", "A4")):
        m = seconds(0.14)
        mix_into(out, mul(osc("tri", note(nm), m), env_ad(m, 0.02, 0.98, 2.4)),
                 seconds(0.055 * i), 0.34)
    return out


def s_ui_click():
    n = seconds(0.05)
    return add(
        gain(mul(osc("sq", 880, n), env_ad(n, 0.002, 0.998, 4.0)), 0.5),
        gain(mul(noise(n, 103), env_ad(n, 0.001, 0.999, 6.0)), 0.25),
    )


def s_ui_hover():
    n = seconds(0.04)
    return mul(osc("sin", 1320, n), env_ad(n, 0.01, 0.99, 3.0))


def s_ui_confirm():
    n = seconds(0.22)
    out = silence(n)
    for i, f in enumerate((660.0, 990.0)):
        m = seconds(0.12)
        mix_into(out, mul(osc("tri", f, m), env_ad(m, 0.01, 0.99, 2.6)),
                 seconds(0.06 * i), 0.45)
    return out


def s_ui_back():
    n = seconds(0.20)
    out = silence(n)
    for i, f in enumerate((700.0, 440.0)):
        m = seconds(0.11)
        mix_into(out, mul(osc("tri", f, m), env_ad(m, 0.01, 0.99, 2.6)),
                 seconds(0.055 * i), 0.45)
    return out


def s_countdown():
    n = seconds(0.13)
    a = mul(osc("sq", 900, n), env_ad(n, 0.005, 0.995, 3.0))
    b = mul(osc("sin", 1800, n), env_ad(n, 0.005, 0.995, 4.0))
    return add(gain(a, 0.5), gain(b, 0.3))


def s_round_win():
    n = seconds(1.05)
    out = silence(n)
    for i, nm in enumerate(("C5", "E5", "G5", "C6")):
        m = seconds(0.42)
        mix_into(out, mul(osc("tri", note(nm), m), env_ad(m, 0.02, 0.98, 2.0)),
                 seconds(0.10 * i), 0.34)
    return out


def s_round_lose():
    n = seconds(1.10)
    out = silence(n)
    for i, nm in enumerate(("A4", "F4", "D4", "A3")):
        m = seconds(0.48)
        mix_into(out, mul(osc("saw", note(nm), m), env_ad(m, 0.03, 0.97, 2.0)),
                 seconds(0.11 * i), 0.28)
    return out


def s_flag_capture():
    n = seconds(0.55)
    return add(
        gain(mul(sweep("tri", 500, 1400, n, 1.2), env_ad(n, 0.05, 0.95, 1.8)), 0.5),
        gain(mul(noise(n, 109), env_ad(n, 0.01, 0.99, 4.0)), 0.2),
    )


# ===========================================================================
# music
# ===========================================================================


def _kick():
    n = seconds(0.18)
    return add(gain(mul(sweep("sin", 150, 42, n, 1.6), env_ad(n, 0.002, 0.998, 2.6)), 1.0),
               gain(mul(noise(n, 5), env_ad(n, 0.001, 0.999, 8.0)), 0.18))


def _snare():
    n = seconds(0.13)
    return add(gain(mul(highpass(noise(n, 17), 0.60), env_ad(n, 0.002, 0.998, 3.4)), 0.75),
               gain(mul(osc("tri", 190, n), env_ad(n, 0.002, 0.998, 3.0)), 0.30))


def _hat():
    n = seconds(0.045)
    return gain(mul(highpass(noise(n, 29), 0.86), env_ad(n, 0.001, 0.999, 5.0)), 0.34)


def _pluck(freq, dur, kind="sq", decay=3.0, g=0.30):
    n = seconds(dur)
    return gain(mul(osc(kind, freq, n), env_ad(n, 0.004, 0.996, decay)), g)


def music_battle():
    """Driving chiptune battle loop, A minor, 128 BPM, 8 bars."""
    bpm = 128.0
    step = 60.0 / bpm / 4.0          # sixteenth note
    bars = 8
    total = seconds(step * 16 * bars)
    out = silence(total)

    # chord roots per bar: Am  Am  F  F  C  C  G  G  (i i VI VI III III VII VII)
    roots = ["A2", "A2", "F2", "F2", "C3", "C3", "G2", "G2"]
    chords = [
        ("A3", "C4", "E4"), ("A3", "C4", "E4"),
        ("F3", "A3", "C4"), ("F3", "A3", "C4"),
        ("C4", "E4", "G4"), ("C4", "E4", "G4"),
        ("G3", "B3", "D4"), ("G3", "B3", "D4"),
    ]

    def at(bar, s16):
        return seconds(step * (bar * 16 + s16))

    for bar in range(bars):
        # bass: driving eighths with an octave pop on the "and" of 4
        for s in range(0, 16, 2):
            nm = roots[bar] if s % 8 != 6 else _octave_up(roots[bar])
            dur = step * 1.7
            mix_into(out, _pluck(note(nm), dur, "saw", 3.4, 0.24), at(bar, s))

        # arpeggio: sixteenths, up-up-down shape
        pat = [0, 1, 2, 1, 0, 1, 2, 1, 0, 1, 2, 1, 2, 1, 0, 1]
        for s in range(16):
            nm = chords[bar][pat[s]]
            mix_into(out, _pluck(note(nm), step * 1.1, "sq", 4.2, 0.085),
                     at(bar, s))

        # lead motif: bars 3 and 7 carry the hook
        if bar in (3, 7):
            melody = [("E5", 0, 4), ("D5", 4, 2), ("C5", 6, 2),
                      ("B4", 8, 4), ("A4", 12, 4)]
            for nm, s, ln in melody:
                mix_into(out, _pluck(note(nm), step * ln * 0.94, "tri", 2.2, 0.22),
                         at(bar, s))

        # drums
        for s in (0, 6, 8, 11, 14):
            mix_into(out, _kick(), at(bar, s), 0.85)
        for s in (4, 12):
            mix_into(out, _snare(), at(bar, s), 0.70)
        for s in range(0, 16, 2):
            mix_into(out, _hat(), at(bar, s), 0.55 if s % 4 else 0.75)

    # gentle low-pass on the whole thing so it sits behind the SFX
    out = lowpass(out, 0.72)
    return make_loop(out, 55)


def _octave_up(nm):
    letter = nm[0]
    rest = nm[1:-1]
    octave = int(nm[-1])
    return "%s%s%d" % (letter, rest, octave + 1)


def music_menu():
    """Slow, spacious menu loop: sustained pads plus a sparse bell motif."""
    bpm = 74.0
    bar = 60.0 / bpm * 4.0
    bars = 8
    total = seconds(bar * bars)
    out = silence(total)

    prog = [
        ("A2", "C4", "E4"),
        ("F2", "A3", "C4"),
        ("C3", "E4", "G4"),
        ("G2", "B3", "D4"),
        ("A2", "C4", "E4"),
        ("F2", "A3", "C4"),
        ("D3", "F3", "A3"),
        ("E3", "G3", "B3"),
    ]

    for b, chord in enumerate(prog):
        start = seconds(bar * b)
        # pad
        for nm in chord:
            n = seconds(bar * 1.06)
            pad = mul(osc("tri", note(nm), n, detune=0.004),
                      env_ads(n, 0.28, 0.70, 0.34, 1.6))
            mix_into(out, pad, start, 0.115)
            pad2 = mul(osc("sin", note(nm) * 0.5, n), env_ads(n, 0.30, 0.66, 0.36, 1.7))
            mix_into(out, pad2, start, 0.10)
        # sparse bell
        if b % 2 == 1:
            bell = mul(osc("sin", note("E5"), seconds(1.5)),
                       env_ad(seconds(1.5), 0.01, 0.99, 3.0))
            mix_into(out, bell, seconds(bar * b + bar * 0.5), 0.14)
        if b == 5:
            bell = mul(osc("sin", note("A5"), seconds(1.7)),
                       env_ad(seconds(1.7), 0.01, 0.99, 3.2))
            mix_into(out, bell, seconds(bar * b + bar * 0.25), 0.12)

    out = lowpass(out, 0.42)
    return make_loop(out, 90)


def music_victory():
    """Short stinger, not looped."""
    n = seconds(2.4)
    out = silence(n)
    for i, nm in enumerate(("C5", "E5", "G5", "C6", "G5", "C6")):
        m = seconds(0.5)
        mix_into(out, mul(osc("tri", note(nm), m), env_ad(m, 0.015, 0.985, 2.0)),
                 seconds(0.16 * i), 0.22)
    for i, nm in enumerate(("C3", "G3", "C4")):
        m = seconds(1.1)
        mix_into(out, mul(osc("saw", note(nm), m), env_ads(m, 0.05, 0.7, 0.3, 1.8)),
                 seconds(0.6 + 0.25 * i), 0.12)
    return lowpass(out, 0.6)


# ===========================================================================
# table
# ===========================================================================

SFX = [
    ("melee_swing", s_melee_swing, False),
    ("melee_hit", s_melee_hit, False),
    ("gun_shot", s_gun_shot, False),
    ("gun_empty", s_gun_empty, False),
    ("reload_start", s_reload_start, False),
    ("reload_done", s_reload_done, False),
    ("hook_fire", s_hook_fire, False),
    ("hook_attach", s_hook_attach, False),
    ("hook_miss", s_hook_miss, False),
    ("hook_release", s_hook_release, False),
    ("roll", s_roll, False),
    ("hit_flesh", s_hit_flesh, False),
    ("hit_wall", s_hit_wall, False),
    ("death_human", s_death_human, False),
    ("death_bot", s_death_bot, False),
    ("spawn", s_spawn, False),
    ("ui_click", s_ui_click, False),
    ("ui_hover", s_ui_hover, False),
    ("ui_confirm", s_ui_confirm, False),
    ("ui_back", s_ui_back, False),
    ("countdown", s_countdown, False),
    ("round_win", s_round_win, False),
    ("round_lose", s_round_lose, False),
    ("flag_capture", s_flag_capture, False),
    ("music_menu", music_menu, True),
    ("music_battle", music_battle, True),
    ("music_victory", music_victory, False),
]


def main():
    print("=== CakeGame sound generator ===")
    ensure_dir(os.path.join(SFX_DIR, "x"))
    total = 0
    rows = []
    for name, fn, loop in SFX:
        sig = fn()
        if not loop:
            sig = fade_edges(sig, 3.0)
        path = os.path.join(SFX_DIR, name + ".wav")
        size = write_wav(path, sig, loop=loop)
        total += size
        rows.append((name, len(sig) / float(SR), size, loop))

    for name, dur, size, loop in rows:
        log("%-16s %6.2fs %8.1f KB%s" % (name, dur, size / 1024.0,
                                         "  [loop]" if loop else ""))
    log("total %.1f MB across %d files" % (total / 1048576.0, len(rows)))
    print("=== done ===")


if __name__ == "__main__":
    main()
