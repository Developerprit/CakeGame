class_name Arena
extends Node2D
## The playfield: painted tiles, the collision / occlusion geometry, and the nav
## grid the bots path on.
##
## Single source of truth: the `grid` byte array. Tiles are painted FROM it, the
## TileSet colliders are generated from it, and the A* grid is built from it.
## Nothing ever reads the tile map back, so the picture and the physics cannot
## disagree. The classic version of that bug is a wall that looks solid but sits
## one cell off in the collision layer, and players report it as "the AI walks
## through walls" - which sends you looking at the AI, where the bug is not.
##
## Navigation is `AStarGrid2D` over the tile grid rather than a
## `NavigationRegion2D`: the map is already an exact 16 px occupancy grid, so a
## baked navmesh would add a bake step, a second geometry pipeline and a class of
## "the mesh has a hole where a crate used to be" bugs to solve a problem the
## grid already solves exactly.

const GROUP: StringName = &"arena"

# Draw order. Actors live at z_index 2, so everything here stays underneath.
const Z_GROUND: int = -6
const Z_MARK: int = -5
const Z_BLOCK: int = -4

## Ambient tint for the arena canvas.
##
## Tuned against a real screenshot, not by eye in the editor. It started at
## (0.42, 0.45, 0.55) - "dusk" - which turned out to multiply an already dark
## floor palette down into near-black and made the whole arena unreadable. The
## lights stay, because a team-coloured glow around each fighter is genuinely
## useful in a 1v3, but they now only add a cool cast and soft wall shadows
## instead of being the difference between visible and invisible.
const AMBIENT_DARK: Color = Color(0.86, 0.89, 0.97)
const AMBIENT_LIT: Color = Color(1.0, 1.0, 1.0)

const FLOOR_NAMES: Array[String] = ["floor_a", "floor_b", "floor_c", "floor_d"]
## Floor grime. Deliberately short: a yellow `decal_warn` outline scattered by
## the same rule as a scuff mark reads as a debug marker or a missing texture,
## not as wear. Warning paint therefore only appears next to geometry, where a
## warning marking would plausibly be painted.
const DECAL_NAMES: Array[String] = [
	"decal_crack", "decal_dot", "decal_stripe",
]
## Longest run of one-tile-wide passage that still counts as a doorway instead of
## a tunnel. A doorway is a breach in a wall: the player has to commit to it for a
## step or two, so a warning stripe there is honest information. A tunnel has the
## same shape for twenty cells in a row, and stamping every third cell of it - the
## first pass did exactly that - turned the lower-right of seeded arenas into a
## hazard-striped racetrack with twenty-odd stripes in one screen.
const GAP_RUN_MAX: int = 5

# --- map state ---------------------------------------------------------------
var size: int = 0
var grid: PackedByteArray = PackedByteArray()
var ground_variants: PackedByteArray = PackedByteArray()
var props: Array = []
var map_kind: String = ""
var map_name: String = "Arena"
var map_seed: int = 0

# --- spawn state -------------------------------------------------------------
var human_cells: Array[Vector2i] = []
var bot_cells: Array[Vector2i] = []

# --- internals ---------------------------------------------------------------
var _data: Dictionary = {}
var _painted: bool = false
var _ground: TileMapLayer
var _mark: TileMapLayer
var _block: TileMapLayer
var _ambient: CanvasModulate
var _astar: AStarGrid2D
var _tile_set: TileSet
var _index: Dictionary = {}
var _prop_kinds: Dictionary = {}


# ===========================================================================
# lifecycle
# ===========================================================================

## The group is registered here, not in `_ready()`.
##
## `_ready()` of a node added to a parent that is not itself ready yet is
## deferred to the end of the frame. Bots look the arena up by group on their
## very first physics tick, so a deferred registration is a one-frame window in
## which every bot silently falls back to "no arena, walk in a straight line".
## `_enter_tree()` fires synchronously inside `add_child`, so the group is live
## the instant the arena exists.
func _enter_tree() -> void:
	if not is_in_group(GROUP):
		add_to_group(GROUP)
	_ensure_layers()


