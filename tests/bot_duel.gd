extends Node2D
## Headless 1v1 duel benchmark: `cakegame_v1` vs `cakegame_v1_pro`.
##
##     godot --headless --path . --fixed-fps 60 res://_check/bot_duel.tscn
##
## ## Why a bespoke scene instead of `tests/match_sim`
##
## `MatchDirector` builds its roster from ONE `GameConfig.bot_version`, so every
## bot in a real match is the same brain - there is no story in which two
## different bots can meet. Building the smallest possible duel rig here (world,
## arena, two actors) is both the only way to compare them and much cheaper:
## no HUD, no camera, no round logic, so a 40 s duel costs 2400 physics frames
## and nothing else.
##
## The two bots go on DIFFERENT TEAMS (HUMANS vs BOTS) rather than relying on
## friendly fire. `Combat.is_enemy` only returns true for same-team pairs when
## `GameConfig.friendly_fire` is on, which would also flip a lot of unrelated
## behaviour; two different teams is reality-identical and needs no global.
##
## ## Bias control
##
## The seeded arena is NOT symmetric between the two spawn clusters, and there is
## a first-contact advantage. Every seed is therefore run TWICE with the brains
## swapped, and a duel only counts for a brain if it appears on both sides of it.
## A brain that wins 10-0 on the human spawn cluster and loses 0-10 on the bot
## cluster is not stronger, and this harness would show that.

const FPS: int = 60
const DUEL_SECONDS: float = 40.0
## Why `seed()` is called here.
##
## `ActorBody.fire_bullet()` spreads its bullet with the GLOBAL `randf_range`,
## not the brain's per-actor RNG, so without seeding the whole process the amount
## every bullet deviates differs between runs - and two consecutive runs of this
## benchmark came back 12-2 and 6-6 on identical code. A benchmark that cannot
## reproduce itself cannot support a claim, so the global generator is pinned.
## The brain RNGs stay seeded from `actor_id` (`BotBrain.setup`) as usual.
const GLOBAL_SEED: int = 20261001
const RESPAWN_DELAY: float = 1.2
const START_SEPARATION: float = 190.0
const SEEDS: Array[String] = [
	"duel-a", "duel-b", "duel-c", "duel-d", "duel-e", "duel-f",
	"duel-g", "duel-h", "duel-i", "duel-j", "duel-k", "duel-l",
	"duel-m", "duel-n", "duel-o", "duel-p", "duel-q", "duel-r",
	"duel-s", "duel-t", "duel-u", "duel-v", "duel-w", "duel-x",
]

# --- rig -------------------------------------------------------------------
var arena: Arena = null
var actors_layer: Node2D = null
var projectiles_layer: Node2D = null

# --- per-duel counters -----------------------------------------------------
var _a: BotActor = null
var _b: BotActor = null
var _deaths: Dictionary = {}
var _damage_out: Dictionary = {}
var _damage_in: Dictionary = {}
var _shots: Dictionary = {}
var _melee_started: Dictionary = {}
var _rolls: Dictionary = {}
var _pending: Dictionary = {}
var _start_a: Vector2 = Vector2.INF
var _start_b: Vector2 = Vector2.INF

# --- engagement diagnostics ------------------------------------------------
var _frames: int = 0
var _vis: int = 0
var _close: int = 0
var _melee_range: int = 0
var _dist_sum: float = 0.0
var _time_now: float = 0.0
var _decided_count: int = 0


