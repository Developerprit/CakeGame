class_name ActorBody
extends CharacterBody2D
## The shared actor: stats, timers, weapons, states, presentation.
##
## Layering: this class owns the body and the rules; `PlayerActor` and
## `BotActor` are thin controllers that only ever fill in *intent* (move vector
## plus `want_*` flags) and an aim direction. Neither controller may call an
## action directly, so the bot physically cannot have a capability the human
## lacks - and there is exactly one place where an intent becomes an action.
##
## `authoritative` is true on the host (and offline). Only the authority applies
## damage; clients simulate the same motion for a smooth picture and let the host
## arbitrate the outcomes.

const GROUP: StringName = &"actor"

## Halo size and strength. `_radial_light()` builds a 128 px texture, so the
## scale is a direct multiplier on its radius: the first version used 2.3, i.e. a
## 294 px halo, which at a 640x360 viewport tinted an entire third of the arena
## in team colour. Orange crates read as yellow on the cyan side. 0.72 gives a
## 92 px halo - about six tiles, enough to spot a fighter and read its team,
## small enough that the tile art keeps its own colours.
const LIGHT_SCALE: float = 0.72
const LIGHT_ENERGY: float = 0.85

var actor_id: int = 0
var team: int = Enums.Team.HUMANS
var kind: int = Enums.Kind.LOCAL_HUMAN
var display_name: String = "Player"
var player_color: Color = Color.WHITE

var max_hp: float = Balance.MAX_HP
var hp: float = Balance.MAX_HP
var alive: bool = true
var hit_radius: float = Balance.BODY_RADIUS
var authoritative: bool = true
var is_local: bool = false

## --- intent (written by the controller, consumed by the states) -------------
var move_input: Vector2 = Vector2.ZERO
var want_fire: bool = false
var want_melee: bool = false
var want_toggle_gun: bool = false
var want_hook: bool = false
var want_roll: bool = false
var want_reload: bool = false

# --- aim --------------------------------------------------------------------
var aim_dir: Vector2 = Vector2.RIGHT
var facing: int = Enums.Facing.E

# --- weapons ----------------------------------------------------------------
var weapon: int = Enums.Weapon.MELEE
var mag: int = Balance.GUN_MAG
var reload_left: float = 0.0
var draw_left: float = 0.0
var gun_bloom: float = 0.0
var fire_anim_left: float = 0.0

# --- cooldowns / status -----------------------------------------------------
var melee_cd: float = 0.0
var gun_cd: float = 0.0
var hook_cd: float = 0.0
var roll_cd: float = 0.0
var i_frames: float = 0.0
var spawn_invuln: float = 0.0
var stun_left: float = 0.0
var hurt_left: float = 0.0
var speed_scale: float = 1.0
var obscured: bool = false

# --- grapple -----------------------------------------------------------------
var hook_anchor: Vector2 = Vector2.ZERO
var roll_dir: Vector2 = Vector2.RIGHT
var active_hook: Hook = null

# --- internals ---------------------------------------------------------------
var machine: StateMachine
var sprite: Sprite2D
var light: PointLight2D
var _under: ActorDecal
var _over: ActorDecal
var anim: String = "idle"
var anim_clock: float = 0.0
var _alive_prev: bool = true
var _collision: CollisionShape2D


# ===========================================================================
# setup
# ===========================================================================

func configure(cfg: Dictionary) -> void:
	actor_id = int(cfg.get("id", 0))
	team = int(cfg.get("team", Enums.Team.HUMANS))
	kind = int(cfg.get("kind", Enums.Kind.BOT))
	display_name = str(cfg.get("name", "Actor"))
	is_local = bool(cfg.get("local", false))
	authoritative = bool(cfg.get("authoritative", true))
	player_color = cfg.get("color", Enums.team_color(team))
	max_hp = float(cfg.get("hp", Balance.MAX_HP))


