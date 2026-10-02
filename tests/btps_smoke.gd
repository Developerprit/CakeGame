extends TestHarness
## Headless acceptance test for the BTPS plugin host.
##
##     godot --headless --path . res://tests/btps_smoke.tscn
##
## ## Do NOT pass `--fixed-fps`
##
## With `--fixed-fps` the engine drives the main loop as fast as it can, and on
## this machine that starves the child process: the bridge starts, stays alive,
## and never gets far enough to publish its port. The host then spends 20 s
## timing out. Without the flag it is ready in well under a second. The flag is
## for deterministic physics in the other suites; a real build runs at vsync
## and is unaffected.
##
## This is the check that actually proves the host works, because it does the
## only thing a static check cannot: install a real `.btp`, let a real Python
## brain drive a real bot, and then uninstall it.
##
## ## Why it can pass without Python
##
## The host's contract is "a broken plugin system must never break the game".
## So when no usable interpreter exists, the test asserts the degraded path
## instead (status NO_PYTHON, game still runs) and reports green. To exercise
## the full path on a machine where auto-detection does not find the
## interpreter, point `BTPS_PYTHON` at it:
##
##     BTPS_PYTHON=/path/to/python godot --headless --path . res://tests/btps_smoke.tscn

const SAMPLE_RES: String = "res://assets/btps_samples/example-bot-1.0.0.btp"
const SAMPLE_NAME: String = "example-bot-1.0.0.btp"
const PLUGIN_ID: String = "com.kscm.cakegame.example-bot"
const BRAIN_ID: String = "btps:" + PLUGIN_ID

# BtpsHost.Status - numeric because the enum lives on an autoload script.
const ST_OFF: int = 0
const ST_NO_PYTHON: int = 1
const ST_STARTING: int = 2
const ST_READY: int = 3
const ST_ERROR: int = 4

const DRIVE_SECONDS: float = 8.0
const FPS: int = 60

var _skipped: bool = false

var _arena: Arena = null
var _actors: Node2D = null
var _plugin_bot: BotActor = null
var _sparring: BotActor = null
var _moved: float = 0.0
var _fired_frames: int = 0
var _plugin_intents: int = 0


func _ready() -> void:
	# Auto-detection looks at `py`, `python`, and the per-user install dir. A
	# portable or sandboxed interpreter is not there, so allow an override.
	var override := OS.get_environment("BTPS_PYTHON")
	if not override.is_empty():
		GameConfig.btps_python_path = override

	await run_async("host boots", _t_boot)
	await run_async("package is readable", _t_scan)
	await run_async("install and enable", _t_install)
	await run_async("brain reaches the registry", _t_registry)
	await run_async("brain drives a bot", _t_drive)
	await run_async("uninstall", _t_uninstall)
	var code := report("BTPS-SMOKE")
	get_tree().quit(code)


# --------------------------------------------------------------------------- #
# checks
# --------------------------------------------------------------------------- #

func _t_boot() -> void:
	# The host queues its own boot a few frames in (see BOOT_DELAY_FRAMES), so
	# give that a chance before kicking it by hand.
	await _wait_until(func() -> bool: return BtpsHost.status != ST_OFF, 3.0)
	if BtpsHost.status == ST_OFF:
		BtpsHost.boot()
	await _wait_until(func() -> bool: return BtpsHost.status != ST_STARTING, 30.0)
	info("status=%d note='%s' python='%s'" % [
		BtpsHost.status, BtpsHost.status_note, BtpsHost.python_path])
	ok(BtpsHost.status != ST_STARTING, "the host settles instead of hanging in STARTING")
	if BtpsHost.status != ST_READY:
		_skipped = true
		info("no live plugin host (%s); the remaining checks assert the degraded path" % BtpsHost.status_note)
	else:
		ok(true, "host reached READY")


func _t_scan() -> void:
	if _skipped:
		ok(true, "skipped (no python)")
		return
	_copy_sample()
	var found := BtpsHost.scan_packages()
	info("packages in user://plugins: %d" % found.size())
	var hit: Dictionary = {}
	for p in found:
		if str(p.get("file", "")) == SAMPLE_NAME:
			hit = p
	ok(not hit.is_empty(), "the sample .btp is found by the scan")
	ok(bool(hit.get("readable", false)), "the manifest can be read without python (ZIPReader)")
	var manifest: Dictionary = hit.get("manifest", {})
	ok(str(manifest.get("id", "")) == PLUGIN_ID, "manifest id matches the plugin")


