extends Node
## Scene transitions with a fade (autoload `SceneRouter`).
##
## Headless safety: tweens require a display loop to advance, so under
## `--headless` they NEVER complete and `await tween.finished` would hang
## forever, silently wedging the whole test. Every path here has an explicit
## headless branch that changes scene directly.

const MENU: String = "res://scenes/main_menu.tscn"
const LOBBY: String = "res://scenes/lobby.tscn"
const GAME: String = "res://scenes/game.tscn"

var _fade: ColorRect
var _busy: bool = false


func _ready() -> void:
	# ALWAYS, and this is not cosmetic. Pausing the game sets `get_tree().paused`,
	# and this node's tweens run on `create_tween()` - which inherits this node's
	# process mode. Left on the default, `_fade_to()` would never advance while
	# paused, so "leave the pause menu and go back to the main menu" would hang on
	# `await tw.finished` forever with the screen stuck black.
	process_mode = Node.PROCESS_MODE_ALWAYS

	var layer := CanvasLayer.new()
	layer.name = "FadeLayer"
	layer.layer = 200
	add_child(layer)

	_fade = ColorRect.new()
	_fade.name = "Fade"
	_fade.color = Color(0, 0, 0, 0)
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_fade)
	_fade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func is_busy() -> bool:
	return _busy


func goto(path: String, fade_out: float = 0.18, fade_in: float = 0.22) -> void:
	if _busy:
		return
	if not ResourceLoader.exists(path):
		push_error("[SceneRouter] scene does not exist: %s" % path)
		EventBus.net_error.emit("scene missing: " + path)
		return
	_busy = true

	if GameConfig.is_headless():
		_instant(path)
		_busy = false
		return

	await _fade_to(1.0, fade_out)
	_instant(path)
	await get_tree().process_frame
	await get_tree().process_frame
	await _fade_to(0.0, fade_in)
	_busy = false


## Fire-and-forget variant for signal handlers that must not yield.
func goto_deferred(path: String) -> void:
	goto.call_deferred(path)


func to_menu() -> void:
	goto(MENU)


func to_lobby() -> void:
	goto(LOBBY)


func to_game() -> void:
	goto(GAME)


func _instant(path: String) -> void:
	var err := get_tree().change_scene_to_file(path)
	if err != OK:
		push_error("[SceneRouter] change_scene_to_file failed (%d) for %s" % [err, path])
	var c := _fade.color
	c.a = 0.0
	_fade.color = c


func _fade_to(target_alpha: float, duration: float) -> void:
	if duration <= 0.0:
		var c := _fade.color
		c.a = target_alpha
		_fade.color = c
		return
	var tw := create_tween()
	tw.set_ease(Tween.EASE_IN_OUT).set_trans(Tween.TRANS_SINE)
	tw.tween_property(_fade, "color:a", target_alpha, duration)
	await tw.finished


## Brief full-screen tint pulse, used for round wins and heavy hits.
func flash(color: Color, duration: float = 0.25) -> void:
	if GameConfig.is_headless():
		return
	var layer := _fade.get_parent() as CanvasLayer
	var rect := ColorRect.new()
	rect.color = color
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(rect)
	rect.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var tw := create_tween()
	tw.tween_property(rect, "color:a", 0.0, duration)
	tw.tween_callback(rect.queue_free)