func _ready() -> void:
	_ensure_layers()
	if not _data.is_empty() and not _painted:
		_paint()


## Build (or rebuild) the arena from a `MapGenerator.generate()` result.
## Safe to call again for a rematch on a different seed.
func build(data: Dictionary) -> void:
	_data = data
	_ensure_layers()
	_paint()


func _ensure_layers() -> void:
	if _ground != null:
		return
	_tile_set = TileSetBuilder.build()
	_index = TileSetBuilder.name_to_coords()
	_ground = _make_layer("Ground", Z_GROUND, false)
	_mark = _make_layer("Mark", Z_MARK, false)
	# Only the block layer takes part in collision and occlusion. Floors that
	# participated would make every tile a shadow caster and the arena would go
	# uniformly dark the moment anything moved.
	_block = _make_layer("Block", Z_BLOCK, true)
	_ambient = CanvasModulate.new()
	_ambient.name = "Ambient"
	_ambient.color = AMBIENT_DARK if GameConfig.light_shadows else AMBIENT_LIT
	add_child(_ambient)


func _make_layer(layer_name: String, z: int, solid: bool) -> TileMapLayer:
	var l := TileMapLayer.new()
	l.name = layer_name
	l.tile_set = _tile_set
	l.z_index = z
	l.collision_enabled = solid
	l.occlusion_enabled = solid
	l.y_sort_enabled = false
	add_child(l)
	return l


# ===========================================================================
# painting
# ===========================================================================

func _paint() -> void:
	if _data.is_empty():
		return
	_clear_paint()
	size = int(_data.get("size", 0))
	grid = _data.get("grid", PackedByteArray())
	ground_variants = _data.get("ground", PackedByteArray())
	props = _data.get("props", [])
	map_kind = str(_data.get("kind", ""))
	map_name = str(_data.get("name", "Arena"))
	map_seed = int(_data.get("seed", 0))
	_paint_ground()
	_paint_blocks()
	_collect_spawns()
	_paint_marks()
	_build_nav()
	_painted = true


func _clear_paint() -> void:
	_painted = false
	grid = PackedByteArray()
	ground_variants = PackedByteArray()
	props = []
	_prop_kinds.clear()
	human_cells.clear()
	bot_cells.clear()
	_astar = null
	if _ground == null:
		return
	_ground.clear()
	_mark.clear()
	_block.clear()


func _paint_ground() -> void:
	for y in size:
		for x in size:
			var cell := Vector2i(x, y)
			# A floor is painted under EVERYTHING, walls and props included. The
			# wall art carries a bevel that reaches past its own cell, and a wall
			# sitting on the clear colour shows it through that bevel as a black
			# fringe - which reads as a rendering bug rather than as a wall.
			var g := 0
			if ground_variants.size() == size * size:
				g = int(ground_variants[y * size + x])
			_paint_cell(_ground, cell, FLOOR_NAMES[clampi(g, 0, 3)])
			if _at(x, y) == MapGenerator.F_FLOOR:
				_paint_floor_detail(cell)