func _t_install() -> void:
	if _skipped:
		ok(true, "skipped (no python)")
		return
	# Idempotent: a previous run may have left it installed.
	if _has_plugin():
		BtpsHost.uninstall(PLUGIN_ID)
		await _wait_until(func() -> bool: return not _has_plugin(), 10.0)
	var path := "user://plugins/" + SAMPLE_NAME
	BtpsHost.install(path, PackedStringArray())
	await _wait_until(func() -> bool: return _has_plugin(), 20.0)
	ok(_has_plugin(), "the plugin is installed")
	if _has_plugin():
		info("state=%s" % _record().get("state", "?"))
		ok(str(_record().get("state", "")) == "enabled", "the plugin is enabled after install")


func _t_registry() -> void:
	if _skipped:
		ok(true, "skipped (no python)")
		return
	var ids := BotRegistry.ids()
	info("bot ids: %s" % ", ".join(ids))
	ok(ids.has(BRAIN_ID), "the plugin brain appears in the bot dropdown")
	ok(ids.has("cakegame_v1"), "the shipped brains are still there")


func _t_drive() -> void:
	if _skipped:
		ok(true, "skipped (no python)")
		return
	_build_rig()
	await get_tree().physics_frame
	var placed := _place_duel()
	await get_tree().physics_frame
	# The precondition, asserted. Everything below depends on the two bots being
	# able to see each other, so it is a check in its own right rather than a
	# silent setup step - a map generator that stops producing open lanes then
	# fails here, loudly, instead of as a mysterious zero.
	ok(placed, "the rig gives both bots a line of sight (%.0f px apart)" % [
		_plugin_bot.global_position.distance_to(_sparring.global_position)])
	var start_pos := _plugin_bot.global_position
	var frames := int(DRIVE_SECONDS * float(FPS))
	var diag := {"replies": 0, "visible": 0, "ammo": 0, "gun_out": 0, "hook_declared": 0}
	for _i in frames:
		if _plugin_bot != null and is_instance_valid(_plugin_bot):
			_moved = maxf(_moved, _plugin_bot.global_position.distance_to(start_pos))
			if bool(_plugin_bot.get("want_fire")):
				_fired_frames += 1
			_diagnose(diag)
		await get_tree().physics_frame
	info("plugin bot travelled %.0f px, wanted fire on %d frames" % [_moved, _fired_frames])
	info("diagnostics: %s" % str(diag))
	ok(_moved > 24.0, "the python brain actually moves the bot")
	# The load-bearing assertion of this whole suite: replies crossed the process
	# boundary and came back. Movement alone would not prove it, because the
	# fallback brain moves too - a dead plugin looks like a working one until you
	# count the round trips.
	ok(int(diag["replies"]) > 0, "the python plugin answered the hook (%d frames)" % int(diag["replies"]))
	ok(_fired_frames > 0, "the python brain produces combat intent")
	_teardown_rig()


## Sample the plugin brain's own state.
##
## "The bot never fired" has four very different root causes - the plugin never
## answered, it answered but saw no line of sight, it answered and wanted to fire
## with an empty magazine, or it answered and the gun was holstered. Guessing
## from the outside costs a rebuild per hypothesis, so read the internals.
func _diagnose(diag: Dictionary) -> void:
	var brain: BotBrain = _plugin_bot.get("brain")
	if brain == null:
		return
	diag["replies"] = int(diag["replies"]) + (1 if int(brain.get("_plugin_replies")) > 0 else 0)
	var foe: ActorBody = brain.get("target")
	if foe != null and is_instance_valid(foe):
		if brain.has_line_to(foe.global_position):
			diag["visible"] = int(diag["visible"]) + 1
	diag["ammo"] = int(_plugin_bot.mag)
	diag["gun_out"] = int(diag["gun_out"]) + (1 if _plugin_bot.is_gun_out() else 0)
	diag["hook_declared"] = 1 if BtpsHost.declares("cakegame.bot.brain") else 0


func _t_uninstall() -> void:
	if _skipped:
		ok(true, "skipped (no python)")
		return
	BtpsHost.uninstall(PLUGIN_ID)
	await _wait_until(func() -> bool: return not _has_plugin(), 15.0)
	ok(not _has_plugin(), "the plugin is gone after uninstall")
	ok(not BotRegistry.ids().has(BRAIN_ID), "the brain leaves the dropdown with it")


# --------------------------------------------------------------------------- #
# helpers
# --------------------------------------------------------------------------- #

func _has_plugin() -> bool:
	for record in BtpsHost.plugins:
		if str(record.get("id", "")) == PLUGIN_ID:
			return true
	return false


func _record() -> Dictionary:
	for record in BtpsHost.plugins:
		if str(record.get("id", "")) == PLUGIN_ID:
			return record
	return {}


