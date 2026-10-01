class_name MatchDirector
extends Node
## Owns one match: the roster, the arena, the round loop and the scoreboard.
##
## This was the missing piece. `EventBus.match_started`, `phase_changed`,
## `score_changed`, `round_finished` and `match_finished` were all declared and
## nothing in the project ever emitted them, so "CakeGame" was five actors
## standing in a tiled arena with no idea a game was happening.
##
## Two round formats, selected by `GameConfig.respawn_enabled`:
##
##  * **Elimination** (default, respawn off) - wipe the other team, win the round,
##    first to `GameConfig.round_target_score` rounds takes the match. One clean
##    beat, and the reason a countdown exists at all.
##  * **Deathmatch** (respawn on) - a downed fighter is back in `respawn_delay`
##    seconds, so a wipe is impossible and elimination rounds could never end.
##    Kills score directly instead, and the target becomes
##    `round_target_score * enemy team size` - "win by as many kills as it would
##    take to wipe them five times". Derived from the same knob rather than
##    introducing a second magic number that would drift out of step with it.
##
## Authority: only the authority (offline, or the listen server) runs the round
## clock and decides who won. The net pass will ship `phase` and `scores` over the
## wire and clients will skip all of this; `authority` is the switch that already
## exists so that pass does not have to restructure anything.

const GROUP: StringName = &"match_director"

## Ring tints. Same hue per team, three lightness tiers within a team, because
## the ring's job is "which one of us is me" and team colour alone cannot answer
## that. The team itself is already carried by the sprite and the actor light.
const HUMAN_TINTS: Array[Color] = [
	Color("5ee4ff"), Color("b6f3ff"), Color("2f8fa8"),
]
const BOT_TINTS: Array[Color] = [
	Color("ff7a52"), Color("ffc09a"), Color("c04a2a"),
]

signal phase_became(phase: int)

# --- wiring -----------------------------------------------------------------
var arena: Arena = null
var actors_layer: Node2D = null
var projectiles_layer: Node2D = null

# --- match state ------------------------------------------------------------
var authority: bool = true
var phase: int = Enums.MatchPhase.LOBBY
var actors: Array[ActorBody] = []
var local_actor: ActorBody = null
var scores: Dictionary = {}
var round_index: int = 0
var timer: float = 0.0
var target: int = Balance.SCORE_TO_WIN
var map_seed: int = 0
var match_winner: int = -1

## Seconds remaining before each downed fighter is back, in deathmatch. Keyed by
## the actor so a second death cannot enqueue the same body twice.
var _respawn_queue: Dictionary = {}
## Set by `_on_actor_died` and consumed in `_process`. `die()` runs in the middle
## of `Combat.apply_damage`'s victim list, so ending the round from inside the
## signal would free bodies the caller is still walking over.
var _round_dirty: bool = false
var _last_countdown_tick: int = -1
var _roster: Array[Dictionary] = []


func _enter_tree() -> void:
	add_to_group(GROUP)


func _exit_tree() -> void:
	# Signals hold references to this node; a freed director that is still wired
	# to the bus turns every later kill into "Attempt to call function on a
	# previously freed instance" and the real error is buried under the noise.
	if EventBus.actor_died.is_connected(_on_actor_died):
		EventBus.actor_died.disconnect(_on_actor_died)


# ===========================================================================
# setup
# ===========================================================================

func configure(p_arena: Arena, p_actors: Node2D, p_projectiles: Node2D,
		p_authority: bool = true) -> void:
	arena = p_arena
	actors_layer = p_actors
	projectiles_layer = p_projectiles
	authority = p_authority
	if not EventBus.actor_died.is_connected(_on_actor_died):
		EventBus.actor_died.connect(_on_actor_died)


## Build the roster, generate the arena, spawn everyone, start the countdown.
## Safe to call again: it tears the previous match down first.
func start(rematch: bool = false) -> void:
	if arena == null or actors_layer == null:
		push_error("[MatchDirector] start() before configure()")
		return
	_roster = _build_roster()
	map_seed = GameConfig.reroll_seed() if rematch else GameConfig.effective_seed()
	target = _compute_target()

	scores = {Enums.Team.HUMANS: 0, Enums.Team.BOTS: 0}
	round_index = 0
	match_winner = -1
	_respawn_queue.clear()
	_round_dirty = false

	arena.build(MapGenerator.generate(map_seed))
	_spawn_actors()

	_begin_countdown()
	EventBus.score_changed.emit(scores)
	EventBus.match_started.emit(NetManager.mode)
	if not GameConfig.is_headless():
		AudioDirector.play_music("music_battle")


