class_name BotActor
extends ActorBody
## AI-driven actor.
##
## The controller is deliberately thin. Everything that makes the bot feel sharp
## lives in its brain; this class only pumps the brain and copies the resulting
## intent onto the body, through exactly the same fields a human controller
## writes. That is what guarantees the bot can never use a move the human cannot,
## and it is what lets a headless harness drive a bot with no input device.

var brain: BotBrain = null
var bot_version: String = BotRegistry.DEFAULT_ID


func setup_brain(version_id: String) -> void:
	bot_version = version_id
	brain = BotRegistry.create(version_id)
	if brain == null:
		push_error("[BotActor] unknown bot version '%s', falling back" % version_id)
		brain = BotRegistry.create(BotRegistry.DEFAULT_ID)
	if brain != null:
		brain.setup(self)


func _exit_tree() -> void:
	if brain != null:
		brain.dispose()
		brain = null
	super._exit_tree()


func _control_tick(delta: float) -> void:
	if brain == null:
		move_input = Vector2.ZERO
		return
	if not alive:
		move_input = Vector2.ZERO
		# A dead brain still needs its timers ticked so a respawn is not a
		# one-frame freeze of stale decisions.
		brain.think(delta)
		return

	brain.think(delta)
	move_input = brain.move_dir
	# Continuous intents: safe to copy on every body tick. `want_fire` is a held
	# trigger and `want_reload` is idempotent (`begin_reload` no-ops while a
	# reload is already running).
	want_fire = brain.want_fire
	aim_dir = brain.aim_dir

	# One-shot intents: copied only on the tick a fresh decision landed.
	#
	# `ActorBody._physics_process` clears these after the state machine has had
	# its chance to act, so they mean "pressed this frame". Re-copying the brain's
	# snapshot on the ~44 body ticks between decisions turned each single press
	# into a four-frame hold - which for `want_toggle_gun` means the weapon
	# toggles at 60 Hz and the draw animation never completes. See
	# `BotBrain.intent_fresh`.
	if brain.intent_fresh:
		brain.intent_fresh = false
		want_melee = brain.want_melee
		want_toggle_gun = brain.want_toggle_gun
		want_hook = brain.want_hook
		want_roll = brain.want_roll
		want_reload = brain.want_reload
