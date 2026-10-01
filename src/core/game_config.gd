extends Node
## Persistent player settings (autoload `GameConfig`).
##
## Stored at `user://settings.cfg` through ConfigFile. Every field has a sane
## default so a fresh install is immediately playable.
##
## IMPORTANT for tests: this file is REAL user state. Any headless test that
## depends on a setting must overwrite it explicitly rather than trusting the
## default, otherwise a human's earlier session silently changes the outcome.

const CONFIG_PATH: String = "user://settings.cfg"
const SECTION: String = "cakegame"

# --- gameplay ---------------------------------------------------------------
var bot_version: String = "cakegame_v1"
var seeded_map: bool = false
var map_seed_text: String = ""
var max_players: int = 8
var human_slots: int = 3
var bot_slots: int = 2
var round_target_score: int = 5
var friendly_fire: bool = false
var respawn_enabled: bool = false
var respawn_delay: float = 3.0

# --- controls / feel --------------------------------------------------------
var mouse_sensitivity: float = 1.0
var aim_assist_gamepad: bool = true

# --- presentation ----------------------------------------------------------
var dark_theme: bool = true
var fullscreen: bool = false
var window_scale: int = 2
var master_volume: float = 0.85
var sfx_volume: float = 1.0
var music_volume: float = 0.45
var light_shadows: bool = false
var screen_shake: bool = true
var damage_numbers: bool = true
var show_fps: bool = false
var language: String = "zh"

# --- networking ------------------------------------------------------------
var player_name: String = "Player"
var server_port: int = 34567
var last_host_ip: String = ""
var last_room_code: String = ""
var signaling_url: String = "https://cakegame.rth1.xyz/api.php"
var relay_url: String = "wss://cakegame.rth1.xyz/relay.node.js"
var preferred_transport: String = "auto"   ## auto | lan | p2p | relay

## Latched map seed. See `effective_seed()` - this is not persisted, because the
## point of it is that one session keeps one map. `_session_seed_text` records the
## seed-box contents the latch was derived from, which is what makes the latch
## self-invalidating instead of depending on somebody remembering to clear it.
var _session_seed: int = 0
var _session_seed_text: String = "\u0000"
var _session_seed_valid: bool = false


func _ready() -> void:
	load_settings()


static func is_headless() -> bool:
	return DisplayServer.get_name() == "headless"


# ---------------------------------------------------------------------------
# persistence
# ---------------------------------------------------------------------------

func load_settings() -> void:
	var cf := ConfigFile.new()
	var err := cf.load(CONFIG_PATH)
	if err != OK:
		# First run: keep defaults, write them out so the file exists and is
		# discoverable by support tooling.
		save_settings()
		return
	bot_version = cf.get_value(SECTION, "bot_version", bot_version)
	seeded_map = cf.get_value(SECTION, "seeded_map", seeded_map)
	map_seed_text = cf.get_value(SECTION, "map_seed_text", map_seed_text)
	max_players = int(cf.get_value(SECTION, "max_players", max_players))
	human_slots = int(cf.get_value(SECTION, "human_slots", human_slots))
	bot_slots = int(cf.get_value(SECTION, "bot_slots", bot_slots))
	round_target_score = int(cf.get_value(SECTION, "round_target_score", round_target_score))
	friendly_fire = cf.get_value(SECTION, "friendly_fire", friendly_fire)
	respawn_enabled = cf.get_value(SECTION, "respawn_enabled", respawn_enabled)
	respawn_delay = float(cf.get_value(SECTION, "respawn_delay", respawn_delay))
	mouse_sensitivity = float(cf.get_value(SECTION, "mouse_sensitivity", mouse_sensitivity))
	aim_assist_gamepad = cf.get_value(SECTION, "aim_assist_gamepad", aim_assist_gamepad)
	dark_theme = cf.get_value(SECTION, "dark_theme", dark_theme)
	fullscreen = cf.get_value(SECTION, "fullscreen", fullscreen)
	window_scale = int(cf.get_value(SECTION, "window_scale", window_scale))
	master_volume = float(cf.get_value(SECTION, "master_volume", master_volume))
	sfx_volume = float(cf.get_value(SECTION, "sfx_volume", sfx_volume))
	music_volume = float(cf.get_value(SECTION, "music_volume", music_volume))
	light_shadows = cf.get_value(SECTION, "light_shadows", light_shadows)
	screen_shake = cf.get_value(SECTION, "screen_shake", screen_shake)
	damage_numbers = cf.get_value(SECTION, "damage_numbers", damage_numbers)
	show_fps = cf.get_value(SECTION, "show_fps", show_fps)
	language = cf.get_value(SECTION, "language", language)
	player_name = cf.get_value(SECTION, "player_name", player_name)
	server_port = int(cf.get_value(SECTION, "server_port", server_port))
	last_host_ip = cf.get_value(SECTION, "last_host_ip", last_host_ip)
	last_room_code = cf.get_value(SECTION, "last_room_code", last_room_code)
	signaling_url = cf.get_value(SECTION, "signaling_url", signaling_url)
	relay_url = cf.get_value(SECTION, "relay_url", relay_url)
	preferred_transport = cf.get_value(SECTION, "preferred_transport", preferred_transport)
	_clamp_all()
	# Anything that reloads settings may have changed the seed box, so the latch
	# has to go with it.
	_session_seed_valid = false