func _ready() -> void:
	hp = max_hp
	add_to_group(GROUP)
	add_to_group(&"actor_team_%d" % team)

	collision_layer = Combat.ACTOR_MASK
	# Deliberately mask only the world: actors pass through each other rather
	# than shoving. Body-blocking in a fast arena shooter causes far more bugs
	# (pushed into walls, teleport jitter, AI path thrash) than it buys.
	collision_mask = Combat.WORLD_MASK
	motion_mode = CharacterBody2D.MOTION_MODE_FLOATING

	_collision = CollisionShape2D.new()
	var c := CircleShape2D.new()
	c.radius = hit_radius
	_collision.shape = c
	add_child(_collision)

	z_index = 2

	_under = ActorDecal.new()
	_under.body = self
	_under.layer_kind = ActorDecal.RING
	_under.z_index = -1
	add_child(_under)

	sprite = Sprite2D.new()
	sprite.texture = AtlasLibrary.fighter_frame("idle", facing, 0, team)
	sprite.z_index = 0
	add_child(sprite)

	_over = ActorDecal.new()
	_over.body = self
	_over.layer_kind = ActorDecal.STATUS
	_over.z_index = 1
	add_child(_over)

	light = PointLight2D.new()
	light.texture = _radial_light()
	light.color = Enums.team_color(team)
	light.energy = LIGHT_ENERGY
	light.texture_scale = LIGHT_SCALE
	# Off by default. With one light per fighter, shadows project a fan of dark
	# wedges across the whole floor for every actor on screen, which at five
	# actors in a 640x360 viewport buries the tile art and reads as a rendering
	# fault rather than as lighting. The glow itself is worth keeping - a
	# team-coloured halo is genuinely useful for tracking a 1v3 - so the light
	# stays and only the shadow-casting is optional.
	light.shadow_enabled = GameConfig.light_shadows
	light.shadow_filter = PointLight2D.SHADOW_FILTER_PCF5
	light.z_index = -1
	add_child(light)

	machine = StateMachine.new()
	machine.setup(self)
	ActorStates.install(machine)

	EventBus.health_changed.emit(self, hp, max_hp)


static func _radial_light(size: int = 128) -> Texture2D:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.45, 0.78, 1.0])
	g.colors = PackedColorArray([
		Color(1, 1, 1, 1.0),
		Color(1, 1, 1, 0.62),
		Color(1, 1, 1, 0.22),
		Color(1, 1, 1, 0.0),
	])
	var t := GradientTexture2D.new()
	t.gradient = g
	t.width = size
	t.height = size
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.0, 0.5)
	return t


func _exit_tree() -> void:
	if machine != null:
		machine.dispose()
		machine = null


# ===========================================================================
# main loop
# ===========================================================================

func _physics_process(delta: float) -> void:
	_tick_timers(delta)
	_aim_tick(delta)
	_control_tick(delta)

	if aim_dir.length_squared() > 0.0001:
		facing = Utils.facing_from_dir(aim_dir)

	machine.physics(delta)
	move_and_slide()

	_update_presentation(delta)

	# consume one-shot intent so a held button does not re-trigger next tick
	want_melee = false
	want_roll = false
	want_hook = false
	want_toggle_gun = false


## Overridden by controllers. Base does nothing so an orphan body is inert.
func _control_tick(_delta: float) -> void:
	pass


## Overridden by controllers that own their aim source.
func _aim_tick(_delta: float) -> void:
	pass


func _tick_timers(delta: float) -> void:
	melee_cd = maxf(0.0, melee_cd - delta)
	gun_cd = maxf(0.0, gun_cd - delta)
	hook_cd = maxf(0.0, hook_cd - delta)
	roll_cd = maxf(0.0, roll_cd - delta)
	i_frames = maxf(0.0, i_frames - delta)
	spawn_invuln = maxf(0.0, spawn_invuln - delta)
	stun_left = maxf(0.0, stun_left - delta)
	hurt_left = maxf(0.0, hurt_left - delta)
	draw_left = maxf(0.0, draw_left - delta)
	fire_anim_left = maxf(0.0, fire_anim_left - delta)
	gun_bloom = maxf(0.0, gun_bloom - delta * Balance.GUN_BLOOM_PER_SHOT * 3.0)

	if reload_left > 0.0:
		reload_left -= delta
		if reload_left <= 0.0:
			reload_left = 0.0
			mag = Balance.GUN_MAG
			AudioDirector.play("reload_done", -6.0)
			EventBus.reload_finished.emit(self)
			EventBus.ammo_changed.emit(self, mag, Balance.GUN_MAG)


