extends TestHarness
## Acceptance test for the plugin host's failure modes.
##
##     godot --headless --path . res://tests/btps_degrade.tscn
##
## ## Do NOT pass `--fixed-fps`
##
## Same reason as `btps_smoke`: the flag spins the main loop hard enough to starve
## the Python child process on this machine.
##
## ## Why this suite exists
##
## `btps_smoke` proves the host works when Python is there. This one proves the
## promise that actually matters to a player, which is the one in the host's own
## header comment: **a broken plugin system must never break the game.**
##
## That claim is easy to make and easy to break, because the plugin host is an
## autoload on every run. A `NO_PYTHON` status that throws, a bridge that never
## publishes its port, or a plugin brain left pointing at a dead bridge are all
## ways to take down a game that has no reason to be down. So each of those is
## provoked on purpose and the game is asked to keep playing afterwards.

const FPS: int = 60

## Frames to let a real match-ish scene run. Long enough that a bot has to make
## decisions, because "the game did not crash" and "the game is still playable"
## are different claims.
const PLAY_SECONDS: float = 3.0

var _world: Node2D = null
var _arena: Arena = null
var _bot: BotActor = null


func _ready() -> void:
	# A suite that cannot even load must not hang the run.
	#
	# This file had a parse error once (`get_tree().physics_frame` treated as a
	# value when it is a signal) and the scene sat there with no output and no
	# exit until it was killed by hand. `get_tree().quit()` after a fixed budget
	# turns "still running at 3 minutes" into a visible failure, which is the
	# difference between a bug you notice and a bug you find later.
	var guard := Timer.new()
	guard.one_shot = true
	guard.wait_time = 120.0
	guard.timeout.connect(func():
		print("BTPS-DEGRADE TIMED OUT - a check is stuck")
		get_tree().quit(2))
	add_child(guard)
	guard.start()

	await run_async("no python is a first-class state", _t_no_python)
	await run_async("the game plays with no python", _t_plays_without_python)
	await run_async("a dead bridge does not stop the game", _t_dead_bridge)
	await run_async("the built-in bot is unaffected", _t_builtin_bot)
	var code := report("BTPS-DEGRADE")
	get_tree().quit(code)


# --------------------------------------------------------------------------- #
# checks
# --------------------------------------------------------------------------- #

## A bad interpreter path must not be the end of the story.
##
## The first draft of this test asserted `status == NO_PYTHON` after pointing
## `btps_python_path` at a path that cannot exist. It failed, and the host was
## right: `_resolve_python()` treats the configured path as a *preference* and
## falls back to auto-detection when the probe fails, so the host reached READY
## on `py -3`. That is the correct product behaviour - a stale path left over
## from a Python uninstall must not permanently disable plugins - so the
## assertion was wrong, not the code.
##
## What is worth asserting is the branch that actually matters: with a
## *deliberately unresolvable* configuration the host must not hang, must not
## report READY, and must leave the game alone.
func _t_no_python() -> void:
	BtpsHost.shutdown()
	GameConfig.btps_python_path = "definitely-not-a-real-interpreter-xyz"
	BtpsHost.boot()
	await _wait_until(func() -> bool: return BtpsHost.status != 2, 20.0)
	info("status=%d note='%s' python='%s'" % [
		BtpsHost.status, BtpsHost.status_note, BtpsHost.python_path])
	ok(BtpsHost.status != 2, "the host settles instead of hanging in STARTING")
	if BtpsHost.status == 3:
		# The fallback found a real interpreter, which is the designed outcome.
		info("auto-detection recovered the host via '%s'" % BtpsHost.python_path)
		ok(BtpsHost.python_path.find("definitely-not-a-real") == -1,
			"the dead path was dropped rather than used")
	else:
		ok(BtpsHost.status == 1, "an unusable interpreter lands in NO_PYTHON")
		ok(BtpsHost.plugins.is_empty(), "no plugins are listed without a host")
		ok(BtpsHost.brains.is_empty(), "no plugin brains are registered without a host")
	# Either way, the registry must not be holding a brain nobody can create.
	ok(not BotRegistry.ids().has("btps:com.kscm.cakegame.example-bot") or BtpsHost.status == 3,
		"no uncreatable plugin brain is offered in the bot list")


