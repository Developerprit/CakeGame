class_name AtlasLibrary
extends RefCounted
## Sprite / tile / fx access, driven by the generated sprite manifest.
##
## AtlasTexture objects are cached by region so that a 6-frame run cycle shared
## by eight actors allocates six textures, not forty-eight. Every frame texture
## sets `filter_clip` so the region edge cannot bleed in a neighbouring frame
## once the canvas is scaled up.

const MANIFEST_PATH: String = "res://src/data/sprite_manifest.json"
const FALLBACK_COLOR: Color = Color(1.0, 0.0, 1.0, 1.0)

## Playback rate per animation. The state machine drives logic timing; this only
## decides how fast the atlas is walked so the visuals land on the logic beats.
const ANIM_FPS: Dictionary = {
	"idle": 4.0,
	"run": 12.0,
	"melee": 11.0,      ## 4 frames over 0.38 s
	"gun_idle": 6.0,
	"gun_fire": 14.0,   ## 3 frames over 0.22 s
	"roll": 12.0,       ## 5 frames over 0.42 s
	"hook": 8.5,
	"hurt": 12.0,
	"dead": 5.5,
}

static var _man: Dictionary = {}
static var _textures: Dictionary = {}
static var _frames: Dictionary = {}
static var _missing_reported: Dictionary = {}


static func ready() -> bool:
	_ensure()
	return not _man.is_empty()


static func _ensure() -> void:
	if not _man.is_empty():
		return
	var f := FileAccess.open(MANIFEST_PATH, FileAccess.READ)
	if f == null:
		push_error("[AtlasLibrary] cannot open %s" % MANIFEST_PATH)
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("[AtlasLibrary] manifest is not a JSON object")
		return
	_man = parsed as Dictionary


static func manifest() -> Dictionary:
	_ensure()
	return _man


# ---------------------------------------------------------------------------
# texture loading
# ---------------------------------------------------------------------------

static func _tex(path: String) -> Texture2D:
	if _textures.has(path):
		return _textures[path] as Texture2D
	# ResourceLoader.exists() returns false until the asset has been imported
	# once, so a fresh clone must run `godot --import` before the game will show
	# anything. Report it loudly instead of silently drawing nothing.
	if not ResourceLoader.exists(path):
		if not _missing_reported.has(path):
			_missing_reported[path] = true
			push_error("[AtlasLibrary] missing texture (run --import?): %s" % path)
		return null
	var t := load(path) as Texture2D
	_textures[path] = t
	return t


static func _region(path: String, x: int, y: int, w: int, h: int) -> AtlasTexture:
	var key := "%s|%d,%d,%d,%d" % [path, x, y, w, h]
	if _frames.has(key):
		return _frames[key] as AtlasTexture
	var src := _tex(path)
	if src == null:
		return null
	var at := AtlasTexture.new()
	at.atlas = src
	at.region = Rect2(x, y, w, h)
	at.filter_clip = true
	_frames[key] = at
	return at


# ---------------------------------------------------------------------------
# fighter
# ---------------------------------------------------------------------------

static func fighter_path(team: int) -> String:
	_ensure()
	var d: Dictionary = _man.get("fighter", {})
	var atl: Dictionary = d.get("atlas", {})
	var key := "cyan" if team == Enums.Team.HUMANS else "ember"
	return str(atl.get(key, str(atl.get("cyan", ""))))


static func anim_frames(anim: String) -> int:
	_ensure()
	var d: Dictionary = _man.get("fighter", {})
	var m: Dictionary = d.get("anim_frames", {})
	return int(m.get(anim, 1))


static func anim_fps(anim: String) -> float:
	return float(ANIM_FPS.get(anim, 6.0))


## "loop" | "once" | "hold". Non-looping animations must clamp their frame index
## to the last cell, otherwise a one-shot walk past the end silently wraps to
## frame 0 and the swing looks like it restarts mid-animation.
static func anim_mode(anim: String) -> String:
	_ensure()
	var d: Dictionary = _man.get("fighter", {})
	var m: Dictionary = d.get("anim_mode", {})
	return str(m.get(anim, "loop"))


static func anim_row(anim: String, facing: int) -> int:
	_ensure()
	var d: Dictionary = _man.get("fighter", {})
	var rows: Dictionary = d.get("anim_rows", {})
	return int(rows.get(anim, 0)) + posmod(facing, 8)