func _update_presentation(delta: float) -> void:
	play_anim(_desired_anim())
	anim_clock += delta

	var fps := AtlasLibrary.anim_fps(anim)
	var idx := int(anim_clock * fps)
	var mode := AtlasLibrary.anim_mode(anim)
	if mode != "loop":
		idx = mini(idx, maxi(0, AtlasLibrary.anim_frames(anim) - 1))
	sprite.texture = AtlasLibrary.fighter_frame(anim, facing, idx, team)

	# Occlusion fades to fully invisible, not to a translucent ghost. A 0.3 alpha
	# reads to players as "blurry", not as "behind a wall", and they keep trying
	# to shoot it. Lerped so it does not pop.
	var target_alpha := 0.0 if obscured else 1.0
	var c := sprite.modulate
	c.a = lerpf(c.a, target_alpha, clampf(delta * 14.0, 0.0, 1.0))
	sprite.modulate = c

	if light != null:
		light.enabled = alive and not obscured
		light.energy = lerpf(light.energy, LIGHT_ENERGY if alive else 0.0, delta * 8.0)

	if _over != null:
		_over.queue_redraw()


func _desired_anim() -> String:
	if not alive or machine.is_state(&"dead"):
		return "dead"
	if hurt_left > 0.0:
		return "hurt"
	match machine.current_id:
		&"melee":
			return "melee"
		&"roll":
			return "roll"
		&"hook_pull":
			return "hook"
	if fire_anim_left > 0.0:
		return "gun_fire"
	if weapon == Enums.Weapon.GUN:
		return "gun_idle"
	return "run" if velocity.length_squared() > Balance.ACCEL * 0.06 else "idle"


func play_anim(name: String, restart: bool = false) -> void:
	if anim == name and not restart:
		return
	anim = name
	anim_clock = 0.0


# ===========================================================================
# queries used by the states and the AI
# ===========================================================================

func is_alive() -> bool:
	return alive


func state_id() -> StringName:
	return machine.current_id if machine != null else &""


func can_act() -> bool:
	return alive and stun_left <= 0.0


func move_speed() -> float:
	return Balance.MOVE_SPEED * speed_scale


func aim_angle() -> float:
	return aim_dir.angle()


func is_gun_out() -> bool:
	return weapon == Enums.Weapon.GUN


## Gun can fire right now?
func gun_ready() -> bool:
	return alive and can_act() and weapon == Enums.Weapon.GUN \
		and draw_left <= 0.0 and reload_left <= 0.0 and mag > 0 and gun_cd <= 0.0


func current_spread_rad() -> float:
	var deg := Balance.GUN_SPREAD_DEG + gun_bloom
	return deg * PI / 180.0


func speed_fraction() -> float:
	var cap := move_speed()
	if cap <= 0.001:
		return 0.0
	return clampf(velocity.length() / cap, 0.0, 1.5)


# ===========================================================================
# actions - ONLY ever called from a state
# ===========================================================================

func melee_strike() -> void:
	if not authoritative:
		Fx.burst(get_parent(), "spark", global_position + aim_dir * 12.0, 0.8, aim_angle())
		AudioDirector.play_at("melee_swing", global_position, global_position)
		return
	var victims := Combat.melee_strike(self)
	AudioDirector.play_at("melee_swing", global_position, global_position)
	var landed := false
	for v in victims:
		var knock := (v.global_position - global_position).normalized() * Balance.MELEE_KNOCKBACK
		if Combat.apply_damage(v, Balance.MELEE_DAMAGE, Enums.DamageKind.MELEE,
				self, knock, v.global_position, self):
			landed = true
	if landed:
		EventBus.hitstop.emit(Balance.HITSTOP_MELEE)
		EventBus.screen_shake.emit(Balance.SHAKE_MELEE, 0.12)
		AudioDirector.play_at("melee_hit", global_position, global_position)


func fire_bullet() -> bool:
	if not gun_ready():
		if weapon == Enums.Weapon.GUN and mag <= 0 and reload_left <= 0.0 and gun_cd <= 0.0:
			AudioDirector.play("gun_empty", -8.0)
			gun_cd = 0.25
		return false
	mag -= 1
	gun_cd = Balance.GUN_COOLDOWN
	fire_anim_left = 0.20
	EventBus.ammo_changed.emit(self, mag, Balance.GUN_MAG)

	var muzzle := global_position + aim_dir * 11.0
	var b := Bullet.new()
	b.authoritative = authoritative
	b.configure(self, aim_dir, randf_range(-1.0, 1.0) * current_spread_rad(),
		Balance.BULLET_DAMAGE, Balance.BULLET_SPEED, Balance.BULLET_RANGE)
	b.global_position = muzzle
	var layer := get_tree().get_first_node_in_group(&"projectile_layer")
	var host: Node = layer if layer != null else (get_tree().current_scene as Node)
	if host == null:
		b.free()
		return false
	host.add_child(b)

	gun_bloom = minf(Balance.GUN_BLOOM_MAX, gun_bloom + Balance.GUN_BLOOM_PER_SHOT)
	velocity -= aim_dir * Balance.GUN_RECOIL_KNOCKBACK
	Fx.muzzle(get_parent(), muzzle, aim_dir)
	AudioDirector.play_at("gun_shot", muzzle, global_position, 420.0, -3.0)
	EventBus.cooldown_started.emit(self, "gun", Balance.GUN_COOLDOWN)

	if mag <= 0:
		begin_reload()
	return true


