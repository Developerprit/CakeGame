class_name BotV1
extends BotBrain
## CakeGame AI Bot v1.
##
## Design thesis: in a game where the character ALWAYS faces the aim source, aim
## direction is public information. That single rule is what turns a competent
## bot into a scary one, because it makes *predictive* dodging legitimate - the
## bot can watch your muzzle swing onto it and be gone before the bullet exists.
## Nothing here reads hidden state: every input is something a human could also
## see on screen.
##
## The decision order is deliberate and is the part that is easy to get wrong:
##
##   1. reactive dodge   (a bullet is already on a collision course)
##   2. predictive dodge (he is pointing at me and can shoot)
##   3. melee execution  (he is reloading / dry / nearly dead)
##   4. reload + cover   (I am dry; break the line instead of dying bravely)
##   5. positional play  (hold the 58-92 px band, orbit, use A* when a wall is
##                        in the way, and grapple in when he runs)
##
## Stage 1 precedes everything. A bot that finishes its reload before dodging
## reads as "dumb" no matter how good its aim is.
##
## Difficulty is fixed. Every number that could soften it lives in `Balance`
## under an `AI_` prefix and is not reachable from any player-facing setting.

enum Mode {
	HUNT,        ## no visible target: move to the last known position
	ENGAGE,      ## shoot and hold the preferred range band
	RUSH,        ## close for melee because the target is in a bad state
	COVER,       ## reloading behind geometry
	REPOSITION,  ## the line is broken; rotate
}

var mode: int = Mode.HUNT

# --- memory ----------------------------------------------------------------
var _last_seen_pos: Vector2 = Vector2.INF
var _last_seen_vel: Vector2 = Vector2.ZERO
var _last_seen_time: float = -99.0
var _target_visible: bool = false
var _acquire_time: float = 0.0

# --- pacing ----------------------------------------------------------------
var _dodge_cd: float = 0.0
var _react: float = 0.0
var _burst: float = 0.0
var _rest: float = 0.0
var _aim_lock: float = 0.0
var _hook_cd: float = 0.0
var _orbit_flip: float = 0.0
var _orbit_sign: float = 1.0

# --- navigation ------------------------------------------------------------
var _path: PackedVector2Array = PackedVector2Array()
var _path_i: int = 0
var _path_goal: Vector2 = Vector2.INF
var _path_t: float = 0.0
var _anchor_pos: Vector2 = Vector2.ZERO
var _anchor_t: float = 0.0
var _stuck: int = 0
var _unstick_left: float = 0.0
var _unstick_dir: Vector2 = Vector2.ZERO

# --- cover -----------------------------------------------------------------
var _cover: Vector2 = Vector2.INF
var _cover_t: float = 0.0

# --- hunting a cold lead ---------------------------------------------------
var _search_goal: Vector2 = Vector2.INF
var _search_wander: float = 0.0
## Enemy spawn pads already checked during the current sweep. Cleared once all of
## them have been visited, so the search is a loop rather than a dead end.
var _search_visited: Dictionary = {}


func setup(a: ActorBody) -> void:
	super.setup(a)
	_anchor_pos = a.global_position
	_orbit_sign = 1.0 if _rng.randf() < 0.5 else -1.0
	_orbit_flip = _rng.randf_range(0.8, 2.0)


# ===========================================================================
# decision
# ===========================================================================