## Decoration on open floor. Everything here is deterministic from the map seed
## and the cell coordinates, so the same seed always produces the same dressing
## and a headless re-run of a match is byte-identical.
func _paint_floor_detail(cell: Vector2i) -> void:
	var h := _hash(cell.x, cell.y, map_seed)
	# Hazard stripes mark one-tile-wide passages. That is real information - "this
	# is a choke point" - dressed as decoration, which is the only kind of
	# decoration worth spending a tile on.
	var walls_lr: bool = _solid(cell + Vector2i(-1, 0)) and _solid(cell + Vector2i(1, 0))
	var walls_ud: bool = _solid(cell + Vector2i(0, -1)) and _solid(cell + Vector2i(0, 1))
	var gap: int = 0
	if walls_lr:
		gap = 1
	elif walls_ud:
		gap = 2
	if gap != 0 and h % 3 == 0 and _gap_run(cell, gap) <= GAP_RUN_MAX:
		_paint_cell(_mark, cell, "hazard_v" if gap == 1 else "hazard_h")
		return
	# Scuffs are common, warning paint is not. ~1 floor cell in 37 gets a scuff
	# (~24 on the minimal arena) and 1 in 401 gets a vent; the first pass ran at
	# 1 in 23 for every decal including the warning outline and the floor looked
	# like it was covered in sticky notes.
	if h % 37 == 0:
		_paint_cell(_ground, cell, DECAL_NAMES[int(h / 37) % DECAL_NAMES.size()])
		return
	if walls_lr or walls_ud:
		if h % 89 == 0:
			_paint_cell(_ground, cell, "decal_warn")
			return
	if h % 401 == 0:
		_paint_cell(_ground, cell, "vent")


## Length of the maximal straight run of the same kind of narrow passage through
## `cell`, including `cell` itself. `gap` is 1 for a passage walled to the north
## and south of the *cell's sides* (i.e. walls left and right, run goes up/down)
## and 2 for the transpose. The walk is capped at `GAP_RUN_MAX` steps to each
## side because the only question being asked is "longer than GAP_RUN_MAX?", and
## answering it on a 200-cell tunnel by walking 200 cells would be 400 wasted
## solidity lookups for nothing.
func _gap_run(cell: Vector2i, gap: int) -> int:
	var axis := Vector2i(0, 1) if gap == 1 else Vector2i(1, 0)
	var total: int = 1
	for step in [-1, 1]:
		var probe: Vector2i = cell + axis * step
		for _i in GAP_RUN_MAX:
			if not _is_narrow(probe, gap):
				break
			total += 1
			probe += axis * step
	return total


func _is_narrow(cell: Vector2i, gap: int) -> bool:
	if _solid(cell):
		return false
	if gap == 1:
		return _solid(cell + Vector2i(-1, 0)) and _solid(cell + Vector2i(1, 0))
	return _solid(cell + Vector2i(0, -1)) and _solid(cell + Vector2i(0, 1))


func _paint_blocks() -> void:
	_prop_kinds.clear()
	for p in props:
		if typeof(p) != TYPE_DICTIONARY:
			continue
		var d: Dictionary = p
		var c: Variant = d.get("cell", null)
		if typeof(c) != TYPE_VECTOR2I:
			continue
		_prop_kinds[c] = str(d.get("kind", "crate"))
	for y in size:
		for x in size:
			var cell := Vector2i(x, y)
			var v := _at(x, y)
			if v == MapGenerator.F_WALL:
				_paint_cell(_block, cell, _wall_tile(cell))
			elif v == MapGenerator.F_PROP:
				var kind_name := str(_prop_kinds.get(cell, "crate"))
				_paint_cell(_block, cell, kind_name)


## Pick the vertical variant for a wall cell.
##
## A multi-tile-tall wall must not repeat its bevel on every row: the `top`
## variant carries the cap, `bot` carries the face, and `mid` is the plain
## middle. Choosing per-cell from the neighbours is what turns a 3x4 wall from
## three stacked slabs into one object.
func _wall_tile(cell: Vector2i) -> String:
	var up_open: bool = not _solid(cell + Vector2i(0, -1))
	var down_open: bool = not _solid(cell + Vector2i(0, 1))
	var left_open: bool = not _solid(cell + Vector2i(-1, 0))
	var right_open: bool = not _solid(cell + Vector2i(1, 0))
	# A block with open ground on all four sides is a pillar, not a wall stub.
	# Either way the collider is identical; only the read changes, and "deliberate
	# architecture" reads a lot better than "broken one-tile wall".
	if up_open and down_open and left_open and right_open:
		return "pillar"
	var stem := "wall_dark_" if _interior_wall(cell) else "wall_"
	if up_open:
		return stem + "top"
	if down_open:
		return stem + "bot"
	return stem + "mid"


