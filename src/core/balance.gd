class_name Balance
extends RefCounted
## Every tuning number in the game, in one place.
##
## Distances are authored in WORLD PIXELS at the project scale of
## **1 tile = 16 px = 1 metre**, and the m/s equivalents are given in comments so
## a number can be sanity-checked against real-world intuition without mental
## arithmetic. Anything the AI or the HUD needs to reason about lives here rather
## than being duplicated at the call site - duplicated balance numbers drift and
## then the AI's lead prediction quietly disagrees with the real bullet speed.

# ---------------------------------------------------------------------------
# actor
# ---------------------------------------------------------------------------
const MAX_HP: float = 100.0
const BODY_RADIUS: float = 5.0
const MOVE_SPEED: float = 57.6          ## 3.6 m/s
const ACCEL: float = 480.0              ## 30 m/s^2 - twin-stick responsiveness
const FRICTION: float = 560.0           ## 35 m/s^2
const TURN_RATE: float = 22.0           ## rad/s the aim can slew (gamepad only)
const SPAWN_INVULN: float = 1.2
const CORPSE_LINGER: float = 0.9

# ---------------------------------------------------------------------------
# melee  (mouse right button)
# ---------------------------------------------------------------------------
const MELEE_DAMAGE: float = 22.0
const MELEE_RANGE: float = 24.0
const MELEE_HALF_ARC: float = 0.95      ## radians, ~109 degree total sweep
const MELEE_WINDUP: float = 0.12
const MELEE_ACTIVE: float = 0.10
const MELEE_RECOVER: float = 0.16
const MELEE_TOTAL: float = 0.38
const MELEE_COOLDOWN: float = 0.55
const MELEE_KNOCKBACK: float = 150.0

# ---------------------------------------------------------------------------
# gun  (E draws, left mouse fires)
# ---------------------------------------------------------------------------
const BULLET_DAMAGE: float = 12.0
const BULLET_SPEED: float = 320.0       ## 20 m/s - the AI leads targets by this
const BULLET_RANGE: float = 200.0
const BULLET_RADIUS: float = 2.4
const GUN_SPREAD_DEG: float = 3.0
const GUN_COOLDOWN: float = 0.22
const GUN_MAG: int = 12
const GUN_RELOAD: float = 1.40
const GUN_DRAW_TIME: float = 0.18       ## must draw before the first shot
const GUN_RECOIL_KNOCKBACK: float = 26.0
const GUN_BLOOM_PER_SHOT: float = 0.55  ## degrees added per shot, decays
const GUN_BLOOM_MAX: float = 3.0

# ---------------------------------------------------------------------------
# grapple hook  (Q)
# ---------------------------------------------------------------------------
const HOOK_DAMAGE: float = 8.0
const HOOK_SPEED: float = 520.0
const HOOK_MAX_RANGE: float = 116.0
const HOOK_COOLDOWN: float = 3.2
const HOOK_PULL_ACCEL: float = 1200.0   ## 75 m/s^2 - the "inertia" the spec asks for
const HOOK_PULL_MAX_SPEED: float = 300.0
const HOOK_KEEP_MOMENTUM: float = 0.62  ## fraction of pull speed kept on release
const HOOK_VICTIM_PULL: float = 260.0   ## speed an enemy is yanked toward you
const HOOK_VICTIM_STUN: float = 0.22
const HOOK_REEL_TIME: float = 0.55      ## max time a hook stays attached to a wall

# ---------------------------------------------------------------------------
# roll  (Shift)
# ---------------------------------------------------------------------------
const ROLL_SPEED: float = 132.0         ## 8.25 m/s
const ROLL_DURATION: float = 0.42
const ROLL_IFRAMES: float = 0.30        ## invulnerability window
const ROLL_COOLDOWN: float = 0.90
const ROLL_END_SPEED_KEEP: float = 0.45

# ---------------------------------------------------------------------------
# feel
# ---------------------------------------------------------------------------
const HITSTOP_MELEE: float = 0.075
const HITSTOP_BULLET: float = 0.030
const HITSTOP_KILL: float = 0.16
const SHAKE_MELEE: float = 3.0
const SHAKE_BULLET: float = 1.2
const SHAKE_KILL: float = 5.5
const DMG_NUMBER_LIFE: float = 0.75

# ---------------------------------------------------------------------------
# AI  (fixed; the spec says difficulty is NOT player-adjustable)
# ---------------------------------------------------------------------------
const AI_THINK_INTERVAL: float = 0.06
const AI_REACTION_TIME: float = 0.12    ## deliberately a bit superhuman, not instant
const AI_MAX_RANGE_ENGAGE: float = 230.0
const AI_PREFERRED_MIN: float = 58.0
const AI_PREFERRED_MAX: float = 92.0
const AI_MELEE_RANGE: float = 20.0
const AI_AIM_LEAD_WEIGHT: float = 1.0
const AI_AIM_SECOND_ORDER: float = 0.35 ## extra lead from target acceleration
const AI_DODGE_AIM_CONE: float = 0.22   ## rad; "he is pointing at me"
const AI_DODGE_REACTION: float = 0.10
const AI_LOW_HP: float = 45.0
const AI_RETREAT_HP: float = 30.0
const AI_BULLET_DODGE_LOOKAHEAD: float = 0.30
const AI_BULLET_DODGE_MARGIN: float = 11.0
const AI_CORNER_BREAK_TIME: float = 0.70
const AI_PATH_REFRESH: float = 0.32
const AI_STUCK_WINDOW: float = 1.5
const AI_STUCK_MIN_NET: float = 12.0
const AI_STUCK_STRIKES: int = 3
const AI_PEEK_TIME: float = 0.85        ## how long it holds cover before re-peeking
## How long a bot keeps extrapolating along a lead it can no longer see before it
## gives up on that lead and sweeps the enemy side instead. Without it, a bot
## that kills everyone keeps orbiting the spot where the last enemy died for the
## rest of the round.
const AI_HUNT_COLD: float = 3.5
const AI_PATH_LOOKAHEAD: float = 96.0   ## how far ahead a fallback path aims
const AI_PATH_LOOKAHEAD_WP: int = 6     ## waypoints considered when smoothing
## How far in front of the actor to probe for a wall when deciding between a
## straight line and an A* detour. Must be a little larger than the body radius
## or the bot clips corners it thinks are clear.
const TILE_PROBE: float = 5.0

# ---------------------------------------------------------------------------
# match
# ---------------------------------------------------------------------------
const COUNTDOWN_TIME: float = 3.0
const ROUND_OVER_TIME: float = 3.4
const SCORE_TO_WIN: int = 5
