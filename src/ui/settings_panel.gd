class_name SettingsPanel
extends Control
## Settings, shared by the main menu and the pause menu.
##
## One panel rather than two, because the two copies of a settings screen always
## drift: a row gets added to the in-game one, somebody forgets the menu one, and
## the two disagree about what I18n.t("Master volume") does.
##
## Every control writes straight into `GameConfig` and commits with
## `GameConfig.save_settings()`. There is no OK/Apply button on purpose - the
## settings are cheap to change and cheap to persist, and a half-applied settings
## screen is a class of bug nobody needs. `GameConfig._clamp_all()` can move a
## value after a write (bot slots vs. max players), so `_commit()` re-reads the
## config back into the widgets; the `_syncing` guard stops that refresh from
## firing the change signals again.

signal closed()

const ROW_LABEL_W: int = 148
const PANEL_W: int = 470
const PANEL_H: int = 316

var _backdrop: ColorRect = null
var _panel: PanelContainer = null
var _body: VBoxContainer = null
var _syncing: bool = false
var _capture_action: StringName = &""
var _capture_button: Button = null

# keep handles so `_sync_from_config()` can re-read the config into them
var _widgets: Dictionary = {}       ## key -> Control
var _volume_labels: Dictionary = {} ## key -> Label
var _key_buttons: Dictionary = {}   ## action -> Button


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	theme = PixelTheme.get_theme()
	_build()
	_bind()
	_post_build()


## Every global hook lives here rather than in `_ready`, so a rebuild re-binds
## exactly what a fresh entry binds and nothing can be missed by one path.
func _bind() -> void:
	# `save_settings()` broadcasts, and this panel is not the only writer - the
	# main menu, the lobby and a future console all call it. Without listening,
	# the widgets silently keep pre-clamp values, so after `max_players` drops to
	# 2 the bot-slot spinner still reads 2 while the config says 0. The panel would
	# then be lying about the very setting the player is looking at.
	EventBus.settings_changed.connect(_sync_from_config)
	EventBus.language_changed.connect(_rebuild)


func _unbind() -> void:
	I18n.unbind_bus(self)


func _post_build() -> void:
	# A freshly built panel is visible by default, and `is_open()` reads `visible`.
	# Skipping this line leaves the panel covering the arena, and it also makes
	# the pause menu's `toggle()` take the "close the settings" branch and show
	# nothing at all.
	_sync_from_config()
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _rebuild(_code: String) -> void:
	# Keep the panel exactly as it was: open or closed, and drop a key capture
	# in progress, because the button that was listening for the keystroke is
	# about to be freed.
	var was_open := is_open()
	if _capture_action != &"":
		_cancel_capture()
	I18n.rebuild_panel(self, _build, _bind, _post_build)
	visible = was_open
	mouse_filter = Control.MOUSE_FILTER_STOP if was_open \
		else Control.MOUSE_FILTER_IGNORE


func _exit_tree() -> void:
	_unbind()


func open() -> void:
	visible = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	_sync_from_config()


func close() -> void:
	_cancel_capture()
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	closed.emit()


func is_open() -> bool:
	return visible


# ===========================================================================
# construction
# ===========================================================================

func _build() -> void:
	# A dim backdrop that also swallows clicks, so a stray click behind the panel
	# cannot reach the arena.
	_backdrop = ColorRect.new()
	_backdrop.color = Color(0, 0, 0, 0.55)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_backdrop)
	_backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	_panel = PanelContainer.new()
	_panel.custom_minimum_size = Vector2(PANEL_W, PANEL_H)
	add_child(_panel)
	# NOTE: no `set_anchors_and_offsets_preset` here. Placement is the LAST thing
	# `_build()` does, via `PixelTheme.center_fixed`, because `MINSIZE` does not
	# honour `custom_minimum_size` and the panel would land as an off-screen stub.

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 6)
	_panel.add_child(outer)

	var head := HBoxContainer.new()
	outer.add_child(head)
	var title := PixelTheme.heading(I18n.t("SETTINGS"))
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	var close_btn := Button.new()
	close_btn.text = I18n.t("CLOSE  [ESC]")
	close_btn.pressed.connect(close)
	head.add_child(close_btn)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	outer.add_child(scroll)

	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 3)
	scroll.add_child(_body)

	_build_gameplay()
	_build_controls()
	_build_presentation()
	_build_network()

	# Placement last, with an explicit size. 470x316 centred in 640x360 leaves
	# 85 px either side and 22 px top and bottom, which is the whole margin budget
	# this panel gets - the scroll body inside it is 1336 px tall and relies on
	# the ScrollContainer, not on the panel growing.
	PixelTheme.center_fixed(_panel, Vector2(PANEL_W, PANEL_H))