## The score a team needs. See the class comment for why deathmatch multiplies.
func _compute_target() -> int:
	if not GameConfig.respawn_enabled:
		return maxi(1, GameConfig.round_target_score)
	var enemy := 0
	for r in _roster:
		if int(r["team"]) == Enums.Team.BOTS:
			enemy += 1
	return maxi(1, GameConfig.round_target_score * maxi(1, enemy))


func team_size(team: int) -> int:
	var n := 0
	for r in _roster:
		if int(r["team"]) == team:
			n += 1
	return n


# ===========================================================================
# roster
# ===========================================================================

## Who is in the match.
##
## Offline the answer is "one human on this machine, plus the configured bots".
## It is NOT `GameConfig.human_slots`, and that is deliberate: the InputMap binds
## WASD and one set of gamepad buttons globally, with no per-device split, so a
## second local human would share player one's keys and both would move as one
## body. Additional humans therefore arrive over the network, which is what
## `human_slots` actually describes.
##
## Bot team is floored at one whenever a human is present, otherwise the match has
## no enemy and can never finish.
func _build_roster() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var humans: Array[Dictionary] = []

	if NetManager.is_offline() or NetManager.slots().is_empty():
		humans.append({
			"team": Enums.Team.HUMANS,
			"kind": Enums.Kind.LOCAL_HUMAN,
			"name": GameConfig.player_name,
			"local": true,
			"peer_id": 1,
		})
	else:
		# Listen server: one actor per occupied human slot. Empty slots become
		# bots below, so a two-player session can still start.
		var ids: Array = NetManager.slots().keys()
		ids.sort()
		for id in ids:
			var slot: Dictionary = NetManager.slots()[id]
			if int(slot.get("team", Enums.Team.HUMANS)) != Enums.Team.HUMANS:
				continue
			humans.append({
				"team": Enums.Team.HUMANS,
				"kind": Enums.Kind.LOCAL_HUMAN if int(id) == NetManager.local_peer_id
					else Enums.Kind.REMOTE_HUMAN,
				"name": str(slot.get("name", "Player %d" % id)),
				"local": int(id) == NetManager.local_peer_id,
				"peer_id": int(id),
			})
		if humans.is_empty():
			humans.append({
				"team": Enums.Team.HUMANS,
				"kind": Enums.Kind.LOCAL_HUMAN,
				"name": GameConfig.player_name,
				"local": true,
				"peer_id": NetManager.local_peer_id,
			})

	var bots := maxi(GameConfig.bot_slots, 1 if not humans.is_empty() else 0)
	# A networked host must keep the total at or under the configured ceiling.
	if not NetManager.is_offline():
		bots = mini(bots, maxi(0, GameConfig.max_players - humans.size()))

	for i in humans.size():
		var h: Dictionary = humans[i]
		h["slot"] = i
		h["bot"] = ""
		out.append(h)
	for i in bots:
		out.append({
			"team": Enums.Team.BOTS,
			"kind": Enums.Kind.BOT,
			"name": "Bot %d" % (i + 1),
			"local": false,
			"peer_id": 0,
			"slot": i,
			"bot": GameConfig.bot_version,
		})
	return out


# ===========================================================================
# spawning
# ===========================================================================

func _spawn_actors() -> void:
	_clear_actors()
	var id := 1
	var human_slot := 0
	var bot_slot := 0
	var local_ordinal := 0
	for r in _roster:
		var team := int(r["team"])
		var kind := int(r["kind"])
		var slot := human_slot
		if team == Enums.Team.BOTS:
			slot = bot_slot
			bot_slot += 1
		else:
			human_slot += 1

		var body: ActorBody = null
		if team == Enums.Team.BOTS:
			body = BotActor.new()
		else:
			body = PlayerActor.new()

		var tints := BOT_TINTS if team == Enums.Team.BOTS else HUMAN_TINTS
		body.configure({
			"id": id,
			"team": team,
			"kind": kind,
			"name": str(r["name"]),
			"local": bool(r["local"]),
			"authoritative": authority,
			"color": tints[slot % tints.size()],
		})
		# Only the FIRST local human can own the pointer. A second one on the same
		# machine would be aiming the same cursor, so they fall back to the pad.
		# The ordinal is counted in this loop rather than searched for in the
		# roster: `Dictionary ==` compares by contents in Godot 4, so an
		# identity search would silently match the wrong entry.
		if body is PlayerActor:
			(body as PlayerActor).use_mouse_aim = bool(r["local"]) and local_ordinal == 0
			if bool(r["local"]):
				local_ordinal += 1
		body.position = arena.spawn_point(team, slot)
		actors_layer.add_child(body)
		if body is BotActor:
			(body as BotActor).setup_brain(str(r["bot"]))
		if bool(r["local"]):
			local_actor = body
		actors.append(body)
		id += 1

	_freeze_actors(true)