## A wall with solid neighbours in all eight directions is the inside of a mass,
## not an exposed face. Using the dark palette there gives large structures a
## readable body instead of a uniform slab.
func _interior_wall(cell: Vector2i) -> bool:
	for d: Vector2i in Utils.DIRS8:
		if not _solid(cell + d):
			return false
	return true


func _paint_cell(layer: TileMapLayer, cell: Vector2i, tile_name: String) -> void:
	var coords := TileSetBuilder.coords_for(tile_name, _index)
	if coords.x < 0:
		return
	layer.set_cell(cell, TileSetBuilder.SOURCE_ID, coords)


# ===========================================================================
# spawns
# ===========================================================================

## Spawns come from the generator, but a prop may have landed on one: the
## generator places props in the main component and spawns are also in the main
## component, so the two sets overlap. Spawning inside a crate is instant and
## permanent (the body is stuck in geometry), so snap instead of trusting.
func _collect_spawns() -> void:
	human_cells = _spawn_cells_from(_data.get("humans", []))
	bot_cells = _spawn_cells_from(_data.get("bots", []))


func _spawn_cells_from(raw: Variant) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	if typeof(raw) != TYPE_ARRAY:
		return out
	var arr: Array = raw
	for item in arr:
		if typeof(item) != TYPE_VECTOR2I:
			continue
		var c: Vector2i = item
		if not is_walkable_cell(c):
			var fixed := nearest_open_cell(c, 4)
			if fixed.x < 0:
				continue
			c = fixed
		out.append(c)
	return out


func spawn_points(team: int) -> Array[Vector2]:
	var out: Array[Vector2] = []
	for c in cells_for_team(team):
		out.append(Utils.tile_center(c))
	return out


func cells_for_team(team: int) -> Array[Vector2i]:
	return human_cells if team == Enums.Team.HUMANS else bot_cells


## Spawn position for a given slot, wrapping around when there are more players
## than pads. Never returns a position outside the arena.
func spawn_point(team: int, slot: int) -> Vector2:
	var list := cells_for_team(team)
	if list.is_empty():
		return center_pos()
	return Utils.tile_center(list[posmod(slot, list.size())])


func _paint_marks() -> void:
	for c in human_cells:
		_paint_cell(_mark, c, "spawn_human")
	for c in bot_cells:
		_paint_cell(_mark, c, "spawn_bot")


# ===========================================================================
# navigation
# ===========================================================================

func _build_nav() -> void:
	_astar = null
	if size <= 0:
		return
	var g := AStarGrid2D.new()
	g.region = Rect2i(0, 0, size, size)
	g.cell_size = Vector2(Utils.TILE, Utils.TILE)
	# Half a tile. With this offset `get_point_path()` returns CELL CENTRES;
	# without it every waypoint is the cell's top-left corner, and every waypoint
	# the bot walks to is half a tile up and left of where it should be. That is
	# a small enough error to look like sloppy movement rather than a bug, which
	# is exactly why it is worth a comment.
	#
	# `offset` must be set BEFORE `update()`: changing it afterwards leaves the
	# grid uninitialised and `get_point_path()` then errors out and returns
	# nothing at all.
	g.offset = Vector2(Utils.TILE * 0.5, Utils.TILE * 0.5)
	# ONLY_IF_NO_OBSTACLES, not AT_LEAST_ONE_WALKABLE. The lenient mode lets a
	# diagonal step squeeze between two touching diagonal walls, and the bot then
	# aims at a corner it cannot physically occupy and grinds against it.
	g.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	g.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	g.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	g.update()
	for y in size:
		for x in size:
			if _solid(Vector2i(x, y)):
				g.set_point_solid(Vector2i(x, y), true)
	_astar = g


## Is the nav grid usable? The bots check this and fall back to straight-line
## movement, so a map that failed to generate degrades to "bots walk at you"
## rather than "bots freeze".
func has_nav() -> bool:
	return _astar != null and size > 0


