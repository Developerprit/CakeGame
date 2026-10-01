extends Node
## Audio playback + bus routing (autoload `AudioDirector`).
##
## SFX live in a fixed pool of players so a burst of hits never allocates during
## combat. Streams are cached lazily; a missing file degrades to silence with a
## single warning instead of crashing, because the asset pipeline generates these
## files and a partial generation run must not brick the game.

const POOL_SIZE: int = 20
const SFX_DIR: String = "res://assets/sfx/"

var _pool: Array[AudioStreamPlayer] = []
var _next: int = 0
var _music: AudioStreamPlayer
var _music_name: String = ""
var _cache: Dictionary = {}
var _missing: Dictionary = {}

var bus_master: int = 0
var bus_sfx: int = 0
var bus_music: int = 0


func _ready() -> void:
	_ensure_bus(&"SFX", &"Master")
	_ensure_bus(&"Music", &"Master")
	bus_master = AudioServer.get_bus_index(&"Master")
	bus_sfx = AudioServer.get_bus_index(&"SFX")
	bus_music = AudioServer.get_bus_index(&"Music")

	for i in POOL_SIZE:
		var p := AudioStreamPlayer.new()
		p.bus = &"SFX"
		add_child(p)
		_pool.append(p)

	_music = AudioStreamPlayer.new()
	_music.bus = &"Music"
	add_child(_music)

	apply_volumes()
	EventBus.settings_changed.connect(apply_volumes)


func _ensure_bus(bus_name: StringName, send_to: StringName) -> void:
	if AudioServer.get_bus_index(bus_name) != -1:
		return
	var idx := AudioServer.bus_count
	AudioServer.add_bus(idx)
	AudioServer.set_bus_name(idx, bus_name)
	AudioServer.set_bus_send(idx, send_to)


func apply_volumes() -> void:
	_set_linear(bus_master, GameConfig.master_volume)
	_set_linear(bus_sfx, GameConfig.sfx_volume)
	_set_linear(bus_music, GameConfig.music_volume)


func _set_linear(bus: int, linear: float) -> void:
	if bus < 0:
		return
	AudioServer.set_bus_mute(bus, linear <= 0.001)
	AudioServer.set_bus_volume_db(bus, linear_to_db(clampf(linear, 0.0001, 1.0)))


# ---------------------------------------------------------------------------
# one-shots
# ---------------------------------------------------------------------------

## Play a one-shot. `pitch` may be a fixed value or a [min,max] Array for
## variation; variation is what stops repeated gunshots sounding robotic.
func play(sfx: String, volume_db: float = 0.0, pitch: Variant = 1.0) -> void:
	var stream := _stream(sfx)
	if stream == null:
		return
	var p := _pool[_next]
	_next = (_next + 1) % _pool.size()
	p.stream = stream
	if pitch is Array:
		var arr: Array = pitch
		if arr.size() >= 2:
			p.pitch_scale = randf_range(float(arr[0]), float(arr[1]))
		else:
			p.pitch_scale = 1.0
	else:
		p.pitch_scale = float(pitch)
	p.volume_db = volume_db
	p.play()


## Play a one-shot positioned in the world, attenuated by distance to the
## listener (the camera centre). Falls back to a plain 2D-less play when the
## listener position is unknown.
func play_at(sfx: String, world_pos: Vector2, listener: Vector2,
		max_dist: float = 260.0, volume_db: float = 0.0) -> void:
	var d := world_pos.distance_to(listener)
	if d > max_dist:
		return
	var att := -18.0 * (d / max_dist)
	play(sfx, volume_db + att)


# ---------------------------------------------------------------------------
# music
# ---------------------------------------------------------------------------

func play_music(name: String, fade: float = 0.4) -> void:
	if _music_name == name and _music.playing:
		return
	var stream := _stream(name, true)
	if stream == null:
		return
	_music_name = name
	_music.stream = stream
	if not GameConfig.is_headless() and fade > 0.0:
		_music.volume_db = -60.0
		_music.play()
		var tw := create_tween()
		tw.tween_property(_music, "volume_db", 0.0, fade)
	else:
		_music.volume_db = 0.0
		_music.play()


func stop_music(fade: float = 0.4) -> void:
	_music_name = ""
	if not _music.playing:
		return
	if GameConfig.is_headless() or fade <= 0.0:
		_music.stop()
		return
	var tw := create_tween()
	tw.tween_property(_music, "volume_db", -60.0, fade)
	tw.tween_callback(_music.stop)


# ---------------------------------------------------------------------------
# loading
# ---------------------------------------------------------------------------

func _stream(sfx: String, is_music: bool = false) -> AudioStream:
	if _cache.has(sfx):
		return _cache[sfx] as AudioStream
	if _missing.has(sfx):
		return null
	var path := SFX_DIR + sfx + ".wav"
	if not ResourceLoader.exists(path):
		_missing[sfx] = true
		push_warning("[AudioDirector] missing stream: %s" % path)
		return null
	var res := load(path)
	if res == null or not (res is AudioStream):
		_missing[sfx] = true
		push_warning("[AudioDirector] not an AudioStream: %s" % path)
		return null
	var stream := res as AudioStream
	# Belt and braces: music files are authored with a loop hint, but if the
	# importer ignored it we still loop by hand on `finished`.
	if is_music and stream is AudioStreamWAV:
		var wav := stream as AudioStreamWAV
		if wav.loop_mode == AudioStreamWAV.LOOP_DISABLED:
			wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
			wav.loop_end = wav.data.size() / 2
	if not _music.finished.is_connected(_on_music_finished):
		_music.finished.connect(_on_music_finished)
	_cache[sfx] = stream
	return stream


func _on_music_finished() -> void:
	if _music_name.is_empty() or _music.stream == null:
		return
	# Only reached when the stream did not declare a loop point.
	_music.play()
