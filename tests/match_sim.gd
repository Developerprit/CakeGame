extends TestHarness
## End-to-end match simulation. This is the "does a game actually happen" gate.
##
##     godot --headless --path . --fixed-fps 60 res://tests/match_sim.tscn
##
## Exit code 0 = all green, 1 = at least one failure.
##
## `selfcheck.gd` proves the parts work in isolation: the map generator, the tile
## set, the camera maths, the nav grid. None of that proves a match runs. This
## boots the real `scenes/game.tscn`, spawns the real roster, and lets the real
## bot brains play against a player who never touches the keyboard - which is the
## strongest end-to-end assertion available without a human, because "the bots
## found the human, closed the distance through the nav grid, shot it and won the
## round" exercises pathing, aim leading, weapon state, damage, death, round
## resolution and respawn in one go.
##
## `--fixed-fps 60` is required. Without it the engine free-runs and each awaited
## frame advances an unpredictable amount of game time, so a 60-second budget
## becomes untestable.
##
## These checks write `GameConfig` fields DIRECTLY and never call
## `save_settings()`. That is deliberate: the config file is real user state, and
## a test suite that persists its own fixture over somebody's settings is a bug
## report waiting to happen.

const FPS: int = 60

# --- event counters ---------------------------------------------------------
# Instance fields rather than locals, because a GDScript lambda captures by value
# and cannot increment a captured local.
var _damage_events: int = 0
var _humans_hurt: int = 0
var _bots_hurt: int = 0
var _gun_fires: int = 0
var _hits_confirmed: int = 0
var _match_finished_calls: int = 0


func _ready() -> void:
	print("CakeGame match simulation")
	print("godot %s  |  %s" % [
		Engine.get_version_info().get("string", "?"), DisplayServer.get_name()])
	print("frame budget: %d frames = %.0fs at %d fps" % [
		_combat_frames(), _combat_frames() / float(FPS), FPS])
	print("-------------------")

	await run_async("seed configuration", _check_seed_config)
	await run_async("scene assembly", _check_assembly)
	await run_async("player weapon", _check_player_weapon)
	await run_async("elimination round", _check_elimination_round)
	await run_async("live combat", _check_live_combat)
	await run_async("deathmatch", _check_deathmatch)
	await run_async("rematch", _check_rematch)
	get_tree().quit(report("MATCH-SIM"))


# ===========================================================================
# helpers
# ===========================================================================

func _combat_frames() -> int:
	return frames_for(60.0, FPS)


## Every check starts from the same fixture, so a failure is reproducible and a
## check cannot be silently influenced by whatever the previous one left behind.
func _configure(respawn: bool, bots: int, target: int = 5,
		seed_text: String = "cakegame") -> void:
	GameConfig.seeded_map = true
	GameConfig.map_seed_text = seed_text
	GameConfig.respawn_enabled = respawn
	GameConfig.respawn_delay = 1.0
	GameConfig.bot_slots = bots
	GameConfig.human_slots = 3
	GameConfig.max_players = 8
	GameConfig.round_target_score = target
	GameConfig.friendly_fire = false
	GameConfig.player_name = "TestPilot"
	GameConfig.bot_version = BotRegistry.DEFAULT_ID
	NetManager.set_offline()


func _boot_game() -> Node:
	var packed: PackedScene = load("res://scenes/game.tscn")
	if packed == null:
		ok(false, "res://scenes/game.tscn failed to load")
		return null
	var game: Node = packed.instantiate()
	add_child(game)
	# `_ready()` of the root builds the whole tree and starts the match; one
	# physics frame and one idle frame is enough for everything to be in place.
	await get_tree().physics_frame
	await get_tree().process_frame
	return game


func _teardown(game: Node) -> void:
	if game != null and is_instance_valid(game):
		game.queue_free()
	await get_tree().process_frame


## Advance `seconds` of game time. `--fixed-fps 60` makes one physics frame
## exactly 1/60 s, and each main-loop iteration runs the idle frame too, so the
## director's `_process` clock and the actors' `_physics_process` stay in step.
func _advance(seconds: float) -> void:
	for _i in frames_for(seconds, FPS):
		await get_tree().physics_frame


