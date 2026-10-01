extends Control
## Main menu. This is `run/main_scene`, so it is the first thing every launch
## builds and the one screen that must never depend on anything already existing.
##
## Layout is built in code like the rest of the project's scenes. Positioning is
## straightforward absolute placement inside the 640x360 design space, with one
## exception: the frame and the footer are anchored to all four viewport edges,
## because `window/stretch/aspect` is `expand` - on a non-16:9 window the viewport
## is wider or taller than 640x360, and an absolute footer would float in the
## middle of the screen on an ultrawide monitor.
##
## Composition, deliberately not a centred stack of buttons: identity top-left,
## actions down the left, and a live read-out of the current match setup on the
## right so the player can see what they are about to start without opening
## Settings.

const MARGIN: float = 10.0
const BUTTON_W: float = 176.0
const BUTTON_H: float = 22.0

var _setup_rows: Dictionary = {}
var _settings: SettingsPanel = null


func _ready() -> void:
	theme = PixelTheme.get_theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_build()
	_bind()
	_post_build()
	if not GameConfig.is_headless():
		AudioDirector.play_music("music_menu")


## Every global hook lives here rather than in `_ready`, so a rebuild re-binds
## exactly what a fresh entry binds and nothing can be missed by one path.
func _bind() -> void:
	EventBus.settings_changed.connect(_refresh_setup)
	EventBus.language_changed.connect(_rebuild)


func _unbind() -> void:
	I18n.unbind_bus(self)


func _post_build() -> void:
	_refresh_setup()


func _rebuild(_code: String) -> void:
	I18n.rebuild_panel(self, _build, _bind, _post_build)


func _exit_tree() -> void:
	_unbind()


# ===========================================================================
# construction
# ===========================================================================

func _build() -> void:
	var bg := ColorRect.new()
	bg.color = PixelTheme.c("bg")
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var frame := Panel.new()
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(frame)
	frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	frame.offset_left = MARGIN
	frame.offset_top = MARGIN
	frame.offset_right = -MARGIN
	frame.offset_bottom = -MARGIN

	_build_identity()
	_build_actions()
	_build_setup_panel()
	_build_footer()

	_settings = SettingsPanel.new()
	_settings.name = "Settings"
	add_child(_settings)


func _build_identity() -> void:
	var title := Label.new()
	title.text = I18n.t("CAKEGAME")
	PixelTheme.apply_font(title, PixelTheme.SIZE_HERO)
	title.add_theme_color_override("font_color", PixelTheme.c("accent"))
	add_child(title)
	_abs(title, MARGIN + 18.0, MARGIN + 18.0, 400.0, 34.0)

	var sub := Label.new()
	sub.text = I18n.t("1-3 PLAYERS   VS   1-2 AI BOTS")
	PixelTheme.apply_font(sub, PixelTheme.SIZE_BODY)
	sub.add_theme_color_override("font_color", PixelTheme.c("text"))
	add_child(sub)
	_abs(sub, MARGIN + 20.0, MARGIN + 56.0, 400.0, 12.0)

	var rule := ColorRect.new()
	rule.color = PixelTheme.c("line")
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(rule)
	_abs(rule, MARGIN + 20.0, MARGIN + 74.0, BUTTON_W, 1.0)

	# One key, not two: the first pass split this across two `I18n.t` calls so
	# that the last line could be joined to a neighbour, and a split key has no
	# entry of its own in the table, so the whole pitch stayed English. Keeping
	# the sentence whole and letting the label autowrap is both shorter and the
	# thing that actually translates.
	var pitch := PixelTheme.body(
		I18n.t("Top-down pixel brawling. Melee, a handgun and a grapple\nyou can aim at a wall or at somebody's back. Every bot is\nthe same difficulty - there is no easy mode."), true)
	pitch.add_theme_color_override("font_color", PixelTheme.c("dim"))
	add_child(pitch)
	_abs(pitch, MARGIN + 20.0, MARGIN + 82.0, 300.0, 40.0)


func _build_actions() -> void:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 5)
	add_child(col)
	_abs(col, MARGIN + 18.0, 132.0, BUTTON_W, 120.0)

	col.add_child(_action(I18n.t("PLAY  VS  BOTS"), _play_offline,
		I18n.t("one human on this machine, against the configured bots")))
	col.add_child(_action(I18n.t("HOST / JOIN ROOM"), _open_lobby,
		I18n.t("LAN discovery and cross-network room codes")))
	col.add_child(_action(I18n.t("SETTINGS"), _open_settings, I18n.t("bot version, arena, controls, audio")))
	col.add_child(_action(I18n.t("QUIT"), _quit, I18n.t("close the game")))


func _action(text: String, handler: Callable, tooltip: String) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(BUTTON_W, BUTTON_H)
	b.tooltip_text = tooltip
	b.pressed.connect(handler)
	return b