func fire_hook() -> void:
	if hook_cd > 0.0 or not can_act():
		return
	hook_cd = Balance.HOOK_COOLDOWN
	var h := Hook.new()
	h.authoritative = authoritative
	h.configure(self, aim_dir)
	h.global_position = global_position + aim_dir * 8.0
	var layer := get_tree().get_first_node_in_group(&"projectile_layer")
	var host: Node = layer if layer != null else (get_tree().current_scene as Node)
	if host == null:
		h.free()
		return
	host.add_child(h)
	active_hook = h
	play_anim("hook", true)
	AudioDirector.play_at("hook_fire", global_position, global_position)
	EventBus.hook_fired.emit(self, aim_dir)
	EventBus.cooldown_started.emit(self, "hook", Balance.HOOK_COOLDOWN)


func toggle_gun() -> void:
	if not can_act():
		return
	if weapon == Enums.Weapon.GUN:
		weapon = Enums.Weapon.MELEE
		reload_left = 0.0
	else:
		weapon = Enums.Weapon.GUN
		draw_left = Balance.GUN_DRAW_TIME
		play_anim("gun_idle", true)
	EventBus.weapon_changed.emit(self, weapon)


func begin_reload() -> void:
	if weapon != Enums.Weapon.GUN or reload_left > 0.0 or mag >= Balance.GUN_MAG:
		return
	reload_left = Balance.GUN_RELOAD
	AudioDirector.play("reload_start", -5.0)
	EventBus.reload_started.emit(self, Balance.GUN_RELOAD)


func begin_hook_pull(anchor: Vector2, dir: Vector2) -> void:
	if not alive:
		return
	hook_anchor = anchor
	velocity = velocity.lerp(dir * Balance.HOOK_PULL_MAX_SPEED * 0.35, 0.5)
	machine.change(&"hook_pull")
	EventBus.hook_attached.emit(self, null, anchor)


func clear_hook() -> void:
	hook_anchor = Vector2.ZERO
	if active_hook != null and is_instance_valid(active_hook):
		active_hook.queue_free()
	active_hook = null


func apply_hook_yank(v: Vector2, stun: float) -> void:
	velocity = v
	stun_left = maxf(stun_left, stun)
	machine.interruptible()


func apply_knockback(v: Vector2) -> void:
	velocity = (velocity + v).limit_length(Balance.ROLL_SPEED * 1.4)


func on_hit_feedback(kind: int, dealt: float) -> void:
	hurt_left = 0.16
	# State colour goes on `self_modulate`; alpha (occlusion) lives on
	# `modulate.a`. Keeping them on separate properties means a flash and a
	# behind-a-wall fade can never overwrite each other.
	self_modulate = Color(2.2, 2.2, 2.2, 1.0)
	var tw := create_tween()
	tw.tween_property(self, "self_modulate", Color.WHITE, 0.13)
	Fx.damage_number(get_parent(), global_position, dealt, kind)
	if is_local:
		EventBus.screen_shake.emit(Balance.SHAKE_BULLET if kind == Enums.DamageKind.BULLET else Balance.SHAKE_MELEE, 0.14)


func set_obscured(value: bool) -> void:
	obscured = value


# ===========================================================================
# death / respawn
# ===========================================================================

