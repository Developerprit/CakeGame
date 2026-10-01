class_name BotV1Pro
extends BotV1
## CakeGame AI Bot v1 pro.
##
## Read `Planning/AI-Bot-v1-Pro.md` first - every number below is argued there.
## The short version:
##
##   v1 tries to aim better. That is the wrong axis. At the range v1 itself holds
##   (58-92 px) the gun is already nearly geometric-perfect: the target subtends
##   4.6 deg, the cone is 3-6 deg, so even at maximum bloom the SHOT lands 77% of
##   the time on a stationary target. What actually kills an exchange is the other
##   factor in the product -
##
##       P(hit) = P(geometric) x P(he does not move out of the way in 0.28 s)
##
##   and a target at 57.6 px/s covers 16 px in that flight time, 2.2x the width of
##   its own silhouette. So v1 pro is built around ONE rule:
##
##       BANK THE SHOT. Spend rounds inside windows where he physically cannot
##       dodge, and walk instead of spraying when he can.
##
## Those windows are all readable from his animation (no hidden state):
##   roll        -> committed along roll_dir,           0.42 s
##   post-roll   -> roll_cd still ticking,               0.90 s  <-- the fat one
##   melee       -> cannot be interrupted before 0.22 s, 0.38 s
##   hook stun   -> abilities are locked while stunned,  0.22 s
##
## Eight upgrades over v1, tagged [U1]..[U8] at the call site:
##   [U1] commitment windows      -> fire banks, melee only when he cannot roll
##   [U2] scored roll landing     -> the roll is a REPOSITION, not a twitch
##   [U3] geometric hit gate      -> no wasted rounds, no reload in his face
##   [U4] EMA lead                -> v1 leads on instantaneous velocity
##   [U5] melee arc escape        -> melee is 22 damage and v1 never avoided it
##   [U6] multi-threat vector     -> v1's movement only ever saw one target
##   [U7] hook combo + escape     -> v1 used the hook solely as a gap closer
##   [U8] dodge bias              -> learned per opponent, from observed rolls
##
## Difficulty is still fixed. Every tunable lives in `Balance` under `AIPRO_`.


## Observable history for one opponent.
##
## Deliberately does NOT store any cooldown READ OFF the body other than the two
## every avatar already shows on screen (`stun_left`, `i_frames`). Everything
## else is inferred from `state_id()` plus how long he has been in that state -
## which is exactly what a human watching the sprite can do.
class EnemyModel extends RefCounted:
	var actor_id: int = 0
	var body: ActorBody = null

	var state: StringName = &""
	var state_since: float = -99.0

	var roll_start: float = -99.0    ## -99 = never seen rolling this life
	var roll_count: int = 0
	var aimed_rolls: int = 0         ## rolls that followed us pointing at him
	var dodge_bias: float = 0.0      ## -1 .. 1, which way he habitually rolls

	var v_ema: Vector2 = Vector2.ZERO
	var v_prev: Vector2 = Vector2.ZERO
	var acc_ema: Vector2 = Vector2.ZERO
	var seen: float = 0.0            ## last time we refreshed him


# --- own state -------------------------------------------------------------
var _models: Dictionary = {}
var _prune_t: float = 0.0
var _press: float = 0.0            ## [U1] we are mid kill-window, keep shooting
var _swing_lock: float = 0.0       ## [U5] we are stepping out of someone's arc


func setup(a: ActorBody) -> void:
	super.setup(a)
	_models.clear()


# ===========================================================================
# decision
# ===========================================================================

