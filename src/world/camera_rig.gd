class_name CameraRig
extends Camera2D
## The match camera: keeps every fighter on screen at once, alive or not, and
## pulls back as the group spreads out.
##
## A fixed camera does not work for this game. The arena is 34-56 tiles across
## (544-896 px) while the viewport is 640x360, and the bots deliberately fight at
## range - so a camera locked to the local player loses the bot that is kiting
## around a building, and the player is killed by something off screen. Framing
## the whole group is the only option that keeps a 1v2 readable.
##
## The frame maths is a static function so it can be unit-tested without a
## window; `--headless` has no real viewport and the interesting bugs here
## (degenerate box for a single actor, zoom snap on a spawn split, camera drifting
## off the map) are all pure geometry.

## Breathing room kept around the framed group, per side, in world pixels.
const FRAME_MARGIN: float = 72.0

## Smallest box the camera will consider. Without a floor, two fighters standing
## on top of each other give a zero-size box and the camera slams to MAX_ZOOM,
## which reads as the game glitching rather than as a close-up.
const MIN_BOX: Vector2 = Vector2(208.0, 136.0)

## Zoom clamp. MAX_ZOOM 3.0 shows 213x120 px (13x7 tiles) at 640x360; MIN_ZOOM
## 0.55 shows 1163x654 px, which is wider than any generated arena, so the map
## clamp below always has something to do at the far end.
const MAX_ZOOM: float = 3.0
const MIN_ZOOM: float = 0.55

## Exponential approach rates, per second. Centre follows faster than zoom: a
## camera that zooms as eagerly as it pans feels like it is hunting.
const CENTER_RATE: float = 7.5
const ZOOM_RATE: float = 4.2

## A wall this close to an actor, on the camera's side of it, hides the actor.
## Deliberately small: the test is "is there geometry immediately in front of
## him", not "is there geometry anywhere along the line". The loose version makes
## every fighter standing near a building flicker in and out of visibility, which
## players describe as the game being broken.
const OBSCURE_NEAR: float = 20.0

var enabled_framing: bool = true

var _desired_center: Vector2 = Vector2.ZERO
var _desired_zoom: float = 1.6
var _snapped: bool = false
var _shake_amp: float = 0.0
var _shake_left: float = 0.0
var _shake_total: float = 1.0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	position_smoothing_enabled = false
	process_callback = Camera2D.CAMERA2D_PROCESS_PHYSICS
	_rng.seed = 0xCA9E
	if not EventBus.screen_shake.is_connected(_on_shake):
		EventBus.screen_shake.connect(_on_shake)
	make_current()


func _physics_process(delta: float) -> void:
	if not enabled_framing:
		return
	_update_target()
	_apply(delta)
	_update_obscured()


## Jump straight to the framed pose instead of easing into it. Called on round
## start and after a respawn split, where easing would show the camera flying
## across the map and the player missing the first second of the fight.
func snap_now() -> void:
	_update_target()
	global_position = _desired_center
	zoom = Vector2(_desired_zoom, _desired_zoom)
	_shake_amp = 0.0
	_shake_left = 0.0
	offset = Vector2.ZERO
	_snapped = true


# ===========================================================================
# framing maths (pure, testable)
# ===========================================================================

## World-space extent the camera needs to cover for a group occupying a
## `box_size` box. Exposed so the tests assert against the same formula the
## runtime uses instead of a hand-copied duplicate that drifts.
static func extent_for(box_size: Vector2) -> Vector2:
	var ext := box_size + Vector2(FRAME_MARGIN, FRAME_MARGIN) * 2.0
	return Vector2(maxf(ext.x, MIN_BOX.x), maxf(ext.y, MIN_BOX.y))


## Framed centre and zoom for a set of world-space points in a `view`-sized
## viewport. Returns `{center, zoom, box}`; `zoom` is <= 0 when `points` is empty.
static func frame_for(points: Array[Vector2], view: Vector2) -> Dictionary:
	if points.is_empty():
		return {"center": Vector2.ZERO, "zoom": 0.0, "box": Rect2()}
	var box := Rect2(points[0], Vector2.ZERO)
	for p in points:
		box = box.expand(p)
	var ext := extent_for(box.size)
	var z := minf(view.x / maxf(1.0, ext.x), view.y / maxf(1.0, ext.y))
	z = clampf(z, MIN_ZOOM, MAX_ZOOM)
	return {"center": box.get_center(), "zoom": z, "box": box}


