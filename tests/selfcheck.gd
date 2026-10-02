extends TestHarness
## Headless self-check. This is the "is the build actually usable" gate.
##
##     godot --headless --path . res://tests/selfcheck.tscn
##
## Exit code 0 = all green, 1 = at least one failure.
##
## -----------------------------------------------------------------------------
## Why this runs as a SCENE and not as `--script <file>.gd`
## -----------------------------------------------------------------------------
## Under `--script`, the custom main loop script is compiled BEFORE the autoloads
## are added to the tree. Any `class_name` script that mentions an autoload
## (`EventBus`, `GameConfig`, `AudioDirector`, `InputSetup`) then fails to compile
## at that moment, and Godot caches the failure: the global class name resolves to
## an EMPTY `GDScript` object for the rest of the run. Measured directly:
##
##     MapGenerator   22 methods   (no autoload references)      -> fine
##     Arena          38 methods   (no autoload references)      -> fine
##     TileSetBuilder  7 methods                                 -> fine
##     CameraRig       0 methods   (`EventBus` in _ready)        -> silently dead
##     ActorBody       1 method    (`EventBus` at line 146)      -> silently dead
##
## `CameraRig.frame_for(...)` then fails with "Nonexistent function in base
## GDScript", which is a baffling message for a class that is obviously fine.
## Running as the main scene compiles everything after the autoloads exist, which
## is also exactly how the game itself runs - so the check exercises the real
## code path instead of a special one.
##
## `_init()` is too early as well: the root window has no children in `_init()`
## and has not entered the tree, so `add_child()` registers nothing at all and
## `_enter_tree()` never fires.

func _ready() -> void:
	print("CakeGame self-check")
	print("godot %s  |  %s" % [
		Engine.get_version_info().get("string", "?"), DisplayServer.get_name()])
	print("-------------------")
	# `run` / `ok` / `info` / `report` come from TestHarness (tests/harness.gd).
	run("manifest", _check_manifest)
	run("minimal map", _check_minimal)
	run("seeded maps", _check_seeds)
	run("determinism", _check_determinism)
	run("tile set", _check_tileset)
	run("camera framing", _check_camera_math)
	run("arena build", _check_arena)
	run("decoration", _check_decoration)
	run("navigation", _check_navigation)
	run("camera node", _check_camera_node)
	run("exportable resources", _check_exportable_resources)
	get_tree().quit(report("SELF-CHECK"))


## Only here so `_check_navigation` can pin down how GDScript treats a default
## argument that reaches into another class's `const`.
static func _default_arg_probe(x: float = Balance.BODY_RADIUS) -> float:
	return x


# ===========================================================================
# assets
# ===========================================================================

func _check_manifest() -> void:
	var problems := AtlasLibrary.validate()
	for p in problems:
		ok(false, "atlas: " + p)
	ok(problems.is_empty(), "all atlases load")
	var tile_problems := TileSetBuilder.validate()
	for p in tile_problems:
		ok(false, "tiles: " + p)
	ok(tile_problems.is_empty(), "every required tile name exists in the manifest")
	var b := Balance.BODY_RADIUS
	ok(b > 0.0 and b < float(Utils.TILE) * 0.5,
		"the body radius (%.1f) fits inside one tile" % b)
	ok(Balance.MOVE_SPEED > 0.0 and Balance.BULLET_SPEED > Balance.MOVE_SPEED,
		"bullets are faster than everyone walks")
	info("tiles atlas: %s" % AtlasLibrary.tiles_texture_path())


# ===========================================================================
# maps
# ===========================================================================