func _ready() -> void:
	seed(GLOBAL_SEED)
	print("CakeGame bot duel  |  %s  |  global seed %d" % [
		Engine.get_version_info().get("string", "?"), GLOBAL_SEED])
	print("%d seeds x 2 sides = %d duels of %.0fs at %d fps" % [
		SEEDS.size(), SEEDS.size() * 2, DUEL_SECONDS, FPS])
	print("-------------------")

	_build_rig()
	_connect_once()

	var tally: Dictionary = {}
	for id in [BotRegistry.DEFAULT_ID, "cakegame_v1_pro"]:
		tally[id] = {"wins": 0, "losses": 0, "draws": 0, "dmg_wins": 0,
			"deaths": 0, "kills": 0, "damage": 0.0, "shots": 0, "rolls": 0}

	var n: int = 0
	for s in SEEDS:
		for swap in [false, true]:
			var left: String = "cakegame_v1_pro" if swap else BotRegistry.DEFAULT_ID
			var right: String = BotRegistry.DEFAULT_ID if swap else "cakegame_v1_pro"
			var r: Dictionary = await _duel(s, left, right)
			var who_a: String = "pro" if left == "cakegame_v1_pro" else "v1 "
			var who_b: String = "pro" if right == "cakegame_v1_pro" else "v1 "
			print("%-8s  humans=%s (%d)  :  (%d) bots=%s   dmg %4.0f:%-4.0f  shots %3d:%-3d  vis %s pct  mean-dist %s" % [
				s, who_a, int(r["a_kills"]), int(r["b_kills"]), who_b,
				float(r["a_dmg"]), float(r["b_dmg"]),
				int(r["a_shots"]), int(r["b_shots"]),
				String.num(float(r["vis"]), 0), String.num(float(r["dist"]), 0)])
			for side in ["a", "b"]:
				var who: String = str(r[side + "_id"])
				var t: Dictionary = tally[who]
				t["kills"] = int(t["kills"]) + int(r[side + "_kills"])
				t["deaths"] = int(t["deaths"]) + int(r[side + "_deaths"])
				t["damage"] = float(t["damage"]) + float(r[side + "_dmg"])
				t["shots"] = int(t["shots"]) + int(r[side + "_shots"])
				t["rolls"] = int(t["rolls"]) + int(r[side + "_rolls"])
			if int(r["a_kills"]) > int(r["b_kills"]):
				tally[left]["wins"] = int(tally[left]["wins"]) + 1
				tally[right]["losses"] = int(tally[right]["losses"]) + 1
			elif int(r["a_kills"]) < int(r["b_kills"]):
				tally[right]["wins"] = int(tally[right]["wins"]) + 1
				tally[left]["losses"] = int(tally[left]["losses"]) + 1
			else:
				tally[left]["draws"] = int(tally[left]["draws"]) + 1
				tally[right]["draws"] = int(tally[right]["draws"]) + 1
			# Kills are rare enough that most duels are draws, so damage is scored
			# as well: same comparison, continuous instead of discrete, and it is
			# the number the fire-discipline upgrade is actually meant to move.
			if float(r["a_dmg"]) > float(r["b_dmg"]) + 12.0:
				tally[left]["dmg_wins"] = int(tally[left]["dmg_wins"]) + 1
			elif float(r["b_dmg"]) > float(r["a_dmg"]) + 12.0:
				tally[right]["dmg_wins"] = int(tally[right]["dmg_wins"]) + 1
			if int(r["a_kills"]) != int(r["b_kills"]):
				_decided_count += 1
			n += 1

	print("-------------------")
	print("%d duels  (%d decided, %d draws)" % [n, _decided(), n - _decided()])
	for id in tally:
		var t: Dictionary = tally[id]
		var wins: int = int(t["wins"])
		var losses: int = int(t["losses"])
		var played: int = wins + losses + int(t["draws"])
		var rate: float = float(wins) * 100.0 / maxf(1.0, float(played))
		var decided_rate: float = float(wins) * 100.0 / maxf(1.0, float(wins + losses))
		var eff: float = float(t["damage"]) / maxf(1.0, float(t["shots"]) * Balance.BULLET_DAMAGE)
		var kd: float = float(t["kills"]) / maxf(1.0, float(t["deaths"]))
		var dmg_rate: float = float(t["dmg_wins"]) * 100.0 / maxf(1.0, float(played))
		print("%-18s  %d-%d-%d   win %s pct (all)  win %s pct (decided)   out-damaged in %s pct  K/D %s" % [
			id, wins, losses, int(t["draws"]),
			String.num(rate, 1), String.num(decided_rate, 1), String.num(dmg_rate, 1),
			String.num(kd, 2)])
		print("%18s  damage %.0f   shots %d   damage per shot %.1f of %d   rolls %d" % [
			"", float(t["damage"]), int(t["shots"]),
			eff * 100.0, int(Balance.BULLET_DAMAGE), int(t["rolls"])])
	get_tree().quit(0)


# ===========================================================================
# rig - the minimum a bot needs to be a bot
# ===========================================================================