## World-space waypoints from `from` to `to`, or empty when there is no route.
##
## Both endpoints are snapped to walkable cells first: callers routinely ask for
## a goal that is inside a wall (the bot's look-ahead target is
## `position + direction * 96`, which is very often inside geometry).
func path_to(from: Vector2, to: Vector2) -> PackedVector2Array:
	var out := PackedVector2Array()
	if not has_nav():
		return out
	var a := _nav_cell(from)
	var b := _nav_cell(to)
	if a.x < 0 or b.x < 0:
		return out
	var pts := _astar.get_point_path(a, b)
	if pts.size() <= 1:
		return out
	out = pts
	# Replace the first waypoint with where the agent actually is. The raw first
	# waypoint is the centre of its own cell, and setting off by first walking to
	# your own cell centre is a visible little step backwards whenever you happen
	# to be standing near a cell edge.
	out[0] = from
	return out


func _nav_cell(pos: Vector2) -> Vector2i:
	if not has_nav():
		return Vector2i(-1, -1)
	var c := Utils.tile_of(pos)
	c.x = clampi(c.x, 0, size - 1)
	c.y = clampi(c.y, 0, size - 1)
	if not _astar.is_point_solid(c):
		return c
	return nearest_open_cell(c, 6)


# ===========================================================================
# grid queries
# ===========================================================================

func is_walkable_cell(cell: Vector2i) -> bool:
	return _at(cell.x, cell.y) == MapGenerator.F_FLOOR


## Can an actor of `radius` stand at `pos`?
##
## Radius-aware on purpose. A bare cell test answers "is the centre point inside
## a floor tile", which is still true two pixels from a wall face - and a bot
## that picks such a point as its cover spot spends the next second grinding into
## the wall while looking like it has forgotten what it was doing. Testing the
## four corners of the body's bounding box is enough to reject those.
##
## The default is deliberately the body radius rather than 0, and the self-check
## asserts `is_walkable_pos(p) == is_walkable_pos(p, Balance.BODY_RADIUS)` so it
## stays that way. A zero default would quietly downgrade every bot call site to
## a bare cell test, which is invisible in play and only shows up as "the AI
## sometimes gets stuck on corners".
func is_walkable_pos(pos: Vector2, radius: float = Balance.BODY_RADIUS) -> bool:
	if size <= 0:
		return true
	if not is_walkable_cell(Utils.tile_of(pos)):
		return false
	if radius <= 0.01:
		return true
	for dx in [-1.0, 1.0]:
		for dy in [-1.0, 1.0]:
			if not is_walkable_cell(Utils.tile_of(pos + Vector2(dx * radius, dy * radius))):
				return false
	return true


## Nearest walkable cell, searched outward in rings so the result is the closest
## one and not merely the first. Returns `Vector2i(-1, -1)` when nothing is open
## within `max_radius`.
func nearest_open_cell(cell: Vector2i, max_radius: int = 10) -> Vector2i:
	if size <= 0:
		return Vector2i(-1, -1)
	for r in range(0, max_radius + 1):
		var best := Vector2i(-1, -1)
		var best_d: float = 1e18
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if maxi(absi(dx), absi(dy)) != r:
					continue
				var c := cell + Vector2i(dx, dy)
				if not is_walkable_cell(c):
					continue
				var d := float(dx * dx + dy * dy)
				if d < best_d:
					best_d = d
					best = c
		if best.x >= 0:
			return best
	return Vector2i(-1, -1)