func decide() -> void:
	var dt: float = Balance.AI_THINK_INTERVAL
	_time_tick(dt)

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
	_update_models(dt)
	_press = maxf(0.0, _press - dt)
	_swing_lock = maxf(0.0, _swing_lock - dt)

	# ---- [U1] reactive: a bullet is on a collision course ------------------
	# Same trigger as v1, different landing: v1 rolled perpendicular to the
	# muzzle and could easily end up still in the crosshair - and having spent
	# its own roll, which is 1.32 s of "cannot dodge again". A human punishes
	# that instinctively. `_scored_dodge_dir` picks the landing that breaks the
	# most lines instead.  [U2]
	var threat := incoming_threat()
	if bool(threat.get("found", false)) and _react >= Balance.AI_DODGE_REACTION \
			and actor.roll_cd <= 0.0 and actor.can_act():
		_do_dodge(_scored_dodge_dir(threat.get("dodge_dir", Vector2.RIGHT)), 0.30)
		return

	# ---- target picture ---------------------------------------------------
	var tgt := _pick_target_pro()
	_target_visible = tgt != null
	if tgt != target:
		_acquire_time = _time
	target = tgt
	if _target_visible:
		_last_seen_pos = target.global_position
		_last_seen_vel = target.velocity
		_last_seen_time = _time

	# ---- [U5] somebody is winding up a swing at us ------------------------
	# Melee is the biggest single damage source in the game (22 vs 12 for a
	# bullet) and v1 had NO answer to it at all - it even SCORED a swinging
	# enemy UP in `pick_target` as "briefly harmless". Getting out of the arc
	# during the 0.12 s windup is free; walking in afterwards is the punish.
	if _evade_swing():
		return

	# ---- [U7] get out alive when we are losing ----------------------------
	if actor.hp <= Balance.AI_RETREAT_HP and _target_visible:
		if _try_hook_escape():
			return

	# ---- no visible target ------------------------------------------------
	if not _target_visible:
		mode = Mode.HUNT
		_pro_weapon_housekeeping(-1.0)
		_move_with_pathing(_hunt_dir(dt))
		return

	var to_t: Vector2 = target.global_position - actor.global_position
	var dist: float = to_t.length()
	var model := _model(target)

	# ---- [U2] predictive dodge: he is aiming at us ------------------------
	if _react >= Balance.AI_DODGE_REACTION and actor.roll_cd <= 0.0 \
			and actor.can_act() and dist < Balance.AI_MAX_RANGE_ENGAGE * 0.85 \
			and is_aimed_at_me(target):
		# Same deliberate imperfection as v1: dodging every single time is not
		# "smart", it is a wall, and the counter-play (fake the aim, fire late)
		# stops existing. We are slightly MORE eager than v1's 0.72 because the
		# scored landing means a dodge now buys position instead of costing it.
		if _rng.randf() < 0.78:
			_do_dodge(_scored_dodge_dir(perpendicular_escape(target)), 0.45)
			return

	# ---- [U1] melee only when he cannot roll away -------------------------
	# v1 swung whenever the target was reloading or below 30% HP. But nobody has
	# to stand there and take it - reloading does not block the dodge. Melee has
	# a 0.38 s lockout of our own, so into a target with a live roll it is a
	# losing trade. We commit only into a locked target, to finish it, or when
	# our own gun is dry and we have nothing to lose.
	if dist <= Balance.AI_MELEE_RANGE + 3.0 and _pro_wants_melee(model, dist):
		mode = Mode.RUSH
		want_melee = true
		want_fire = false
		move_dir = to_t.normalized()
		_aim_direct(target, false)
		return

	_pro_weapon_housekeeping(dist)

	if actor.reload_left > 0.0:
		mode = Mode.COVER
		_move_to_cover(to_t, dt)
		return

	# ---- [U7] hook combo --------------------------------------------------
	if _try_hook_combo(to_t, dist, model):
		return

	# ---- [U7] plain gap closer, kept from v1 ------------------------------
	if actor.hook_cd <= 0.0 and _hook_cd <= 0.0 and actor.can_act() \
			and dist > Balance.AI_PREFERRED_MAX + 30.0:
		_hook_cd = 2.0
		want_hook = true
		want_fire = false
		_aim_direct(target, false)
		move_dir = to_t.normalized()
		return

	# ---- [U6] movement ----------------------------------------------------
	mode = Mode.ENGAGE
	_move_with_pathing(_multi_threat_dir(to_t, dist))

	# ---- [U3] fire control ------------------------------------------------
	_aim_direct(target, true)
	if _should_fire(dist, model):
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
# aim  [U4]
# ===========================================================================