func _build_setup_panel() -> void:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(232, 0)
	add_child(panel)
	# Anchored to the right edge with negative offsets, so it keeps hugging the
	# right on a viewport wider than 640.
	panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE, 0)
	panel.offset_left = -232.0 - MARGIN - 16.0
	panel.offset_right = -MARGIN - 16.0
	panel.offset_top = 96.0

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 3)
	panel.add_child(col)

	var head := PixelTheme.body(I18n.t("MATCH SETUP"))
	head.add_theme_color_override("font_color", PixelTheme.c("accent"))
	col.add_child(head)
	var rule := HSeparator.new()
	col.add_child(rule)

	for key in ["bot", "arena", "roster", "score", "respawn", "lights"]:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		col.add_child(row)
		var k := PixelTheme.body(_setup_label(key), true)
		k.custom_minimum_size = Vector2(70, 0)
		row.add_child(k)
		var v := PixelTheme.body("-")
		v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		v.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		row.add_child(v)
		_setup_rows[key] = v

	var note := PixelTheme.body(I18n.t("Edit these in SETTINGS."), true)
	col.add_child(note)


func _setup_label(key: String) -> String:
	match key:
		"bot":
			return I18n.t("BOT")
		"arena":
			return I18n.t("ARENA")
		"roster":
			return I18n.t("ROSTER")
		# `I18n.t` is applied at the call site in `_build_setup()`... it is applied
		# here too, because these two are hardcoded inside the label maps and the
		# earlier pass wrapped every other row and missed them.
		"score":
			return I18n.t("WIN AT")
		"respawn":
			return I18n.t("RESPAWN")
		"lights":
			return I18n.t("SHADOWS")
	return key.to_upper()


## One full-width row with a flexible gap in the middle, rather than two labels
## anchored to opposite corners.
##
## The two-corner version looked fine and was not: nothing in the engine keeps a
## BOTTOM_LEFT control and a BOTTOM_RIGHT control apart, and measured, the two
## strings came to 689 px in a 584 px frame - a 77 px overlap straight through
## the middle of the footer. Both texts are also shorter here. The version string
## no longer repeats the product name (the hero title is 300 px above it) and the
## license URL moved to a tooltip, which buys ~100 px of slack so a longer
## version or a new control hint does not re-create the collision.
func _build_footer() -> void:
	var version := str(ProjectSettings.get_setting("application/config/version", "?"))

	var foot := HBoxContainer.new()
	foot.name = "Footer"
	foot.add_theme_constant_override("separation", 12)
	add_child(foot)

	var left := PixelTheme.body(I18n.t("v%s   ·   Available License") % version, true)
	left.tooltip_text = I18n.t("Released under the Available License - license.kscm.top/available.md")
	foot.add_child(left)

	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	foot.add_child(gap)

	var right := PixelTheme.body(
		I18n.t("WASD move  ·  mouse aim  ·  RMB melee  ·  E gun  ·  Q hook  ·  Shift roll"), true)
	foot.add_child(right)

	PixelTheme.bottom_row(foot, 12.0, MARGIN + 18.0, MARGIN + 14.0)


## Absolute placement inside the design space, measured from the parent's top-left
## corner. `Control.position` alone is relative to the parent's top-left but does
## NOT resize the control; going through the four offsets does both, which is what
## makes a tooltip-bearing Button actually hit-test over its whole rectangle.
func _abs(c: Control, x: float, y: float, w: float, h: float) -> void:
	c.set_anchors_and_offsets_preset(
		Control.PRESET_TOP_LEFT, Control.PRESET_MODE_MINSIZE, 0)
	c.offset_left = x
	c.offset_top = y
	c.offset_right = x + w
	c.offset_bottom = y + h


# ===========================================================================
# state
# ===========================================================================

func _refresh_setup() -> void:
	theme = PixelTheme.get_theme()
	if _settings != null:
		_settings.theme = theme
	# Values only, no sentences: the panel is 232 px wide in a 640 px design
	# space and a wrapped English sentence turns it into a wall of text. The
	# Chinese descriptions of the bot itself live in the Settings panel, where
	# there is room for them.
	_setup_rows["bot"].text = BotRegistry.display_name(GameConfig.bot_version)
	if not GameConfig.seeded_map:
		_setup_rows["arena"].text = I18n.t("built-in (34x34)")
	elif GameConfig.seed_is_random():
		_setup_rows["arena"].text = I18n.t("seeded, random each match")
	else:
		_setup_rows["arena"].text = "seeded \"%s\"" % GameConfig.map_seed_text
	_setup_rows["roster"].text = I18n.t("1 human + %d bot") % maxi(1, GameConfig.bot_slots)
	if GameConfig.respawn_enabled:
		_setup_rows["score"].text = I18n.t("%d kills") % (
			GameConfig.round_target_score * maxi(1, GameConfig.bot_slots))
	else:
		_setup_rows["score"].text = I18n.t("%d rounds") % GameConfig.round_target_score
	_setup_rows["respawn"].text = ("after %.1fs" % GameConfig.respawn_delay) \
		if GameConfig.respawn_enabled else I18n.t("off (elimination)")
	_setup_rows["lights"].text = I18n.t("on") if GameConfig.light_shadows else I18n.t("off")


func _open_settings() -> void:
	_settings.open()


func _open_lobby() -> void:
	SceneRouter.to_lobby()


## Offline is the only mode with a working transport today, so it is also the
## only button that starts a match directly. The lobby routes here through its
## own START button once the transports land.
func _play_offline() -> void:
	NetManager.set_offline()
	NetManager.set_local_slot(GameConfig.player_name, Enums.Team.HUMANS,
		Enums.Kind.LOCAL_HUMAN)
	SceneRouter.to_game()


func _quit() -> void:
	get_tree().quit()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"pause"):
		if _settings != null and _settings.is_open():
			return
		_open_settings()
		get_viewport().set_input_as_handled()