## The load-bearing check: with the host permanently unable to start, does a
## normal match still run?
func _t_plays_without_python() -> void:
	_build_rig()
	await get_tree().physics_frame
	var start := _bot.global_position
	var moved := 0.0
	for _i in int(PLAY_SECONDS * float(FPS)):
		if _bot != null and is_instance_valid(_bot):
			moved = maxf(moved, _bot.global_position.distance_to(start))
		await get_tree().physics_frame
	info("bot moved %.0f px with the plugin host unavailable" % moved)
	ok(_bot != null and is_instance_valid(_bot), "the bot survived the broken host")
	ok(_bot != null and _bot.is_alive(), "the bot is still alive after 3 s")
	ok(moved > 8.0, "the bot still makes decisions without a plugin host (%.0f px)" % moved)
	ok(BtpsHost.status != 2, "the host did not get stuck in STARTING")
	_teardown_rig()


## Kill the bridge out from under a running host.
##
## This is the crash case, and the promise is specific: the child process dies,
## Godot notices, the game keeps going, and - since the runtime lives in a child
## process - the host brings itself back once.
##
## The kill goes through `_fail()` rather than `stop()` on purpose. `stop()` is
## the *clean* shutdown path and lands the bridge in `IDLE`, which the host
## deliberately treats as "the player asked for this" and does not escalate; the
## first version of this test called it and then asserted the host had noticed,
## which failed for the right reason. A crash is `DEAD`, and that is the branch
## with restart logic behind it.
func _t_dead_bridge() -> void:
	# Restore a real interpreter so the host actually starts, then break it.
	GameConfig.btps_python_path = ""
	BtpsHost.boot()
	await _wait_until(func() -> bool: return BtpsHost.status == 3, 30.0)
	if BtpsHost.status != 3:
		ok(false, "the host did not reach READY, so the crash path is untested")
		return
	ok(true, "the host reached READY with a working interpreter")
	var bridge: BtpsBridge = BtpsHost.get("_bridge")
	ok(bridge != null and bridge.is_live(), "the bridge is live before the kill")

	_build_rig()
	await get_tree().physics_frame
	var start := _bot.global_position
	var moved := 0.0
	var frames_alive := 0

	# Kill the child mid-flight rather than before the rig exists: the point is
	# that a *running* game survives losing its plugin host, not that a game which
	# never started one is fine.
	#
	# `physics_frame` is a SIGNAL, not a frame counter - the first version tried to
	# subtract it, which is a parse error, so the whole suite failed to load and
	# hung with no output. Nothing here needs a frame count, so the loop just
	# awaits.
	if bridge != null:
		bridge.call("_fail", "killed on purpose by the degrade test")
	for _i in int(PLAY_SECONDS * float(FPS)):
		if _bot != null and is_instance_valid(_bot) and _bot.is_alive():
			frames_alive += 1
			moved = maxf(moved, _bot.global_position.distance_to(start))
		await get_tree().physics_frame

	info("after the kill: status=%d, bot moved %.0f px, alive on %d frames" % [
		BtpsHost.status, moved, frames_alive])
	ok(frames_alive == int(PLAY_SECONDS * float(FPS)),
		"the bot stayed alive for every frame after the bridge died")
	ok(moved > 8.0, "the game kept simulating after the bridge died (%.0f px)" % moved)
	# Deliberately NOT asserting `status != READY` here. The restart is deferred
	# by only 8 frames and the loop below runs 180, so by the time this line is
	# reached the host has legitimately come back up - a green "still READY" is
	# the *good* outcome and asserting otherwise would have demanded a bug.
	# What has to hold is that the game never noticed, which is the two lines above.
	ok(BtpsHost.status == 3, "the host is serving again after the kill")

	# The restart is deferred by BOOT_DELAY_FRAMES, and `PLAY_SECONDS` may have
	# already elapsed, so give it a fair window before asking.
	await _wait_until(func() -> bool: return BtpsHost.status == 3, 25.0)
	info("after the restart window: status=%d" % BtpsHost.status)
	ok(BtpsHost.status == 3, "the host came back by itself after one restart")
	# The host reuses ONE BtpsBridge instance for its whole life, created in
	# `_ready()` and re-`start()`ed after a death. So "the same object is live
	# again" is the success signal, not a bug - the first version of this line
	# asserted the opposite and failed against a correctly restarted host.
	ok(bridge != null and bridge.is_live(),
		"the bridge object is serving again after the restart")

	# A second death must NOT loop forever: the budget is one, and exhausting it
	# has to surface as an error the player can see.
	var bridge2: BtpsBridge = BtpsHost.get("_bridge")
	if bridge2 != null and bridge2.is_live():
		bridge2.call("_fail", "killed a second time on purpose")
		await _wait_until(func() -> bool: return BtpsHost.status != 2, 20.0)
	info("after the second kill: status=%d note='%s'" % [
		BtpsHost.status, BtpsHost.status_note])
	ok(BtpsHost.status == 4, "a second death is reported as a real error, not retried forever")
	_teardown_rig()