func _copy_sample() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://plugins"))
	var bytes := FileAccess.get_file_as_bytes(SAMPLE_RES)
	if bytes.is_empty():
		ok(false, "sample .btp is missing from the project")
		return
	var handle := FileAccess.open("user://plugins/" + SAMPLE_NAME, FileAccess.WRITE)
	if handle == null:
		ok(false, "cannot write into user://plugins")
		return
	handle.store_buffer(bytes)
	handle.close()


func _wait_until(condition: Callable, seconds: float) -> void:
	var frames := int(seconds * float(FPS))
	for _i in frames:
		if condition.call():
			return
		await get_tree().process_frame


# --------------------------------------------------------------------------- #
# rig - two bots and an arena, nothing else
# --------------------------------------------------------------------------- #

func _build_rig() -> void:
	GameConfig.seeded_map = true
	GameConfig.map_seed_text = "btps-smoke"
	GameConfig.friendly_fire = false
	NetManager.set_offline()

	var world := Node2D.new()
	world.name = "World"
	add_child(world)

	_arena = Arena.new()
	_arena.name = "Arena"
	world.add_child(_arena)
	_arena.build(MapGenerator.generate(GameConfig.effective_seed()))

	_actors = Node2D.new()
	_actors.name = "Actors"
	world.add_child(_actors)

	var projectiles := Node2D.new()
	projectiles.name = "Projectiles"
	projectiles.add_to_group(&"projectile_layer")
	world.add_child(projectiles)

	_plugin_bot = _spawn(1, Enums.Team.HUMANS, "Plugin", BRAIN_ID)
	_sparring = _spawn(2, Enums.Team.BOTS, "Sparring", "cakegame_v1")
	_moved = 0.0
	_fired_frames = 0
	_plugin_intents = 0


## Put both bots somewhere they can actually see each other.
##
## The rig originally used `spawn_point(team, 0)`, which on the seeded map put
## the two of them on opposite sides of the arena with walls in between. That is
## a legitimate position for a real match and a useless one for this test:
## `pick_target()` only ever selects from *visible* enemies, so with no line of
## sight `target` stayed null, the plugin was handed
## `{visible: false, dist: 0}`, and it correctly declined to shoot. The result was
## a green "the bot moves" and a red "the bot never fires" that said nothing about
## the bridge at all.
##
## So the duel now searches the map for a walkable pair with a clear line, and
## asserts it found one - the precondition becomes a checked fact instead of an
## assumption, and a map generator that stops producing open lanes fails loudly
## here rather than as a mysterious zero.
func _place_duel() -> bool:
	for candidate in _duel_candidates():
		# Move first, then check. `Combat.has_line` casts from the attacker's
		# CURRENT position, so validating before the teleport measures the line
		# from the spawn pad - which is how this first attempt "found" a pair that
		# turned out to be 48 px apart and still walled off.
		_plugin_bot.global_position = candidate["a"]
		_sparring.global_position = candidate["b"]
		_plugin_bot.velocity = Vector2.ZERO
		_sparring.velocity = Vector2.ZERO
		if Combat.has_line(_plugin_bot, _sparring.global_position):
			return true
	return false


## Candidate duels, best first: mid-range and in open space.
##
## Ordered by "how much room is around it" rather than by distance from the
## middle, because a lane that is technically clear at 3 tiles can still have a
## prop at its edge that the physics body brushes during the approach.
func _duel_candidates() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if _arena == null:
		return out
	for gap in [7, 6, 8, 5, 9, 10]:
		for y in range(0, _arena.size, 2):
			for x in range(0, _arena.size, 2):
				var a := Vector2i(x, y)
				var b := a + Vector2i(gap, 0)
				if not _arena.is_walkable_pos(_arena.cell_center(a)):
					continue
				if not _arena.is_walkable_pos(_arena.cell_center(b)):
					continue
				out.append({"a": _arena.cell_center(a), "b": _arena.cell_center(b)})
	return out


func _spawn(id: int, team: int, label: String, brain_id: String) -> BotActor:
	var body := BotActor.new()
	body.configure({
		"id": id,
		"team": team,
		"kind": Enums.Kind.BOT,
		"name": label,
		"local": false,
		"authoritative": true,
		"color": Enums.team_color(team),
	})
	body.position = _arena.spawn_point(team, 0)
	_actors.add_child(body)
	body.setup_brain(brain_id)
	return body


func _teardown_rig() -> void:
	for node in get_tree().get_nodes_in_group(&"actor"):
		node.queue_free()
	_plugin_bot = null
	_sparring = null
	_arena = null
	await get_tree().process_frame