func _reset_counters() -> void:
	_damage_events = 0
	_humans_hurt = 0
	_bots_hurt = 0
	_gun_fires = 0
	_hits_confirmed = 0
	_match_finished_calls = 0


func _wire_events() -> void:
	if not EventBus.actor_damaged.is_connected(_on_actor_damaged):
		EventBus.actor_damaged.connect(_on_actor_damaged)
	if not EventBus.cooldown_started.is_connected(_on_cooldown_started):
		EventBus.cooldown_started.connect(_on_cooldown_started)
	if not EventBus.hit_confirmed.is_connected(_on_hit_confirmed):
		EventBus.hit_confirmed.connect(_on_hit_confirmed)
	if not EventBus.match_finished.is_connected(_on_match_finished):
		EventBus.match_finished.connect(_on_match_finished)


func _on_actor_damaged(actor: Node, _amount: float, _kind: int, _source: Node) -> void:
	_damage_events += 1
	var body := actor as ActorBody
	if body == null:
		return
	if body.team == Enums.Team.HUMANS:
		_humans_hurt += 1
	else:
		_bots_hurt += 1


func _on_cooldown_started(_actor: Node, slot: String, _duration: float) -> void:
	if slot == "gun":
		_gun_fires += 1


func _on_hit_confirmed(_a: Node, _v: Node, _kind: int, _amount: float,
		_pos: Vector2) -> void:
	_hits_confirmed += 1


func _on_match_finished(_winner: int) -> void:
	_match_finished_calls += 1


func _bullets_in_play(game: Node) -> int:
	var layer := game.get("projectiles_layer") as Node
	if layer == null:
		return -1
	var n := 0
	for c in layer.get_children():
		if c is Bullet:
			n += 1
	return n


# ===========================================================================
# checks
# ===========================================================================

## The seed box used to be a silent trap: `Utils.resolve_seed("")` returns 0, and
## 0 is exactly the sentinel `MapGenerator.generate()` reads as "use the built-in
## arena". So ticking "seeded map" and leaving the box empty handed back the
## hand-made arena instead of a random one.
func _check_seed_config() -> void:
	GameConfig.seeded_map = false
	ok(GameConfig.effective_seed() == 0,
		"seeded map off returns 0, which the generator reads as the built-in arena")

	GameConfig.seeded_map = true
	GameConfig.map_seed_text = ""
	var invented := GameConfig.effective_seed()
	ok(invented != 0, "an empty seed box invents a seed instead of falling back to 0")
	ok(invented > 100000, "the invented seed is spread out, not a small integer")
	ok(GameConfig.effective_seed() == invented,
		"the invented seed is latched, so a match keeps one map")
	GameConfig.map_seed_text = "cakegame"
	ok(GameConfig.effective_seed() == Utils.seed_from_string("cakegame"),
		"editing the seed box invalidates the latch and the typed seed is used")
	GameConfig.map_seed_text = "12345"
	ok(GameConfig.effective_seed() == 12345, "a numeric seed is parsed as a number")

	# `reroll_seed()` re-derives from the CURRENT text, so with something typed it
	# returns the same number - and that is the point. A player who typed a seed
	# wants that arena again on a rematch. Only an empty box means "surprise me".
	ok(GameConfig.reroll_seed() == 12345,
		"reroll keeps an explicitly typed seed, so a rematch of that arena is the same arena")
	GameConfig.map_seed_text = ""
	var first := GameConfig.effective_seed()
	var second := GameConfig.reroll_seed()
	ok(first != second, "reroll invents a different seed when the box is empty")
	info("invented=%d  rerolled(empty box)=%d" % [invented, second])


