extends Node
## Builds the entire InputMap at runtime (autoload `InputSetup`).
##
## Why runtime instead of project.godot: the serialised `InputEventKey` blobs in
## project.godot are enormous, easy to corrupt, and impossible to review in a
## diff. Doing it in code keeps the whole control scheme readable in one screen
## and makes rebinding a one-liner.
##
## Control scheme (per the design spec — the character ALWAYS faces the aim
## source, and aiming is driven by the pointer for mouse users):
##   WASD ....... move
##   mouse ...... aim (character faces the pointer at all times)
##   RMB ........ melee attack
##   E .......... draw / holster the gun
##   LMB ........ fire (only while the gun is drawn)
##   Q .......... grapple hook (pull yourself, or pull the target to you)
##   Shift ...... roll (invulnerability frames)
##   Esc ........ pause

const DEADZONE: float = 0.22

## Runtime-rebindable slots. Keys are the action names used everywhere else.
const REBINDABLE: Array[StringName] = [
	&"move_up", &"move_down", &"move_left", &"move_right",
	&"melee", &"toggle_gun", &"fire", &"hook", &"roll", &"reload", &"pause",
]

var _default_keys: Dictionary = {}


func _ready() -> void:
	_build_all()
	_snapshot_defaults()


func _build_all() -> void:
	_reset_actions()

	# ---- movement (keyboard) ----
	_key(&"move_up", KEY_W)
	_key(&"move_down", KEY_S)
	_key(&"move_left", KEY_A)
	_key(&"move_right", KEY_D)
	# arrows as a secondary, because laptop users exist
	_key(&"move_up", KEY_UP)
	_key(&"move_down", KEY_DOWN)
	_key(&"move_left", KEY_LEFT)
	_key(&"move_right", KEY_RIGHT)

	# ---- movement (gamepad sticks + dpad) ----
	_axis(&"move_left", JOY_AXIS_LEFT_X, -1.0)
	_axis(&"move_right", JOY_AXIS_LEFT_X, 1.0)
	_axis(&"move_up", JOY_AXIS_LEFT_Y, -1.0)
	_axis(&"move_down", JOY_AXIS_LEFT_Y, 1.0)
	_btn(&"move_up", JOY_BUTTON_DPAD_UP)
	_btn(&"move_down", JOY_BUTTON_DPAD_DOWN)
	_btn(&"move_left", JOY_BUTTON_DPAD_LEFT)
	_btn(&"move_right", JOY_BUTTON_DPAD_RIGHT)

	# ---- aim (gamepad right stick, used only when a pad is active) ----
	_axis(&"aim_left", JOY_AXIS_RIGHT_X, -1.0)
	_axis(&"aim_right", JOY_AXIS_RIGHT_X, 1.0)
	_axis(&"aim_up", JOY_AXIS_RIGHT_Y, -1.0)
	_axis(&"aim_down", JOY_AXIS_RIGHT_Y, 1.0)

	# ---- combat ----
	_mouse(&"melee", MOUSE_BUTTON_RIGHT)
	_btn(&"melee", JOY_BUTTON_LEFT_SHOULDER)   # LB
	_axis(&"melee", JOY_AXIS_TRIGGER_LEFT, 1.0)

	_key(&"toggle_gun", KEY_E)
	_btn(&"toggle_gun", JOY_BUTTON_X)

	_mouse(&"fire", MOUSE_BUTTON_LEFT)
	_btn(&"fire", JOY_BUTTON_RIGHT_SHOULDER)   # RB
	_axis(&"fire", JOY_AXIS_TRIGGER_RIGHT, 1.0)

	_key(&"hook", KEY_Q)
	_btn(&"hook", JOY_BUTTON_Y)

	_key(&"roll", KEY_SHIFT)
	_btn(&"roll", JOY_BUTTON_B)

	_key(&"reload", KEY_R)
	_btn(&"reload", JOY_BUTTON_LEFT_STICK)

	_key(&"pause", KEY_ESCAPE)
	_btn(&"pause", JOY_BUTTON_START)

	# ---- misc / debug ----
	_btn(&"ui_accept", JOY_BUTTON_A)
	_btn(&"ui_cancel", JOY_BUTTON_B)


func _reset_actions() -> void:
	for name: StringName in REBINDABLE:
		if InputMap.has_action(name):
			InputMap.action_erase_events(name)
		else:
			InputMap.add_action(name, DEADZONE)
	for extra: StringName in [&"aim_up", &"aim_down", &"aim_left", &"aim_right"]:
		if InputMap.has_action(extra):
			InputMap.action_erase_events(extra)
		else:
			InputMap.add_action(extra, 0.35)


func _key(action: StringName, keycode: int) -> void:
	var ev := InputEventKey.new()
	ev.physical_keycode = keycode
	_add(action, ev)


func _mouse(action: StringName, button: int) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = button as MouseButton
	_add(action, ev)


func _btn(action: StringName, button: int) -> void:
	var ev := InputEventJoypadButton.new()
	ev.button_index = button as JoyButton
	_add(action, ev)


func _axis(action: StringName, axis: int, value: float) -> void:
	var ev := InputEventJoypadMotion.new()
	ev.axis = axis as JoyAxis
	ev.axis_value = value
	_add(action, ev)


func _add(action: StringName, ev: InputEvent) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action, DEADZONE)
	InputMap.action_add_event(action, ev)


# ---------------------------------------------------------------------------
# query helpers
# ---------------------------------------------------------------------------

## Normalised movement vector from keyboard + stick. Length <= 1.
func move_vector() -> Vector2:
	return Input.get_vector(&"move_left", &"move_right", &"move_up", &"move_down")


## Normalised aim vector from the gamepad's right stick. Zero when idle, which
## the player controller reads as "no stick aim, fall back to the pointer".
func stick_aim_vector() -> Vector2:
	var v := Vector2(
		Input.get_action_strength(&"aim_right") - Input.get_action_strength(&"aim_left"),
		Input.get_action_strength(&"aim_down") - Input.get_action_strength(&"aim_up"),
	)
	if v.length() < 0.35:
		return Vector2.ZERO
	return v.normalized()


func gamepad_active() -> bool:
	return Input.get_connected_joypads().size() > 0


# ---------------------------------------------------------------------------
# rebinding
# ---------------------------------------------------------------------------

func _snapshot_defaults() -> void:
	_default_keys.clear()
	for a: StringName in REBINDABLE:
		var evs := InputMap.action_get_events(a)
		for e in evs:
			if e is InputEventKey:
				_default_keys[a] = (e as InputEventKey).physical_keycode
				break


func default_key(action: StringName) -> int:
	return int(_default_keys.get(action, 0))


## Replace a keyboard binding at runtime. Returns false on a duplicate that
## would shadow another action.
func rebind_key(action: StringName, keycode: int) -> bool:
	if not InputMap.has_action(action):
		return false
	for other: StringName in REBINDABLE:
		if other == action:
			continue
		for e in InputMap.action_get_events(other):
			if e is InputEventKey and (e as InputEventKey).physical_keycode == keycode:
				return false
	# strip only keyboard events, keep mouse/pad binds intact
	for e in InputMap.action_get_events(action):
		if e is InputEventKey:
			InputMap.action_erase_event(action, e)
	var ev := InputEventKey.new()
	ev.physical_keycode = keycode as Key
	InputMap.action_add_event(action, ev)
	return true


func key_label(action: StringName) -> String:
	for e in InputMap.action_get_events(action):
		if e is InputEventKey:
			return OS.get_keycode_string((e as InputEventKey).physical_keycode)
	return "-"