func update_aim(delta: float) -> void:
	if _aim_lock > 0.0:
		_aim_lock -= delta
		return
	if actor == null or not is_instance_valid(actor) or not actor.alive:
		return
	# Mid-reel we are flying anchor-first; aiming anywhere else during it only
	# fights the roll we are about to do on landing.
	if actor.state_id() == &"hook_pull":
		return
	if target == null or not is_instance_valid(target) or not target.alive:
		return
	if not _target_visible:
		return
	var dist: float = actor.global_position.distance_to(target.global_position)
	var p: Vector2 = _pro_lead_point(target, _model_or_null(target), dist)
	var d: Vector2 = p - actor.global_position
	if d.length_squared() > 1.0:
		aim_dir = d.normalized()


## Why not simply `lead_point()`:
##
## v1 leads on `t.velocity` - the INSTANTANEOUS vector. Against a strafing
## opponent that is precisely the wrong time series to integrate, because a
## strafing opponent spends most of its time decelerating toward the turn it is
## about to make. The exponential average below lags in exchange for pointing at
## where the *average* velocity takes him, which is what the 0.28 s integration
## actually wants. The lag is bounded and is paid back by [U1]: inside a
## commitment window the velocity is DETERMINED (roll_dir, or zero under stun),
## so EMA and truth agree exactly when the shot counts.
func _pro_lead_point(t: ActorBody, m: EnemyModel, dist: float) -> Vector2:
	var base: Vector2 = t.global_position
	if m == null or m.seen <= 0.0:
		return lead_point(t, actor.global_position, Balance.BULLET_SPEED)
	var tof: float = dist / Balance.BULLET_SPEED
	var p: Vector2 = base
	p += m.v_ema * tof * Balance.AI_AIM_LEAD_WEIGHT
	p += 0.5 * m.acc_ema * tof * tof * Balance.AI_AIM_SECOND_ORDER
	# [U8] He has been rolling to the same side all match. Bias the aim that
	# way so the round arrives where he is going, not where he is. Only applied
	# while he can still choose to roll - inside a commitment window he cannot,
	# and biasing there would make us miss an otherwise free hit.
	if absf(m.dodge_bias) > 0.05 and _escape_readiness(m) >= 0.5:
		var axis: Vector2 = (t.global_position - actor.global_position).normalized()
		var perp := Vector2(-axis.y, axis.x)
		p += perp * m.dodge_bias * Balance.AIPRO_DODGE_BIAS_MAX * t.hit_radius * 2.0
	return p


# ===========================================================================
# [U1] opponent model
# ===========================================================================

func _update_models(dt: float) -> void:
	_prune_t -= dt
	var do_prune: bool = _prune_t <= 0.0
	if do_prune:
		_prune_t = 5.0

	for e in live_enemies():
		var m := _model(e)
		m.seen = _time
		_model_step(m, e, dt)

	if do_prune:
		var dead_ids: Array[int] = []
		for k in _models:
			var mm: EnemyModel = _models[k]
			if mm == null or not is_instance_valid(mm.body) or not mm.body.alive:
				dead_ids.append(int(k))
		for k in dead_ids:
			_models.erase(k)


func _model(e: ActorBody) -> EnemyModel:
	var key: int = e.actor_id
	var m: EnemyModel = _models.get(key, null) as EnemyModel
	if m != null and is_instance_valid(m.body) and m.body == e:
		return m
	m = EnemyModel.new()
	m.actor_id = key
	m.body = e
	m.state = e.state_id()
	m.state_since = _time
	m.v_ema = e.velocity
	m.v_prev = e.velocity
	_models[key] = m
	return m


