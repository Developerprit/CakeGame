"""CakeGame example bot brain - "Brawler".

The host calls ``bot_decide`` roughly every 0.06 s with an observation dict and
uses whatever comes back until the next reply lands. Values are clamped by the
host, so returning silly numbers is harmless - it just gets clipped.

Observation keys (all floats / bools, JSON-safe)::

    {"self":   {"pos": [x, y], "vel": [x, y], "hp": f, "max_hp": f, "state": str,
                "roll_cd": f, "gun_cd": f, "melee_cd": f, "hook_cd": f,
                "ammo": i, "reloading": b},
     "target": {"pos": [x, y], "vel": [x, y], "hp": f, "state": str,
                "visible": b, "dist": f},
     "arena":  {"w": f, "h": f},
     "tick":   i}

Reply::

    {"move": [x, y], "aim": [x, y], "gun": b, "melee": b, "hook": b, "roll": b}
"""

from btps import install_context

ctx = None

# State names the host's ActorBody.state_id() can report.
COMMITTED = ("melee", "roll", "hook", "stun")


def btps_setup(context):
    global ctx
    ctx = context
    install_context(context)
    context.log.info("brawler brain loaded")
    return {"brain": "brawler"}


def on_load(context):
    context.log.info("brawler v%s ready", context.version)


def on_enable(context):
    n = context.storage.get("enables", 0) + 1
    context.storage.set("enables", n)
    context.log.info("brawler enabled (%d time(s))", n)


def on_disable():
    pass


def _vec(pair, default=(0.0, 0.0)):
    try:
        return float(pair[0]), float(pair[1])
    except (TypeError, ValueError, IndexError):
        return default


def bot_decide(obs):
    """Return one intent for this tick."""
    me = obs.get("self") or {}
    foe = obs.get("target") or {}
    arena = obs.get("arena") or {}

    my_pos = _vec(me.get("pos"))
    foe_pos = _vec(foe.get("pos"), my_pos)
    my_hp = float(me.get("hp", 0.0))
    max_hp = float(me.get("max_hp", 1.0)) or 1.0
    dist = float(foe.get("dist", 0.0))
    visible = bool(foe.get("visible", False))
    foe_state = str(foe.get("state", ""))

    preferred = 62.0
    aggression = 0.7
    if ctx is not None:
        preferred = float(ctx.settings.get("preferred_range", preferred))
        aggression = float(ctx.settings.get("aggression", aggression))

    # Aim where he is going, not where he is - a 0.28 s bullet flight at
    # ~58 px/s is 16 px of drift, which is twice his silhouette.
    foe_vel = _vec(foe.get("vel"))
    lead = 0.22 if dist > 40.0 else 0.08
    aim = (foe_pos[0] + foe_vel[0] * lead, foe_pos[1] + foe_vel[1] * lead)

    dx = foe_pos[0] - my_pos[0]
    dy = foe_pos[1] - my_pos[1]
    length = (dx * dx + dy * dy) ** 0.5
    if length < 0.001:
        unit = (0.0, 0.0)
    else:
        unit = (dx / length, dy / length)

    # Hold the preferred band: back off when closer, close in when further.
    error = dist - preferred
    if abs(error) < 8.0:
        # Strafe instead of walking straight at him.
        move = (-unit[1] * 0.8, unit[0] * 0.8)
    else:
        toward = 1.0 if error > 0 else -1.0
        move = (unit[0] * toward, unit[1] * toward)

    # Never walk into a wall: steer back toward the middle near the edge.
    w = float(arena.get("w", 0.0))
    h = float(arena.get("h", 0.0))
    if w > 0.0 and h > 0.0:
        margin = 48.0
        if my_pos[0] < margin:
            move = (move[0] + 1.0, move[1])
        elif my_pos[0] > w - margin:
            move = (move[0] - 1.0, move[1])
        if my_pos[1] < margin:
            move = (move[0], move[1] + 1.0)
        elif my_pos[1] > h - margin:
            move = (move[0], move[1] - 1.0)

    roll = False
    # He is mid-swing and close: get out of the arc.
    if foe_state in COMMITTED and dist < 58.0 and float(me.get("roll_cd", 1.0)) <= 0.0:
        roll = True
    # Low health: disengage, but only if the escape is actually available.
    if my_hp < max_hp * 0.3 and float(me.get("roll_cd", 1.0)) <= 0.0 and dist < 90.0:
        roll = True
        move = (-unit[0], -unit[1])

    melee = visible and dist < 34.0 and float(me.get("melee_cd", 1.0)) <= 0.0
    gun = (
        visible
        and not melee
        and bool(me.get("ammo", 0))
        and not bool(me.get("reloading", False))
        and float(me.get("gun_cd", 1.0)) <= 0.0
        and dist < 320.0
    )
    hook = (
        visible
        and dist > 90.0
        and dist < 240.0
        and float(me.get("hook_cd", 1.0)) <= 0.0
        and aggression > 0.5
    )

    return {
        "move": [move[0], move[1]],
        "aim": [aim[0], aim[1]],
        "gun": gun,
        "melee": melee,
        "hook": hook,
        "roll": roll,
        "note": "brawler",
    }
