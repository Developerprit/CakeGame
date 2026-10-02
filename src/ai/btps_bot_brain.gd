class_name BtpsBotBrain
extends BotBrain

## Adapter that lets a Python plugin drive a bot.
##
## The interesting decision here is that **the plugin is never awaited**.
## `decide()` runs every 0.06 s, but a reply crosses a process boundary and can
## be delayed by the plugin, the interpreter, or the OS. Blocking the physics
## tick on that would stall the whole match, so instead:
##
##   * every think sends a fresh observation and keeps acting on the last reply
##     that actually arrived (one or two frames stale - invisible next to the
##     0.12 s reaction delay every brain here already carries);
##   * if no reply has landed for `STALE_AFTER`, a real `BotV1` takes over
##     silently, so a crashed or slow plugin degrades to "a bot that plays like
##     v1" rather than "a bot that stands still".
##
## Values from the plugin are clamped: a plugin cannot make the bot faster than
## the game allows, it can only choose a direction.

const HOOK: String = "cakegame.bot.brain"
const STALE_AFTER: float = 0.5
const REQUEST_TIMEOUT: float = 0.45

var plugin_id: String = ""

var _fallback: BotV1 = null
var _last: Dictionary = {}
var _age: float = STALE_AFTER
var _tick: int = 0
var _in_flight: bool = false
var _using_plugin: bool = false
## Replies the plugin has actually sent since setup.
##
## Exposed because "the bot plays badly" and "the plugin is dead" look identical
## from the outside - the fallback quietly takes over and the bot still moves. A
## test or a debug panel needs to tell those apart, and a counter is the cheapest
## way that does not require the bridge to log every invoke.
var _plugin_replies: int = 0


func setup(a: ActorBody) -> void:
	super.setup(a)
	# The fallback is a full brain, not a stub: it needs its own target, path
	# state and reaction timing to behave like v1 the moment it is needed.
	if _fallback == null:
		_fallback = BotV1.new()
	_fallback.setup(a)


func dispose() -> void:
	if _fallback != null:
		_fallback.dispose()
		_fallback = null
	super.dispose()


func decide() -> void:
	_age += Balance.AI_THINK_INTERVAL
	_send()
	if _age > STALE_AFTER or _last.is_empty():
		_from_fallback()
	else:
		_from_plugin()


func update_aim(delta: float) -> void:
	if _using_plugin and not _last.is_empty():
		# The plugin gives a world point, not a direction, because that is what
		# a brain written against screen coordinates actually computes.
		var point := Vector2(float(_last.get("ax", 0.0)), float(_last.get("ay", 0.0)))
		var to := point - actor.global_position
		if to.length_squared() > 1.0:
			aim_dir = to.normalized()
		return
	if _fallback != null:
		_fallback.actor = actor
		_fallback.target = target
		_fallback.update_aim(delta)
		aim_dir = _fallback.aim_dir
		want_fire = _fallback.want_fire


# --------------------------------------------------------------------------- #
# intent sources
# --------------------------------------------------------------------------- #

func _from_plugin() -> void:
	_using_plugin = true
	move_dir = Vector2(float(_last.get("mx", 0.0)), float(_last.get("my", 0.0))).limit_length(1.0)
	want_fire = bool(_last.get("gun", false))
	want_melee = bool(_last.get("melee", false))
	want_hook = bool(_last.get("hook", false))
	want_roll = bool(_last.get("roll", false))
	want_reload = bool(_last.get("reload", false))
	want_toggle_gun = false
	# Reloading is the one thing the plugin cannot see coming: it reads ammo,
	# but an empty magazine with no intent is just a bot standing there.
	if _ammo_empty():
		want_fire = false
		want_reload = true