func _build_gameplay() -> void:
	_section(I18n.t("GAMEPLAY"))

	# --- bot version ---------------------------------------------------------
	var row := _row(I18n.t("Bot version"))
	var opt := OptionButton.new()
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for n in BotRegistry.display_names():
		opt.add_item(n)
	opt.item_selected.connect(func(i: int):
		GameConfig.bot_version = BotRegistry.id_at(i)
		_commit())
	row.add_child(opt)
	_widgets["bot_version"] = opt

	var desc := PixelTheme.body("", true)
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.custom_minimum_size = Vector2(PANEL_W - 40, 0)
	_body.add_child(desc)
	_widgets["bot_desc"] = desc

	# --- seed map ------------------------------------------------------------
	var seed_row := _row(I18n.t("Seeded map"))
	var seed_box := CheckButton.new()
	seed_box.text = I18n.t("random arena from a seed")
	seed_box.toggled.connect(func(on: bool):
		GameConfig.seeded_map = on
		_commit())
	seed_row.add_child(seed_box)
	_widgets["seeded_map"] = seed_box

	var input_row := _row(I18n.t("Seed"))
	var seed_edit := LineEdit.new()
	seed_edit.placeholder_text = I18n.t("blank = invent one")
	seed_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	seed_edit.text_changed.connect(func(t: String):
		GameConfig.map_seed_text = t)
	seed_edit.focus_exited.connect(_commit)
	seed_edit.text_submitted.connect(func(_t: String): _commit())
	input_row.add_child(seed_edit)
	var reroll := Button.new()
	reroll.text = I18n.t("REROLL")
	reroll.pressed.connect(func():
		GameConfig.reroll_seed()
		seed_edit.text = ""
		_commit())
	input_row.add_child(reroll)
	_widgets["map_seed_text"] = seed_edit

	# --- roster --------------------------------------------------------------
	var players := _row(I18n.t("Max players"))
	var mp := _spin(2, 8, 1)
	mp.value_changed.connect(func(v: float):
		GameConfig.max_players = int(v)
		_commit())
	players.add_child(mp)
	_widgets["max_players"] = mp

	var humans := _row(I18n.t("Human slots"))
	var hs := _spin(0, 8, 1)
	hs.value_changed.connect(func(v: float):
		GameConfig.human_slots = int(v)
		_commit())
	humans.add_child(hs)
	_widgets["human_slots"] = hs

	var bots := _row(I18n.t("Bot slots"))
	var bs := _spin(0, 2, 1)
	bs.value_changed.connect(func(v: float):
		GameConfig.bot_slots = int(v)
		_commit())
	bots.add_child(bs)
	_widgets["bot_slots"] = bs
	_note(I18n.t("Only one human can play on this machine: the InputMap binds WASD and "
		+ "one set of pad buttons globally, so a second local player would share "
		+ "player one's keys. Extra humans join over LAN / room code, which is "
		+ "what 'Human slots' describes. Offline you get one human plus the bots, "
		+ "and the bot count is floored at one so a match always has an enemy."))

	# --- match rules ---------------------------------------------------------
	var score := _row(I18n.t("Score to win"))
	var sc := _spin(1, 30, 1)
	sc.value_changed.connect(func(v: float):
		GameConfig.round_target_score = int(v)
		_commit())
	score.add_child(sc)
	_widgets["round_target_score"] = sc

	var resp := _row("Respawn")
	var resp_box := CheckButton.new()
	resp_box.text = I18n.t("deathmatch (back after the delay)")
	resp_box.toggled.connect(func(on: bool):
		GameConfig.respawn_enabled = on
		_commit())
	resp.add_child(resp_box)
	_widgets["respawn_enabled"] = resp_box
	_note(I18n.t("Off: elimination rounds, wipe the other team, first to the score wins. "
		+ "On: no rounds - a downed fighter returns, kills score, and the target "
		+ "becomes 'score to win' times the enemy team size."))

	var delay := _row(I18n.t("Respawn delay"))
	var dl := _spin(0.5, 20.0, 0.5)
	dl.value_changed.connect(func(v: float):
		GameConfig.respawn_delay = v
		_commit())
	delay.add_child(dl)
	_widgets["respawn_delay"] = dl

	var ff := _row(I18n.t("Friendly fire"))
	var ff_box := CheckButton.new()
	ff_box.toggled.connect(func(on: bool):
		GameConfig.friendly_fire = on
		_commit())
	ff.add_child(ff_box)
	_widgets["friendly_fire"] = ff_box


