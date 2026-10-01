class_name Enums
extends RefCounted
## Central enum registry. All enums live here so every system shares one truth.
## Access statically, e.g. `Enums.Team.HUMANS`.


## 8-way sprite facing. Index order matches Utils.DIRS8 and the atlas row order.
## Index 0 is East (+x) and the index increases clockwise on screen (y grows down).
enum Facing { E = 0, SE = 1, S = 2, SW = 3, W = 4, NW = 5, N = 6, NE = 7 }

## Match sides. Humans always fight bots (the negotiated rule).
enum Team { HUMANS = 0, BOTS = 1 }

## What kind of controller drives an actor.
enum Kind { LOCAL_HUMAN = 0, REMOTE_HUMAN = 1, BOT = 2 }

enum Weapon { MELEE = 0, GUN = 1 }

enum DamageKind { MELEE = 0, BULLET = 1, HOOK = 2, ENVIRONMENT = 3 }

enum MatchPhase { LOBBY = 0, COUNTDOWN = 1, LIVE = 2, ROUND_OVER = 3, MATCH_OVER = 4 }

## How this machine is attached to the session. Drives what the UI shows and
## which peer owns authority.
enum NetMode {
	OFFLINE = 0,       ## single machine, no networking at all
	LAN_HOST = 1,
	LAN_CLIENT = 2,
	P2P_HOST = 3,      ## direct connection after successful UDP hole punching
	P2P_CLIENT = 4,
	RELAY_HOST = 5,    ## fell back to the WebSocket relay
	RELAY_CLIENT = 6,
}

## Vertical origin for tile variants. A wall tile picks its look from whether
## the tiles above / below are open, so multi-tile-tall walls do not stack bevels.
enum WallVariant { MID = 0, TOP = 1, BOTTOM = 2 }

enum HitFx { SPARK = 0, BLOOD = 1, RING = 2 }


static func team_name(t: int) -> String:
	return "HUMANS" if t == Team.HUMANS else "BOTS"


static func team_color(t: int) -> Color:
	if t == Team.HUMANS:
		return Color("4fd6f0")
	return Color("f0714f")


static func team_dark(t: int) -> Color:
	if t == Team.HUMANS:
		return Color("1d5a6b")
	return Color("6b2f1d")


static func is_host_mode(m: int) -> bool:
	return m == NetMode.LAN_HOST or m == NetMode.P2P_HOST or m == NetMode.RELAY_HOST


static func is_client_mode(m: int) -> bool:
	return m == NetMode.LAN_CLIENT or m == NetMode.P2P_CLIENT or m == NetMode.RELAY_CLIENT


static func is_networked(m: int) -> bool:
	return m != NetMode.OFFLINE


static func net_mode_label(m: int) -> String:
	match m:
		NetMode.OFFLINE:
			return "OFFLINE"
		NetMode.LAN_HOST:
			return "LAN HOST"
		NetMode.LAN_CLIENT:
			return "LAN CLIENT"
		NetMode.P2P_HOST:
			return "P2P HOST"
		NetMode.P2P_CLIENT:
			return "P2P CLIENT"
		NetMode.RELAY_HOST:
			return "RELAY HOST"
		NetMode.RELAY_CLIENT:
			return "RELAY CLIENT"
	return "?"