func _check_minimal() -> void:
	var d := MapGenerator.generate(0)
	ok(int(d.get("size", 0)) == MapGenerator.MINIMAL_SIZE,
		"minimal map is %d tiles" % MapGenerator.MINIMAL_SIZE)
	ok(str(d.get("kind", "")) == MapGenerator.KIND_MINIMAL, "kind is minimal")
	var a := MapGenerator.analyze(d)
	ok(int(a["main_fraction"] * 100.0) == 100, "one connected region (main_fraction=%f)" % a["main_fraction"])
	ok(int(a["components"]) == 1, "exactly one component, got %d" % a["components"])
	ok(int(a["unreachable_props"]) == 0, "no unreachable props")
	ok(int(a["floor"]) > 0, "floor exists")
	ok(float(a["avg_wall_dist"]) >= 1.0,
		"minimal map is not a bare box (avg_wall_dist=%.2f)" % a["avg_wall_dist"])
	ok(_spawns_ok(d), "minimal map has usable spawn pads for both teams")
	# 4-fold symmetry: the mirrored cover must not accidentally put cover only on
	# one team's half, or every "balanced" match is decided by spawn side.
	ok(_is_four_fold_symmetric(d), "minimal map is 4-fold symmetric")
	info("floor=%d avg_wall_dist=%.2f corridor_ratio=%.3f dead_ends=%d props=%d" % [
		a["floor"], a["avg_wall_dist"], a["corridor_ratio"], a["dead_ends"], a["props"]])


func _check_seeds() -> void:
	const COUNT := 40
	var worst_main := 1.0
	var min_floor := 1 << 30
	var worst_open := 1e9
	var sealed_maps := 0
	var total_sealed := 0
	var worst_corridor := 1.0
	for i in range(1, COUNT + 1):
		var seed_value := i * 7919
		var d := MapGenerator.generate(seed_value)
		var a := MapGenerator.analyze(d)
		worst_main = minf(worst_main, float(a["main_fraction"]))
		worst_corridor = minf(worst_corridor, float(a["corridor_ratio"]))
		min_floor = mini(min_floor, int(a["floor"]))
		worst_open = minf(worst_open, float(a["avg_wall_dist"]))
		if int(a["components"]) > 1:
			sealed_maps += 1
		total_sealed += int(a["floor"]) - int(a["main_floor"])
		if int(a["unreachable_props"]) != 0:
			ok(false, "seed %d has %d unreachable props" % [seed_value, a["unreachable_props"]])
			return
		if not _spawns_ok(d):
			ok(false, "seed %d produced an unusable spawn set" % seed_value)
			return
	ok(worst_main >= 0.999, "every seed is fully connected (worst main_fraction=%f)" % worst_main)
	ok(min_floor > 400, "no seed degenerates into a closet (min floor=%d)" % min_floor)
	ok(worst_open >= 1.2, "no seed is a bare box (worst avg_wall_dist=%.2f)" % worst_open)
	info("%d seeds: %d needed sealing, %d floor cells re-walled in total" % [
		COUNT, sealed_maps, total_sealed])
	info("worst main_fraction=%f min floor=%d worst avg_wall_dist=%.2f worst corridor_ratio=%.3f" % [
		worst_main, min_floor, worst_open, worst_corridor])


func _spawns_ok(d: Dictionary) -> bool:
	var grid: PackedByteArray = d.get("grid", PackedByteArray())
	var n := int(d.get("size", 0))
	if n <= 0 or grid.size() != n * n:
		return false
	for key in ["humans", "bots"]:
		var list: Variant = d.get(key, [])
		if typeof(list) != TYPE_ARRAY:
			return false
		var arr: Array = list
		if arr.size() < 2:
			return false
		for item in arr:
			if typeof(item) != TYPE_VECTOR2I:
				return false
			var c: Vector2i = item
			if c.x < 0 or c.y < 0 or c.x >= n or c.y >= n:
				return false
			if int(grid[c.y * n + c.x]) != MapGenerator.F_FLOOR:
				return false
	return true