func decide() -> void:
	var dt: float = Balance.AI_THINK_INTERVAL
	_time_tick(dt)

	# reset the whole intent surface so nothing is repeated from last think
	want_fire = false
	want_melee = false
	want_roll = false
	want_hook = false
	want_toggle_gun = false
	want_reload = false
	move_dir = Vector2.ZERO

	if actor == null or not is_instance_valid(actor) or not actor.alive:
		return

	_update_stuck(dt)

	# ---- 1. reactive: something is about to hit me ------------------------
	var threat := incoming_threat()
	if bool(threat.get("found", false)) and _react >= Balance.AI_DODGE_REACTION \
			and actor.roll_cd <= 0.0 and actor.can_act():
		_do_dodge(threat.get("dodge_dir", Vector2.RIGHT), 0.30)
		return

	# ---- target picture ---------------------------------------------------
	var tgt := pick_target()
	_target_visible = tgt != null
	if tgt != target:
		_acquire_time = _time
	target = tgt
	if _target_visible:
		_last_seen_pos = target.global_position
		_last_seen_vel = target.velocity
		_last_seen_time = _time

	# ---- 2. predictive: he is aiming at me --------------------------------
	if _target_visible and _react >= Balance.AI_DODGE_REACTION \
			and actor.roll_cd <= 0.0 and actor.can_act():
		var d: float = actor.global_position.distance_to(target.global_position)
		if d < Balance.AI_MAX_RANGE_ENGAGE * 0.85 and is_aimed_at_me(target):
			# Not literally every time. A bot that dodges with 100% reliability is
			# not "smart", it is unbeatable, and the counter-play (fake the aim,
			# then fire late) stops existing.
			if _rng.randf() < 0.72:
				_do_dodge(perpendicular_escape(target), 0.45)
				return

	if not _target_visible:
		mode = Mode.HUNT
		_weapon_housekeeping()
		_move_with_pathing(_hunt_dir(dt))
		return

	# ---- 3/4. engagement --------------------------------------------------
	var to_t: Vector2 = target.global_position - actor.global_position
	var dist: float = to_t.length()

	if dist <= Balance.AI_MELEE_RANGE + 3.0 and _wants_melee(target, dist):
		mode = Mode.RUSH
		want_melee = true
		want_fire = false
		move_dir = to_t.normalized()
		_aim_direct(target, false)
		return

	_weapon_housekeeping()

	if actor.reload_left > 0.0:
		mode = Mode.COVER
		_move_to_cover(to_t, dt)
		return

	# ---- grapple in when he disengages ------------------------------------
	if actor.hook_cd <= 0.0 and _hook_cd <= 0.0 and actor.can_act():
		if dist > Balance.AI_PREFERRED_MAX + 30.0:
			_hook_cd = 2.0
			want_hook = true
			want_fire = false
			_aim_direct(target, false)
			move_dir = to_t.normalized()
			return

	# ---- 5. positional play -----------------------------------------------
	mode = Mode.ENGAGE
	_move_with_pathing(_desired_velocity(to_t, dist))

	# ---- fire control -----------------------------------------------------
	_aim_direct(target, true)
	if _can_shoot(target):
		want_fire = true
		_burst += dt
		if _burst >= 0.34:
			_burst = 0.0
			_rest = _rng.randf_range(0.09, 0.20)
	else:
		if _rest > 0.0:
			_rest -= dt
		else:
			_burst = 0.0


# ===========================================================================
# aim
# ===========================================================================

func update_aim(delta: float) -> void:
	if _aim_lock > 0.0:
		_aim_lock -= delta
		return
	if actor == null or not is_instance_valid(actor) or not actor.alive:
		return
	if target == null or not is_instance_valid(target) or not target.alive:
		return
	if not _target_visible:
		return
	# Directional lead scaled by range: at knife range a full lead misses a
	# strafing target worse than no lead at all.
	var dist: float = actor.global_position.distance_to(target.global_position)
	var lead_weight: float = clampf(dist / 80.0, 0.0, 1.0)
	var p: Vector2 = target.global_position
	if lead_weight > 0.05:
		var full := lead_point(target, actor.global_position, Balance.BULLET_SPEED)
		p = target.global_position.lerp(full, lead_weight)
	var d: Vector2 = p - actor.global_position
	if d.length_squared() > 1.0:
		aim_dir = d.normalized()


func _aim_direct(t: ActorBody, lead: bool) -> void:
	aim_at(t, lead)
	_aim_lock = 0.05


# ===========================================================================
# behaviour helpers
# ===========================================================================

func _time_tick(dt: float) -> void:
	_react += dt
	_dodge_cd = maxf(0.0, _dodge_cd - dt)
	_hook_cd = maxf(0.0, _hook_cd - dt)
	_orbit_flip -= dt
	if _orbit_flip <= 0.0:
		_orbit_flip = _rng.randf_range(0.9, 2.4)
		_orbit_sign = 1.0 if _rng.randf() < 0.5 else -1.0