## Clamp a framed centre so the visible rectangle stays inside `bounds` whenever
## the bounds are bigger than the view, and centre on the bounds otherwise.
static func clamp_to_bounds(center: Vector2, z: float, view: Vector2,
		bounds: Rect2) -> Vector2:
	if bounds.size.x <= 0.0 or bounds.size.y <= 0.0:
		return center
	var half := view / maxf(0.001, z) * 0.5
	var out := center
	if bounds.size.x > half.x * 2.0:
		out.x = clampf(out.x, bounds.position.x + half.x, bounds.end.x - half.x)
	else:
		out.x = bounds.get_center().x
	if bounds.size.y > half.y * 2.0:
		out.y = clampf(out.y, bounds.position.y + half.y, bounds.end.y - half.y)
	else:
		out.y = bounds.get_center().y
	return out


# ===========================================================================
# per-frame update
# ===========================================================================

func _update_target() -> void:
	var pts := _frame_points()
	if pts.is_empty():
		return
	var view := get_viewport_rect().size
	if view.x <= 1.0 or view.y <= 1.0:
		view = Vector2(640.0, 360.0)
	var framed := frame_for(pts, view)
	var arena := _arena()
	var center: Vector2 = framed["center"]
	var z: float = framed["zoom"]
	if arena != null:
		center = clamp_to_bounds(center, z, view, arena.world_rect())
	_desired_center = center
	_desired_zoom = z


## Living fighters define the frame. When nobody is standing we fall back to the
## whole roster so the last kill is still on screen while the round-over banner
## comes up, instead of the camera sitting wherever the final body happened to
## land with nothing in frame.
func _frame_points() -> Array[Vector2]:
	var out: Array[Vector2] = []
	var tree := get_tree()
	if tree == null:
		return out
	var living: Array[Vector2] = []
	var everyone: Array[Vector2] = []
	for n in tree.get_nodes_in_group(ActorBody.GROUP):
		var a := n as ActorBody
		if a == null or not is_instance_valid(a):
			continue
		everyone.append(a.global_position)
		if a.is_alive():
			living.append(a.global_position)
	if not living.is_empty():
		return living
	return everyone


func _apply(delta: float) -> void:
	if not _snapped:
		global_position = _desired_center
		zoom = Vector2(_desired_zoom, _desired_zoom)
		_snapped = true
	else:
		global_position = global_position.lerp(_desired_center,
			clampf(delta * CENTER_RATE, 0.0, 1.0))
		# Zoom is interpolated in LOG space. Linear interpolation spends most of
		# its travel at the wide end, so pulling out snaps while pushing in
		# crawls; log space makes the rate feel constant, which is what people
		# actually perceive as "smooth zoom".
		var cur: float = maxf(0.01, zoom.x)
		var target: float = maxf(0.01, _desired_zoom)
		var nz: float = exp(lerpf(log(cur), log(target),
			clampf(delta * ZOOM_RATE, 0.0, 1.0)))
		zoom = Vector2(nz, nz)
		_shake_tick(delta)


func _on_shake(amount: float, duration: float) -> void:
	if amount <= 0.0 or duration <= 0.0:
		return
	# Take the strongest request rather than summing: two bullets landing in the
	# same frame should not double the shake, or a shotgun burst throws the view
	# off the fight.
	_shake_amp = maxf(_shake_amp, amount)
	_shake_total = maxf(duration, _shake_left)
	_shake_left = _shake_total


func _shake_tick(delta: float) -> void:
	if _shake_left <= 0.0:
		offset = Vector2.ZERO
		return
	_shake_left = maxf(0.0, _shake_left - delta)
	var falloff: float = _shake_left / maxf(0.001, _shake_total)
	var amp: float = _shake_amp * falloff * falloff
	offset = Vector2(_rng.randf_range(-amp, amp), _rng.randf_range(-amp, amp))
	if _shake_left <= 0.0:
		_shake_amp = 0.0
		offset = Vector2.ZERO


# ===========================================================================
# occlusion
# ===========================================================================

## Fade fighters that have geometry immediately in front of them, from the
## camera's point of view.
##
## The local player is exempt. Fading your own character while you are still
## moving it is disorienting - you lose track of where you are at exactly the
## moment you need it - and you already know where you are standing.
##
## Runs in the physics step because `direct_space_state` is only valid there.
func _update_obscured() -> void:
	var tree := get_tree()
	if tree == null or get_world_2d() == null:
		return
	var space := get_world_2d().direct_space_state
	if space == null:
		return
	var eye := global_position
	for n in tree.get_nodes_in_group(ActorBody.GROUP):
		var a := n as ActorBody
		if a == null or not is_instance_valid(a):
			continue
		if a.is_local or not a.is_alive():
			a.set_obscured(false)
			continue
		var hidden := false
		var hit := Combat.world_ray(space, eye, a.global_position)
		if not hit.is_empty():
			var hp: Vector2 = hit.get("position", Vector2.ZERO)
			hidden = hp.distance_to(a.global_position) <= OBSCURE_NEAR
		a.set_obscured(hidden)


func _arena() -> Arena:
	var tree := get_tree()
	if tree == null:
		return null
	return tree.get_first_node_in_group(Arena.GROUP) as Arena