## Texture for one frame. `frame` wraps, so callers can pass a monotonically
## increasing counter without worrying about the cycle length.
static func fighter_frame(anim: String, facing: int, frame: int, team: int) -> AtlasTexture:
	_ensure()
	var d: Dictionary = _man.get("fighter", {})
	var fw := int(d.get("frame_w", 24))
	var fh := int(d.get("frame_h", 24))
	var nf := maxi(1, anim_frames(anim))
	var col := posmod(frame, nf)
	var row := anim_row(anim, facing)
	return _region(fighter_path(team), col * fw, row * fh, fw, fh)


static func fighter_frame_size() -> Vector2:
	_ensure()
	var d: Dictionary = _man.get("fighter", {})
	return Vector2(int(d.get("frame_w", 24)), int(d.get("frame_h", 24)))


# ---------------------------------------------------------------------------
# tiles
# ---------------------------------------------------------------------------

static func tile_coords(tile_name: String) -> Vector2i:
	_ensure()
	var d: Dictionary = _man.get("tiles", {})
	var idx: Dictionary = d.get("index", {})
	var arr: Variant = idx.get(tile_name, null)
	if typeof(arr) != TYPE_ARRAY:
		return Vector2i(-1, -1)
	var a: Array = arr
	return Vector2i(int(a[0]), int(a[1]))


static func tile_frame(tile_name: String) -> AtlasTexture:
	_ensure()
	var d: Dictionary = _man.get("tiles", {})
	var fw := int(d.get("frame_w", 16))
	var fh := int(d.get("frame_h", 16))
	var c := tile_coords(tile_name)
	if c.x < 0:
		return null
	return _region(str(d.get("atlas", "")), c.x * fw, c.y * fh, fw, fh)


static func tiles_texture_path() -> String:
	_ensure()
	var d: Dictionary = _man.get("tiles", {})
	return str(d.get("atlas", ""))


# ---------------------------------------------------------------------------
# fx
# ---------------------------------------------------------------------------

static func fx_count(fx_name: String) -> int:
	_ensure()
	var d: Dictionary = _man.get("fx", {})
	var m: Dictionary = d.get("counts", {})
	return int(m.get(fx_name, 1))


static func fx_frame(fx_name: String, index: int) -> AtlasTexture:
	_ensure()
	var d: Dictionary = _man.get("fx", {})
	var idx: Dictionary = d.get("index", {})
	var arr: Variant = idx.get(fx_name, null)
	if typeof(arr) != TYPE_ARRAY:
		return null
	var a: Array = arr
	var fw := int(d.get("frame_w", 24))
	var fh := int(d.get("frame_h", 24))
	var col := posmod(index, maxi(1, fx_count(fx_name)))
	var row := int(a[1])
	return _region(str(d.get("atlas", "")), col * fw, row * fh, fw, fh)


## The base column recorded in the manifest (all fx rows start at column 0).
static func fx_base_col(fx_name: String) -> int:
	_ensure()
	var d: Dictionary = _man.get("fx", {})
	var idx: Dictionary = d.get("index", {})
	var arr: Variant = idx.get(fx_name, null)
	if typeof(arr) != TYPE_ARRAY:
		return 0
	var a: Array = arr
	return int(a[0])


static func fx_frame_size() -> Vector2:
	_ensure()
	var d: Dictionary = _man.get("fx", {})
	return Vector2(int(d.get("frame_w", 24)), int(d.get("frame_h", 24)))


## Debug helper used by the self-check: verifies the manifest is self-consistent.
static func validate() -> Array[String]:
	var problems: Array[String] = []
	if not ready():
		problems.append("manifest missing or unreadable")
		return problems
	if _tex(fighter_path(Enums.Team.HUMANS)) == null:
		problems.append("fighter_cyan atlas not loadable")
	if _tex(fighter_path(Enums.Team.BOTS)) == null:
		problems.append("fighter_ember atlas not loadable")
	if _tex(tiles_texture_path()) == null:
		problems.append("tiles atlas not loadable")
	var d: Dictionary = _man.get("fx", {})
	if _tex(str(d.get("atlas", ""))) == null:
		problems.append("fx atlas not loadable")
	return problems