func _model_or_null(e: ActorBody) -> EnemyModel:
	if e == null:
		return null
	var m: EnemyModel = _models.get(e.actor_id, null) as EnemyModel
	if m != null and (m.body == null or not is_instance_valid(m.body) or m.body != e):
		return null
	return m


func _model_step(m: EnemyModel, e: ActorBody, dt: float) -> void:
	# --- velocity / acceleration ---
	m.v_prev = m.v_ema
	m.v_ema = m.v_ema.lerp(e.velocity, Balance.AIPRO_EMA_ALPHA)
	var inst_acc: Vector2 = (m.v_ema - m.v_prev) / maxf(0.001, dt)
	m.acc_ema = m.acc_ema.lerp(inst_acc, 0.3)

	# --- state transitions ---
	var st: StringName = e.state_id()
	if st != m.state:
		# entering roll: remember it, and which side he went
		if st == &"roll":
			m.roll_start = _time
			m.roll_count += 1
			if _was_aimed_at(e):
				m.aimed_rolls += 1
			m.dodge_bias = lerpf(m.dodge_bias, _roll_side(e),
				Balance.AIPRO_DODGE_BIAS_RATE)
		elif m.state == &"roll":
			# roll just finished - nothing to store, `_roll_lock` derives the
			# remaining window from `roll_start`
			pass
		m.state = st
		m.state_since = _time
	elif st == &"roll":
		# a second roll inside one state is impossible, but a respawn resets the
		# clock, so guard against a stale window being trusted
		if _time - m.roll_start > Balance.ROLL_DURATION + Balance.ROLL_COOLDOWN:
			m.roll_start = _time


func _was_aimed_at(e: ActorBody) -> bool:
	var to_e: Vector2 = e.global_position - actor.global_position
	if to_e.length() > Balance.AI_MAX_RANGE_ENGAGE:
		return false
	return absf(Utils.angle_delta(actor.aim_dir.angle(), to_e.angle())) \
		<= Balance.AI_DODGE_AIM_CONE


func _roll_side(e: ActorBody) -> float:
	var to_me: Vector2 = actor.global_position - e.global_position
	if to_me.length_squared() < 0.01:
		return 0.0
	var perp := Vector2(-to_me.y, to_me.x).normalized()
	var side: float = signf(e.velocity.dot(perp))
	if absf(side) < 0.15:
		return 0.0
	return clampf(side, -1.0, 1.0)


## 0 = he cannot dodge right now, 1 = he is free to.
##
## Derived from state + elapsed time, never from reading his cooldown fields.
## This is the single number [U1] is built on: every decision below that cares
## about "is this shot going to land" is multiplied through it.
func _escape_readiness(m: EnemyModel) -> float:
	if m == null or m.body == null or not is_instance_valid(m.body):
		return 1.0
	var b := m.body
	if not b.alive:
		return 1.0
	# Stun locks every ability: `Locomotion.physics` gates roll/melee/hook behind
	# `stun_left <= 0.0`, so a hooked or hurt target is a sitting duck.
	if b.stun_left > 0.0:
		return 0.0
	if b.state_id() == &"roll":
		return 0.0
	# A roll set roll_cd = DURATION + COOLDOWN at its START and it never resets,
	# so for 0.90 s after the roll animation ends he still cannot roll again.
	if m.roll_start >= 0.0:
		var since: float = _time - m.roll_start
		if since < Balance.ROLL_DURATION + Balance.ROLL_COOLDOWN:
			return 0.0
	if b.state_id() == &"melee":
		if _time - m.state_since < Balance.AIPRO_MELEE_PUNISH_TIME:
			return 0.15
		return 0.8
	if b.reload_left > 0.0:
		# He CAN roll out of a reload - this is why v1's "he is reloading, go
		# hit him with a sword" is a bad trade, and why the score stays high.
		return 0.85
	return 1.0


func _locked(m: EnemyModel) -> bool:
	return _escape_readiness(m) < 0.5


# ===========================================================================
# target selection
# ===========================================================================