## Mirror the grid about both axes and about the centre; a mirrored layout must
## land on itself. Catches "I added a bit of cover and broke the symmetry" which
## is invisible on a screenshot and decisive in a 1v1.
func _is_four_fold_symmetric(d: Dictionary) -> bool:
	var grid: PackedByteArray = d.get("grid", PackedByteArray())
	var n := int(d.get("size", 0))
	if n <= 0 or grid.size() != n * n:
		return false
	for y in n:
		for x in n:
			var v := int(grid[y * n + x])
			if int(grid[y * n + (n - 1 - x)]) != v:
				return false
			if int(grid[(n - 1 - y) * n + x]) != v:
				return false
			if int(grid[(n - 1 - y) * n + (n - 1 - x)]) != v:
				return false
	return true


func _check_determinism() -> void:
	for seed_value in [1, 4242, 999983]:
		var a := MapGenerator.generate(seed_value)
		var b := MapGenerator.generate(seed_value)
		var ga: PackedByteArray = a["grid"]
		var gb: PackedByteArray = b["grid"]
		ok(ga == gb, "seed %d regenerates the same grid" % seed_value)
		ok(a["humans"] == b["humans"], "seed %d regenerates the same human spawns" % seed_value)
		ok(a["bots"] == b["bots"], "seed %d regenerates the same bot spawns" % seed_value)
		var pa: Array = a["props"]
		var pb: Array = b["props"]
		ok(pa.size() == pb.size(), "seed %d regenerates the same prop count" % seed_value)
	# a string seed must hash the same way every run, or two players typing the
	# same seed get different maps and one of them is at a disadvantage
	ok(Utils.seed_from_string("cake") == Utils.seed_from_string("CAKE"),
		"string seeds are case-insensitive")
	ok(Utils.seed_from_string(" cake ") == Utils.seed_from_string("cake"),
		"string seeds ignore surrounding spaces")
	ok(Utils.resolve_seed("") == 0, "an empty seed means 'pick one'")
	ok(Utils.resolve_seed("12345") == 12345, "a numeric seed is used directly")


# ===========================================================================
# tiles
# ===========================================================================

func _check_tileset() -> void:
	var ts := TileSetBuilder.build()
	ok(ts != null, "tile set builds")
	if ts == null:
		return
	ok(ts.get_physics_layers_count() == 1, "exactly one physics layer")
	ok(ts.get_occlusion_layers_count() == 1, "exactly one occlusion layer")
	ok(ts.get_physics_layer_collision_layer(TileSetBuilder.PHYSICS_LAYER) == Combat.WORLD_MASK,
		"the tile physics layer is on the world collision layer")
	var src := ts.get_source(TileSetBuilder.SOURCE_ID) as TileSetAtlasSource
	ok(src != null, "tile set has the atlas source")
	if src == null:
		return
	var solid_missing: Array[String] = []
	var deco_solid: Array[String] = []
	var occluder_missing: Array[String] = []
	for name in TileSetBuilder.REQUIRED_TILES:
		var coords := TileSetBuilder.coords_for(name)
		if coords.x < 0:
			continue
		var data := src.get_tile_data(coords, TileSetBuilder.ALTERNATIVE)
		if data == null:
			solid_missing.append(name + "(no tile data)")
			continue
		var polys := data.get_collision_polygons_count(TileSetBuilder.PHYSICS_LAYER)
		if TileSetBuilder.SOLID_TILES.has(name):
			if polys != 1:
				solid_missing.append("%s(%d polys)" % [name, polys])
			if data.get_occluder(TileSetBuilder.OCCLUSION_LAYER) == null:
				occluder_missing.append(name)
		elif polys != 0:
			deco_solid.append(name)
	ok(solid_missing.is_empty(), "every solid tile has a collider: %s" % str(solid_missing))
	ok(deco_solid.is_empty(), "no decorative tile is solid: %s" % str(deco_solid))
	ok(occluder_missing.is_empty(), "every solid tile casts a shadow: %s" % str(occluder_missing))

	var wall := src.get_tile_data(TileSetBuilder.coords_for("wall_mid"),
		TileSetBuilder.ALTERNATIVE)
	if wall != null:
		var pts := wall.get_collision_polygon_points(TileSetBuilder.PHYSICS_LAYER, 0)
		var widest := 0.0
		for p in pts:
			widest = maxf(widest, maxf(absf(p.x), absf(p.y)))
		ok(widest < float(Utils.TILE) * 0.5,
			"wall collider is inset (half-extent %.1f of %.1f)" % [widest, float(Utils.TILE) * 0.5])
		info("wall collider half-extent %.1f px" % widest)


