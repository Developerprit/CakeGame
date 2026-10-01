class_name ActorStates
extends RefCounted
## All actor states.
##
## Layering note: the controller (human input or bot brain) never calls actions
## directly. It only fills in *intent* fields on the body - `move_input`,
## `want_fire`, `want_melee`, `want_roll`, ... - and these states decide whether
## and when that intent becomes an action. The payoff is that the bot drives the
## exact same action pipeline the player does, so a bot can never accidentally
## have a capability (or a missing cooldown) that the human lacks, and balance
## changes apply to both sides at once.
##
## The second payoff is testability: a headless harness can drive a bot by
## filling in a Dictionary of intents, with no input device involved.

# ===========================================================================
# Locomotion - walking, gunning, reloading. The home state.
# ===========================================================================


class Locomotion extends ActorState:
	func enter(_prev: StringName, _data: Dictionary) -> void:
		actor.clear_hook()

	func physics(delta: float) -> void:
		if not actor.is_alive():
			machine.force(&"dead")
			return

		# --- weapon handling. Gun state is a MODE, not a state, so it coexists
		#     with walking: you can strafe while aiming, which is the whole
		#     reason melee and gun feel different.
		if actor.want_toggle_gun:
			actor.toggle_gun()
			actor.want_toggle_gun = false
		if actor.want_reload:
			actor.begin_reload()
			actor.want_reload = false
		if actor.want_fire:
			actor.fire_bullet()

		# --- ability actions take priority, they are what the player pressed ---
		if actor.stun_left <= 0.0:
			if actor.want_roll and actor.roll_cd <= 0.0:
				if machine.change(&"roll"):
					return
			if actor.want_melee and actor.melee_cd <= 0.0:
				if machine.change(&"melee"):
					return
			if actor.want_hook and actor.hook_cd <= 0.0:
				actor.fire_hook()
				actor.want_hook = false

		# --- movement ---
		var target := Vector2.ZERO
		if actor.can_act():
			target = actor.move_input * actor.move_speed()
			if actor.hurt_left > 0.0:
				target *= 0.25
		var rate: float = Balance.ACCEL if target.length_squared() > 0.001 else Balance.FRICTION
		actor.velocity = actor.velocity.move_toward(target, rate * delta)


# ===========================================================================
# Melee - a committed three-phase swing.
# ===========================================================================


class Melee extends ActorState:
	var _struck: bool = false

	func enter(_prev: StringName, _data: Dictionary) -> void:
		_struck = false
		actor.play_anim("melee", true)
		actor.velocity *= 0.35

	func physics(delta: float) -> void:
		if not actor.is_alive():
			machine.force(&"dead")
			return
		actor.velocity = actor.velocity.move_toward(Vector2.ZERO, Balance.FRICTION * 1.1 * delta)

		# active window opens at windup end; the lunge is what makes a whiff look
		# like a real swing rather than a statue waving its arms
		if not _struck and time >= Balance.MELEE_WINDUP:
			_struck = true
			actor.melee_strike()
			actor.velocity = actor.aim_dir * Balance.MELEE_RANGE * 4.2

		if time >= Balance.MELEE_TOTAL:
			actor.melee_cd = Balance.MELEE_COOLDOWN
			machine.change(&"locomotion")

	## Non-interruptible through windup + active: committing to a swing has to be
	## a real risk, otherwise melee is strictly better than shooting at close
	## range and the bot never gets to punish a whiff.
	func interruptible() -> bool:
		return time >= Balance.MELEE_WINDUP + Balance.MELEE_ACTIVE


# ===========================================================================
# Roll - dodge with invulnerability frames.
# ===========================================================================


class Roll extends ActorState:
	func enter(_prev: StringName, _data: Dictionary) -> void:
		# Rolling follows the stick when there is one, and the aim when there is
		# not - so "roll backwards while still facing the enemy" works, which is
		# the whole point of having a dodge in an aim-driven game.
		var d: Vector2 = actor.move_input
		if d.length_squared() < 0.01:
			d = actor.aim_dir
		actor.roll_dir = d.normalized()
		actor.play_anim("roll", true)
		actor.i_frames = maxf(actor.i_frames, Balance.ROLL_IFRAMES)
		actor.roll_cd = Balance.ROLL_DURATION + Balance.ROLL_COOLDOWN
		EventBus.roll_started.emit(actor, actor.roll_dir)

	func physics(delta: float) -> void:
		if not actor.is_alive():
			machine.force(&"dead")
			return
		# a slight ease-out: constant speed for the whole roll feels like a slide
		var t: float = clampf(time / Balance.ROLL_DURATION, 0.0, 1.0)
		var speed: float = Balance.ROLL_SPEED * lerpf(1.0, 0.62, t)
		actor.velocity = actor.roll_dir * speed
		if time >= Balance.ROLL_DURATION:
			actor.velocity *= Balance.ROLL_END_SPEED_KEEP
			EventBus.roll_ended.emit(actor)
			machine.change(&"locomotion")

	func interruptible() -> bool:
		return time >= Balance.ROLL_IFRAMES


# ===========================================================================
# HookPull - being reeled toward a grapple anchor.
# ===========================================================================


class HookPull extends ActorState:
	func enter(_prev: StringName, _data: Dictionary) -> void:
		actor.play_anim("hook", true)

	func exit() -> void:
		actor.clear_hook()
		EventBus.hook_released.emit(actor)

	func physics(delta: float) -> void:
		if not actor.is_alive():
			machine.force(&"dead")
			return
		var anchor: Vector2 = actor.hook_anchor
		var to_anchor: Vector2 = anchor - actor.global_position
		var dist: float = to_anchor.length()

		# The spec asks for inertial acceleration rather than a snap-to-anchor, so
		# this accelerates every tick and keeps a fraction of the speed on exit -
		# that is what produces the slingshot feel and the ability to overshoot.
		var dir: Vector2 = to_anchor.normalized() if dist > 0.001 else actor.aim_dir
		actor.velocity = (actor.velocity + dir * Balance.HOOK_PULL_ACCEL * delta) \
			.limit_length(Balance.HOOK_PULL_MAX_SPEED)

		# let the player cut the line early with a roll
		if actor.want_roll and actor.roll_cd <= 0.0:
			if machine.change(&"roll"):
				actor.velocity *= Balance.HOOK_KEEP_MOMENTUM
				return

		if dist <= 13.0 or time >= Balance.HOOK_REEL_TIME:
			actor.hook_cd = Balance.HOOK_COOLDOWN
			actor.velocity *= Balance.HOOK_KEEP_MOMENTUM
			machine.change(&"locomotion")


# ===========================================================================
# Dead
# ===========================================================================


class Dead extends ActorState:
	func enter(_prev: StringName, _data: Dictionary) -> void:
		actor.velocity = Vector2.ZERO
		actor.on_death_visual()

	func exit() -> void:
		actor.on_revive_visual()

	func interruptible() -> bool:
		return false


# ===========================================================================
# registration helper
# ===========================================================================


## Build and register the standard state set. Keeping this here means the body
## never has to enumerate state classes, which is what would re-introduce the
## cyclic reference this layering exists to avoid.
static func install(machine: StateMachine) -> void:
	machine.register(&"locomotion", Locomotion.new())
	machine.register(&"melee", Melee.new())
	machine.register(&"roll", Roll.new())
	machine.register(&"hook_pull", HookPull.new())
	machine.register(&"dead", Dead.new())
	machine.change(&"locomotion")