func _pick_target_pro() -> ActorBody:
	var vis := visible_enemies()
	if vis.is_empty():
		return null
	var best: ActorBody = null
	var best_score: float = -1e9
	for e in vis:
		var d: float = actor.global_position.distance_to(e.global_position)
		var score: float = -d
		score += (1.0 - clampf(e.hp / maxf(1.0, e.max_hp), 0.0, 1.0)) * 90.0
		var m := _model_or_null(e)
		# [U1] A locked opponent is worth 45 px of closing: rounds spent on him
		# actually convert, and there is no risk of running in for nothing.
		if m != null and _locked(m):
			score += 45.0
		if e.stun_left > 0.0:
			score += 60.0
		if e.reload_left > 0.0:
			score += 20.0
		if e.state_id() == &"melee":
			score += 15.0
		# An invulnerable target cannot be damaged at all. v1 only filtered these
		# at the muzzle; with several enemies on screen that still let i-framed
		# and spawn-protected actors win the "closest / lowest HP" comparison and
		# pull us around the arena by the nose.
		if e.i_frames > 0.0 or e.spawn_invuln > 0.0:
			score -= 140.0
		if score > best_score:
			best_score = score
			best = e
	return best


# ===========================================================================
# [U3] fire control
# ===========================================================================

## Geometric hit chance, straight from the two half-angles.
##
## The target subtends `atan((hit_radius + BULLET_RADIUS) / d)`; the muzzle cone
## is `GUN_SPREAD_DEG + gun_bloom`. The spread term is uniform, so the ratio of
## the two is the probability - no simulation required, and it updates itself if
## `Balance` ever moves.
func _hit_chance(t: ActorBody, dist: float) -> float:
	var silhouette: float = atan((t.hit_radius + Balance.BULLET_RADIUS) / maxf(1.0, dist))
	var cone: float = actor.current_spread_rad()
	if cone <= 0.0001:
		return 1.0
	return clampf(silhouette / cone, 0.0, 1.0)


func _should_fire(dist: float, m: EnemyModel) -> bool:
	if not _can_shoot(target):
		return false
	var chance: float = _hit_chance(target, dist)
	# [U3] Do not let a bloomed cone reach out to a far target. Letting it fall
	# costs ~0.2 s of bloom decay (1.65 deg/s); the round it saves is worth more
	# than the round not fired.
	if actor.gun_bloom >= Balance.AIPRO_BLOOM_GUARD \
			and dist > Balance.AIPRO_BLOOM_GUARD_RANGE:
		return false
	var free: float = _escape_readiness(m)
	if free >= 0.5:
		chance *= Balance.AIPRO_FREE_TARGET_FACTOR
	else:
		# Remember we were in a window: the last shot of a barrage is worth more
		# than the pristine gate suggests, because he is still mid-commitment even
		# though the strict timers have just lapsed.
		_press = 0.35
	var floor_chance: float = Balance.AIPRO_HIT_CHANCE_MIN
	if _press > 0.0:
		floor_chance *= 0.75
	# Fast lateral movers are the ones whose FUTURE position we least trust, so
	# the bar rises for them unless the geometry is already overwhelming.
	if target.velocity.length() > Balance.AIPRO_LATERAL_JITTER \
			and chance < Balance.AIPRO_CONFIDENT_CHANCE:
		return false
	return chance >= floor_chance


func _pro_weapon_housekeeping(dist: float) -> void:
	if actor.mag > 0 and not actor.is_gun_out():
		want_toggle_gun = true
	if not actor.is_gun_out() or actor.reload_left > 0.0 or actor.mag > 3:
		return
	# A reload is 1.40 s of standing still. v1 started one the moment it dipped
	# to 3 rounds and the target happened to be far away - which is exactly the
	# moment the target walks back into the corridor. We still reload when there
	# is nothing to shoot at, or when we are dry, because those are not choices.
	if dist < 0.0:
		want_reload = true
		return
	if actor.mag <= 0:
		want_reload = true
		return
	if target != null and is_instance_valid(target) \
			and dist > Balance.AI_PREFERRED_MAX:
		var m := _model_or_null(target)
		# Only top up into someone who cannot punish the 1.4 s we will be busy.
		if m != null and _locked(m):
			want_reload = true