# ===========================================================================
# camera
# ===========================================================================

func _check_camera_math() -> void:
	var view := Vector2(640.0, 360.0)

	var empty := CameraRig.frame_for([], view)
	ok(float(empty["zoom"]) <= 0.0, "an empty roster reports no framing")

	# A lone fighter must not slam to MAX_ZOOM. The floor box exists for exactly
	# this case, and losing it reads as "the camera is weird when I am alone",
	# which nobody files as a bug.
	var one := CameraRig.frame_for([Vector2(100.0, 100.0)], view)
	var ext_one := CameraRig.extent_for(Vector2.ZERO)
	var expect_one: float = minf(view.x / ext_one.x, view.y / ext_one.y)
	ok(absf(float(one["zoom"]) - expect_one) < 0.001,
		"a lone fighter frames on the minimum box (%.3f vs %.3f)" % [one["zoom"], expect_one])
	ok(float(one["zoom"]) < CameraRig.MAX_ZOOM, "a lone fighter does not hit max zoom")
	ok(one["center"] == Vector2(100.0, 100.0), "a lone fighter is centred")
	info("minimum framing extent = %s" % ext_one)

	var near := CameraRig.frame_for([Vector2(0.0, 0.0), Vector2(60.0, 0.0)], view)
	var far := CameraRig.frame_for([Vector2(0.0, 0.0), Vector2(420.0, 0.0)], view)
	ok(float(near["zoom"]) > float(far["zoom"]), "closer fighters are framed tighter")
	ok(absf(float(near["center"].x) - 30.0) < 0.001, "a pair is centred between them")
	# Asserts against the runtime formula, not a hand-copied duplicate: the first
	# version of this test recomputed the expected zoom with its own arithmetic
	# and failed on a camera that was correct.
	var ext_far := CameraRig.extent_for(Vector2(420.0, 0.0))
	var expect_far: float = minf(view.x / ext_far.x, view.y / ext_far.y)
	ok(absf(float(far["zoom"]) - expect_far) < 0.01,
		"a wide split is framed by its widest axis (%.3f vs %.3f)" % [far["zoom"], expect_far])
	ok(ext_far.x > ext_far.y, "a horizontal split is limited by the horizontal extent")

	var stacked := CameraRig.frame_for([Vector2(0.0, 0.0), Vector2(0.0, 0.0)], view)
	ok(float(stacked["zoom"]) <= CameraRig.MAX_ZOOM + 0.0001, "a stacked pair stays under max zoom")
	var huge := CameraRig.frame_for([Vector2(-9000.0, -9000.0), Vector2(9000.0, 9000.0)], view)
	ok(float(huge["zoom"]) >= CameraRig.MIN_ZOOM - 0.0001, "a huge spread stays over min zoom")

	var bounds := Rect2(Vector2.ZERO, Vector2(544.0, 544.0))
	var far_out := CameraRig.clamp_to_bounds(Vector2(-500.0, -500.0), 1.6, view, bounds)
	ok(far_out.x >= 0.0 and far_out.y >= 0.0, "the camera cannot leave the arena")
	var half := view / 1.6 * 0.5
	ok(absf(far_out.x - half.x) < 0.001, "clamped to the arena edge, not past it")
	# A view bigger than the arena must centre on the arena rather than clamping
	# to a range whose min exceeds its max - `clamp()` in that case silently
	# returns the max, which parks the camera in a corner.
	var tiny := Rect2(Vector2.ZERO, Vector2(120.0, 120.0))
	var centred := CameraRig.clamp_to_bounds(Vector2(1000.0, 1000.0), 1.0, view, tiny)
	ok(centred == tiny.get_center(), "an arena smaller than the view is centred")
	info("lone=%.2f tight=%.2f wide=%.2f clamped=%s" % [
		one["zoom"], near["zoom"], far["zoom"], far_out])