func _do_dodge(dir: Vector2, cooldown: float) -> void:
	var d := dir
	if d.length_squared() < 0.01:
		d = _random_dir()
	# Never roll into a wall: a dodge that ends against geometry is a free kill
	# hand-out, and it looks like a bug from the outside.
	if _direction_blocked(d):
		d = -d
	move_dir = d.normalized()
	want_roll = true
	want_fire = false
	_dodge_cd = cooldown
	_react = 0.0
	_unstick_left = 0.0


## Melee is a finisher, not a default. The bot only commits when the target is
## reloading, dry, or nearly dead - i.e. when it cannot punish the approach.
func _wants_melee(t: ActorBody, dist: float) -> bool:
	if actor.melee_cd > 0.0:
		return false
	if dist > Balance.AI_MELEE_RANGE + 3.0:
		return false
	var vulnerable: bool = t.reload_left > 0.0 or t.mag <= 0 \
		or (t.hp / maxf(1.0, t.max_hp)) < 0.30
	var i_am_dry: bool = actor.mag <= 0
	return vulnerable or i_am_dry


func _weapon_housekeeping() -> void:
	if actor.mag > 0 and not actor.is_gun_out():
		want_toggle_gun = true
	# Top up during a lull rather than at zero, so the bot is never caught empty
	# mid-duel by its own fault.
	if actor.is_gun_out() and actor.reload_left <= 0.0 and actor.mag <= 3:
		var t := target
		if t != null and is_instance_valid(t):
			var d: float = actor.global_position.distance_to(t.global_position)
			if actor.mag <= 0 or d > Balance.AI_PREFERRED_MAX:
				want_reload = true


func _can_shoot(t: ActorBody) -> bool:
	if not actor.gun_ready():
		return false
	if _rest > 0.0:
		return false
	if _time - _acquire_time < Balance.AI_REACTION_TIME:
		return false
	if t == null or not is_instance_valid(t) or not t.alive:
		return false
	# Do not waste rounds on someone inside their dodge i-frames: the shot
	# physically cannot land, and a human would hold fire too.
	if t.state_id() == &"roll" and t.i_frames > 0.0:
		return false
	if t.spawn_invuln > 0.0:
		return false
	var dist: float = actor.global_position.distance_to(t.global_position)
	if dist > Balance.BULLET_RANGE * 0.96:
		return false
	return true


func _move_to_cover(to_t: Vector2, dt: float) -> void:
	_cover_t -= dt
	if _cover == Vector2.INF or _cover_t <= 0.0 or \
			actor.global_position.distance_to(_cover) < 10.0:
		_cover = find_cover(target.global_position)
		_cover_t = 1.1
	if _cover == Vector2.INF:
		# Nothing to hide behind: concede ground along the axis instead.
		var back: Vector2 = -to_t.normalized()
		if _direction_blocked(back):
			back = Vector2(-back.y, back.x)
		move_dir = back
		return
	_move_with_pathing((_cover - actor.global_position).normalized())


# ===========================================================================
# movement
# ===========================================================================

## Hold the preferred range band and orbit. Strafing perpendicular to the
## target's aim axis is what makes the bot hard to hit with a mouse: a target
## that only ever closes or retreats sits directly on your crosshair.
func _desired_velocity(to_t: Vector2, dist: float) -> Vector2:
	var radial := Vector2.ZERO
	if dist > Balance.AI_PREFERRED_MAX:
		radial = to_t.normalized() * clampf(
			(dist - Balance.AI_PREFERRED_MAX) / 45.0, 0.35, 1.0)
	elif dist < Balance.AI_PREFERRED_MIN:
		radial = -to_t.normalized() * clampf(
			(Balance.AI_PREFERRED_MIN - dist) / 34.0, 0.35, 1.0)

	var tangent := Vector2(-to_t.y, to_t.x).normalized() * _orbit_sign
	var out := (radial + tangent * 0.9)
	if out.length_squared() < 0.01:
		out = tangent
	return out.limit_length(1.0)