func _check_assembly() -> void:
	_configure(false, 2)
	_reset_counters()
	_wire_events()
	var game := await _boot_game()
	if game == null:
		return

	var arena := game.get("arena") as Arena
	var d := game.get("director") as MatchDirector
	var hud := game.get("hud") as GameHUD
	var rig := game.get("rig") as CameraRig
	var projectiles := game.get("projectiles_layer") as Node

	ok(d != null, "the scene assembled a MatchDirector")
	ok(arena != null, "the scene assembled an Arena")
	ok(hud != null, "the scene assembled a HUD")
	ok(rig != null, "the scene assembled a CameraRig")
	ok(projectiles != null and projectiles.is_in_group(&"projectile_layer"),
		"bullets and hooks have a 'projectile_layer' group to land in")
	ok(projectiles != null and projectiles.get_child_count() == 0,
		"the projectile layer starts empty")
	if d == null or arena == null:
		await _teardown(game)
		return

	# --- roster ---------------------------------------------------------------
	ok(d.actors.size() == 3, "roster is 1 human + 2 bots (got %d)" % d.actors.size())
	ok(d.team_size(Enums.Team.HUMANS) == 1,
		"offline is one local human even though human_slots is 3")
	ok(d.team_size(Enums.Team.BOTS) == 2, "two bots on the other team")
	ok(d.local_actor != null, "the local player is identified")
	ok(d.local_actor is PlayerActor, "the local player is a PlayerActor")
	ok(d.local_actor.display_name == "TestPilot", "the local player uses the configured name")
	var bots := d.actors_of(Enums.Team.BOTS)
	var brainless := 0
	for b in bots:
		if (b as BotActor).brain == null:
			brainless += 1
	ok(brainless == 0, "every bot got a brain from the registry (%d missing)" % brainless)
	ok(d.actors_of(Enums.Team.HUMANS)[0].player_color
		!= d.actors_of(Enums.Team.BOTS)[0].player_color,
		"the two teams get different ring colours")

	# --- arena ----------------------------------------------------------------
	ok(arena.has_nav(), "the arena published a navigation grid")
	ok(arena.open_cell_count() > 400, "the seeded arena has floor to fight on")
	ok(arena.map_seed == Utils.seed_from_string("cakegame"),
		"the arena used the configured seed (got %d)" % arena.map_seed)

	# --- spawn placement ------------------------------------------------------
	var inside := 0
	for a in d.actors:
		if not arena.world_rect().has_point(a.global_position):
			inside += 1
	ok(inside == 0, "every actor spawned inside the arena (%d outside)" % inside)
	# Teams must not spawn on top of each other, or round one is a coin flip.
	var closest := 1e9
	for h in d.actors_of(Enums.Team.HUMANS):
		for b in d.actors_of(Enums.Team.BOTS):
			closest = minf(closest, h.global_position.distance_to(b.global_position))
	ok(closest > 64.0, "the teams spawn apart (closest pair %.0f px)" % closest)

	# --- match opens on a countdown ------------------------------------------
	ok(d.phase == Enums.MatchPhase.COUNTDOWN,
		"the match opens on COUNTDOWN (got %s)" % d.phase_label())
	ok(d.countdown_left() > 0, "the countdown reports time left")
	ok(d.target == GameConfig.round_target_score,
		"elimination mode uses the raw score target")
	ok(d.score_of(Enums.Team.HUMANS) == 0 and d.score_of(Enums.Team.BOTS) == 0,
		"the scoreboard starts at zero")
	# Frozen during the countdown: the actors must not be able to act before the
	# round starts, and `_freeze_actors` is what enforces that.
	var moving := 0
	for a in d.actors:
		if a.is_physics_processing():
			moving += 1
	ok(moving == 0, "every actor is frozen during the countdown (%d still ticking)" % moving)

	var start_pos: Dictionary = {}
	for a in d.actors:
		start_pos[a] = a.global_position
	await _advance(Balance.COUNTDOWN_TIME - 0.5)
	moving = 0
	for a in d.actors:
		if a.global_position.distance_to(start_pos[a]) > 1.0:
			moving += 1
	ok(moving == 0, "nobody drifts during the countdown (%d moved)" % moving)

	await _advance(0.8)
	ok(d.phase == Enums.MatchPhase.LIVE,
		"the countdown ends and the round goes live (got %s)" % d.phase_label())
	moving = 0
	for a in d.actors:
		if a.is_physics_processing():
			moving += 1
	ok(moving == d.actors.size(), "every actor is released when the round goes live")
	info("assembly: %s" % d.describe())

	await _teardown(game)


