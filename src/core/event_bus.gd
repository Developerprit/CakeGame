extends Node
## Global signal hub (autoload `EventBus`).
##
## Rules of engagement, learned the hard way in earlier projects:
##  * A handler must NEVER re-emit the signal it is listening to. That builds an
##    infinite recursion and blows the stack with no useful error message.
##  * If UI needs derived data, have it read the controller's state directly
##    instead of inventing a new mirrored signal.
##  * Keep payloads typed; untyped Variant payloads hide bugs for months.

# --- lifecycle ---------------------------------------------------------------
signal match_started(mode: int)
signal phase_changed(phase: int)
signal round_finished(winner_team: int)
signal match_finished(winner_team: int)
signal score_changed(scores: Dictionary)

# --- actors ------------------------------------------------------------------
signal actor_spawned(actor: Node)
signal actor_removed(actor: Node)
signal actor_died(actor: Node, killer: Node, kind: int)
signal actor_respawned(actor: Node)
signal actor_damaged(actor: Node, amount: float, kind: int, source: Node)
signal health_changed(actor: Node, hp: float, max_hp: float)

# --- weapons -----------------------------------------------------------------
signal weapon_changed(actor: Node, weapon: int)
signal ammo_changed(actor: Node, mag: int, reserve: int)
signal reload_started(actor: Node, duration: float)
signal reload_finished(actor: Node)
signal cooldown_started(actor: Node, slot: String, duration: float)

# --- movement abilities ------------------------------------------------------
signal roll_started(actor: Node, dir: Vector2)
signal roll_ended(actor: Node)
signal hook_fired(actor: Node, aim_dir: Vector2)
signal hook_attached(actor: Node, victim: Node, anchor: Vector2)
signal hook_missed(actor: Node)
signal hook_released(actor: Node)

# --- feedback ----------------------------------------------------------------
signal hit_confirmed(attacker: Node, victim: Node, kind: int, amount: float, pos: Vector2)
signal damage_number(pos: Vector2, amount: float, kind: int)
signal kill_feed(attacker_name: String, victim_name: String, kind: int, team_attacker: int, team_victim: int)
signal screen_shake(amount: float, duration: float)
signal hitstop(duration: float)

# --- lobby / networking ------------------------------------------------------
signal lobby_changed()
signal net_status(text: String, quality: String)
signal net_error(text: String)
signal peer_joined(id: int, info: Dictionary)
signal peer_left(id: int)
signal chat_message(from_name: String, text: String)
signal room_code_ready(code: String)
signal direct_connect_ready(ip: String, port: int)

# --- settings ----------------------------------------------------------------
signal settings_changed()
signal theme_changed(dark: bool)
signal language_changed(code: String)


## Convenience wrapper so callers do not have to remember the 5-argument shape.
func emit_kill(attacker: Node, victim: Node, kind: int) -> void:
	var an := "?"
	var vt := "?"
	var ta := Enums.Team.HUMANS
	var tv := Enums.Team.BOTS
	if attacker != null and is_instance_valid(attacker) and attacker.has_method("display_name"):
		an = attacker.display_name()
	if victim != null and is_instance_valid(victim) and victim.has_method("display_name"):
		vt = victim.display_name()
	if attacker != null and is_instance_valid(attacker) and "team" in attacker:
		ta = attacker.team
	if victim != null and is_instance_valid(victim) and "team" in victim:
		tv = victim.team
	actor_died.emit(victim, attacker, kind)
	kill_feed.emit(an, vt, kind, ta, tv)
