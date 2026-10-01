class_name PauseMenu
extends Control
## ESC menu for a live match.
##
## Pausing uses `get_tree().paused`. That single line stops the characters, the
## bullets, the hooks, the FX and the round clock together, which is exactly the
## set that has to stop - a hand-rolled "pause flag" threaded through five systems
## is five chances to forget one, and a round clock that keeps ticking behind a
## pause screen is a bug players report as I18n.t("the AI got a free round").
##
## The consequence is that anything which must keep working while paused has to
## opt in with PROCESS_MODE_ALWAYS. That is this node, the HUD, and
## `SceneRouter` - the last one because leaving to the main menu runs a fade tween,
## and a tween on a pausable node never finishes, so the screen would sit black
## forever.

var director: MatchDirector = null
var game_root: Node = null

var _panel: PanelContainer = null
var _settings: SettingsPanel = null
var _title: Label = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# The theme is fetched rather than inherited because this node may sit on a
	# CanvasLayer that is not under the settings panel's branch of the tree.
	theme = PixelTheme.get_theme()
	_build()
	_bind()
	_post_build()


## Every global hook lives here rather than in `_ready`, so a rebuild re-binds
## exactly what a fresh entry binds and nothing can be missed by one path.
func _bind() -> void:
	EventBus.language_changed.connect(_rebuild)


func _unbind() -> void:
	I18n.unbind_bus(self)


func _post_build() -> void:
	visible = false


func _rebuild(_code: String) -> void:
	# A language switch can come from inside this very panel (Settings is a child
	# of it), so the open/closed state is restored here instead of assuming
	# closed, otherwise the panel would vanish under the player's cursor.
	var was_open := is_open()
	I18n.rebuild_panel(self, _build, _bind, _post_build)
	visible = was_open
	mouse_filter = Control.MOUSE_FILTER_STOP if was_open \
		else Control.MOUSE_FILTER_IGNORE


func _build() -> void:
	var backdrop := ColorRect.new()
	backdrop.color = Color(0, 0, 0, 0.62)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(backdrop)
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_panel = PanelContainer.new()
	_panel.custom_minimum_size = Vector2(196, 0)
	add_child(_panel)
	# No preset here - see the `PixelTheme.center_content` call at the end of
	# `_build()`. It must run after the buttons exist, and it must not go through
	# `PRESET_MODE_MINSIZE`, which ignores `custom_minimum_size`.

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	_panel.add_child(col)

	_title = PixelTheme.heading("PAUSED")
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(_title)

	var status := PixelTheme.body("", true)
	status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(status)

	col.add_child(_button("RESUME", _resume))
	col.add_child(_button("REMATCH", _rematch))
	col.add_child(_button(I18n.t("SETTINGS"), _open_settings))
	col.add_child(_button(I18n.t("MAIN MENU"), _to_menu))

	var hint := PixelTheme.body(I18n.t("ESC to resume"), true)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(hint)

	_settings = SettingsPanel.new()
	_settings.name = "Settings"
	add_child(_settings)

	# Sized from the buttons above, which now exist, and centred explicitly. This
	# panel is the only way out of a paused match: placing it through
	# `PRESET_MODE_MINSIZE` before its children existed put it at (312,175) in a
	# 640x360 space, so pausing a match dimmed the screen and showed no menu.
	PixelTheme.center_content(_panel)


func _button(text: String, handler: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(handler)
	return b


# ===========================================================================
# open / close
# ===========================================================================

func is_open() -> bool:
	return visible


func toggle() -> void:
	if _settings != null and _settings.is_open():
		_settings.close()
		return
	if visible:
		_resume()
	else:
		_open()


func _open() -> void:
	visible = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	_title.text = I18n.t("MATCH PAUSED")
	get_tree().paused = true
	# Nothing in the arena will tick while paused, so the frozen state has to be
	# correct before the pause lands: a countdown mid-tick must stay frozen rather
	# than resume into a live round.
	if director != null:
		director.refresh_freeze()


func _resume() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	get_tree().paused = false
	if director != null:
		director.refresh_freeze()


func _open_settings() -> void:
	if _settings != null:
		_settings.open()


func _rematch() -> void:
	_resume()
	if game_root != null and game_root.has_method("restart_match"):
		game_root.call("restart_match")


func _to_menu() -> void:
	# Unpause BEFORE the transition. `SceneRouter.goto()` awaits a two-frame
	# yield and then a fade tween; with the tree still paused the scene swap would
	# technically happen but the fade would never run and the router would stay
	# busy forever, so the next transition would be silently refused.
	get_tree().paused = false
	visible = false
	SceneRouter.to_menu()


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	# ESC inside the settings sub-panel belongs to the sub-panel. Without this
	# guard one press closes the settings AND resumes the match, because both
	# nodes see the same unhandled event.
	if _settings != null and _settings.is_open():
		return
	if event.is_action_pressed(&"pause"):
		_resume()
		get_viewport().set_input_as_handled()


func _exit_tree() -> void:
	# A pause flag left set on a freed scene means the NEXT scene starts paused
	# with no way out. Cheap to guarantee, and the alternative is an unrecoverable
	# black screen.
	if visible and get_tree() != null:
		get_tree().paused = false
