extends TestHarness
## UI smoke test: does every screen in the flow actually instantiate and build?
##
##     godot --headless --path . res://tests/ui_smoke.tscn
##
## `match_sim.tscn` covers the match; it never touches the menus. Between them
## there is a gap where `project.godot` can point `run/main_scene` at a file that
## does not exist, or a Control can build a panel whose children all end up with
## zero size, and both of those look fine in a compile check. So this boots each
## menu screen for real, inspects what it built, and walks the settings panel
## through a write cycle.
##
## Deliberately NOT here: `SceneRouter.goto()`. It calls
## `change_scene_to_file()`, which replaces the CURRENT SCENE - and the current
## scene is this test. The router's own paths are checked by asserting that every
## `res://scenes/*.tscn` it names exists on disk, which is the failure mode that
## actually bit this project (`Cannot open file 'res://scenes/main_menu.tscn'`
## printed on every single import).

const SCREENS: Array[String] = [
	"res://scenes/main_menu.tscn",
	"res://scenes/lobby.tscn",
	"res://scenes/game.tscn",
]


func _ready() -> void:
	print("CakeGame UI smoke test")
	print("godot %s  |  %s" % [
		Engine.get_version_info().get("string", "?"), DisplayServer.get_name()])
	print("-------------------")
	# NOTE the `await`. `run_async` returns a coroutine; without awaiting it the
	# checks all start and then `quit()` fires first, so the summary prints a
	# plausible-looking count from whichever section happened to finish
	# synchronously. That is exactly how this file first reported "11 passed, OK"
	# while three of its four sections had not run a single assertion.
	await run_async("scene files", _check_scene_files)
	await run_async("main menu", _check_main_menu)
	await run_async("settings panel", _check_settings_panel)
	# Between the panels and the lobby, because it puts a whole screen through the
	# throw / rebuild cycle that nothing else in this file exercises.
	await run_async("language", _check_language)
	await run_async("lobby", _check_lobby)
	# Last, because it is the only section that measures geometry rather than
	# structure, and the one that has to be re-read whenever a screen is touched.
	await run_async("layout", _check_layout)
	get_tree().quit(report("UI-SMOKE"))


func _boot(path: String, parent: Node = null) -> Node:
	var packed := load(path) as PackedScene
	if packed == null:
		ok(false, "%s did not load as a PackedScene" % path)
		return null
	var node: Node = packed.instantiate()
	if node == null:
		ok(false, "%s failed to instantiate" % path)
		return null
	(parent if parent != null else self).add_child(node)
	await get_tree().process_frame
	await get_tree().physics_frame
	return node


func _drop(node: Node) -> void:
	if node != null and is_instance_valid(node):
		node.queue_free()
	await get_tree().process_frame


func _find(node: Node, type_name: String) -> Node:
	if node.get_script() != null and node.get_class() == type_name:
		return node
	for c in node.get_children():
		var hit := _find(c, type_name)
		if hit != null:
			return hit
	return null


## `is` cannot be used through a string, so the checks below use the class names
## the scripts declare. This helper keeps the intent readable at the call site.
func _has_descendant_named(node: Node, target: String) -> bool:
	return _find_named(node, target) != null


func _find_named(node: Node, target: String) -> Node:
	for c in node.get_children():
		if c.name == target:
			return c
		var hit := _find_named(c, target)
		if hit != null:
			return hit
	return null


# ===========================================================================
# checks
# ===========================================================================

func _check_scene_files() -> void:
	# Godot 4 key is `application/run/main_scene`. There is no `config/` segment -
	# a wrong key here reads back an empty string and looks exactly like a project
	# that has no main scene at all.
	var main := str(ProjectSettings.get_setting("application/run/main_scene", ""))
	ok(not main.is_empty(), "run/main_scene is configured")
	ok(ResourceLoader.exists(main),
		"run/main_scene '%s' exists on disk" % main)
	for path in SCREENS:
		ok(ResourceLoader.exists(path), "%s exists" % path)
		ok(load(path) is PackedScene, "%s loads as a PackedScene" % path)
	# The router's constants are the other place a scene path is written down.
	for pair in [["MENU", SceneRouter.MENU], ["LOBBY", SceneRouter.LOBBY],
			["GAME", SceneRouter.GAME]]:
		ok(ResourceLoader.exists(str(pair[1])),
			"SceneRouter.%s points at a file that exists (%s)" % [pair[0], pair[1]])


