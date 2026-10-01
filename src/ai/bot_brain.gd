class_name BotBrain
extends RefCounted
## Base class and shared toolkit for bot brains.
##
## A brain is pure decision-making: it reads the world and writes intent. It
## never touches the actor's internals, never applies damage, and never moves
## anything directly. That boundary is what keeps "the bot cheats" from ever
## being a true statement - everything a brain can do, a human controller can do
## through the same six `want_*` flags.
##
## Tactical (slow) decisions run on `AI_THINK_INTERVAL`; aim runs every physics
## tick because a stuttering aim is instantly readable as "that is a bot".

var actor: ActorBody = null

var move_dir: Vector2 = Vector2.ZERO
var aim_dir: Vector2 = Vector2.RIGHT
var want_fire: bool = false
var want_melee: bool = false
var want_toggle_gun: bool = false
var want_hook: bool = false
var want_roll: bool = false
var want_reload: bool = false

var target: ActorBody = null

## True from the tick a fresh `decide()` landed until the controller has copied
## the one-shot intents onto the body.
##
## This flag exists because the brain thinks at `Balance.AI_THINK_INTERVAL`
## (about 16 Hz) while the body ticks at 60 Hz, and `want_toggle_gun` / `want_melee`
## / `want_roll` / `want_hook` are ONE-SHOT: the body consumes them and clears them
## when it acts. Copying the brain's snapshot on every body tick therefore
## re-asserted the same single "press" about four frames in a row. Measured on a
## live match, that made the gun toggle at 60 Hz - draw, holster, draw - so a bot
## could never finish drawing, never fired a bullet, and a 60-second match ended
## 0-0 with the bots walking 2700 px each without landing a single hit.
var intent_fresh: bool = false

var _time: float = 0.0
var _think_accum: float = 0.0
var _prev_target_vel: Vector2 = Vector2.ZERO
var _prev_target: ActorBody = null
var _rng := RandomNumberGenerator.new()


func setup(a: ActorBody) -> void:
	actor = a
	# Seeded from the actor id so a headless replay of the same match produces the
	# same bot behaviour. Unseeded randomness makes AI bugs unreproducible.
	_rng.seed = 0xA1B2C3 + a.actor_id * 7919


## Override. Called every physics tick.
func think(delta: float) -> void:
	_time += delta
	_think_accum += delta
	if _think_accum >= Balance.AI_THINK_INTERVAL:
		_think_accum = 0.0
		decide()
		# Raised after `decide()`, never inside it, so a brain that overrides
		# `decide()` without calling super cannot forget to set it.
		intent_fresh = true
	update_aim(delta)


## Override. Tactical layer; runs at the AI think rate.
func decide() -> void:
	pass


## Override (or keep the default, which is good enough for most brains).
func update_aim(delta: float) -> void:
	pass


func dispose() -> void:
	actor = null
	target = null
	_prev_target = null


# ===========================================================================
# perception toolkit
# ===========================================================================

func live_enemies() -> Array[ActorBody]:
	var out: Array[ActorBody] = []
	var tree := _tree()
	if tree == null:
		return out
	for n in tree.get_nodes_in_group(&"actor"):
		var e := n as ActorBody
		if e == null or e == actor or not e.is_alive():
			continue
		if not Combat.is_enemy(actor.team, e.team):
			continue
		out.append(e)
	return out


## Enemies with an unobstructed line to us. This is the only list the bot is
## allowed to shoot at or lead - shooting at something through a wall is the
## classic "the AI is broken" complaint, and it is exactly what happens when the
## range check is not paired with a line-of-sight check.
func visible_enemies() -> Array[ActorBody]:
	var out: Array[ActorBody] = []
	for e in live_enemies():
		if Combat.has_line(actor, e.global_position):
			out.append(e)
	return out


## Prefer the enemy that is (a) visible, (b) closest, with a bonus for low HP so
## the bot finishes wounded players instead of spreading damage evenly.
func pick_target() -> ActorBody:
	var vis := visible_enemies()
	if vis.is_empty():
		return null
	var best: ActorBody = null
	var best_score: float = -1e9
	for e in vis:
		var d: float = actor.global_position.distance_to(e.global_position)
		var score: float = -d
		score += (1.0 - clampf(e.hp / maxf(1.0, e.max_hp), 0.0, 1.0)) * 90.0
		if e.reload_left > 0.0:
			score += 30.0
		# an enemy that is mid-melee-swing is briefly harmless: a good moment to
		# push, so treat it as a slightly better target
		if e.state_id() == &"melee":
			score += 15.0
		if score > best_score:
			best_score = score
			best = e
	return best


func has_line_to(pos: Vector2) -> bool:
	return Combat.has_line(actor, pos)


## Predicted intercept point for a bullet fired from `from` at `t`.
##
## First order (velocity * time-of-flight) is the obvious part. The second-order
## term is what makes the bot feel uncanny: if the target is actively changing
## direction (accelerating), a purely linear lead aims consistently behind a
## strafing opponent. `_prev_target_vel` gives a cheap acceleration estimate.
func lead_point(t: ActorBody, from: Vector2, speed: float) -> Vector2:
	if t == null or not is_instance_valid(t):
		return from
	var dist: float = from.distance_to(t.global_position)
	var tof: float = dist / maxf(1.0, speed)
	var acc := Vector2.ZERO
	if _prev_target == t:
		acc = (t.velocity - _prev_target_vel) / maxf(0.001, Balance.AI_THINK_INTERVAL)
	var p: Vector2 = t.global_position
	p += t.velocity * tof * Balance.AI_AIM_LEAD_WEIGHT
	p += 0.5 * acc * tof * tof * Balance.AI_AIM_SECOND_ORDER
	return p