## The player's own weapon path, checked in the safest window there is: right
## after the round goes live, at full health, with 1.2 s of spawn invulnerability
## and the bots still most of the arena away. Doing it later would be a race
## against a bot that is allowed to shoot back.
func _check_player_weapon() -> void:
	_configure(false, 2)
	var game := await _boot_game()
	if game == null:
		return
	var d := game.get("director") as MatchDirector
	if d == null:
		await _teardown(game)
		return
	await _advance(Balance.COUNTDOWN_TIME + 0.2)
	ok(d.phase == Enums.MatchPhase.LIVE, "round is live for the weapon check")

	var human := d.local_actor
	ok(human != null and human.alive, "the local player is alive")

	ok(human.weapon == Enums.Weapon.MELEE, "the player starts on melee")
	human.toggle_gun()
	ok(human.weapon == Enums.Weapon.GUN, "E draws the gun")
	ok(not human.gun_ready(), "the gun is not ready during the draw animation")
	await _advance(Balance.GUN_DRAW_TIME + 0.1)
	ok(human.gun_ready(), "the gun is ready once the draw finishes")

	var before := human.mag
	ok(human.fire_bullet(), "fire_bullet() succeeds")
	ok(human.mag == before - 1, "a shot costs exactly one round (%d -> %d)" % [
		before, human.mag])
	var live := _bullets_in_play(game)
	ok(live == 1, "one bullet exists in the projectile layer (found %d)" % live)
	ok(human.gun_cd > 0.0, "firing starts the gun cooldown")

	human.toggle_gun()
	ok(human.weapon == Enums.Weapon.MELEE, "E holsters the gun again")
	info("player weapon: fired, mag %d -> %d, bullet spawned, cooldown %.2fs" % [
		before, human.mag, human.gun_cd])

	await _teardown(game)


func _check_elimination_round() -> void:
	_configure(false, 2)
	_reset_counters()
	_wire_events()
	var game := await _boot_game()
	if game == null:
		return
	var d := game.get("director") as MatchDirector
	if d == null:
		await _teardown(game)
		return

	await _advance(Balance.COUNTDOWN_TIME + 0.2)
	ok(d.phase == Enums.MatchPhase.LIVE, "round one is live")

	var human := d.local_actor
	var bots := d.actors_of(Enums.Team.BOTS)
	# A real killer, not `null`: `die()` only routes through `emit_kill` when the
	# killer is valid, and the director scores off that signal. Passing null here
	# would test nothing.
	for b in bots:
		b.die(human, Enums.DamageKind.MELEE)
	ok(d.alive_count(Enums.Team.BOTS) == 0, "the bot team is wiped")

	await _advance(0.2)
	ok(d.score_of(Enums.Team.HUMANS) == 1,
		"wiping the bots scores the round (score %d)" % d.score_of(Enums.Team.HUMANS))
	ok(d.phase == Enums.MatchPhase.ROUND_OVER,
		"the round ends (phase %s)" % d.phase_label())
	ok(_match_finished_calls == 0, "the match is not over after one round")

	await _advance(Balance.ROUND_OVER_TIME + 0.5)
	ok(d.phase == Enums.MatchPhase.COUNTDOWN,
		"round two opens on a countdown (phase %s)" % d.phase_label())
	ok(d.alive_count(Enums.Team.BOTS) == 2,
		"both bots came back for round two (%d alive)" % d.alive_count(Enums.Team.BOTS))
	ok(d.alive_count(Enums.Team.HUMANS) == 1, "the human came back for round two")
	ok(d.score_of(Enums.Team.HUMANS) == 1, "the score carries across rounds")
	var hp_ok := 0
	for a in d.actors:
		if a.alive and is_equal_approx(a.hp, a.max_hp):
			hp_ok += 1
	ok(hp_ok == d.actors.size(), "respawn restores full health (%d of %d)" % [
		hp_ok, d.actors.size()])
	ok(d.actors.size() == 3, "no actors leaked across the round boundary")

	info("elimination: %s" % d.describe())
	await _teardown(game)


