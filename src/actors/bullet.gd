class_name Bullet
extends Node2D
## A hitscan-ish projectile.
##
## It is a moving Node2D that raycasts along each frame's travel segment rather
## than an Area2D that overlaps. At 320 px/s a bullet moves 5.3 px per physics
## tick, which is already more than a character's collision radius once the
## frame rate dips - overlap-based bullets start tunnelling straight through
## people. A segment query cannot tunnel, and it also gives the exact impact
## point for free.
##
## `authoritative` is false on clients. Such a bullet still moves and still
## stops when it hits geometry (so the visuals match), but it deals no damage -
## only the host decides who got hit.

var shooter: ActorBody = null
var team: int = Enums.Team.HUMANS
var dir: Vector2 = Vector2.RIGHT
var speed: float = Balance.BULLET_SPEED
var damage: float = Balance.BULLET_DAMAGE
var max_range: float = Balance.BULLET_RANGE
var knockback: float = Balance.GUN_RECOIL_KNOCKBACK
var authoritative: bool = true
var traveled: float = 0.0
var clock: float = 0.0
var dead: bool = false

var _sprite: Sprite2D


func configure(sh: ActorBody, aim: Vector2, spread_rad: float = 0.0,
		dmg: float = -1.0, spd: float = -1.0, rng: float = -1.0) -> void:
	shooter = sh
	team = sh.team if sh != null else Enums.Team.HUMANS
	dir = aim.rotated(spread_rad).normalized()
	if dmg > 0.0:
		damage = dmg
	if spd > 0.0:
		speed = spd
	if rng > 0.0:
		max_range = rng
	rotation = dir.angle()


func _ready() -> void:
	z_index = 3
	_sprite = Sprite2D.new()
	_sprite.texture = AtlasLibrary.fx_frame("bullet", 0)
	_sprite.z_index = 3
	add_child(_sprite)


func _physics_process(delta: float) -> void:
	if dead:
		return
	clock += delta
	_sprite.texture = AtlasLibrary.fx_frame("bullet", int(clock * 24.0))

	var from := global_position
	var step := dir * speed * delta
	var to := from + step
	var travel := step.length()
	traveled += travel

	if authoritative:
		var hit := _resolve(from, to)
		if not hit.is_empty():
			_apply(hit)
			return

	global_position = to
	if traveled >= max_range:
		_expire(false)


## Walk the segment, skipping over friendlies when friendly fire is off.
## Returns {} for a clean miss, otherwise a hit descriptor.
func _resolve(from: Vector2, to: Vector2) -> Dictionary:
	var space := get_world_2d().direct_space_state
	if space == null:
		return {}
	var ex: Array[RID] = []
	if shooter != null and is_instance_valid(shooter):
		ex.append(shooter.get_rid())

	var cursor := from
	for _guard in 5:
		var q := PhysicsRayQueryParameters2D.create(cursor, to,
			Combat.WORLD_MASK | Combat.ACTOR_MASK)
		q.collide_with_areas = false
		q.collide_with_bodies = true
		if not ex.is_empty():
			q.exclude = ex
		var res := space.intersect_ray(q)
		if res.is_empty():
			return {}
		var pos: Vector2 = res.get("position", to)
		var col: Object = res.get("collider")
		var ab := col as ActorBody
		if ab != null:
			if ab == shooter:
				ex.append(ab.get_rid())
				cursor = pos + dir * 0.25
				continue
			if not Combat.is_enemy(team, ab.team):
				ex.append(ab.get_rid())
				cursor = pos + dir * 0.25
				continue
			return {"actor": ab, "pos": pos}
		return {"wall": true, "pos": pos}
	return {}


func _apply(hit: Dictionary) -> void:
	var pos: Vector2 = hit.get("pos", global_position)
	var ab := hit.get("actor") as ActorBody
	if ab != null:
		var knock := dir * knockback
		var landed := Combat.apply_damage(ab, damage, Enums.DamageKind.BULLET,
			shooter, knock, pos, shooter)
		Fx.burst(get_parent(), "blood", pos, 0.7, dir.angle())
		if landed:
			AudioDirector.play_at("hit_flesh", pos, pos, 300.0)
		else:
			AudioDirector.play_at("hit_wall", pos, pos, 300.0)
	else:
		Fx.burst(get_parent(), "spark", pos, 0.8, -dir.angle())
		AudioDirector.play_at("hit_wall", pos, pos, 300.0)
	_expire(true)


func _expire(_hit_something: bool) -> void:
	dead = true
	queue_free()