func _build_rig() -> void:
	var world := Node2D.new()
	world.name = "World"
	add_child(world)

	arena = Arena.new()
	arena.name = "Arena"
	world.add_child(arena)

	actors_layer = Node2D.new()
	actors_layer.name = "Actors"
	world.add_child(actors_layer)

	projectiles_layer = Node2D.new()
	projectiles_layer.name = "Projectiles"
	projectiles_layer.add_to_group(&"projectile_layer")
	projectiles_layer.z_index = 1
	world.add_child(projectiles_layer)


## Where they start, and why not the pads.
##
## On a seeded arena the two spawn clusters can be 700 px apart with three
## corridors between them, and a 40 s duel then measures SEARCHING, not
## fighting - several seeds came back 0-0 with zero shots fired. The point of
## this benchmark is the exchange, so both fighters are dropped on random open
## floor at a controlled separation, which is the part of the loop that decides
## duels. Nothing is learned about navigation here because both brains share v1's
## navigation unchanged; that side of things is `tests/match_sim`'s job.
##
## The RNG is seeded per duel so a failure reproduces exactly.
func _boot_arena(seed_text: String) -> void:
	GameConfig.seeded_map = false
	GameConfig.friendly_fire = false
	NetManager.set_offline()
	arena.build(MapGenerator.generate(GameConfig.effective_seed()))
	var rng := RandomNumberGenerator.new()
	rng.seed = absi(seed_text.hash())
	_start_a = _open_spot(rng, Vector2.INF, 0.0)
	_start_b = _open_spot(rng, _start_a, START_SEPARATION)


func _open_spot(rng: RandomNumberGenerator, away_from: Vector2,
		min_dist: float) -> Vector2:
	var fallback := arena.spawn_point(Enums.Team.BOTS, 0)
	for _i in 200:
		var p: Vector2 = arena.random_open_pos(rng)
		if p == Vector2.INF:
			break
		if away_from == Vector2.INF:
			return p
		var d: float = p.distance_to(away_from)
		if d >= min_dist and d <= min_dist * 2.6:
			return p
	return fallback


# ===========================================================================
# one duel
# ===========================================================================

func _duel(seed_text: String, left_id: String, right_id: String) -> Dictionary:
	_clear_actors()
	_boot_arena(seed_text)
	_reset()

	_a = _spawn(1, Enums.Team.HUMANS, "A", left_id, _start_a)
	_b = _spawn(2, Enums.Team.BOTS, "B", right_id, _start_b)
	await get_tree().physics_frame

	var frames: int = frames_for(DUEL_SECONDS)
	for i in frames:
		_tick_respawns(1.0 / float(FPS))
		_sample()
		await get_tree().physics_frame

	return {
		"a_id": left_id, "b_id": right_id,
		"a_kills": _deaths.get(_b, 0), "b_kills": _deaths.get(_a, 0),
		"a_deaths": _deaths.get(_a, 0), "b_deaths": _deaths.get(_b, 0),
		"a_dmg": _damage_out.get(_a, 0.0), "b_dmg": _damage_out.get(_b, 0.0),
		"a_shots": _shots.get(_a, 0), "b_shots": _shots.get(_b, 0),
		"a_rolls": _rolls.get(_a, 0), "b_rolls": _rolls.get(_b, 0),
		"vis": (float(_vis) * 100.0 / maxf(1.0, float(_frames))),
		"close": (float(_close) * 100.0 / maxf(1.0, float(_frames))),
		"dist": (_dist_sum / maxf(1.0, float(_frames))),
	}


func frames_for(seconds: float) -> int:
	return int(ceili(seconds * float(FPS)))


## Sampled from OUTSIDE the brains on purpose: the question being answered is
## "do these two actually fight", and asking either brain about it would beg the
## question. Visibility here is plain world geometry between two points.
func _sample() -> void:
	if _a == null or _b == null:
		return
	if not is_instance_valid(_a) or not is_instance_valid(_b):
		return
	if not _a.alive or not _b.alive:
		return
	_frames += 1
	_time_now += 1.0 / float(FPS)
	var d: float = _a.global_position.distance_to(_b.global_position)
	_dist_sum += d
	if d <= Balance.AI_PREFERRED_MAX * 1.6:
		_close += 1
	if Combat.has_line(_a, _b.global_position):
		_vis += 1
	if d <= Balance.AI_MELEE_RANGE + 8.0:
		_melee_range += 1


