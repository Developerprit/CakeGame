class_name StateMachine
extends RefCounted
## Minimal, explicit state machine.
##
## Two deliberate choices, both learned from earlier projects:
##
## 1. States are registered under an explicit StringName instead of reading a
##    default off each state object. A GDScript inner class cannot give the base
##    class a per-subclass default, so every state would otherwise report the
##    same key.
## 2. `change()` refuses to leave a non-interruptible state unless forced. That
##    single guard prevents a whole genre of "the roll got cancelled halfway and
##    the i-frames leaked" bugs - but it also means anything that MUST be able to
##    interrupt (death, round reset) has to call `force()` on purpose.

var actor: ActorBody
var states: Dictionary = {}
var current: ActorState = null
var current_id: StringName = &""
var previous_id: StringName = &""
var change_count: int = 0
var last_refused: StringName = &""


func setup(a: ActorBody) -> void:
	actor = a


func register(state_id: StringName, st: ActorState) -> void:
	st.id = state_id
	st.setup(self, actor)
	states[state_id] = st


func has(state_id: StringName) -> bool:
	return states.has(state_id)


func state(state_id: StringName) -> ActorState:
	return states.get(state_id, null) as ActorState


## Returns true when the transition happened.
func change(state_id: StringName, data: Dictionary = {}) -> bool:
	if not states.has(state_id):
		push_error("[StateMachine] unknown state: %s" % state_id)
		return false
	if state_id == current_id:
		# Re-entering the current state is almost always a bug at the call site,
		# and silently restarting the state would reset its timers and make
		# animations stutter. Refuse unless the caller insists.
		if not bool(data.get("restart", false)):
			return false
	var forced := bool(data.get("force", false))
	if current != null and current_id != state_id and not forced and not current.interruptible():
		last_refused = state_id
		return false
	if current != null:
		current.exit()
	previous_id = current_id
	current_id = state_id
	current = states[state_id]
	current.time = 0.0
	current.entered_count += 1
	current.enter(previous_id, data)
	change_count += 1
	return true


## Whether `change()` may currently leave the current state.
##
## `ActorBody.apply_hook_yank()` asks for this before a grapple interrupts its
## victim, so a hook can cut a bot out of a swing. The method used to be missing
## from this class, so that call threw "Nonexistent function 'interruptible'"
## every time a hook caught somebody - which is why hooking a bot did nothing.
func interruptible() -> bool:
	return current == null or current.interruptible()


## Transition that ignores `interruptible()`. Use for death, round resets and
## anything the player has no agency over.
func force(state_id: StringName, data: Dictionary = {}) -> bool:
	var d := data.duplicate()
	d["force"] = true
	return change(state_id, d)


func is_state(state_id: StringName) -> bool:
	return current_id == state_id


func update(delta: float) -> void:
	if current == null:
		return
	current.time += delta
	current.update(delta)


## Physics tick: the state clock advances HERE, not in `update()`.
##
## The clock used to live only in `update()`, which nothing ever called for an
## actor - `ActorBody` drives the machine through `physics()` and never touches
## `update()`. Every state condition written in seconds (`time >= MELEE_WINDUP`,
## `time >= ROLL_DURATION`, ...) therefore compared against a clock frozen at 0:
## the melee active window opened never, the swing never struck, the melee state
## never finished, and roll and hook never terminated. That is why the attacks
## looked like they could not be triggered at all - the swing started, then
## wedged the actor in place forever.
##
## Both entry points advance the clock so either one is safe to drive from.
func physics(delta: float) -> void:
	if current == null:
		return
	current.time += delta
	current.physics(delta)


## Break the actor <-> state back-reference so a freed actor can be collected.
func dispose() -> void:
	if current != null:
		current.exit()
	current = null
	for k in states.keys():
		states[k] = null
	states.clear()
	actor = null