# ===========================================================================
# melee
# ===========================================================================

func _pro_wants_melee(m: EnemyModel, dist: float) -> bool:
	if actor.melee_cd > 0.0:
		return false
	if dist > Balance.AI_MELEE_RANGE + 3.0:
		return false
	var locked: bool = _locked(m)
	var low_hp: bool = target.hp <= Balance.MELEE_DAMAGE + 6.0
	var dry: bool = actor.mag <= 0
	if locked or low_hp or dry:
		return true
	# Punish a whiff: he is inside his own recovery and has committed 0.38 s to
	# it. He may still roll out, but that spends HIS roll on OUR terms, which is
	# a tempo win even when the swing misses.
	if target.state_id() == &"melee" and m != null \
			and _time - m.state_since >= Balance.AIPRO_MELEE_PUNISH_TIME:
		return true
	return false


# ===========================================================================
# [U5] melee arc escape
# ===========================================================================

## True when we took over this tick's movement.
##
## The 0.12 s before a swing lands is one of the few guaranteed-free beats in the
## whole game: the swinger's trajectory is set, his aim cannot re-acquire you
## mid-windup, and 22 damage is nearly two bullets' worth.
func _evade_swing() -> bool:
	var reach_max: float = Balance.MELEE_RANGE + Balance.BODY_RADIUS \
		+ Balance.AIPRO_MELEE_AVOID_MARGIN
	for e in live_enemies():
		if not Combat.has_line(actor, e.global_position):
			continue
		var to_me: Vector2 = actor.global_position - e.global_position
		var d: float = to_me.length()
		if d > reach_max:
			continue
		var st: StringName = e.state_id()
		if st != &"melee":
			continue
		# Already resolved? Then there is nothing to dodge - `_pro_wants_melee`
		# handles the punish instead.
		if _time - _state_since(e) >= Balance.MELEE_WINDUP + Balance.MELEE_ACTIVE:
			continue
		if absf(Utils.angle_delta(e.aim_dir.angle(), to_me.angle())) \
				> Balance.MELEE_HALF_ARC:
			continue
		# Roll through if we can: i-frames eat the swing outright. Otherwise get
		# off the aim axis - stepping INSIDE the arc and past him is better than
		# running straight back, which keeps us in front of him the whole way.
		if actor.roll_cd <= 0.0 and actor.can_act():
			_do_dodge(_scored_dodge_dir(Vector2(-to_me.y, to_me.x).normalized()), 0.35)
		else:
			var out := Vector2(-to_me.y, to_me.x).normalized()
			if out.dot(to_me.normalized()) > 0.0:
				out = -out
			move_dir = out
			_swing_lock = 0.25
		return true
	return false


func _state_since(e: ActorBody) -> float:
	var m := _model_or_null(e)
	if m == null:
		return _time
	return m.state_since


# ===========================================================================
# [U2] scored dodging
# ===========================================================================

## Pick where to LAND, not just which way to twitch.
##
## A roll covers ~45 px (ROLL_SPEED x ROLL_DURATION, eased). v1 picked the
## perpendicular with no regard for what was 45 px that way, so a third of its
## dodges simply moved it to another part of the same corridor - and cost it
## 1.32 s of being unable to dodge again.
func _scored_dodge_dir(fallback: Vector2) -> Vector2:
	var space := actor.get_world_2d().direct_space_state
	if space == null:
		return fallback
	var enemies: Array[ActorBody] = live_enemies()
	if enemies.is_empty():
		return fallback
	var ex := Combat.exclude_rids([actor])
	var best: Vector2 = Vector2.ZERO
	var best_s: float = -1e9
	var n: int = Balance.AIPRO_SEEK_SAMPLES
	var spin: float = _rng.randf() * TAU / float(n)
	for i in n:
		var d := Vector2.RIGHT.rotated(spin + TAU * (float(i) / float(n)))
		var land: Vector2 = actor.global_position + d * Balance.AIPRO_ROLL_RADIUS
		if not _walkable(land):
			continue
		var s: float = -float(_lines_on(land, enemies, space, ex)) * 26.0
		# Prefer landing somewhere we can still answer from, rather than ending
		# up safe but irrelevant on the far side of the arena.
		if target != null and is_instance_valid(target):
			s -= absf(land.distance_to(target.global_position) \
				- Balance.AI_PREFERRED_MAX) * 0.55
		if s > best_s:
			best_s = s
			best = d
	if best.length_squared() < 0.01:
		return fallback
	return best.normalized()