## Point the gun at `t` right now (no lead) - correct for melee and for targets
## that are standing still.
func aim_at(t: ActorBody, lead: bool) -> void:
	if t == null or not is_instance_valid(t):
		return
	var point: Vector2 = t.global_position
	if lead:
		point = lead_point(t, actor.global_position, Balance.BULLET_SPEED)
	var d: Vector2 = point - actor.global_position
	if d.length_squared() > 1.0:
		aim_dir = d.normalized()


# ===========================================================================
# threat assessment
# ===========================================================================

## Is anything about to hit us?
##
## Uses closest-approach geometry on live bullets rather than "is a bullet near
## me", so the bot only reacts to shots that are actually on a collision course.
## Returns {found, dodge_dir, time}.
func incoming_threat() -> Dictionary:
	var result := {"found": false, "dodge_dir": Vector2.ZERO, "time": 0.0}
	var tree := _tree()
	if tree == null:
		return result
	var me := actor.global_position
	var my_vel := actor.velocity
	var best_t: float = 1e9
	for n in tree.get_nodes_in_group(&"bullet"):
		var b := n as Bullet
		if b == null or b.dead or b.shooter == actor:
			continue
		if not Combat.is_enemy(b.team, actor.team):
			continue
		var rel: Vector2 = b.global_position - me
		var bullet_vel: Vector2 = b.dir * b.speed
		var rel_vel: Vector2 = bullet_vel - my_vel
		var vv: float = rel_vel.length_squared()
		if vv < 1.0:
			continue
		var tca: float = -rel.dot(rel_vel) / vv
		if tca < 0.0 or tca > Balance.AI_BULLET_DODGE_LOOKAHEAD:
			continue
		var miss: float = (rel + rel_vel * tca).length()
		if miss > Balance.AI_BULLET_DODGE_MARGIN + actor.hit_radius:
			continue
		# perpendicular to the bullet's travel, toward the side that increases
		# the miss distance
		var perp := Vector2(-bullet_vel.y, bullet_vel.x).normalized()
		var side: float = signf(rel.dot(perp))
		if absf(side) < 0.01:
			side = 1.0 if _rng.randf() < 0.5 else -1.0
		if tca < best_t:
			best_t = tca
			result = {
				"found": true,
				"dodge_dir": perp * side,
				"time": tca,
			}
	return result


## Is `t` currently pointing a loaded gun at us? This does NOT require them to
## have fired - it is a read of their facing, which is public information.
##
## This is the mechanic the whole bot is built around: because the character
## always faces the aim source, the bot can start a roll before the shot exists.
## A human watching the bot's visor gets the same tell, and the bot's roll is
## beatable by firing late or faking the aim first, so it is a duel rather than a
## wall.
func is_aimed_at_me(t: ActorBody) -> bool:
	if t == null or not is_instance_valid(t) or not t.is_alive():
		return false
	if not t.is_gun_out() or t.mag <= 0 or t.reload_left > 0.0:
		return false
	var to_me: Vector2 = actor.global_position - t.global_position
	if to_me.length() > Balance.AI_MAX_RANGE_ENGAGE:
		return false
	var delta := absf(Utils.angle_delta(t.aim_dir.angle(), to_me.angle()))
	if delta > Balance.AI_DODGE_AIM_CONE:
		return false
	# Line of sight is symmetric, so "I can see him" already implies "he can see
	# me". Callers must therefore only ask this about a target they have already
	# confirmed is visible.
	return true


## Which way to dodge so we break the line the shooter is holding.
## Moving perpendicular to their aim axis is strictly better than running along
## it: running directly away keeps you inside their cone the whole time.
func perpendicular_escape(t: ActorBody) -> Vector2:
	if t == null or not is_instance_valid(t):
		return _random_dir()
	var axis: Vector2 = t.aim_dir
	var perp := Vector2(-axis.y, axis.x)
	var to_me: Vector2 = actor.global_position - t.global_position
	var side: float = signf(to_me.dot(perp))
	if absf(side) < 0.01:
		side = 1.0 if _rng.randf() < 0.5 else -1.0
	return perp * side


## Sample a ring of candidate points and return the one that actually blocks the
## shooter's line, preferring candidates that stay near the enemy (so the bot
## does not retreat out of the fight) and are reachable.
func find_cover(from_pos: Vector2, radius: float = 46.0, samples: int = 12) -> Vector2:
	var best := Vector2.INF
	var best_score := -1e9
	var space := actor.get_world_2d().direct_space_state if actor.get_world_2d() != null else null
	if space == null:
		return best
	var ex := Combat.exclude_rids([actor])
	for i in samples:
		var a: float = TAU * (float(i) / float(samples)) + _rng.randf() * 0.3
		var p: Vector2 = actor.global_position + Vector2.RIGHT.rotated(a) * radius
		if not _walkable(p):
			continue
		if not Combat.blocked(space, from_pos, p, ex):
			continue   # still exposed
		var score: float = -p.distance_to(actor.global_position)
		score -= p.distance_to(from_pos) * 0.35
		if score > best_score:
			best_score = score
			best = p
	return best


func _walkable(p: Vector2) -> bool:
	var arena := _arena()
	if arena == null:
		return true
	return arena.is_walkable_pos(p)


func _arena() -> Arena:
	var tree := _tree()
	if tree == null:
		return null
	return tree.get_first_node_in_group(&"arena") as Arena


func _tree() -> SceneTree:
	if actor == null or not is_instance_valid(actor):
		return null
	return actor.get_tree()


func _random_dir() -> Vector2:
	return Vector2.RIGHT.rotated(_rng.randf() * TAU)