func _check_camera_node() -> void:
	var rig := CameraRig.new()
	add_child(rig)
	ok(rig.is_inside_tree(), "camera rig enters the tree")
	var view := rig.get_viewport_rect().size
	ok(view.x > 1.0 and view.y > 1.0, "viewport reports a usable size (%s)" % view)
	rig.snap_now()
	ok(rig.zoom.x > 0.0, "camera has a positive zoom")
	ok(rig.get_viewport_rect().size.x > 0.0, "camera still resolves its viewport")
	rig.queue_free()
	await get_tree().process_frame


# ===========================================================================
# arena + navigation
# ===========================================================================

func _check_arena() -> void:
	var arena := Arena.new()
	add_child(arena)
	ok(arena.is_inside_tree(), "arena actually entered the tree")
	arena.build(MapGenerator.generate(0))
	ok(arena.size == MapGenerator.MINIMAL_SIZE, "arena reports the right size")
	ok(arena.is_in_group(Arena.GROUP), "arena registers itself in the '%s' group" % Arena.GROUP)
	ok(get_tree().get_first_node_in_group(Arena.GROUP) == arena,
		"the arena is findable by group lookup")
	ok(arena.open_cell_count() > 0, "arena has open cells")
	ok(arena.has_nav(), "arena built a nav grid")
	ok(arena.human_cells.size() >= 2, "human spawns survived the prop pass")
	ok(arena.bot_cells.size() >= 2, "bot spawns survived the prop pass")
	ok(arena.world_rect().size.x > 0.0, "arena reports a world rect")

	for c in arena.human_cells:
		if not arena.is_walkable_pos(arena.cell_center(c)):
			ok(false, "human spawn %s is not standable" % c)
	ok(true, "every human spawn is standable")
	for c in arena.bot_cells:
		if not arena.is_walkable_pos(arena.cell_center(c)):
			ok(false, "bot spawn %s is not standable" % c)
	ok(true, "every bot spawn is standable")

	# Walkability must agree with the grid cell for cell. If these ever diverge,
	# the AI is playing a different map from the player.
	var bad := 0
	for y in arena.size:
		for x in arena.size:
			var cell := Vector2i(x, y)
			var walk := arena.is_walkable_cell(cell)
			var solid := MapGenerator.at(arena.grid, arena.size, x, y) != MapGenerator.F_FLOOR
			if walk == solid:
				bad += 1
	ok(bad == 0, "walkability agrees with the grid everywhere (%d mismatches)" % bad)
	info("arena: %s" % arena.describe())
	arena.queue_free()
	await get_tree().process_frame