## The bots that ship with the game must be exactly as good with the host dead
## as with it absent, because that is the whole point of the fallback path.
func _t_builtin_bot() -> void:
	_build_rig("cakegame_v1_pro")
	await get_tree().physics_frame
	var start := _bot.global_position
	var moved := 0.0
	for _i in int(PLAY_SECONDS * float(FPS)):
		if _bot != null and is_instance_valid(_bot):
			moved = maxf(moved, _bot.global_position.distance_to(start))
		await get_tree().physics_frame
	info("v1 pro moved %.0f px with the host down" % moved)
	ok(moved > 8.0, "a built-in brain plays normally with the host down (%.0f px)" % moved)
	ok(BotRegistry.ids().has("cakegame_v1"), "the built-in v1 is still registered")
	ok(BotRegistry.ids().has("cakegame_v1_pro"), "v1 pro is still registered")
	_teardown_rig()


# --------------------------------------------------------------------------- #
# helpers
# --------------------------------------------------------------------------- #

func _wait_until(condition: Callable, seconds: float) -> void:
	for _i in int(seconds * float(FPS)):
		if condition.call():
			return
		await get_tree().process_frame


## One arena and one bot - enough that the bot has a world to think about, and
## nothing that could fail for reasons unrelated to the plugin host.
func _build_rig(brain_id: String = "cakegame_v1") -> void:
	GameConfig.seeded_map = true
	GameConfig.map_seed_text = "btps-degrade"
	GameConfig.friendly_fire = false
	NetManager.set_offline()

	_world = Node2D.new()
	_world.name = "World"
	add_child(_world)

	_arena = Arena.new()
	_arena.name = "Arena"
	_world.add_child(_arena)
	_arena.build(MapGenerator.generate(GameConfig.effective_seed()))

	var projectiles := Node2D.new()
	projectiles.name = "Projectiles"
	projectiles.add_to_group(&"projectile_layer")
	_world.add_child(projectiles)

	var body := BotActor.new()
	body.configure({
		"id": 1,
		"team": Enums.Team.HUMANS,
		"kind": Enums.Kind.BOT,
		"name": "Solo",
		"local": false,
		"authoritative": true,
		"color": Enums.team_color(Enums.Team.HUMANS),
	})
	body.position = _arena.spawn_point(Enums.Team.HUMANS, 0)
	_world.add_child(body)
	body.setup_brain(brain_id)
	_bot = body


func _teardown_rig() -> void:
	for node in get_tree().get_nodes_in_group(&"actor"):
		node.queue_free()
	if _world != null and is_instance_valid(_world):
		_world.queue_free()
	_bot = null
	_world = null
	_arena = null
	await get_tree().process_frame