func _spawn(id: int, team: int, name: String, brain_id: String,
		start: Vector2) -> BotActor:
	var body := BotActor.new()
	body.configure({
		"id": id,
		"team": team,
		"kind": Enums.Kind.BOT,
		"name": name,
		"local": false,
		"authoritative": true,
		"color": Enums.team_color(team),
	})
	body.position = start if start != Vector2.INF else arena.spawn_point(team, 0)
	actors_layer.add_child(body)
	body.setup_brain(brain_id)
	# Countdown invulnerability exists to protect a player whose screen is still
	# fading in. Neither entrant here has a screen, and leaving it on would hand
	# 1.2 free seconds to whoever aims first - which would be pure noise.
	body.spawn_invuln = 0.0
	return body


## Detach BEFORE queueing the free, exactly as `MatchDirector._clear_actors`
## does: a merely-queued actor is still in the `actor` group and still hittable,
## so the next duel's opening shots would land on this duel's corpses.
func _clear_actors() -> void:
	var marks: Array[Node] = []
	for n in get_tree().get_nodes_in_group(&"actor"):
		marks.append(n)
	for n in marks:
		var p := n.get_parent()
		if p != null:
			p.remove_child(n)
		n.queue_free()
	_a = null
	_b = null
	if projectiles_layer != null:
		for c in projectiles_layer.get_children():
			c.queue_free()


func _reset() -> void:
	_frames = 0
	_vis = 0
	_close = 0
	_melee_range = 0
	_dist_sum = 0.0
	_deaths.clear()
	_damage_out.clear()
	_damage_in.clear()
	_shots.clear()
	_melee_started.clear()
	_rolls.clear()
	_pending.clear()


# ===========================================================================
# counting
# ===========================================================================

func _decided() -> int:
	return _decided_count


func _connect_once() -> void:
	if EventBus.actor_damaged.is_connected(_on_damaged):
		return
	EventBus.actor_damaged.connect(_on_damaged)
	EventBus.actor_died.connect(_on_died)
	EventBus.cooldown_started.connect(_on_cooldown)
	EventBus.roll_started.connect(_on_roll)


func _bump(d: Dictionary, who: Node, amount: float = 0.0) -> void:
	var key: Variant = who
	d[key] = float(d.get(key, 0.0)) + amount


func _on_damaged(actor: Node, amount: float, _kind: int, source: Node) -> void:
	if source == null or not is_instance_valid(source):
		return
	_bump(_damage_out, source, amount)
	_bump(_damage_in, actor, amount)


func _on_died(actor: Node, _killer: Node, _kind: int) -> void:
	_bump(_deaths, actor, 1.0)
	_pending[actor] = RESPAWN_DELAY


func _on_cooldown(actor: Node, slot: String, _duration: float) -> void:
	if slot != "gun":
		return
	_bump(_shots, actor, 1.0)


func _on_roll(actor: Node, _dir: Vector2) -> void:
	_bump(_rolls, actor, 1.0)


func _tick_respawns(dt: float) -> void:
	for key in _pending.keys():
		var left: float = float(_pending[key]) - dt
		if left > 0.0:
			_pending[key] = left
			continue
		_pending.erase(key)
		var body := key as ActorBody
		if body == null or not is_instance_valid(body):
			continue
		var slot: int = 0
		# Respawn NEAR the survivor rather than on a home pad. A death followed by
		# 20 s of crossing the arena measures hunting, not fighting, and left 14 of
		# 24 duels undecided. Bringing the loser straight back into rifle range is
		# what turns this into the exchange it is supposed to sample.
		var other: ActorBody = _b if body == _a else _a
		var spot: Vector2 = arena.spawn_point(body.team, slot)
		if other != null and is_instance_valid(other) and other.alive:
			var rng := RandomNumberGenerator.new()
			rng.seed = (body.actor_id * 7919) + int(_time_now * 60.0)
			var near: Vector2 = _open_spot(rng, other.global_position, START_SEPARATION)
			if near != Vector2.INF:
				spot = near
		body.respawn(spot)
		body.spawn_invuln = 0.0
