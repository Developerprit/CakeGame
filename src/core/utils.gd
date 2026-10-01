class_name Utils
extends RefCounted
## Shared static helpers. Everything here is static so nothing needs an instance.
##
## Scale convention for the whole project: **1 tile = 16 world pixels = 1 metre**.
## Use `Utils.m(4.0)` instead of writing `64.0`, so balance numbers stay readable
## and can be compared against real m/s values directly.

const TILE: int = 16
const TILE_F: float = 16.0

## Index order matches Enums.Facing / the sprite atlas rows:
## E, SE, S, SW, W, NW, N, NE  (clockwise on screen, y grows downward).
const DIRS8: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, 1), Vector2i(-1, 1),
	Vector2i(-1, 0), Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
]

## 4-way cardinal set used by flood fills / map generation.
const DIRS4: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(0, -1),
]

const EPSILON: float = 0.0001


## Metres -> world pixels.
static func m(v: float) -> float:
	return v * TILE_F


## World pixels -> metres (handy when printing debug values).
static func to_m(v: float) -> float:
	return v / TILE_F


static func tile_of(pos: Vector2) -> Vector2i:
	return Vector2i(floori(pos.x / TILE_F), floori(pos.y / TILE_F))


static func tile_center(cell: Vector2i) -> Vector2:
	return Vector2(cell.x * TILE_F + TILE_F * 0.5, cell.y * TILE_F + TILE_F * 0.5)


## Nearest of the 8 sprite facings for an arbitrary direction vector.
static func facing_from_dir(dir: Vector2) -> int:
	if dir.length_squared() < EPSILON:
		return Enums.Facing.S
	var step := PI / 4.0
	var idx := int(roundf(dir.angle() / step))
	return posmod(idx, 8)


static func dir_from_facing(f: int) -> Vector2:
	var d: Vector2i = DIRS8[posmod(f, 8)]
	return Vector2(d.x, d.y).normalized()


## Shortest signed angular distance from a to b, in radians, range [-PI, PI].
static func angle_delta(a: float, b: float) -> float:
	return wrapf(b - a, -PI, PI)


## Deterministic seed from an arbitrary string, so map seed text is reproducible
## across machines (`abs()` because Godot hashes can be negative).
static func seed_from_string(s: String) -> int:
	return absi(hash(s.strip_edges().to_lower()))


## Turn an arbitrary user string into a short numeric seed. Empty input and
## "0" both mean "pick one from the clock".
static func resolve_seed(text: String) -> int:
	var t := text.strip_edges()
	if t.is_empty():
		return 0
	if t.is_valid_int():
		return absi(t.to_int())
	return seed_from_string(t)


static func rng(seed_value: int) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = seed_value
	return r


## Random 6-character room code using an unambiguous alphabet (no 0/O/1/I/L).
const ROOM_ALPHABET := "ABCDEFGHJKMNPQRSTUVWXYZ23456789"

static func random_room_code(r: RandomNumberGenerator) -> String:
	var out := ""
	for i in 6:
		out += ROOM_ALPHABET[r.randi_range(0, ROOM_ALPHABET.length() - 1)]
	return out


## Normalise a room code typed by a human (uppercase, strip spaces / dashes).
static func clean_room_code(text: String) -> String:
	var t := text.strip_edges().to_upper()
	t = t.replace(" ", "").replace("-", "")
	return t


static func format_clock(seconds: float) -> String:
	var s := maxi(0, floori(seconds))
	return "%d:%02d" % [s / 60, s % 60]


static func format_ms(msec: int) -> String:
	return "%dms" % msec


## Convenience: pick a pseudo-random item with a seeded rng.
static func pick(r: RandomNumberGenerator, arr: Array) -> Variant:
	if arr.is_empty():
		return null
	return arr[r.randi_range(0, arr.size() - 1)]


static func shuffle_seeded(arr: Array, r: RandomNumberGenerator) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j := r.randi_range(0, i)
		var tmp: Variant = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp


## Grow a float toward a target by at most `delta` — the scalar equivalent of
## `move_toward`, used all over the AI so accelerations read clearly.
static func approach(current: float, target: float, delta: float) -> float:
	if current < target:
		return minf(current + delta, target)
	return maxf(current - delta, target)


static func approach_v2(current: Vector2, target: Vector2, delta: float) -> Vector2:
	return current.move_toward(target, delta)


## Snap a position to the nearest walkable cell centre given a predicate.
## Returns the input unchanged when no candidate within `radius` is walkable.
static func snap_to_walkable(pos: Vector2, is_walkable: Callable, radius: int = 2) -> Vector2:
	if is_walkable.call(tile_of(pos)):
		return pos
	for r in range(1, radius + 1):
		for d: Vector2i in DIRS8:
			var c := tile_of(pos) + d * r
			if is_walkable.call(c):
				return tile_center(c)
	return pos


## True when `target` lies inside a cone of half-angle `half_angle_rad` centred
## on `facing_rad`. Used for melee arcs and the bot's "is he aiming at me" check.
static func in_cone(origin: Vector2, facing_rad: float, target: Vector2, half_angle_rad: float) -> bool:
	var to_target := target - origin
	if to_target.length_squared() < EPSILON:
		return true
	return absf(angle_delta(facing_rad, to_target.angle())) <= half_angle_rad