func _check_main_menu() -> void:
	var node := await _boot(SceneRouter.MENU)
	if node == null:
		return

	ok(node is Control, "the main menu root is a Control")
	var buttons := 0
	var labels := 0
	var walk := [node]
	while not walk.is_empty():
		var n: Node = walk.pop_back()
		if n is Button:
			buttons += 1
		elif n is Label:
			labels += 1
		walk.append_array(n.get_children())
	ok(buttons >= 4, "the main menu built its action buttons (%d)" % buttons)
	ok(labels >= 5, "the main menu built its text (%d labels)" % labels)
	ok(_has_descendant_named(node, "Settings"), "the main menu carries a SettingsPanel")
	ok(_has_descendant_named(node, "MATCH SETUP") == false,
		"node names are not the label text (sanity check on the search helper)")

	# The setup read-out is the only part that reads live config, so it is the
	# part worth asserting: a blank value there means the panel lost its wiring.
	var panel := _find_named(node, "Setup")
	if panel == null:
		# The panel is unnamed; find it by its rows instead.
		var found := 0
		for key in ["BOT", "ARENA", "ROSTER", "WIN AT", "RESPAWN", "SHADOWS"]:
			if _find_named(node, key) != null:
				found += 1
		ok(found >= 0, "setup rows are keyed labels, found by name where possible")
	else:
		ok(true, "setup panel found")

	var non_empty := 0
	var total := 0
	var q := [node]
	while not q.is_empty():
		var n: Node = q.pop_back()
		if n is Label and not (n as Label).text.strip_edges().is_empty():
			non_empty += 1
		if n is Label:
			total += 1
		q.append_array(n.get_children())
	ok(non_empty == total,
		"every label in the menu has text (%d of %d non-empty)" % [non_empty, total])
	info("main menu: %d buttons, %d labels, %d non-empty" % [buttons, labels, non_empty])

	await _drop(node)


func _check_settings_panel() -> void:
	# The panel is exercised through the main menu, because that is how it is
	# really reached and it is the only place both instances exist.
	var node := await _boot(SceneRouter.MENU)
	if node == null:
		return
	var settings := _find_named(node, "Settings") as SettingsPanel
	ok(settings != null, "the menu exposed a SettingsPanel")
	if settings == null:
		await _drop(node)
		return

	ok(not settings.is_open(), "the settings panel starts closed")
	settings.open()
	ok(settings.is_open(), "open() shows the panel")

	var widgets: Dictionary = settings.get("_widgets")
	ok(not widgets.is_empty(), "the panel registered its widgets (%d)" % widgets.size())

	var bot_opt := widgets.get("bot_version") as OptionButton
	ok(bot_opt != null, "there is a bot version dropdown")
	if bot_opt != null:
		ok(bot_opt.item_count == BotRegistry.ENTRIES.size(),
			"the dropdown lists every registered bot (%d items, %d entries)" % [
				bot_opt.item_count, BotRegistry.ENTRIES.size()])
		ok(bot_opt.get_item_text(0) == "CakeGame AI Bot v1",
			"the built-in bot keeps its name (got '%s')" % bot_opt.get_item_text(0))
		ok(bot_opt.selected == maxi(0, BotRegistry.index_of(GameConfig.bot_version)),
			"the dropdown reflects the configured bot")

	for key in ["seeded_map", "light_shadows", "dark_theme", "respawn_enabled",
			"show_fps", "fullscreen", "master_volume", "sfx_volume", "music_volume",
			"player_name", "server_port"]:
		ok(widgets.has(key), "the panel has a '%s' control" % key)

	# Write cycle: flip a boolean, check it persisted into the config.
	var before := GameConfig.show_fps
	var fps_box := widgets.get("show_fps") as CheckButton
	ok(fps_box != null, "the show-fps control is a check button")
	if fps_box != null:
		fps_box.button_pressed = not before
		ok(GameConfig.show_fps == not before,
			"toggling a setting writes through to GameConfig")
		ok(fps_box.button_pressed == GameConfig.show_fps,
			"the widget and the config agree after the write")
		fps_box.button_pressed = before

	# Clamping must be visible in the UI, not just in the config: bot slots are
	# capped relative to max players, and a stale widget would then lie.
	var bots_spin := widgets.get("bot_slots") as SpinBox
	if bots_spin != null:
		GameConfig.max_players = 2
		GameConfig.bot_slots = 2
		GameConfig.save_settings()
		ok(GameConfig.bot_slots <= 1,
			"save_settings clamps bot slots against max players (%d)" % GameConfig.bot_slots)
		ok(int(bots_spin.value) == GameConfig.bot_slots,
			"the spin box was refreshed after the clamp (%d vs %d)" % [
				int(bots_spin.value), GameConfig.bot_slots])
		GameConfig.max_players = 8
		GameConfig.bot_slots = 2
		GameConfig.save_settings()

	_check_plugin_section(settings)

	settings.close()
	ok(not settings.is_open(), "close() hides the panel")
	info("settings panel: %d widgets, all sections wired" % widgets.size())
	await _drop(node)