func _lines_on(p: Vector2, enemies: Array[ActorBody],
		space: PhysicsDirectSpaceState2D, ex: Array[RID]) -> int:
	var n: int = 0
	for e in enemies:
		if not Combat.blocked(space, e.global_position, p, ex):
			n += 1
	return n


# ===========================================================================
# [U6] movement
# ===========================================================================

## v1's `_desired_velocity` is a radial term plus a tangent term around ONE
## target. In a 1v1 that is fine. In a 1v3 it walks straight into the crossfire
## of the two opponents it is not looking at, which is the single most common
## way a human team beats these bots.
##
## The replacement samples a ring and scores each candidate for how BAD the
## fight from there would be. The ring is shared with [U2] (same constant) so
## one set of candidate points serves both systems.
func _multi_threat_dir(to_t: Vector2, dist: float) -> Vector2:
	var enemies: Array[ActorBody] = live_enemies()
	if enemies.size() <= 1:
		# One opponent: v1's analytic answer is cheaper and identical in effect.
		return _desired_velocity(to_t, dist)
	var space := actor.get_world_2d().direct_space_state
	if space == null:
		return _desired_velocity(to_t, dist)
	var ex := Combat.exclude_rids([actor])
	var best: Vector2 = Vector2.ZERO
	var best_s: float = -1e9
	var n: int = Balance.AIPRO_SEEK_SAMPLES
	var spin: float = _rng.randf() * TAU / float(n)
	for i in n:
		var d := Vector2.RIGHT.rotated(spin + TAU * (float(i) / float(n)))
		var p: Vector2 = actor.global_position + d * Balance.AIPRO_SEEK_RADIUS
		if not _walkable(p):
			continue
		var s := _score_spot(p, enemies, space, ex)
		if s > best_s:
			best_s = s
			best = d
	if best.length_squared() < 0.01:
		return _desired_velocity(to_t, dist)
	return best.normalized()


func _score_spot(p: Vector2, enemies: Array[ActorBody],
		space: PhysicsDirectSpaceState2D, ex: Array[RID]) -> float:
	var s: float = 0.0
	var los: int = 0
	var anchor: Vector2 = _threat_anchor(enemies)
	for e in enemies:
		if Combat.blocked(space, e.global_position, p, ex):
			continue
		los += 1
		if e != target:
			var d: float = e.global_position.distance_to(p)
			s -= Balance.AIPRO_THREAT_WEIGHT * (140.0 / maxf(40.0, d))
	# Being seen by nobody at all is not automatically good - we cannot shoot
	# back either - but refusing to accept two muzzles is what keeps us alive.
	if los > 1:
		s -= float(los - 1) * Balance.AIPRO_LOS_WEIGHT
	# Keep the primary inside the working band, and shootable from there.
	if target != null and is_instance_valid(target):
		var dp: float = p.distance_to(target.global_position)
		if dp < Balance.AI_PREFERRED_MIN:
			s -= (Balance.AI_PREFERRED_MIN - dp) * Balance.AIPRO_BAND_WEIGHT
		elif dp > Balance.AIPRO_HOOK_COMBO_MAX:
			s -= (dp - Balance.AIPRO_HOOK_COMBO_MAX) * Balance.AIPRO_BAND_WEIGHT
		if Combat.blocked(space, p, target.global_position, ex):
			s -= 22.0
	# A spot that still has a line is worthless for a reload, so prefer the ones
	# hugging geometry when we are about to be busy.
	if los == 0 and actor.reload_left <= 0.0 and actor.mag <= 3:
		s += Balance.AIPRO_COVER_WEIGHT
	if not anchor.is_equal_approx(Vector2.INF):
		s -= p.distance_to(anchor) * 0.12
	return s


