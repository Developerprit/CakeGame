class_name Hook
extends Node2D
## Grapple hook (Q).
##
## Two outcomes, both required by the spec ("used for repositioning OR pulling a
## target closer"):
##   * hits geometry  -> stays planted and the SHOOTER is reeled in, with
##                       acceleration rather than a snap, so you can slingshot
##   * hits an enemy  -> deals a little damage and YANKS THEM toward the shooter
##
## The rope is drawn in `_draw()` rather than as a sprite so it can stretch to
## exactly bridge the two points regardless of distance.

enum Phase { FLYING, PLANTED, RETRACTING }

const CLAW_RADIUS: float = 6.0

var shooter: ActorBody = null
var team: int = Enums.Team.HUMANS
var dir: Vector2 = Vector2.RIGHT
var speed: float = Balance.HOOK_SPEED
var damage: float = Balance.HOOK_DAMAGE
var max_range: float = Balance.HOOK_MAX_RANGE
var authoritative: bool = true

var phase: int = Phase.FLYING
var traveled: float = 0.0
var clock: float = 0.0
var anchor: Vector2 = Vector2.ZERO
var victim: ActorBody = null

var _claw: Sprite2D
var _line_col: Color = Color("c9d6dd")
var _line_w: float = 1.6


func configure(sh: ActorBody, aim: Vector2) -> void:
	shooter = sh
	team = sh.team if sh != null else Enums.Team.HUMANS
	dir = aim.normalized()
	anchor = sh.global_position if sh != null else global_position
	rotation = dir.angle()


func _ready() -> void:
	z_index = 3
	_claw = Sprite2D.new()
	_claw.texture = AtlasLibrary.fx_frame("hook_head", 0)
	_claw.z_index = 4
	add_child(_claw)
	_line_col = PixelTheme.c("accent")


func _physics_process(delta: float) -> void:
	clock += delta
	_claw.texture = AtlasLibrary.fx_frame("hook_head", int(clock * 18.0))

	match phase:
		Phase.FLYING:
			_fly(delta)
		Phase.PLANTED:
			_check_owner()
			_check_planted_timeout()
		Phase.RETRACTING:
			_retract(delta)
	queue_redraw()


func _fly(delta: float) -> void:
	var from := global_position
	var step := dir * speed * delta
	var to := from + step
	traveled += step.length()

	if authoritative:
		var hit := _resolve(from, to)
		if not hit.is_empty():
			var pos: Vector2 = hit.get("pos", to)
			global_position = pos
			var ab := hit.get("actor") as ActorBody
			if ab != null:
				_hit_actor(ab, pos)
			else:
				_plant(pos)
			return

	global_position = to
	if traveled >= max_range:
		_fail()


func _resolve(from: Vector2, to: Vector2) -> Dictionary:
	var space := get_world_2d().direct_space_state
	if space == null:
		return {}
	var ex: Array[RID] = []
	if shooter != null and is_instance_valid(shooter):
		ex.append(shooter.get_rid())
	var q := PhysicsRayQueryParameters2D.create(from, to,
		Combat.WORLD_MASK | Combat.ACTOR_MASK)
	q.collide_with_areas = false
	if not ex.is_empty():
		q.exclude = ex
	var res := space.intersect_ray(q)
	if res.is_empty():
		return {}
	var pos: Vector2 = res.get("position", to)
	var col: Object = res.get("collider")
	var ab := col as ActorBody
	if ab != null:
		if ab == shooter or not Combat.is_enemy(team, ab.team):
			return {}
		return {"actor": ab, "pos": pos}
	return {"wall": true, "pos": pos}


func _plant(pos: Vector2) -> void:
	phase = Phase.PLANTED
	anchor = pos
	global_position = pos
	Fx.burst(get_parent(), "spark", pos, 0.9, -dir.angle())
	AudioDirector.play_at("hook_attach", pos, pos, 320.0)
	if shooter != null and is_instance_valid(shooter):
		# Normalise the anchor direction using the LIVE shooter position, not the
		# fire direction: the target may have moved while the hook was in flight,
		# and pulling along a stale direction looks wrong and can push the shooter
		# into a wall.
		var live := (pos - shooter.global_position).normalized()
		shooter.begin_hook_pull(pos, live)


func _hit_actor(ab: ActorBody, pos: Vector2) -> void:
	victim = ab
	Fx.burst(get_parent(), "blood", pos, 0.8, dir.angle())
	AudioDirector.play_at("hook_attach", pos, pos, 320.0)
	if authoritative and shooter != null and is_instance_valid(shooter):
		var landed := Combat.apply_damage(ab, damage, Enums.DamageKind.HOOK,
			shooter, Vector2.ZERO, pos, shooter)
		if landed:
			# yank the victim toward the shooter, in the shooter's direction
			var pull_dir := (shooter.global_position - ab.global_position).normalized()
			ab.apply_hook_yank(pull_dir * Balance.HOOK_VICTIM_PULL,
				Balance.HOOK_VICTIM_STUN)
	phase = Phase.RETRACTING


func _check_owner() -> void:
	if shooter == null or not is_instance_valid(shooter) or not shooter.is_alive():
		phase = Phase.RETRACTING
		return
	# The owner may have cancelled the pull with a roll.
	if shooter.state_id() != &"hook_pull":
		phase = Phase.RETRACTING
		return
	if shooter.hook_anchor.distance_to(anchor) > 2.0:
		phase = Phase.RETRACTING


func _check_planted_timeout() -> void:
	if clock > Balance.HOOK_REEL_TIME + 0.6:
		phase = Phase.RETRACTING


func _retract(delta: float) -> void:
	var home := global_position
	if shooter != null and is_instance_valid(shooter):
		home = shooter.global_position
	var to := global_position.move_toward(home, speed * 2.2 * delta)
	global_position = to
	if global_position.distance_to(home) < 5.0:
		queue_free()


func _fail() -> void:
	if shooter != null and is_instance_valid(shooter):
		EventBus.hook_missed.emit(shooter)
	AudioDirector.play_at("hook_miss", global_position, global_position, 260.0)
	phase = Phase.RETRACTING


func _draw() -> void:
	var origin := global_position
	if shooter != null and is_instance_valid(shooter):
		origin = shooter.global_position
	# The rope is drawn in this node's local space, so offset by -global_position.
	var a := origin - global_position
	var b := Vector2.ZERO
	draw_line(a, b, Color(0.0, 0.0, 0.0, 0.55), _line_w + 1.6)
	draw_line(a, b, _line_col, _line_w)
	if phase == Phase.PLANTED:
		draw_arc(b, CLAW_RADIUS, 0.0, TAU, 16, Color(1.0, 1.0, 1.0, 0.45), 1.0)