func _check_live_combat() -> void:
	_configure(false, 2)
	_reset_counters()
	_wire_events()
	var game := await _boot_game()
	if game == null:
		return
	var d := game.get("director") as MatchDirector
	var arena := game.get("arena") as Arena
	if d == null or arena == null:
		await _teardown(game)
		return

	var bots := d.actors_of(Enums.Team.BOTS)
	var travelled: Dictionary = {}
	var last: Dictionary = {}
	for b in bots:
		travelled[b] = 0.0
		last[b] = b.global_position

	await _advance(Balance.COUNTDOWN_TIME + 0.2)
	var frames := _combat_frames()
	var sample := 4
	for i in frames:
		await get_tree().physics_frame
		if i % sample != 0:
			continue
		# Accumulate distance travelled rather than comparing first and last
		# positions: a bot that wins a round and respawns on its pad can be back
		# where it started, and a naive displacement check would call that "never
		# moved" for the exact bot that played best.
		for b in bots:
			if not is_instance_valid(b):
				continue
			var now: Vector2 = b.global_position
			travelled[b] = float(travelled[b]) + now.distance_to(last[b])
			last[b] = now

	var least := 1e9
	for b in bots:
		if is_instance_valid(b):
			least = minf(least, float(travelled[b]))
	ok(bots.size() == 2, "both bots are still valid objects after 60 s")
	ok(least > 400.0, "the bots actually navigated the arena (least travelled %.0f px)" % least)
	ok(_gun_fires > 0, "a bot drew its gun and fired (%d shots)" % _gun_fires)
	ok(_damage_events > 0, "damage was dealt (%d events)" % _damage_events)
	ok(_humans_hurt > 0,
		"the bots found and hit the stationary human (%d hits on humans)" % _humans_hurt)
	ok(_hits_confirmed > 0, "hit feedback fired (%d confirms)" % _hits_confirmed)

	# The strong one: two bots versus a player who never presses a key must
	# actually win a round. This is the whole premise of the product - "算法极强"
	# - and it is the assertion that fails loudly if pathing, aim leading,
	# engagement range or weapon state quietly break.
	ok(d.score_of(Enums.Team.BOTS) > 0,
		"the bots won at least one round against an idle player (bots %d, humans %d)" % [
			d.score_of(Enums.Team.BOTS), d.score_of(Enums.Team.HUMANS)])
	# The player never fires in this fixture, so damage landing on a bot would mean
	# one bot hit another - i.e. friendly fire is leaking between team-mates.
	ok(_bots_hurt == 0,
		"no bot damaged a team-mate while the player was idle (%d events)" % _bots_hurt)
	ok(d.phase != Enums.MatchPhase.LOBBY, "the match is still in progress (%s)" % d.phase_label())
	info("combat over %ds: travelled>=%.0f px each, %d gun shots, %d damage events, score %d-%d" % [
		frames / FPS, least, _gun_fires, _damage_events,
		d.score_of(Enums.Team.HUMANS), d.score_of(Enums.Team.BOTS)])

	await _teardown(game)