## Decoration density, checked over several seeds because it is a *density* rule
## and one seed can easily look fine while another is a disaster.
##
## The rule that matters: hazard stripes only earn their tile on a short doorway,
## never along a long one-tile-wide tunnel. Choking every third cell of a 20-cell
## tunnel painted 23 stripes into the lower-right corner of a seeded arena - a
## striped racetrack that read as a missing-texture bug. The minimum arena is the
## worst case because it is the most open, so it is checked with the tightest
## budget; seeded arenas are checked against their own floor area.
func _check_decoration() -> void:
	# NOTE: no `await` anywhere in this function on purpose. `_ready()` runs every
	# check, calls `_report()` and quits in the same frame, so a check that
	# suspends half way through has its remaining assertions silently dropped -
	# and `_run()`'s "did anything get asserted?" guard cannot catch it, because
	# the assertions before the await already moved the counter. Arenas are left
	# to `queue_free()` at end of frame instead.
	var worst_ratio := 0.0
	var worst_seed := 0
	var total_haz := 0
	var total_floor := 0

	# --- minimal arena: the most open map, so the fewest stripes of all -------
	var minimal := Arena.new()
	add_child(minimal)
	minimal.build(MapGenerator.generate(0))
	var m_floor := minimal.open_cell_count()
	var m_haz := minimal.count_marks("hazard_v") + minimal.count_marks("hazard_h")
	ok(m_floor > 0, "the minimal arena has floor to decorate")
	ok(m_haz * 40 <= m_floor,
		"minimal arena is not carpeted in hazard stripes (%d stripes / %d floor)" % [m_haz, m_floor])
	ok(minimal.count_marks("spawn_human") >= 2, "human spawn markers survived")
	ok(minimal.count_marks("spawn_bot") >= 2, "bot spawn markers survived")
	info("minimal arena: %d floor, %d hazard stripes" % [m_floor, m_haz])
	minimal.queue_free()

	# --- seeded arenas: the shape that actually regressed --------------------
	# Long one-tile-wide tunnels only ever form on the seeded maps, and the old
	# per-cell `h % 3` rule stamped a stripe into every third cell of them.
	for i in range(1, 13):
		var seed_value := i * 7919
		var arena := Arena.new()
		add_child(arena)
		arena.build(MapGenerator.generate(seed_value))
		var floor_cells := arena.open_cell_count()
		var haz := arena.count_marks("hazard_v") + arena.count_marks("hazard_h")
		total_haz += haz
		total_floor += floor_cells
		var ratio := float(haz) / maxf(1.0, float(floor_cells))
		if ratio > worst_ratio:
			worst_ratio = ratio
			worst_seed = seed_value
		ok(haz * 25 <= floor_cells,
			"seed %d: hazard stripes stay sparse (%d stripes / %d floor)" % [
				seed_value, haz, floor_cells])
		arena.queue_free()
	ok(worst_ratio <= 0.03,
		"no seeded arena exceeds 3%% hazard coverage (worst %.2f%% on seed %d)" % [
			worst_ratio * 100.0, worst_seed])
	info("12 seeded arenas: %d hazard stripes over %d floor cells, worst coverage %.2f%% (seed %d)" % [
		total_haz, total_floor, worst_ratio * 100.0, worst_seed])