func _build_controls() -> void:
	_section(I18n.t("CONTROLS"))

	var sens := _row(I18n.t("Mouse sensitivity"))
	var sl := _slider(0.2, 4.0, 0.05)
	sl.value_changed.connect(func(v: float):
		GameConfig.mouse_sensitivity = v
		_commit())
	sens.add_child(sl)
	_widgets["mouse_sensitivity"] = sl

	var assist := _row(I18n.t("Pad aim assist"))
	var ab := CheckButton.new()
	ab.toggled.connect(func(on: bool):
		GameConfig.aim_assist_gamepad = on
		_commit())
	assist.add_child(ab)
	_widgets["aim_assist_gamepad"] = ab

	_note(I18n.t("Click a key to rebind it, then press the new key. Escape cancels."))
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 2)
	_body.add_child(grid)
	for action in InputSetup.REBINDABLE:
		var name_label := PixelTheme.body(_action_name(action), true)
		name_label.custom_minimum_size = Vector2(ROW_LABEL_W, 0)
		grid.add_child(name_label)
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(84, 0)
		btn.pressed.connect(_begin_capture.bind(action, btn))
		grid.add_child(btn)
		_key_buttons[action] = btn
		var spacer := Control.new()
		grid.add_child(spacer)


func _build_presentation() -> void:
	_section(I18n.t("PRESENTATION"))

	var dark := _row(I18n.t("Dark theme"))
	var db := CheckButton.new()
	db.toggled.connect(func(on: bool):
		GameConfig.dark_theme = on
		_apply_theme()
		_commit())
	dark.add_child(db)
	_widgets["dark_theme"] = db

	var shadows := _row(I18n.t("Light shadows"))
	var sh := CheckButton.new()
	sh.text = I18n.t("fighter lights cast shadows")
	sh.toggled.connect(func(on: bool):
		GameConfig.light_shadows = on
		_apply_theme()
		_commit())
	shadows.add_child(sh)
	_widgets["light_shadows"] = sh
	_note(I18n.t("Off by default. One light per fighter is five shadow casters: they "
		+ "project a fan of dark wedges across the whole floor, which at five "
		+ "actors buries the tile art and reads as a rendering fault rather than "
		+ "as lighting. The team-coloured glow stays either way - it is how you "
		+ "track a 1v3."))

	var shake := _row(I18n.t("Screen shake"))
	var shb := CheckButton.new()
	shb.toggled.connect(func(on: bool):
		GameConfig.screen_shake = on
		_commit())
	shake.add_child(shb)
	_widgets["screen_shake"] = shb

	var dmg := _row(I18n.t("Damage numbers"))
	var dmg_box := CheckButton.new()
	dmg_box.toggled.connect(func(on: bool):
		GameConfig.damage_numbers = on
		_commit())
	dmg.add_child(dmg_box)
	_widgets["damage_numbers"] = dmg_box

	var fps := _row(I18n.t("Show FPS"))
	var fps_box := CheckButton.new()
	fps_box.toggled.connect(func(on: bool):
		GameConfig.show_fps = on
		_commit())
	fps.add_child(fps_box)
	_widgets["show_fps"] = fps_box

	for key in ["master_volume", "sfx_volume", "music_volume"]:
		var vol_row := _row("%s volume" % key.replace("_volume", "").capitalize())
		var vs := _slider(0.0, 1.0, 0.05)
		vs.value_changed.connect(_on_volume.bind(key))
		vol_row.add_child(vs)
		_widgets[key] = vs
		var vl := PixelTheme.body("", true)
		vl.custom_minimum_size = Vector2(34, 0)
		vl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		vol_row.add_child(vl)
		_volume_labels[key] = vl

	var scale_row := _row(I18n.t("Window scale"))
	var scale_opt := OptionButton.new()
	for s in range(1, 5):
		scale_opt.add_item("%dx  (%d x %d)" % [s, 640 * s, 360 * s])
	scale_opt.item_selected.connect(func(i: int):
		GameConfig.window_scale = i + 1
		_commit())
	scale_row.add_child(scale_opt)
	_widgets["window_scale"] = scale_opt

	var full := _row(I18n.t("Fullscreen"))
	var fb := CheckButton.new()
	fb.toggled.connect(func(on: bool):
		GameConfig.fullscreen = on
		_commit())
	full.add_child(fb)
	_widgets["fullscreen"] = fb

	var lang := _row(I18n.t("Language"))
	var lopt := OptionButton.new()
	lopt.add_item(I18n.t("English"))
	lopt.add_item(I18n.t("中文"))
	lopt.item_selected.connect(func(i: int):
		# Go through I18n so the change is published on EventBus and every open
		# panel rebuilds. Writing GameConfig directly - which is what this did -
		# only saved the value and left the screen in the old language.
		I18n.set_lang("zh" if i == 1 else "en")
		_commit())
	lang.add_child(lopt)
	_widgets["language"] = lopt