func _hunt_dir(dt: float) -> Vector2:
	# Never seen anybody this round, or nobody for a long time: go and look.
	#
	# This branch is load-bearing, and it used to be missing. The old code seeded
	# `_last_seen_pos` with the bot's OWN position when it had no lead, so the
	# "have I arrived at the lead?" test was true on the very first frame and the
	# bot fell straight into the orbit-the-area sweep - around its own spawn pad,
	# forever. Two bots spent a whole round circling where they started, 2700 px
	# each, and never met the players. Measured, not theorised.
	if _last_seen_pos == Vector2.INF or _time - _last_seen_time > Balance.AI_HUNT_COLD:
		return _search_dir()
	# Extrapolate along the direction they were travelling when we lost them.
	# Heading to the exact last-seen point makes the bot stop at the spot they
	# left, which looks like it gave up.
	var age: float = clampf(_time - _last_seen_time, 0.0, 2.5)
	var guess: Vector2 = _last_seen_pos + _last_seen_vel * age
	var d: Vector2 = guess - actor.global_position
	if d.length() < 14.0:
		# arrived at the guess: sweep the area instead of standing on the spot
		_orbit_flip -= dt
		if _orbit_flip <= 0.0:
			_orbit_flip = _rng.randf_range(1.0, 2.5)
			_orbit_sign = 1.0 if _rng.randf() < 0.5 else -1.0
		if d.length_squared() > 0.01:
			return Vector2(-d.y, d.x).normalized() * _orbit_sign
		return _random_dir()
	return d.normalized()


## Where to go when there is no lead at all - the start of a round, or long after
## the last sighting.
##
## The spawn pads are painted on the arena floor and both sides can see them, so
## "head for the enemy pads" is information a human player has too. This is a
## search, not clairvoyance, and it is deliberately the *nearest* pad rather than
## the arena centre so a bot on the left looks to its right instead of walking
## the whole diagonal.
##
## Pads are visited in turn, not by "nearest". Nearest-only is a trap, and the
## probe trace shows exactly how it fails: the bot crossed the arena, arrived at
## the closest enemy pad, found nobody, and then re-picked that same pad every
## second for the rest of the round - circling a 40 px patch 270 px away from a
## player it never went to look at. Marking pads as visited for the duration of a
## sweep and only clearing the set once all of them are done turns that into an
## actual search of the enemy side, which is what reaches the players.
func _search_dir() -> Vector2:
	if _search_goal != Vector2.INF:
		var to_goal: Vector2 = _search_goal - actor.global_position
		if to_goal.length() >= 20.0:
			return to_goal.normalized()
		# Arrived, nobody here. Note it, spend a moment sweeping the immediate
		# area, then move on to the next pad - the beat that stops the bot reading
		# as a robot that beelines pad to pad and ignores the room.
		_search_visited[_search_goal] = true
		_search_goal = Vector2.INF
		_search_wander = 0.7
	if _search_wander > 0.0:
		_search_wander -= Balance.AI_THINK_INTERVAL
		return _random_dir()

	var arena := _arena()
	if arena == null:
		return _random_dir()
	var enemy_team := Enums.Team.BOTS if actor.team == Enums.Team.HUMANS \
		else Enums.Team.HUMANS
	var pads := arena.spawn_points(enemy_team)
	if pads.is_empty():
		return _random_dir()

	var best := Vector2.INF
	var best_d := INF
	for p in pads:
		if _search_visited.has(p):
			continue
		var d: float = actor.global_position.distance_squared_to(p)
		if d < best_d:
			best_d = d
			best = p
	if best == Vector2.INF:
		# Whole enemy side swept and still nobody: start over. Against a player
		# who is hiding this is the loop that eventually finds them.
		_search_visited.clear()
		for p in pads:
			var d: float = actor.global_position.distance_squared_to(p)
			if d < best_d:
				best_d = d
				best = p
	if best == Vector2.INF:
		return _random_dir()
	_search_goal = best
	var dir: Vector2 = best - actor.global_position
	if dir.length_squared() < 1.0:
		_search_goal = Vector2.INF
		return _random_dir()
	return dir.normalized()