func _check_navigation() -> void:
	var arena := Arena.new()
	add_child(arena)
	arena.build(MapGenerator.generate(0))

	var hs := arena.spawn_points(Enums.Team.HUMANS)
	var bs := arena.spawn_points(Enums.Team.BOTS)
	ok(not hs.is_empty() and not bs.is_empty(), "both teams have spawn points")

	var empty_paths := 0
	var off_grid := 0
	for h in hs:
		for b in bs:
			var p := arena.path_to(h, b)
			if p.size() == 0:
				empty_paths += 1
				continue
			for i in p.size():
				if not arena.is_walkable_cell(Utils.tile_of(p[i])):
					off_grid += 1
	ok(empty_paths == 0, "every spawn-to-spawn route exists (%d empty)" % empty_paths)
	ok(off_grid == 0, "every waypoint sits in a walkable cell (%d off-grid)" % off_grid)

	# The first waypoint must be where the agent is, not the centre of its own
	# cell: the raw A* output starts at that centre, and walking to it first is a
	# visible backwards step whenever the agent stands near a cell edge.
	var probe_from := hs[0] + Vector2(6.0, 6.0)
	var p0 := arena.path_to(probe_from, bs[0])
	ok(p0.size() > 0 and p0[0] == probe_from, "the path starts at the caller's position")

	# A goal inside a wall must be snapped, not refused: the bot's look-ahead
	# target is `position + direction * 96` and is inside geometry most of the time.
	var wall_cell := Vector2i(-1, -1)
	for y in arena.size:
		for x in arena.size:
			if not arena.is_walkable_cell(Vector2i(x, y)):
				wall_cell = Vector2i(x, y)
				break
		if wall_cell.x >= 0:
			break
	ok(wall_cell.x >= 0, "found a wall cell to test goal snapping against")
	ok(arena.path_to(hs[0], arena.cell_center(wall_cell)).size() > 0,
		"a goal inside a wall is snapped to a reachable cell")

	ok(arena.path_to(hs[0], Vector2(-500.0, -500.0)).size() > 0,
		"a far out-of-bounds goal still routes")
	ok(not arena.is_walkable_pos(Vector2(-40.0, -40.0)),
		"out-of-bounds positions are not walkable")

	var bad_snap := 0
	var tested := 0
	for y in arena.size:
		for x in arena.size:
			var cell := Vector2i(x, y)
			if arena.is_walkable_cell(cell):
				continue
			tested += 1
			var p := arena.nearest_open_pos(arena.cell_center(cell))
			if p != Vector2.INF and not arena.is_walkable_pos(p):
				bad_snap += 1
			if tested >= 300:
				break
		if tested >= 300:
			break
	ok(bad_snap == 0, "nearest_open_pos always returns a standable spot (%d bad)" % bad_snap)
	ok(arena.nearest_open_pos(Vector2(-90.0, -90.0)) != Vector2.INF,
		"nearest_open_pos recovers from out of bounds")

	# is_walkable_pos must be radius-aware. A point 1 px from a wall face is
	# "inside a floor tile" but no body can stand there, and a bot that picks it
	# as a cover spot grinds into the wall for a second.
	#
	# Regression guard for a default-argument trap: writing
	# `radius: float = Balance.BODY_RADIUS` parses fine but evaluates the default
	# to 0.0, silently downgrading every call site to a bare cell test. The two
	# calls below must disagree.
	var near_wall := _find_near_wall_pos(arena)
	ok(near_wall != Vector2.INF, "found a point parked against a wall")
	if near_wall != Vector2.INF:
		var solid_above := Utils.tile_of(near_wall) + Vector2i(0, -1)
		ok(not arena.is_walkable_cell(solid_above),
			"the point really does sit against a wall (%s is solid)" % solid_above)
		ok(arena.is_walkable_pos(near_wall, 0.0),
			"the point is inside a floor tile (cell test says yes)")
		ok(not arena.is_walkable_pos(near_wall, Balance.BODY_RADIUS),
			"a point tight against a wall is rejected for a body-sized actor")
		ok(not arena.is_walkable_pos(near_wall),
			"the default radius behaves like the body radius")
		info("near-wall probe: pos=%s wall_cell=%s radius=%.1f" % [
			near_wall, solid_above, Balance.BODY_RADIUS])

	# Language fact worth pinning down rather than assuming: does a default
	# argument that references ANOTHER class's `const` actually resolve? If it
	# silently became 0.0, every `radius: float = Balance.BODY_RADIUS` style
	# default in the project would be quietly wrong.
	ok(_default_arg_probe() == Balance.BODY_RADIUS,
		"a cross-class const as a default argument resolves (%f vs %f)" % [
			_default_arg_probe(), Balance.BODY_RADIUS])

	var sealed := PackedByteArray()
	sealed.resize(9 * 9)
	sealed.fill(MapGenerator.F_WALL)
	var a2 := Arena.new()
	add_child(a2)
	a2.build({
		"size": 9, "grid": sealed, "ground": PackedByteArray(),
		"props": [], "humans": [], "bots": [], "kind": "sealed", "name": "sealed",
		"seed": 0,
	})
	ok(a2.has_nav(), "a fully-walled map still produces a nav grid")
	ok(a2.nearest_open_pos(Vector2(40.0, 40.0)) == Vector2.INF,
		"a fully-walled map honestly reports that there is nowhere to stand")
	ok(a2.spawn_point(Enums.Team.HUMANS, 0) == a2.center_pos(),
		"a spawnless map falls back to the centre")
	ok(a2.path_to(Vector2(40.0, 40.0), Vector2(80.0, 80.0)).size() == 0,
		"a fully-walled map yields no path instead of a bogus one")
	a2.queue_free()
	arena.queue_free()
	await get_tree().process_frame