## Closest safe standing position to `pos`.
##
## Used as the bot's emergency unstick. Note it clamps `pos` INTO the target cell
## rather than jumping to the cell centre: the caller passes "where the bot is,
## nudged", and teleporting it a whole tile would be a visible pop. Returns
## `Vector2.INF` when the arena has no open cell at all - callers test for that,
## so returning a plausible-looking position instead would silently leave a stuck
## bot stuck.
func nearest_open_pos(pos: Vector2, max_radius: int = 10) -> Vector2:
	if size <= 0:
		return Vector2.INF
	var c := Utils.tile_of(pos)
	c.x = clampi(c.x, 0, size - 1)
	c.y = clampi(c.y, 0, size - 1)
	var f := nearest_open_cell(c, max_radius)
	if f.x < 0:
		return Vector2.INF
	var origin := Vector2(f.x * Utils.TILE, f.y * Utils.TILE)
	var lo := origin + Vector2.ONE
	var hi := origin + Vector2(Utils.TILE - 1.0, Utils.TILE - 1.0)
	var cand := Vector2(clampf(pos.x, lo.x, hi.x), clampf(pos.y, lo.y, hi.y))
	return cand if is_walkable_pos(cand) else Utils.tile_center(f)


func random_open_pos(rng: RandomNumberGenerator) -> Vector2:
	if size <= 0:
		return Vector2.INF
	for _i in 64:
		var c := Vector2i(rng.randi_range(0, size - 1), rng.randi_range(0, size - 1))
		if is_walkable_cell(c) and is_walkable_pos(Utils.tile_center(c)):
			return Utils.tile_center(c)
	return nearest_open_pos(center_pos())


func center_pos() -> Vector2:
	return Utils.tile_center(Vector2i(size / 2, size / 2))


func cell_center(cell: Vector2i) -> Vector2:
	return Utils.tile_center(cell)


func world_rect() -> Rect2:
	var side := float(size * Utils.TILE)
	return Rect2(Vector2.ZERO, Vector2(side, side))


func open_cell_count() -> int:
	var n := 0
	for i in grid.size():
		if int(grid[i]) == MapGenerator.F_FLOOR:
			n += 1
	return n


func _at(x: int, y: int) -> int:
	if x < 0 or y < 0 or x >= size or y >= size:
		return MapGenerator.F_WALL
	if grid.size() != size * size:
		return MapGenerator.F_WALL
	return int(grid[y * size + x])


func _solid(cell: Vector2i) -> bool:
	var v := _at(cell.x, cell.y)
	return v == MapGenerator.F_WALL or v == MapGenerator.F_PROP


# ===========================================================================
# lighting
# ===========================================================================

## Turn the arena's ambient dimming on or off.
##
## Dimming only pays for itself when the fighters' lights cast shadows - that is
## the whole reason for a dark ambient. With shadows off it is pure loss: it
## multiplies an already dark palette down and takes the tile art with it.
func set_lit(enabled: bool) -> void:
	if _ambient == null:
		return
	_ambient.color = AMBIENT_DARK if enabled else AMBIENT_LIT


# ===========================================================================
# diagnostics
# ===========================================================================

func stats() -> Dictionary:
	if _data.is_empty():
		return {}
	return MapGenerator.analyze(_data)


## Cells on the decoration layer that carry `tile_name`. Exposed for the
## self-check: decoration density is exactly the kind of thing that regresses the
## moment somebody retunes a divisor, and the symptom - a thousand hazard stripes
## packed into one corner of one seed - is invisible in any summary count.
func count_marks(tile_name: String) -> int:
	if _mark == null:
		return 0
	var atlas := TileSetBuilder.coords_for(tile_name)
	if atlas.x < 0:
		return 0
	var total: int = 0
	for cell in _mark.get_used_cells():
		if _mark.get_cell_source_id(cell) != TileSetBuilder.SOURCE_ID:
			continue
		if _mark.get_cell_atlas_coords(cell) == atlas:
			total += 1
	return total


## Deterministic cell noise. Cheap integer mix, no RNG object, so the same seed
## always dresses the map the same way on every machine.
static func _hash(x: int, y: int, s: int) -> int:
	var h := x * 73856093
	h = h ^ (y * 19349663)
	h = h ^ (s * 83492791)
	return absi(h)


func describe() -> String:
	return "%s (%d x %d, seed %d, %d open cells)" % [
		map_name, size, size, map_seed, open_cell_count(),
	]