func _build_network() -> void:
	_section(I18n.t("NETWORK"))

	var name_row := _row(I18n.t("Player name"))
	var ne := LineEdit.new()
	ne.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ne.text_changed.connect(func(t: String):
		GameConfig.player_name = t)
	ne.focus_exited.connect(_commit)
	ne.text_submitted.connect(func(_t: String): _commit())
	name_row.add_child(ne)
	_widgets["player_name"] = ne

	var port_row := _row(I18n.t("Server port"))
	var port := _spin(1024, 65535, 1)
	port.value_changed.connect(func(v: float):
		GameConfig.server_port = int(v)
		_commit())
	port_row.add_child(port)
	_widgets["server_port"] = port

	var trans_row := _row(I18n.t("Transport"))
	var topt := OptionButton.new()
	for t in [I18n.t("auto"), I18n.t("lan"), I18n.t("p2p"), I18n.t("relay")]:
		topt.add_item(t)
	topt.item_selected.connect(func(i: int):
		GameConfig.preferred_transport = [I18n.t("auto"), I18n.t("lan"), I18n.t("p2p"), I18n.t("relay")][i]
		_commit())
	trans_row.add_child(topt)
	_widgets["preferred_transport"] = topt

	for key in ["signaling_url", "relay_url"]:
		var r := _row(key.replace("_url", " URL").capitalize())
		var e := LineEdit.new()
		e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		e.text_changed.connect(func(t: String):
			GameConfig.set(key, t))
		e.focus_exited.connect(_commit)
		e.text_submitted.connect(func(_t: String): _commit())
		r.add_child(e)
		_widgets[key] = e

	var reset := Button.new()
	reset.text = I18n.t("RESET ALL SETTINGS TO DEFAULTS")
	reset.pressed.connect(func():
		GameConfig.reset_to_defaults()
		_apply_theme()
		_sync_from_config())
	_body.add_child(reset)


# ===========================================================================
# row helpers
# ===========================================================================

func _section(title: String) -> void:
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 4)
	_body.add_child(spacer)
	var l := PixelTheme.body(title)
	l.add_theme_color_override("font_color", PixelTheme.c("accent"))
	_body.add_child(l)
	var rule := HSeparator.new()
	rule.add_theme_constant_override("separation", 2)
	_body.add_child(rule)


func _row(label: String) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	_body.add_child(h)
	var l := PixelTheme.body(label)
	l.custom_minimum_size = Vector2(ROW_LABEL_W, 0)
	h.add_child(l)
	return h


func _note(text: String) -> void:
	var l := PixelTheme.body(text, true)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(PANEL_W - 46, 0)
	_body.add_child(l)


func _spin(min_v: float, max_v: float, step: float) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = min_v
	s.max_value = max_v
	s.step = step
	s.custom_minimum_size = Vector2(96, 0)
	return s


func _slider(min_v: float, max_v: float, step: float) -> HSlider:
	var s := HSlider.new()
	s.min_value = min_v
	s.max_value = max_v
	s.step = step
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.custom_minimum_size = Vector2(140, 0)
	return s


static func _action_name(action: StringName) -> String:
	return String(action).replace("_", " ").capitalize()


# ===========================================================================
# state
# ===========================================================================

func _on_volume(value: float, key: String) -> void:
	GameConfig.set(key, value)
	_commit()


func _apply_theme() -> void:
	# `get_theme()` caches one Theme per variant, so switching simply hands back
	# the other cached one; `invalidate()` would only be needed if the palette
	# itself changed shape.
	PixelTheme.invalidate()
	theme = PixelTheme.get_theme()


func _commit() -> void:
	if _syncing:
		return
	GameConfig.save_settings()
	AudioDirector.apply_volumes()
	GameConfig.apply_display()
	# No `_sync_from_config()` here: `save_settings()` already broadcast
	# `settings_changed`, which this panel listens to. Refreshing twice is
	# harmless today and becomes a double-refresh bug the moment a widget grows
	# an expensive rebuild.