func _threat_anchor(enemies: Array[ActorBody]) -> Vector2:
	if enemies.is_empty():
		return Vector2.INF
	var c := Vector2.ZERO
	for e in enemies:
		c += e.global_position
	return c / float(enemies.size())


# ===========================================================================
# [U7] hook
# ===========================================================================

## Hook -> yank -> close -> melee. ~30-55 damage inside a second.
##
## Gated on the target being LOCKED, because a hook in flight is a commitment of
## our own that we cannot take back, and a target with a live roll simply steps
## out of the line.
func _try_hook_combo(to_t: Vector2, dist: float, m: EnemyModel) -> bool:
	if actor.hook_cd > 0.0 or _hook_cd > 0.0 or not actor.can_act():
		return false
	if dist < Balance.AIPRO_HOOK_COMBO_MIN or dist > Balance.HOOK_MAX_RANGE:
		return false
	if not Combat.has_line(actor, target.global_position):
		return false
	var okay: bool = _locked(m)
	# Exception: somebody reloading at range cannot shoot us during the flight
	# and cannot easily move, so the same combo lands without the lock.
	if not okay:
		okay = target.reload_left > 0.0 and dist > Balance.AI_PREFERRED_MIN
	if not okay:
		return false
	_hook_cd = 3.6
	want_hook = true
	want_fire = false
	_aim_direct(target, false)
	move_dir = to_t.normalized()
	return true


## Wall-hook escape: the only real disengage in the game.
##
## The reel moves us at up to 300 px/s for 0.55 s (~90 px) and keeps 62% of that
## speed afterwards. A roll is 45 px and then we are standing still in the open.
## Running is 57.6 px/s. Against a human who is winning the exchange, this is
## the difference between "disengaged" and "died 20 px from safety".
func _try_hook_escape() -> bool:
	if actor.hook_cd > 0.0 or _hook_cd > 0.0 or not actor.can_act():
		return false
	var threats: Array[ActorBody] = visible_enemies()
	if threats.is_empty():
		return false
	var space := actor.get_world_2d().direct_space_state
	if space == null:
		return false
	var away := Vector2.ZERO
	for e in threats:
		away += (actor.global_position - e.global_position).normalized()
	if away.length_squared() < 0.01:
		return false
	away = away.normalized()
	var ex := Combat.exclude_rids([actor])
	var best: Vector2 = Vector2.ZERO
	var best_d: float = 0.0
	for i in 14:
		var d := away.rotated(_rng.randf_range(-0.85, 0.85))
		var hit := Combat.world_ray(space, actor.global_position,
			actor.global_position + d * Balance.HOOK_MAX_RANGE, ex)
		if hit.is_empty():
			continue
		var hit_pos: Vector2 = hit.get("position", Vector2.ZERO)
		var reach: float = actor.global_position.distance_to(hit_pos)
		if reach > best_d and reach > 34.0:
			best_d = reach
			best = d
	if best_d <= 0.0:
		return false
	# Hold the aim for a beat: `update_aim` runs every physics frame and would
	# otherwise snap the muzzle back onto the target we are running FROM.
	_hold_aim(best.normalized(), 0.25)
	_hook_cd = 3.6
	want_hook = true
	want_fire = false
	move_dir = best.normalized()
	return true


func _hold_aim(d: Vector2, seconds: float) -> void:
	if d.length_squared() > 0.01:
		aim_dir = d.normalized()
	_aim_lock = maxf(_aim_lock, seconds)