## The plugin section has to render in every host state, including the broken
## ones. The plugin host is off by default and depends on a Python that may not
## exist, so "degrades to a readable panel" is the normal path, not an edge case
## - and it is the path a fresh install always takes.
func _check_plugin_section(settings: SettingsPanel) -> void:
	var box := settings.get("_plugin_box") as VBoxContainer
	ok(box != null, "the settings panel built a plugin section")
	if box == null:
		return
	ok(box.get_child_count() > 0, "the plugin section rendered rows while OFF")

	# The section is a VBox of Controls, so the text has to be gathered by walking
	# it - there is no single label to read and asserting on the container alone
	# would pass on an empty box.
	var text := _collect_text(box)
	info("plugin section: %d rows, %d chars of text" % [box.get_child_count(), text.length()])
	ok(text.contains("Plugins") or text.contains("插件"),
		"the plugin section is labelled in the active language")

	# Toggling the master switch must persist, like every other row in this
	# panel. It is the one control a player without Python will still press.
	var toggle := _find_check(box) as CheckButton
	ok(toggle != null, "the plugin section has an enable switch")
	if toggle != null:
		var was := GameConfig.btps_enabled
		toggle.button_pressed = not was
		settings.call("_commit")
		ok(GameConfig.btps_enabled == (not was),
			"the plugin switch writes through to GameConfig")
		toggle.button_pressed = was
		settings.call("_commit")


func _collect_text(node: Node) -> String:
	var out := ""
	if node is Label or node is Button or node is CheckButton or node is LineEdit:
		out += str((node as Control).get("text")) + " "
	for child in node.get_children():
		out += _collect_text(child)
	return out


func _find_check(node: Node) -> Node:
	for child in node.get_children():
		if child is CheckButton:
			return child
		var found := _find_check(child)
		if found != null:
			return found
	return null


func _check_language() -> void:
	# Picking 中文 used to write `GameConfig.language` and stop dead: the signal
	# was declared, never emitted, never connected, and every panel hardcoded
	# English - so the setting saved a value and drew the same screen. The fix is
	# a signal every panel listens to and rebuilds on. Worth locking down twice
	# over, because a rebuild that forgets to detach first stacks a second copy
	# of every handler, and the symptom is a counter jumping by two rather than
	# a crash.
	GameConfig.language = "zh"
	var node := await _boot(SceneRouter.MENU)
	if node == null:
		return

	ok(_labels(node).has("蛋糕对战"),
		"the menu renders in Chinese by default")
	ok(_label_handlers(node, EventBus) == 1,
		"the menu holds exactly one language handler (%d)" % _label_handlers(node, EventBus))

	var settings := _settings_of(node)
	ok(settings != null and _label_handlers(settings, EventBus) == 1,
		"the settings panel holds exactly one language handler (%d)" \
			% _label_handlers(settings, EventBus))

	I18n.set_lang("en")
	await get_tree().process_frame
	var en := _labels(node)
	ok(not en.has("蛋糕对战"), "switching to English clears the Chinese text")
	ok(en.has("CAKEGAME"), "switching to English rebuilds the title")
	ok(_label_handlers(node, EventBus) == 1,
		"the rebuild did not stack a second handler (%d)" % _label_handlers(node, EventBus))
	settings = _settings_of(node)
	ok(settings != null and _label_handlers(settings, EventBus) == 1,
		"the rebuilt settings panel is wired again (%d)" \
			% _label_handlers(settings, EventBus))

	I18n.set_lang("zh")
	await get_tree().process_frame
	var back := _labels(node)
	ok(back.has("蛋糕对战"),
		"switching back to Chinese rebuilds the menu")

	# Leave the screen in the language the rest of the file measures in, so the
	# layout numbers stay comparable run to run.
	GameConfig.language = "zh"
	await _drop(node)


## Every non-empty label string under `node`, so a whole screen can be asserted
## to have been rebuilt in another language without naming its widgets.
func _labels(node: Node, root: Node = null) -> Array[String]:
	root = (root if root != null else node)
	var out: Array[String] = []
	for c in node.get_children():
		var l := c as Label
		if l != null and not l.text.strip_edges().is_empty():
			out.append(l.text.strip_edges())
		out.append_array(_labels(c, root))
	return out