## Push config values into the widgets. Wrapped in `_syncing` because writing a
## `CheckButton.button_pressed` or a `SpinBox.value` emits the very signal that
## writes back into the config - without the guard, `_commit()` would recurse.
func _sync_from_config() -> void:
	_syncing = true

	var opt := _widgets.get("bot_version") as OptionButton
	if opt != null:
		opt.selected = maxi(0, BotRegistry.index_of(GameConfig.bot_version))
	var desc := _widgets.get("bot_desc") as Label
	if desc != null:
		desc.text = "%s\n%s" % [
			BotRegistry.display_name(GameConfig.bot_version),
			BotRegistry.description(GameConfig.bot_version,
				GameConfig.language == "zh")]

	_set_check("seeded_map", GameConfig.seeded_map)
	var seed_edit := _widgets.get("map_seed_text") as LineEdit
	if seed_edit != null and seed_edit.text != GameConfig.map_seed_text:
		seed_edit.text = GameConfig.map_seed_text

	for key in ["max_players", "human_slots", "bot_slots", "round_target_score",
			"respawn_delay", "server_port"]:
		var spin := _widgets.get(key) as SpinBox
		if spin != null:
			spin.value = float(GameConfig.get(key))
	_set_check("respawn_enabled", GameConfig.respawn_enabled)
	_set_check("friendly_fire", GameConfig.friendly_fire)
	_set_check("aim_assist_gamepad", GameConfig.aim_assist_gamepad)
	_set_check("dark_theme", GameConfig.dark_theme)
	_set_check("light_shadows", GameConfig.light_shadows)
	_set_check("screen_shake", GameConfig.screen_shake)
	_set_check("damage_numbers", GameConfig.damage_numbers)
	_set_check("show_fps", GameConfig.show_fps)
	_set_check("fullscreen", GameConfig.fullscreen)

	var sens := _widgets.get("mouse_sensitivity") as HSlider
	if sens != null:
		sens.value = GameConfig.mouse_sensitivity
	for key in ["master_volume", "sfx_volume", "music_volume"]:
		var sl := _widgets.get(key) as HSlider
		if sl != null:
			sl.value = float(GameConfig.get(key))
		var vl := _volume_labels.get(key) as Label
		if vl != null:
			vl.text = "%d%%" % roundi(float(GameConfig.get(key)) * 100.0)

	var ws := _widgets.get("window_scale") as OptionButton
	if ws != null:
		ws.selected = clampi(GameConfig.window_scale - 1, 0, 3)
	var lang := _widgets.get("language") as OptionButton
	if lang != null:
		lang.selected = 1 if GameConfig.language == "zh" else 0
	var trans := _widgets.get("preferred_transport") as OptionButton
	if trans != null:
		var idx := [I18n.t("auto"), I18n.t("lan"), I18n.t("p2p"), I18n.t("relay")].find(GameConfig.preferred_transport)
		trans.selected = maxi(0, idx)

	for key in ["player_name", "signaling_url", "relay_url"]:
		var e := _widgets.get(key) as LineEdit
		if e != null and e.text != str(GameConfig.get(key)):
			e.text = str(GameConfig.get(key))

	for action in _key_buttons.keys():
		var btn := _key_buttons[action] as Button
		if btn != null:
			btn.text = InputSetup.key_label(action)

	_syncing = false


func _set_check(key: String, value: bool) -> void:
	var cb := _widgets.get(key) as BaseButton
	if cb != null:
		cb.button_pressed = value


# ===========================================================================
# rebinding
# ===========================================================================

func _begin_capture(action: StringName, button: Button) -> void:
	_cancel_capture()
	_capture_action = action
	_capture_button = button
	button.text = "press a key"


func _cancel_capture() -> void:
	if _capture_button != null and is_instance_valid(_capture_button):
		_capture_button.text = InputSetup.key_label(_capture_action)
	_capture_action = &""
	_capture_button = null


func _input(event: InputEvent) -> void:
	if _capture_action == &"":
		return
	if not visible:
		_cancel_capture()
		return
	if event is InputEventKey and (event as InputEventKey).pressed:
		var key := event as InputEventKey
		if key.keycode == KEY_ESCAPE:
			_cancel_capture()
			get_viewport().set_input_as_handled()
			return
		if not InputSetup.rebind_key(_capture_action, key.physical_keycode):
			push_warning("[SettingsPanel] %s is already bound to another action"
				% OS.get_keycode_string(key.physical_keycode))
		_cancel_capture()
		get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed(&"pause") and _capture_action == &"":
		close()
		get_viewport().set_input_as_handled()