func _clear_actors() -> void:
	_respawn_queue.clear()
	for a in actors:
		if not is_instance_valid(a):
			continue
		# Detach before queueing the free. A rematch spawns the new fighters in
		# this same call, and an actor that is merely queued for deletion is
		# still in the `actor` group and still hittable - so the opening shots of
		# round one would land on last match's corpses.
		var parent := a.get_parent()
		if parent != null:
			parent.remove_child(a)
		a.queue_free()
	actors.clear()
	local_actor = null
	if projectiles_layer != null:
		for c in projectiles_layer.get_children():
			c.queue_free()


## Countdown freeze. Disabling the actors' processing is the cheapest correct way
## to hold everyone still: no flag has to be threaded through the state machine,
## aim integration and the AI, and nothing can drift while it waits.
func _freeze_actors(frozen: bool) -> void:
	for a in actors:
		if not is_instance_valid(a):
			continue
		a.set_physics_process(not frozen)
		a.set_process(not frozen)
		a.velocity = Vector2.ZERO


# ===========================================================================
# round loop
# ===========================================================================

func _begin_countdown() -> void:
	_set_phase(Enums.MatchPhase.COUNTDOWN)
	timer = Balance.COUNTDOWN_TIME
	_last_countdown_tick = -1
	_freeze_actors(true)


func _go_live() -> void:
	_set_phase(Enums.MatchPhase.LIVE)
	_freeze_actors(false)
	for a in actors:
		if is_instance_valid(a):
			a.spawn_invuln = Balance.SPAWN_INVULN


## Rewind everyone to their pads and clear the battlefield. Used between rounds
## of an elimination match, where the map itself stays put - swapping the arena
## every round would make the first ten seconds of each round a fresh scouting
## trip instead of a fight.
func _reset_round() -> void:
	_respawn_queue.clear()
	_round_dirty = false
	if projectiles_layer != null:
		for c in projectiles_layer.get_children():
			c.queue_free()
	var human_slot := 0
	var bot_slot := 0
	for a in actors:
		if not is_instance_valid(a):
			continue
		var slot := human_slot
		if a.team == Enums.Team.BOTS:
			slot = bot_slot
			bot_slot += 1
		else:
			human_slot += 1
		a.clear_hook()
		a.active_hook = null
		a.respawn(arena.spawn_point(a.team, slot))
	_freeze_actors(true)


func _end_round(winner: int) -> void:
	_award(winner, 1)
	round_index += 1
	_set_phase(Enums.MatchPhase.ROUND_OVER)
	timer = Balance.ROUND_OVER_TIME
	_freeze_actors(true)
	EventBus.round_finished.emit(winner)
	if scores.get(winner, 0) >= target:
		match_winner = winner


func _award(team: int, amount: int) -> void:
	scores[team] = int(scores.get(team, 0)) + amount
	EventBus.score_changed.emit(scores)


func _finish_match(winner: int) -> void:
	_set_phase(Enums.MatchPhase.MATCH_OVER)
	_freeze_actors(true)
	EventBus.match_finished.emit(winner)
	if not GameConfig.is_headless():
		AudioDirector.play_music("music_victory")


func _set_phase(next: int) -> void:
	if phase == next:
		return
	phase = next
	EventBus.phase_changed.emit(next)
	phase_became.emit(next)


func _process(delta: float) -> void:
	if not authority:
		return

	match phase:
		Enums.MatchPhase.COUNTDOWN:
			timer -= delta
			var left := ceili(maxf(0.0, timer))
			if left != _last_countdown_tick:
				_last_countdown_tick = left
				if left > 0 and not GameConfig.is_headless():
					AudioDirector.play("countdown", -6.0)
			if timer <= 0.0:
				_go_live()
		Enums.MatchPhase.LIVE:
			_tick_respawns(delta)
			# Guarded on the mode as well as the flag: `respawn_enabled` can be
			# toggled from the pause menu mid-match, and an elimination resolve
			# running inside a deathmatch would award a second point for the same
			# kill and end the match one kill early.
			if _round_dirty and not GameConfig.respawn_enabled:
				_round_dirty = false
				_resolve_round()
		Enums.MatchPhase.ROUND_OVER:
			timer -= delta
			if timer <= 0.0:
				if match_winner >= 0:
					_finish_match(match_winner)
				else:
					_reset_round()
					_begin_countdown()