## Files the game needs at runtime that the exporter does not recognise.
##
## `export_filter="all_resources"` ships what the engine considers a resource,
## and it does not consider `.py` or `.btp` to be one. So the whole vendored BTPS
## runtime plus `bridge.py` were left out of the exe: the plugin host would boot,
## fail to find `bridge.py`, and sit in ERROR forever - while every test stayed
## green, because the tests run from the project directory where those files do
## exist on disk. A shipped build with a dead feature and a green suite is the
## worst combination there is, so the fix is pinned here instead of in a
## checklist nobody reads.
##
## `include_filter` is what makes it work. This asserts the two halves stay in
## step: the preset keeps the patterns, and the files still exist.
func _check_exportable_resources() -> void:
	var preset := FileAccess.get_file_as_string("res://export_presets.cfg")
	ok(preset.contains("*.py"),
		"export_presets.cfg keeps .py files (the BTPS runtime is not a Godot resource)")
	ok(preset.contains("*.btp"), "export_presets.cfg keeps .btp plugin packages")
	# `all_resources` alone would drop them again the moment someone "tidied up"
	# the include list, and the failure is invisible until a player opens the
	# plugin panel.
	ok(preset.contains("export_filter=\"all_resources\""),
		"the export filter is still all_resources (this check assumes that)")
	# The files themselves: a rename that missed the preset would ship a host
	# pointing at a path that no longer exists.
	ok(FileAccess.file_exists("res://assets/btps_runtime/bridge.py"),
		"the Python bridge is where the host expects it")
	ok(FileAccess.file_exists("res://assets/btps_runtime/VERSION"),
		"the runtime version stamp is present (it gates re-extraction)")
	ok(FileAccess.file_exists("res://assets/btps_runtime/btps/__init__.py"),
		"the vendored BTPS package is importable from the released runtime")
	ok(FileAccess.file_exists("res://assets/btps_samples/example-bot-1.0.0.btp"),
		"the sample plugin package ships with the game")
	# The one thing a path typo would break quietly.
	var host_script := FileAccess.get_file_as_string("res://src/btps/btps_host.gd")
	ok(host_script.contains("res://assets/btps_runtime"),
		"the host releases the runtime from the path that is actually shipped")


## A position 1 px outside a wall face: the cell containing it is open, but a
## body parked there overlaps the wall.
##
## The guard reads `if walkable(above): continue` - i.e. keep only cells whose
## northern neighbour is SOLID. The first version of this helper had the test
## inverted (`if not walkable(above): continue`), which selected cells whose
## neighbour was open, then asserted that a body-sized probe is rejected at a
## point that had nothing near it. The assertion failed and the helper looked
## like it had found a real bug in `is_walkable_pos`. It had not.
func _find_near_wall_pos(arena: Arena) -> Vector2:
	for y in range(1, arena.size - 1):
		for x in range(1, arena.size - 1):
			var cell := Vector2i(x, y)
			if not arena.is_walkable_cell(cell):
				continue
			if arena.is_walkable_cell(cell + Vector2i(0, -1)):
				continue
			# 1 px below the wall's bottom edge, i.e. just inside this cell
			return Vector2(float(x * Utils.TILE) + 8.0, float(y * Utils.TILE) + 1.0)
	return Vector2.INF