func _from_fallback() -> void:
	if _fallback == null:
		return
	_using_plugin = false
	# `think()` would also raise intent_fresh and run update_aim; here we only
	# want the tactical layer, because intent_fresh is owned by this brain.
	_fallback.actor = actor
	_fallback.decide()
	move_dir = _fallback.move_dir
	want_fire = _fallback.want_fire
	want_melee = _fallback.want_melee
	want_hook = _fallback.want_hook
	want_roll = _fallback.want_roll
	want_reload = _fallback.want_reload
	want_toggle_gun = _fallback.want_toggle_gun
	aim_dir = _fallback.aim_dir


func _ammo_empty() -> bool:
	if actor == null:
		return false
	return actor.mag <= 0


# --------------------------------------------------------------------------- #
# observation / request
# --------------------------------------------------------------------------- #

func _send() -> void:
	if plugin_id.is_empty() or actor == null or not actor.is_alive():
		return
	if BtpsHost == null or not BtpsHost.declares(HOOK):
		return
	# One request in flight. Stacking them would only make the queue stale.
	if _in_flight:
		return
	if target == null or not is_instance_valid(target) or not target.is_alive():
		target = pick_target()
	_tick += 1
	_in_flight = true
	BtpsHost.invoke(plugin_id, HOOK, _observation(), _on_reply, REQUEST_TIMEOUT)


func _observation() -> Dictionary:
	var self_pos := actor.global_position
	var foe_pos := self_pos
	var foe_vel := Vector2.ZERO
	var foe_hp := 0.0
	var foe_state := ""
	var visible := false
	var dist := 0.0
	if target != null and is_instance_valid(target) and target.is_alive():
		foe_pos = target.global_position
		foe_vel = target.velocity
		foe_hp = float(target.hp)
		foe_state = str(target.state_id())
		visible = has_line_to(foe_pos)
		dist = self_pos.distance_to(foe_pos)

	var arena := _arena()
	var span := 0.0
	if arena != null:
		# Arena stores a cell count; the world is that many tiles across.
		span = float(arena.size) * Utils.TILE_F

	return {
		"self": {
			"pos": [self_pos.x, self_pos.y],
			"vel": [actor.velocity.x, actor.velocity.y],
			"hp": float(actor.hp),
			"max_hp": float(actor.get("max_hp")),
			"state": str(actor.state_id()),
			"roll_cd": actor.roll_cd,
			"gun_cd": actor.gun_cd,
			"melee_cd": actor.melee_cd,
			"hook_cd": actor.hook_cd,
			"ammo": int(actor.mag),
			"reloading": actor.reload_left > 0.0,
		},
		"target": {
			"pos": [foe_pos.x, foe_pos.y],
			"vel": [foe_vel.x, foe_vel.y],
			"hp": foe_hp,
			"state": foe_state,
			"visible": visible,
			"dist": dist,
		},
		"arena": {"w": span, "h": span},
		"tick": _tick,
	}


func _on_reply(ok: bool, result: Variant, _error: String) -> void:
	_in_flight = false
	if not ok or result == null:
		# Let _age run past STALE_AFTER so the fallback picks it up.
		return
	var payload: Dictionary = result.get("result", {}) if typeof(result) == TYPE_DICTIONARY else {}
	if payload.is_empty():
		return
	_last = {
		"mx": _num(payload.get("move", [0, 0]), 0),
		"my": _num(payload.get("move", [0, 0]), 1),
		"ax": _num(payload.get("aim", [0, 0]), 0),
		"ay": _num(payload.get("aim", [0, 0]), 1),
		"gun": bool(payload.get("gun", false)),
		"melee": bool(payload.get("melee", false)),
		"hook": bool(payload.get("hook", false)),
		"roll": bool(payload.get("roll", false)),
		"reload": bool(payload.get("reload", false)),
	}
	_plugin_replies += 1
	_age = 0.0


func _num(pair: Variant, index: int) -> float:
	if typeof(pair) != TYPE_ARRAY:
		return 0.0
	var arr := pair as Array
	if index >= arr.size():
		return 0.0
	return float(arr[index])