func save_settings() -> void:
	_clamp_all()
	# The seed box may have just been edited, so the previously latched seed is
	# no longer the one the player asked for.
	_session_seed_valid = false
	var cf := ConfigFile.new()
	cf.set_value(SECTION, "bot_version", bot_version)
	cf.set_value(SECTION, "seeded_map", seeded_map)
	cf.set_value(SECTION, "map_seed_text", map_seed_text)
	cf.set_value(SECTION, "max_players", max_players)
	cf.set_value(SECTION, "human_slots", human_slots)
	cf.set_value(SECTION, "bot_slots", bot_slots)
	cf.set_value(SECTION, "round_target_score", round_target_score)
	cf.set_value(SECTION, "friendly_fire", friendly_fire)
	cf.set_value(SECTION, "respawn_enabled", respawn_enabled)
	cf.set_value(SECTION, "respawn_delay", respawn_delay)
	cf.set_value(SECTION, "mouse_sensitivity", mouse_sensitivity)
	cf.set_value(SECTION, "aim_assist_gamepad", aim_assist_gamepad)
	cf.set_value(SECTION, "dark_theme", dark_theme)
	cf.set_value(SECTION, "fullscreen", fullscreen)
	cf.set_value(SECTION, "window_scale", window_scale)
	cf.set_value(SECTION, "master_volume", master_volume)
	cf.set_value(SECTION, "sfx_volume", sfx_volume)
	cf.set_value(SECTION, "music_volume", music_volume)
	cf.set_value(SECTION, "light_shadows", light_shadows)
	cf.set_value(SECTION, "screen_shake", screen_shake)
	cf.set_value(SECTION, "damage_numbers", damage_numbers)
	cf.set_value(SECTION, "show_fps", show_fps)
	cf.set_value(SECTION, "language", language)
	cf.set_value(SECTION, "player_name", player_name)
	cf.set_value(SECTION, "server_port", server_port)
	cf.set_value(SECTION, "last_host_ip", last_host_ip)
	cf.set_value(SECTION, "last_room_code", last_room_code)
	cf.set_value(SECTION, "signaling_url", signaling_url)
	cf.set_value(SECTION, "relay_url", relay_url)
	cf.set_value(SECTION, "preferred_transport", preferred_transport)
	cf.save(CONFIG_PATH)
	EventBus.settings_changed.emit()


func _clamp_all() -> void:
	max_players = clampi(max_players, 2, 8)
	human_slots = clampi(human_slots, 1, max_players)
	bot_slots = clampi(bot_slots, 0, mini(2, max_players - 1))
	if human_slots + bot_slots > max_players:
		bot_slots = maxi(0, max_players - human_slots)
	round_target_score = clampi(round_target_score, 1, 30)
	respawn_delay = clampf(respawn_delay, 0.5, 20.0)
	window_scale = clampi(window_scale, 1, 4)
	server_port = clampi(server_port, 1024, 65535)
	master_volume = clampf(master_volume, 0.0, 1.0)
	sfx_volume = clampf(sfx_volume, 0.0, 1.0)
	music_volume = clampf(music_volume, 0.0, 1.0)
	if player_name.strip_edges().is_empty():
		player_name = "Player"


func apply_display() -> void:
	if is_headless():
		return
	var win := get_window()
	if win == null:
		return
	win.mode = Window.MODE_EXCLUSIVE_FULLSCREEN if fullscreen else Window.MODE_WINDOWED
	if not fullscreen:
		var target := Vector2i(640 * window_scale, 360 * window_scale)
		win.size = target
		var screen := DisplayServer.screen_get_usable_rect(DisplayServer.window_get_current_screen())
		win.position = screen.position + (screen.size - target) / 2


func reset_to_defaults() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(CONFIG_PATH))
	load_settings()


## Effective map seed for the current session. Returns 0 when the seeded map is
## switched off, which `MapGenerator.generate()` treats as "use the built-in
## arena".
##
## The latch exists because of a real bug: `Utils.resolve_seed("")` returns 0, and
## 0 IS the sentinel for the hand-made arena - so ticking "seeded map" and leaving
## the seed box empty silently handed back the built-in arena instead of a random
## one, and calling this twice would have produced two different maps mid-match.
## Empty box now means "invent a seed, then keep it"; `reroll_seed()` is what a
## rematch calls to get a fresh one.
func effective_seed() -> int:
	if not seeded_map:
		_session_seed_valid = false
		return 0
	# Latch on the text it came from. The settings panel writes `map_seed_text` on
	# every keystroke but only commits on focus loss, so a bare "is the latch
	# valid?" test would hand back the seed belonging to the previous text.
	if _session_seed_valid and _session_seed_text == map_seed_text:
		return _session_seed
	var s := Utils.resolve_seed(map_seed_text)
	if s == 0:
		# A real RNG, XORed with the microsecond clock.
		#
		# The first version used `Time.get_ticks_msec()` alone, and that is a
		# same-frame constant - so `reroll_seed()` returned the seed it had just
		# invalidated whenever both calls happened in one frame, and a rematch
		# silently rebuilt the identical arena. The match simulation caught it.
		# `randi()` is safe to rely on here: Godot 4 seeds the global RNG from the
		# OS at startup.
		s = absi(randi() ^ int(Time.get_ticks_usec()))
		# Deliberately spread out and non-tiny: the generator feeds the seed
		# straight into its RNG, and small integers ("1", "2") are the first
		# thing anybody types, so they are not where a random seed should land.
		s = s % 900000000 + 100000
	_session_seed = s
	_session_seed_text = map_seed_text
	_session_seed_valid = true
	return _session_seed


## Forget the latched seed so the next `effective_seed()` invents a new one. This
## is what a rematch calls; everything else self-invalidates on a text change.
func reroll_seed() -> int:
	_session_seed_valid = false
	_session_seed_text = "\u0000"
	return effective_seed()


## True when the seed box is empty, i.e. the seed is being invented for the
## player rather than typed by them. The menus use it to show "RANDOM".
func seed_is_random() -> bool:
	return seeded_map and map_seed_text.strip_edges().is_empty()