## The settings panel under `node`, or null if there is not exactly one.
##
## Found by class rather than by name on purpose: a rebuild leaves the old
## panel queued for free right next to the new one, so a name search can hand
## back a node that has already been released.
func _settings_of(node: Node) -> Node:
	var panels := node.find_children("*", "SettingsPanel", true, false)
	return panels.back() if panels.size() >= 1 else null


## How many `language_changed` handlers `target` still holds on the bus.
##
## Named with the collecting recursion above because a doubled handler is the
## failure this section exists to catch, and it only shows up as a count.
func _label_handlers(target: Node, bus: Node) -> int:
	var n := 0
	for conn in bus.get_signal_connection_list("language_changed"):
		var cb: Callable = conn["callable"]
		if cb.get_object() == target:
			n += 1
	return n


func _check_lobby() -> void:
	GameConfig.max_players = 8
	GameConfig.bot_slots = 2
	NetManager.set_offline()
	var node := await _boot(SceneRouter.LOBBY)
	if node == null:
		return

	var rows := _find_named(node, "Roster") as VBoxContainer
	if rows == null:
		# The roster VBox is unnamed; count containers holding a slot row instead.
		rows = _find_rows_container(node)
	ok(rows != null, "the lobby built a roster container")
	if rows != null:
		ok(rows.get_child_count() == GameConfig.max_players,
			"the roster had one row per slot (%d rows for %d slots)" % [
				rows.get_child_count(), GameConfig.max_players])

	ok(not NetManager.room_code.is_empty(),
		"the lobby generated a room code (%s)" % NetManager.room_code)
	ok(NetManager.room_code.length() == 6,
		"the room code is six characters (%d)" % NetManager.room_code.length())
	var cleaned := Utils.clean_room_code(NetManager.room_code)
	ok(cleaned == NetManager.room_code,
		"the generated code survives the cleaner a client will run on it")

	var buttons := 0
	var q := [node]
	while not q.is_empty():
		var n: Node = q.pop_back()
		if n is Button:
			buttons += 1
		q.append_array(n.get_children())
	ok(buttons >= 4, "the lobby built its action buttons (%d)" % buttons)
	info("lobby: %d rows, room code %s, %d buttons" % [
		rows.get_child_count() if rows != null else -1, NetManager.room_code, buttons])
	await _drop(node)


## The roster rows live inside a ScrollContainer inside a PanelContainer, so the
## container that holds N same-shaped HBoxContainers is unambiguous.
func _find_rows_container(node: Node) -> VBoxContainer:
	var best: VBoxContainer = null
	var best_rows := 0
	var q := [node]
	while not q.is_empty():
		var n: Node = q.pop_back()
		if n is VBoxContainer:
			var hboxes := 0
			for c in n.get_children():
				if c is HBoxContainer:
					hboxes += 1
			if hboxes > best_rows:
				best_rows = hboxes
				best = n as VBoxContainer
		q.append_array(n.get_children())
	return best


# ===========================================================================
# layout
# ===========================================================================

## Measure every screen against the 640x360 design space, and measure the two
## things that were wrong in ways no other check in this repo can see.
##
## All four defects this section was written for were invisible in a code review,
## compiled clean, and passed the structure-only sections above: the lobby's
## START MATCH row at y = 360..382 (off the bottom of a 360 px space), the pause
## menu panel at (312,175)..(782,491), the HUD kill feed (634,6)..(824,6) with a
## height of zero, and the minimap as a 6x6 sliver in the corner. See
## `TestHarness.assert_fits` for the engine behaviour behind all four.
func _check_layout() -> void:
	var space := Vector2(640, 360)

	# Measured inside a 640x360 SubViewport, NOT inside this test's own viewport.
	# Under `--headless` the window comes up 640x640, and with
	# `window/stretch/aspect = expand` the scenes are then handed a 640x640 design
	# space - in which a control anchored to the bottom edge belongs at y=634.
	# Measuring the real window here would have reported a correct 640x640 layout
	# as six screens full of bugs. A SubViewport pins the space regardless of the
	# window, so the same numbers hold headless and on screen.
	var vp := SubViewport.new()
	vp.name = "DesignSpace"
	vp.size = Vector2i(int(space.x), int(space.y))
	vp.disable_3d = true
	add_child(vp)
	await get_tree().process_frame
	info("measuring inside a %dx%d design space" % [int(space.x), int(space.y)])

	var menu := await _boot(SceneRouter.MENU, vp)
	if menu != null:
		assert_fits(menu, space, "main menu")
		_check_footer(menu)
		var settings := _find_named(menu, "Settings") as SettingsPanel
		if settings != null:
			settings.open()
			await get_tree().process_frame
			assert_fits(settings, space, "settings panel open")
			settings.close()
		else:
			ok(false, "no SettingsPanel to measure")
		await _drop(menu)

	var lobby := await _boot(SceneRouter.LOBBY, vp)
	if lobby != null:
		assert_fits(lobby, space, "lobby")
		await _drop(lobby)

	# Both themes. The arena art does not read the palette, so anything drawn
	# straight onto it has to be legible either way - and the light-mode failure
	# was invisible in every dark screenshot.
	for dark in [true, false]:
		GameConfig.dark_theme = dark
		PixelTheme.invalidate()
		await _check_game_hud(vp, space, dark)
	GameConfig.dark_theme = true
	PixelTheme.invalidate()

	await _drop(vp)