func die(killer: Node, kind: int) -> void:
	if not alive:
		return
	alive = false
	hp = 0.0
	clear_hook()
	EventBus.health_changed.emit(self, 0.0, max_hp)
	machine.force(&"dead")
	Fx.burst(get_parent(), "blood", global_position, 1.1, 0.0)
	AudioDirector.play_at(
		"death_bot" if team == Enums.Team.BOTS else "death_human",
		global_position, global_position, 420.0)
	if is_local:
		EventBus.screen_shake.emit(Balance.SHAKE_KILL, 0.3)
	if killer == self or (killer != null and is_instance_valid(killer)):
		EventBus.hitstop.emit(Balance.HITSTOP_KILL)
	EventBus.emit_kill(killer, self, kind)


func on_death_visual() -> void:
	anim = "dead"
	anim_clock = 0.0
	collision_layer = 0
	velocity = Vector2.ZERO
	if light != null:
		light.enabled = false
	if _under != null:
		_under.queue_redraw()
	if _over != null:
		_over.visible = false


func on_revive_visual() -> void:
	collision_layer = Combat.ACTOR_MASK
	self_modulate = Color.WHITE
	var c := sprite.modulate
	c.a = 1.0
	sprite.modulate = c
	if light != null:
		light.enabled = true
	if _over != null:
		_over.visible = true


func respawn(pos: Vector2) -> void:
	global_position = pos
	hp = max_hp
	alive = true
	velocity = Vector2.ZERO
	weapon = Enums.Weapon.MELEE
	mag = Balance.GUN_MAG
	reload_left = 0.0
	draw_left = 0.0
	melee_cd = 0.0
	gun_cd = 0.0
	hook_cd = 0.0
	roll_cd = 0.0
	stun_left = 0.0
	hurt_left = 0.0
	spawn_invuln = Balance.SPAWN_INVULN
	i_frames = 0.0
	obscured = false
	machine.force(&"locomotion")
	EventBus.health_changed.emit(self, hp, max_hp)
	EventBus.ammo_changed.emit(self, mag, Balance.GUN_MAG)
	EventBus.weapon_changed.emit(self, weapon)
	EventBus.actor_respawned.emit(self)
	AudioDirector.play_at("spawn", global_position, global_position)


# ===========================================================================
# decals drawn under / over the sprite
# ===========================================================================

class ActorDecal extends Node2D:
	const RING: int = 0
	const STATUS: int = 1

	var body: ActorBody = null
	var layer_kind: int = RING

	func _draw() -> void:
		if body == null or not is_instance_valid(body):
			return
		if layer_kind == RING:
			_draw_ring()
		else:
			_draw_status()

	## A per-actor floor ring in the actor's own colour. Team colour already
	## lives on the sprite, so the ring exists to answer "which of the three of
	## us is me", which team colour alone cannot do.
	func _draw_ring() -> void:
		if not body.alive:
			return
		var col := body.player_color
		draw_arc(Vector2.ZERO, body.hit_radius + 3.2, 0.0, TAU, 22,
			Color(col.r, col.g, col.b, 0.80), 1.4)
		if body.spawn_invuln > 0.0:
			draw_arc(Vector2.ZERO, body.hit_radius + 5.4, 0.0, TAU, 22,
				Color(col.r, col.g, col.b, 0.35), 1.0)

	func _draw_status() -> void:
		if not body.alive:
			return
		var w := 20.0
		var h := 3.0
		var top := -body.hit_radius - 13.0
		draw_rect(Rect2(-w * 0.5 - 1.0, top - 1.0, w + 2.0, h + 2.0),
			Color(0.0, 0.0, 0.0, 0.62), true)
		var frac: float = clampf(body.hp / maxf(1.0, body.max_hp), 0.0, 1.0)
		var col := Color("5ddc8a")
		if frac < 0.34:
			col = Color("ef5350")
		elif frac < 0.67:
			col = Color("e0b23c")
		draw_rect(Rect2(-w * 0.5, top, w * frac, h), col, true)
		# reload pip: white bar that fills as the reload completes
		if body.reload_left > 0.0:
			var done: float = 1.0 - clampf(body.reload_left / Balance.GUN_RELOAD, 0.0, 1.0)
			draw_rect(Rect2(-w * 0.5, top + h + 1.0, w * done, 1.5),
				Color(0.85, 0.92, 1.0, 0.9), true)
		if body.stun_left > 0.0:
			draw_arc(Vector2.ZERO, body.hit_radius + 6.5, -PI * 0.5,
				-PI * 0.5 + TAU * clampf(body.stun_left / 0.3, 0.0, 1.0), 18,
				Color(1.0, 0.85, 0.3, 0.85), 1.2)
