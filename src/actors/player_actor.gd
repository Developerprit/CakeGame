class_name PlayerActor
extends ActorBody
## Local human player.
##
## Aiming rule from the spec: the character ALWAYS faces the aim source, and for
## a mouse that means the pointer. The knock-on effect - and the reason the bots
## are allowed to be genuinely strong - is that aim direction is public
## information. A bot can see your muzzle swing onto it and roll before you
## finish pulling the trigger. That is a legitimate read, not clairvoyance,
## because a human can do exactly the same thing by watching the bot's visor.

var use_mouse_aim: bool = true


func _aim_tick(delta: float) -> void:
	if not is_local or not alive:
		return
	# A gamepad drives the aim directly from the right stick (classic twin-stick).
	# Instant snapping feels bad on a stick, so slew toward the requested angle.
	var stick := InputSetup.stick_aim_vector()
	if stick.length_squared() > 0.01:
		var want := stick.angle()
		var cur := aim_dir.angle()
		var step := Balance.TURN_RATE * delta
		aim_dir = Vector2.RIGHT.rotated(cur + clampf(Utils.angle_delta(cur, want), -step, step))
		use_mouse_aim = false
		return

	use_mouse_aim = true
	var mouse := get_global_mouse_position()
	var to_mouse := mouse - global_position
	if to_mouse.length_squared() > 4.0:
		aim_dir = to_mouse.normalized()


func _control_tick(_delta: float) -> void:
	if not is_local or not alive:
		move_input = Vector2.ZERO
		return
	move_input = InputSetup.move_vector()

	want_fire = Input.is_action_pressed(&"fire")
	want_melee = Input.is_action_just_pressed(&"melee")
	want_toggle_gun = Input.is_action_just_pressed(&"toggle_gun")
	want_hook = Input.is_action_just_pressed(&"hook")
	want_roll = Input.is_action_just_pressed(&"roll")
	want_reload = Input.is_action_just_pressed(&"reload")