func _check_deathmatch() -> void:
	# Target must be computed as score_to_win x enemy team size, so keep both small
	# and check the arithmetic: 2 x 1 bot = 2.
	_configure(true, 1, 2)
	_reset_counters()
	_wire_events()
	var game := await _boot_game()
	if game == null:
		return
	var d := game.get("director") as MatchDirector
	if d == null:
		await _teardown(game)
		return

	ok(d.target == 2, "deathmatch target is score x enemy team size (got %d)" % d.target)
	ok(d.team_size(Enums.Team.BOTS) == 1, "one bot in this fixture")

	await _advance(Balance.COUNTDOWN_TIME + 0.2)
	ok(d.phase == Enums.MatchPhase.LIVE, "deathmatch goes live")

	var human := d.local_actor
	var bot := d.actors_of(Enums.Team.BOTS)[0]
	bot.die(human, Enums.DamageKind.BULLET)
	await _advance(0.2)
	ok(d.score_of(Enums.Team.HUMANS) == 1,
		"the kill scores directly (score %d)" % d.score_of(Enums.Team.HUMANS))
	ok(d.phase == Enums.MatchPhase.LIVE,
		"deathmatch has no round break (phase %s)" % d.phase_label())
	ok(not bot.alive, "the bot is down")

	await _advance(GameConfig.respawn_delay + 0.6)
	ok(bot.alive, "the bot came back after the respawn delay")
	ok(is_equal_approx(bot.hp, bot.max_hp), "the respawned bot is at full health")
	ok(d.score_of(Enums.Team.HUMANS) == 1, "respawning does not change the score")

	# Second kill reaches the target and ends the match. Done through `die()` on a
	# live body, so the whole signal path runs.
	ok(bot.alive, "the bot is alive and can be killed again")
	bot.die(human, Enums.DamageKind.MELEE)
	await _advance(0.2)
	ok(d.score_of(Enums.Team.HUMANS) == 2, "the second kill reaches the target")
	ok(d.phase == Enums.MatchPhase.ROUND_OVER,
		"hitting the target starts the closing beat (phase %s)" % d.phase_label())
	await _advance(Balance.ROUND_OVER_TIME + 0.5)
	ok(d.phase == Enums.MatchPhase.MATCH_OVER,
		"the match ends (phase %s)" % d.phase_label())
	ok(_match_finished_calls == 1,
		"match_finished fired exactly once (fired %d)" % _match_finished_calls)

	info("deathmatch: %s" % d.describe())
	await _teardown(game)


## A rematch has to tear the old match down completely: reset score, fresh bodies,
## and the right arena. The leak that matters is actors surviving into the new
## match, which would double the roster and leave last match's corpses standing in
## the `actor` group as valid targets.
##
## Both seed cases are covered, because they are genuinely different promises:
## an empty box means "give me a new arena", a typed seed means "give me this one
## again".
func _check_rematch() -> void:
	await _rematch_case("", true, "empty seed box")
	await _rematch_case("cakegame", false, "typed seed")


func _rematch_case(seed_text: String, expect_new_seed: bool, label: String) -> void:
	_configure(false, 2, 5, seed_text)
	var game := await _boot_game()
	if game == null:
		return
	var d := game.get("director") as MatchDirector
	var arena := game.get("arena") as Arena
	if d == null or arena == null:
		await _teardown(game)
		return

	await _advance(Balance.COUNTDOWN_TIME + 0.2)
	d.scores[Enums.Team.HUMANS] = 3
	var old_seed := arena.map_seed
	var old_actors := d.actors.size()

	game.call("restart_match")
	await _advance(0.3)

	ok(d.actors.size() == old_actors,
		"%s: the roster is the same size after a rematch (%d -> %d)" % [
			label, old_actors, d.actors.size()])
	ok(d.score_of(Enums.Team.HUMANS) == 0, "%s: the scoreboard is reset" % label)
	if expect_new_seed:
		ok(arena.map_seed != old_seed, "%s: a rematch rolls a new arena (%d -> %d)" % [
			label, old_seed, arena.map_seed])
	else:
		ok(arena.map_seed == old_seed,
			"%s: a rematch keeps the arena the player asked for (%d)" % [
				label, arena.map_seed])
	ok(d.phase == Enums.MatchPhase.COUNTDOWN,
		"%s: the rematch opens on a countdown" % label)

	# The old bodies must be gone, not merely queued for deletion: `get_nodes_in_group`
	# only sees nodes still in the tree, and a lingering corpse is still hittable.
	var grouped := get_tree().get_nodes_in_group(ActorBody.GROUP).size()
	var stray := 0
	for n in get_tree().get_nodes_in_group(ActorBody.GROUP):
		if not d.actors.has(n):
			stray += 1
	ok(stray == 0, "%s: no orphaned actors in the 'actor' group (%d strays, %d total)" % [
		label, stray, grouped])
	ok(grouped == d.actors.size(),
		"%s: the 'actor' group matches the roster exactly (%d vs %d)" % [
			label, grouped, d.actors.size()])

	info("%s: seed %d -> %d, %d actors, score reset" % [
		label, old_seed, arena.map_seed, d.actors.size()])
	await _teardown(game)