func _tick_respawns(delta: float) -> void:
	if _respawn_queue.is_empty():
		return
	for key in _respawn_queue.keys():
		if not is_instance_valid(key):
			_respawn_queue.erase(key)
			continue
		var body: ActorBody = key
		_respawn_queue[key] = float(_respawn_queue[key]) - delta
		if float(_respawn_queue[key]) <= 0.0:
			_respawn_queue.erase(key)
			body.respawn(_respawn_slot_pos(body))


func _respawn_slot_pos(body: ActorBody) -> Vector2:
	var slot := 0
	for a in actors:
		if a == body:
			break
		if a.team == body.team:
			slot += 1
	return arena.spawn_point(body.team, slot)


# ===========================================================================
# death
# ===========================================================================

func _on_actor_died(victim: Node, killer: Node, _kind: int) -> void:
	if not authority:
		return
	var body := victim as ActorBody
	if body == null or not actors.has(body):
		return

	if GameConfig.respawn_enabled:
		_respawn_queue[body] = maxf(0.1, GameConfig.respawn_delay)
		var scorer := _team_of(killer)
		if scorer != body.team:
			_award(scorer, 1)
			if int(scores.get(scorer, 0)) >= target:
				match_winner = scorer
				# The closing beat. Going straight to MATCH_OVER would cut the
				# final kill's hitstop and death animation off mid-frame, which
				# reads as a crash rather than as a win.
				_set_phase(Enums.MatchPhase.ROUND_OVER)
				timer = Balance.ROUND_OVER_TIME
				_freeze_actors(true)
		return

	_round_dirty = true


func _team_of(n: Node) -> int:
	if n == null or not is_instance_valid(n) or not ("team" in n):
		return -1
	return int(n.team)


## Called once per frame at most, and only from `_process`, never from the death
## signal. Elimination rounds are won by whoever still has somebody standing.
func _resolve_round() -> void:
	var humans := alive_count(Enums.Team.HUMANS)
	var bots := alive_count(Enums.Team.BOTS)
	if humans > 0 and bots > 0:
		return
	if humans == 0 and bots == 0:
		# Mutual destruction on the same frame. Nobody scores; replay the round.
		_reset_round()
		_begin_countdown()
		return
	_end_round(Enums.Team.HUMANS if humans > 0 else Enums.Team.BOTS)


func alive_count(team: int) -> int:
	var n := 0
	for a in actors:
		if is_instance_valid(a) and a.team == team and a.alive:
			n += 1
	return n


func actors_of(team: int) -> Array[ActorBody]:
	var out: Array[ActorBody] = []
	for a in actors:
		if is_instance_valid(a) and a.team == team:
			out.append(a)
	return out


# ===========================================================================
# pause
# ===========================================================================

## Re-apply "should everyone be holding still" after an unpause.
##
## Pausing itself uses `get_tree().paused`, which is the one mechanism that
## reliably halts characters, bullets, hooks, FX and the round clock at once.
## This is the other half of that: the tree pause is lifted, but during a
## countdown the actors have to remain frozen without the tree being paused.
func refresh_freeze() -> void:
	_freeze_actors(phase != Enums.MatchPhase.LIVE)


# ===========================================================================
# queries for the HUD
# ===========================================================================

func phase_label() -> String:
	match phase:
		Enums.MatchPhase.LOBBY:
			return "LOBBY"
		Enums.MatchPhase.COUNTDOWN:
			return "GET READY"
		Enums.MatchPhase.LIVE:
			return "LIVE"
		Enums.MatchPhase.ROUND_OVER:
			return "ROUND OVER"
		Enums.MatchPhase.MATCH_OVER:
			return "MATCH OVER"
	return "?"


func countdown_left() -> int:
	return ceili(maxf(0.0, timer)) if phase == Enums.MatchPhase.COUNTDOWN else 0


func respawn_left(body: ActorBody) -> float:
	return float(_respawn_queue.get(body, 0.0))


func score_of(team: int) -> int:
	return int(scores.get(team, 0))


func describe() -> String:
	return "%s  %d-%d  (target %d, seed %d, %d actors)" % [
		phase_label(), score_of(Enums.Team.HUMANS), score_of(Enums.Team.BOTS),
		target, map_seed, actors.size(),
	]
