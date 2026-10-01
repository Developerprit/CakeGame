class_name Combat
extends RefCounted
## Damage resolution and hit queries.
##
## All queries go through `PhysicsDirectSpaceState2D`, which is only valid while
## the physics server is stepping - i.e. from inside `_physics_process`. Calling
## these from `_process` or from a signal handler outside the physics step will
## either return garbage or error, so every caller here is a physics-time caller.

const WORLD_MASK: int = 1 << 0        ## physics layer 1: walls, props
const ACTOR_MASK: int = 1 << 1        ## physics layer 2: characters
const PROJECTILE_MASK: int = 1 << 2   ## physics layer 3: bullets, hooks


static func is_enemy(team_a: int, team_b: int) -> bool:
	if team_a == team_b:
		return GameConfig.friendly_fire
	return true


static func exclude_rids(actors: Array) -> Array[RID]:
	var out: Array[RID] = []
	for a in actors:
		var co := a as CollisionObject2D
		if co != null:
			out.append(co.get_rid())
	return out


## Ray against the world geometry only.
static func world_ray(space: PhysicsDirectSpaceState2D, from: Vector2, to: Vector2,
		exclude: Array[RID] = []) -> Dictionary:
	if space == null:
		return {}
	var q := PhysicsRayQueryParameters2D.create(from, to, WORLD_MASK)
	q.collide_with_areas = false
	q.collide_with_bodies = true
	if not exclude.is_empty():
		q.exclude = exclude
	return space.intersect_ray(q)


static func blocked(space: PhysicsDirectSpaceState2D, from: Vector2, to: Vector2,
		exclude: Array[RID] = []) -> bool:
	return not world_ray(space, from, to, exclude).is_empty()


## True when `attacker` has an unobstructed line to `target`.
## Used both by the AI (never shoot through a wall) and by bullets.
static func has_line(attacker: Node2D, target_pos: Vector2) -> bool:
	if attacker == null or attacker.get_world_2d() == null:
		return false
	var space := attacker.get_world_2d().direct_space_state
	var ex := exclude_rids([attacker])
	return not blocked(space, attacker.global_position, target_pos, ex)


# ---------------------------------------------------------------------------
# melee
# ---------------------------------------------------------------------------

## Cone sweep in front of the attacker.
##
## The line-of-sight test is NOT optional. Without it a swing reaches straight
## through a wall, which in practice means the bot stands on the far side of a
## corner and shreds anything that walks past - and it looks like a physics bug.
static func melee_strike(attacker: ActorBody) -> Array[ActorBody]:
	var out: Array[ActorBody] = []
	if attacker == null or not attacker.is_alive():
		return out
	var tree := attacker.get_tree()
	if tree == null:
		return out
	var space := attacker.get_world_2d().direct_space_state
	var origin := attacker.global_position
	var aim := attacker.aim_dir
	var ex := exclude_rids([attacker])
	var reach := Balance.MELEE_RANGE + attacker.hit_radius

	for n in tree.get_nodes_in_group(&"actor"):
		var t := n as ActorBody
		if t == null or t == attacker or not t.is_alive():
			continue
		if not is_enemy(attacker.team, t.team):
			continue
		var to_t: Vector2 = t.global_position - origin
		if to_t.length() > reach + t.hit_radius:
			continue
		if absf(Utils.angle_delta(aim.angle(), to_t.angle())) > Balance.MELEE_HALF_ARC:
			continue
		if blocked(space, origin, t.global_position, ex):
			continue
		out.append(t)
		if out.size() >= 3:
			break
	return out


# ---------------------------------------------------------------------------
# damage application
# ---------------------------------------------------------------------------

## Central damage entry point. Returns true when the hit actually landed.
##
## `source` may be null (environmental damage). Every rejection reason produces a
## distinguishable return so the AI can learn "he is invulnerable right now"
## rather than assuming a miss.
static func apply_damage(victim: ActorBody, amount: float, kind: int,
		source: ActorBody, knockback: Vector2, hit_pos: Vector2,
		attacker_node: Node = null) -> bool:
	if victim == null or not victim.is_alive() or amount <= 0.0:
		return false
	if victim.i_frames > 0.0 or victim.spawn_invuln > 0.0:
		EventBus.hit_confirmed.emit(attacker_node, victim, kind, 0.0, hit_pos)
		return false
	if source != null and not is_enemy(source.team, victim.team):
		return false

	var before := victim.hp
	victim.hp = maxf(0.0, victim.hp - amount)
	var dealt := before - victim.hp
	if dealt <= 0.0:
		return false

	victim.apply_knockback(knockback)
	victim.on_hit_feedback(kind, dealt)

	EventBus.actor_damaged.emit(victim, dealt, kind, attacker_node)
	EventBus.health_changed.emit(victim, victim.hp, victim.max_hp)
	EventBus.hit_confirmed.emit(attacker_node, victim, kind, dealt, hit_pos)

	if victim.hp <= 0.0:
		victim.die(attacker_node, kind)
	return true


## Convenience for bullets and hooks, which know their shooter but not the
## shooter's body object.
static func apply_damage_from_team(victim: ActorBody, amount: float, kind: int,
		shooter_team: int, shooter: ActorBody, knockback: Vector2,
		hit_pos: Vector2, attacker_node: Node) -> bool:
	if victim == null:
		return false
	if not is_enemy(shooter_team, victim.team):
		return false
	return apply_damage(victim, amount, kind, shooter, knockback, hit_pos, attacker_node)