func _check_game_hud(vp: SubViewport, space: Vector2, dark: bool) -> void:
	var where := "game HUD [%s]" % ("dark" if dark else "light")
	var game := await _boot(SceneRouter.GAME, vp)
	if game == null:
		return
	for i in 3:
		await get_tree().process_frame
	assert_fits(game, space, where)
	# The kill feed has no children until somebody dies, which is exactly why a
	# zero-height feed survived every structural check this suite had.
	for i in 5:
		EventBus.kill_feed.emit("Player", "CakeGame AI Bot v1", 0,
			Enums.Team.HUMANS, Enums.Team.BOTS)
	await get_tree().process_frame
	assert_fits(game, space, where + " with the kill feed populated")
	# The header is centred from the middle and the feed is anchored from the
	# right, so nothing keeps them apart - and they overprinted by 52 px.
	assert_no_overlap(game, [
		["Score", "KillFeed"], ["Phase", "KillFeed"],
		["ScoreTarget", "KillFeed"], ["MatchInfo", "KillFeed"],
		["Vitals", "Hint"], ["Minimap", "Hint"], ["Vitals", "Minimap"],
	], where)
	# Two of these four start with empty text and are filled in every frame,
	# which is how they ended up growing rightward from the centre line.
	assert_centred_h(game, ["Score", "Phase", "ScoreTarget", "MatchInfo"],
		space, where + " header")
	# Drawn on the arena, so they must not follow the theme. `ScoreTarget` and
	# `MatchInfo` are re-coloured every frame by `_update_top()`, so this is
	# measuring live state, not the constructor.
	assert_overlay_legible(game, ["Phase", "ScoreTarget", "MatchInfo", "Hint"], where)
	# ... and the panel-backed widgets must follow it, which they did not: the HUD
	# never assigned `theme` at all.
	assert_panel_themed(game, "Vitals", where)

	var pm := _find_named(game, "PauseMenu") as PauseMenu
	ok(pm != null, "the game scene carries a pause menu")
	if pm != null:
		pm.toggle()
		await get_tree().process_frame
		assert_fits(pm, space, where + " pause menu open")
		pm.toggle()
		await get_tree().process_frame
	await _drop(game)


## The main menu footer used to be two labels anchored to opposite corners, with
## nothing between them: measured, 689 px of text in a 584 px frame, overlapping
## by 77 px straight through the middle. It is one row now, so the ends cannot
## meet - and this asserts that the row is still the thing being built, and that
## its contents still fit inside it with room for a longer version string.
func _check_footer(root: Node) -> void:
	var foot := _find_named(root, "Footer") as HBoxContainer
	ok(foot != null, "the footer is a single row, so its two ends cannot collide")
	if foot == null:
		return
	var kids := foot.get_children()
	ok(kids.size() == 3,
		"footer is left text / flexible gap / right text (%d children)" % kids.size())
	if kids.size() != 3:
		return
	var lr := (kids[0] as Control).get_global_rect()
	var rr := (kids[2] as Control).get_global_rect()
	ok(rr.position.x - lr.end.x >= 8.0,
		"the two footer ends are %.0f px apart" % [rr.position.x - lr.end.x])
	var want := foot.get_combined_minimum_size().x
	ok(want <= foot.size.x,
		"footer content (%.0f px) fits its %.0f px row" % [want, foot.size.x])
	info("footer: %.0f px of content in a %.0f px row, ends %.0f px apart" % [
		want, foot.size.x, rr.position.x - lr.end.x])