## Try a straight line first; fall back to A* only when geometry is in the way.
## Direct movement is smoother and cheaper, and the path grid is a tile
## approximation that visibly zig-zags on open ground.
##
## ALWAYS writes `move_dir`. An earlier version returned a bool meaning "pathing
## took over", and a caller read that bool the wrong way round - producing a bot
## that stood perfectly still whenever the way ahead was clear, which is the
## easiest way for a total navigation failure to hide behind "the AI looks calm".
func _move_with_pathing(desired: Vector2) -> void:
	if _unstick_left > 0.0:
		move_dir = _unstick_dir
		_unstick_left -= Balance.AI_THINK_INTERVAL
		return
	if desired.length_squared() < 0.001:
		move_dir = Vector2.ZERO
		return
	if not _direction_blocked(desired):
		_path = PackedVector2Array()
		_path_i = 0
		_path_goal = Vector2.INF
		move_dir = desired.normalized()
		return
	move_dir = _path_step(actor.global_position
		+ desired.normalized() * Balance.AI_PATH_LOOKAHEAD)


func _path_step(goal: Vector2) -> Vector2:
	var arena := _arena()
	if arena == null or not arena.has_nav():
		var d: Vector2 = goal - actor.global_position
		return d.normalized() if d.length_squared() > 1.0 else Vector2.ZERO

	_path_t -= Balance.AI_THINK_INTERVAL
	if _path_t <= 0.0 or _path.is_empty() or _path_goal == Vector2.INF \
			or goal.distance_to(_path_goal) > 26.0:
		_path = arena.path_to(actor.global_position, goal)
		_path_i = 0
		_path_goal = goal
		_path_t = Balance.AI_PATH_REFRESH

	while _path_i < _path.size() \
			and actor.global_position.distance_to(_path[_path_i]) < 7.0:
		_path_i += 1
	if _path_i >= _path.size():
		return Vector2.ZERO

	# Look-ahead: walk toward the furthest waypoint still in a straight line.
	# Waypoint-by-waypoint following stop-starts at every corner.
	var best: int = _path_i
	var limit: int = mini(_path.size() - 1, _path_i + 6)
	for j in range(limit, _path_i, -1):
		var d: Vector2 = _path[j] - actor.global_position
		if not _direction_blocked(d):
			best = j
			break
	var to := _path[best] - actor.global_position
	return to.normalized() if to.length_squared() > 1.0 else Vector2.ZERO


func _direction_blocked(dir: Vector2) -> bool:
	if actor == null or not is_instance_valid(actor):
		return true
	var space := actor.get_world_2d().direct_space_state
	if space == null:
		return false
	var probe: Vector2 = actor.global_position + dir.normalized() \
		* (actor.hit_radius + Balance.TILE_PROBE)
	return Combat.blocked(space, actor.global_position, probe,
		Combat.exclude_rids([actor]))


# ===========================================================================
# stuck watchdog
# ===========================================================================

## Net displacement over a fixed window, NOT per-tick movement.
##
## Per-tick movement is unreliable here: a bot oscillating 0.7 px back and forth
## is "moving" every single frame while making no progress whatsoever, and the
## only symptom is an AI that looks like it forgot what it was doing.
func _update_stuck(dt: float) -> void:
	if not actor.authoritative:
		return
	_anchor_t += dt
	if _anchor_t < Balance.AI_STUCK_WINDOW:
		return
	var net: float = actor.global_position.distance_to(_anchor_pos)
	_anchor_pos = actor.global_position
	_anchor_t = 0.0
	if net > Balance.AI_STUCK_MIN_NET:
		_stuck = 0
		return
	if actor.state_id() != &"locomotion":
		return
	_path = PackedVector2Array()
	_path_i = 0
	_path_goal = Vector2.INF
	_stuck += 1
	var perp: Vector2 = Vector2(-move_dir.y, move_dir.x) if move_dir.length() > 0.1 \
		else _random_dir()
	if _direction_blocked(perp):
		perp = -perp
	_unstick_dir = perp.normalized()
	_unstick_left = 0.6
	if _stuck >= Balance.AI_STUCK_STRIKES:
		_stuck = 0
		var arena := _arena()
		if arena != null:
			var p := arena.nearest_open_pos(actor.global_position + Vector2(26.0, 26.0))
			if p != Vector2.INF:
				actor.global_position = p
