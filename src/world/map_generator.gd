class_name MapGenerator
extends RefCounted
## Deterministic arena generation.
##
## Two modes, matching the requested design:
##   * seed 0  -> "minimal arena": a hand-shaped, 4-fold symmetric layout. It is
##                deliberately sparse, but NOT literally empty - an arena with
##                zero geometry makes the bot's "uses terrain" requirement
##                impossible to satisfy and turns every duel into a coin flip.
##                Symmetry also means neither team gets a better half, which
##                matters when the whole point is humans vs bots.
##   * seed != 0 -> Minecraft-style pure random layout from a text or numeric
##                seed. Same seed, same map, on every machine.
##
## The generator never emits a map with an unreachable pocket: after carving it
## computes connected components, keeps the largest one, and seals the rest.
## Without that step a random blueprint can wall off a chunk of floor and the
## bots will path into a dead pocket forever, which looks exactly like "the AI is
## broken" rather than "the map is broken".

const F_FLOOR: int = 0
const F_WALL: int = 1
const F_PROP: int = 2

const MINIMAL_SIZE: int = 34
const SEEDED_SIZE: int = 56
const SEEDED_SECTION: int = 14

const KIND_MINIMAL: String = "minimal"
const KIND_SEEDED: String = "seeded"


static func generate(seed_value: int) -> Dictionary:
	if seed_value == 0:
		return _minimal()
	return _seeded(seed_value)


# ===========================================================================
# minimal arena
# ===========================================================================

## Rectangles for one quadrant, mirrored four ways for perfect symmetry.
## (x, y, w, h) in tile coordinates.
const QUADRANT_COVER: Array = [
	[7, 12, 4, 1],
	[12, 7, 1, 4],
	[5, 5, 3, 3],
	[13, 13, 2, 2],
	[2, 14, 3, 1],
	[14, 3, 1, 3],
]


static func _minimal() -> Dictionary:
	var n := MINIMAL_SIZE
	var grid := PackedByteArray()
	grid.resize(n * n)
	grid.fill(F_FLOOR)

	# border
	for i in n:
		_put(grid, n, i, 0, F_WALL)
		_put(grid, n, i, n - 1, F_WALL)
		_put(grid, n, 0, i, F_WALL)
		_put(grid, n, n - 1, i, F_WALL)

	# mirrored cover: four copies of the same quadrant, so the layout has
	# 180-degree and mirror symmetry about both axes
	for r: Array in QUADRANT_COVER:
		var x := int(r[0])
		var y := int(r[1])
		var w := int(r[2])
		var h := int(r[3])
		_fill_rect(grid, n, x, y, w, h, F_WALL)
		_fill_rect(grid, n, n - x - w, y, w, h, F_WALL)
		_fill_rect(grid, n, x, n - y - h, w, h, F_WALL)
		_fill_rect(grid, n, n - x - w, n - y - h, w, h, F_WALL)

	var out := _finalize(grid, n, 0x51E1D, true)
	out["kind"] = KIND_MINIMAL
	out["name"] = "Minimal Arena"
	out["seed"] = 0
	return out


# ===========================================================================
# seeded arena
# ===========================================================================

static func _seeded(seed_value: int) -> Dictionary:
	var n := SEEDED_SIZE
	var rng := Utils.rng(seed_value)
	var grid := PackedByteArray()
	grid.resize(n * n)
	grid.fill(F_FLOOR)

	for i in n:
		_put(grid, n, i, 0, F_WALL)
		_put(grid, n, i, n - 1, F_WALL)
		_put(grid, n, 0, i, F_WALL)
		_put(grid, n, n - 1, i, F_WALL)

	var sec := SEEDED_SECTION
	var blocks := n / sec
	for by in blocks:
		for bx in blocks:
			var ox := bx * sec
			var oy := by * sec
			var roll := rng.randf()
			if roll < 0.26:
				_build_building(grid, n, ox, oy, sec, rng)
			elif roll < 0.54:
				_build_cover_field(grid, n, ox, oy, sec, rng)
			elif roll < 0.76:
				_build_corridors(grid, n, ox, oy, sec, rng)
			else:
				_build_open(grid, n, ox, oy, sec, rng)

	var out := _finalize(grid, n, seed_value, false)
	out["kind"] = KIND_SEEDED
	out["name"] = "Seed %d" % seed_value
	out["seed"] = seed_value
	return out


static func _build_building(grid: PackedByteArray, n: int, ox: int, oy: int,
		s: int, rng: RandomNumberGenerator) -> void:
	var margin := rng.randi_range(1, 3)
	var x := ox + margin
	var y := oy + margin
	var w := s - margin * 2
	var h := s - margin * 2
	if w < 6 or h < 6:
		return
	# outer ring
	_fill_rect(grid, n, x, y, w, 1, F_WALL)
	_fill_rect(grid, n, x, y + h - 1, w, 1, F_WALL)
	_fill_rect(grid, n, x, y, 1, h, F_WALL)
	_fill_rect(grid, n, x + w - 1, y, 1, h, F_WALL)
	# doorways punched into the ring. Generated DURING construction, not carved
	# afterwards into a finished wall - post-hoc holes reliably produce openings
	# that lead nowhere.
	var doors := rng.randi_range(2, 3)
	for _d in doors:
		var side := rng.randi_range(0, 3)
		var span := 2
		match side:
			0:
				var dx := rng.randi_range(x + 1, x + w - span - 1)
				_fill_rect(grid, n, dx, y, span, 1, F_FLOOR)
			1:
				var dx2 := rng.randi_range(x + 1, x + w - span - 1)
				_fill_rect(grid, n, dx2, y + h - 1, span, 1, F_FLOOR)
			2:
				var dy := rng.randi_range(y + 1, y + h - span - 1)
				_fill_rect(grid, n, x, dy, 1, span, F_FLOOR)
			_:
				var dy2 := rng.randi_range(y + 1, y + h - span - 1)
				_fill_rect(grid, n, x + w - 1, dy2, 1, span, F_FLOOR)
	# interior pillars -> an inner ring you can circle, which gives the AI
	# something to orbit instead of standing in a doorway
	if w >= 9 and h >= 9:
		for _p in rng.randi_range(2, 4):
			var px := rng.randi_range(x + 3, x + w - 4)
			var py := rng.randi_range(y + 3, y + h - 4)
			_fill_rect(grid, n, px, py, rng.randi_range(1, 2), rng.randi_range(1, 2), F_WALL)


static func _build_cover_field(grid: PackedByteArray, n: int, ox: int, oy: int,
		s: int, rng: RandomNumberGenerator) -> void:
	# Orthogonal shapes only. Random-angle blocks read as noise at 16 px tiles;
	# an L or a short wall reads instantly and is what makes a chase legible.
	var count := rng.randi_range(3, 5)
	for _i in count:
		var px := ox + rng.randi_range(2, s - 4)
		var py := oy + rng.randi_range(2, s - 4)
		var horizontal := rng.randf() < 0.5
		var ln := rng.randi_range(3, 5)
		if horizontal:
			_fill_rect(grid, n, px, py, ln, 1, F_WALL)
			# L bend
			_fill_rect(grid, n, px, py, 1, rng.randi_range(2, 3), F_WALL)
		else:
			_fill_rect(grid, n, px, py, 1, ln, F_WALL)
			_fill_rect(grid, n, px, py, rng.randi_range(2, 3), 1, F_WALL)


static func _build_corridors(grid: PackedByteArray, n: int, ox: int, oy: int,
		s: int, rng: RandomNumberGenerator) -> void:
	var lines := rng.randi_range(2, 3)
	for _i in lines:
		if rng.randf() < 0.5:
			var y := oy + rng.randi_range(3, s - 4)
			var gap := rng.randi_range(ox + 2, ox + s - 4)
			_fill_rect(grid, n, ox + 1, y, gap - ox - 1, 1, F_WALL)
			_fill_rect(grid, n, gap + 2, y, ox + s - gap - 3, 1, F_WALL)
		else:
			var x := ox + rng.randi_range(3, s - 4)
			var gap2 := rng.randi_range(oy + 2, oy + s - 4)
			_fill_rect(grid, n, x, oy + 1, 1, gap2 - oy - 1, F_WALL)
			_fill_rect(grid, n, x, gap2 + 2, 1, oy + s - gap2 - 3, F_WALL)


static func _build_open(grid: PackedByteArray, n: int, ox: int, oy: int,
		s: int, rng: RandomNumberGenerator) -> void:
	for _i in rng.randi_range(0, 2):
		var px := ox + rng.randi_range(3, s - 4)
		var py := oy + rng.randi_range(3, s - 4)
		_fill_rect(grid, n, px, py, rng.randi_range(1, 2), rng.randi_range(1, 2), F_WALL)


# ===========================================================================
# shared finishing pass
# ===========================================================================

static func _finalize(grid: PackedByteArray, n: int, seed_for_ground: int,
		symmetric: bool) -> Dictionary:
	var sealed := _seal_unreachable(grid, n)
	# Components are computed ONCE and threaded through every later pass. Each
	# pass used to recompute them on its own, which meant three full O(n^2)
	# flood fills per map and, worse, three chances to disagree about which
	# component is "main".
	var info := components(sealed, n)
	var comp: PackedInt32Array = info["comp"]
	var main_id := int(info["main_id"])
	var props := _place_props(sealed, n, comp, main_id, seed_for_ground, symmetric)
	var ground := _ground_variants(n, seed_for_ground)
	var spawns := _spawn_sets(sealed, n, comp, main_id)
	return {
		"size": n,
		"grid": sealed,
		"comp": comp,
		"main_id": main_id,
		"props": props,
		"ground": ground,
		"humans": spawns[0],
		"bots": spawns[1],
	}


static func _put(grid: PackedByteArray, n: int, x: int, y: int, v: int) -> void:
	if x < 0 or y < 0 or x >= n or y >= n:
		return
	grid[y * n + x] = v


static func at(grid: PackedByteArray, n: int, x: int, y: int) -> int:
	if x < 0 or y < 0 or x >= n or y >= n:
		return F_WALL
	return grid[y * n + x]


static func _fill_rect(grid: PackedByteArray, n: int, x: int, y: int, w: int,
		h: int, v: int) -> void:
	for yy in range(y, y + h):
		for xx in range(x, x + w):
			_put(grid, n, xx, yy, v)


static func is_solid_cell(grid: PackedByteArray, n: int, c: Vector2i) -> bool:
	var v := at(grid, n, c.x, c.y)
	return v == F_WALL or v == F_PROP


## Flood-fill labels; -1 for anything solid.
static func _component_of(grid: PackedByteArray, n: int) -> PackedInt32Array:
	var comp := PackedInt32Array()
	comp.resize(n * n)
	comp.fill(-1)
	var next_id := 1
	var queue: Array[Vector2i] = []
	for y in n:
		for x in n:
			if at(grid, n, x, y) != F_FLOOR or comp[y * n + x] != -1:
				continue
			var id := next_id
			next_id += 1
			comp[y * n + x] = id
			queue.clear()
			queue.append(Vector2i(x, y))
			var head := 0
			while head < queue.size():
				var c: Vector2i = queue[head]
				head += 1
				for d: Vector2i in Utils.DIRS4:
					var nx := c.x + d.x
					var ny := c.y + d.y
					if nx < 0 or ny < 0 or nx >= n or ny >= n:
						continue
					if at(grid, n, nx, ny) != F_FLOOR:
						continue
					if comp[ny * n + nx] != -1:
						continue
					comp[ny * n + nx] = id
					queue.append(Vector2i(nx, ny))
	return comp


## Keep the BIGGEST walkable component and wall in everything else.
##
## Seeding this from "the first floor cell I happen to scan" is the bug that
## destroys maps: the first floor cell can easily sit inside a six-tile pocket,
## and then the entire real map is judged unreachable and filled in solid.
##
## `components()` is the single source of truth for "which component is main".
## It returns the label map, the winning id, and the per-id cell counts, so no
## caller ever has to re-derive any of it (and no two callers can disagree).
static func components(grid: PackedByteArray, n: int) -> Dictionary:
	var comp := _component_of(grid, n)
	var counts := {}
	for i in comp.size():
		var id := comp[i]
		if id > 0:
			counts[id] = int(counts.get(id, 0)) + 1
	var main_id := -1
	var main_count := -1
	for k in counts.keys():
		var c := int(counts[k])
		# Tie-break on the id so the choice is deterministic if two components
		# ever end up exactly equal in size.
		if c > main_count or (c == main_count and int(k) < main_id):
			main_count = c
			main_id = int(k)
	return {
		"comp": comp,
		"counts": counts,
		"main_id": main_id,
		"main_count": maxi(main_count, 0),
	}


## Seal everything outside the largest component.
static func _seal_unreachable(grid: PackedByteArray, n: int) -> PackedByteArray:
	var info := components(grid, n)
	var comp: PackedInt32Array = info["comp"]
	var main_id := int(info["main_id"])
	var out := grid.duplicate()
	if main_id < 0:
		return out
	for i in comp.size():
		if comp[i] > 0 and comp[i] != main_id:
			out[i] = F_WALL
	return out


## Props go only inside the main component, and never in a cell that would pinch
## a corridor shut. A prop in the wrong place is an unreachable-object metric
## failure and, worse, an invisible wall the AI will grind against.
##
## The "all four neighbours walkable" test is necessary but NOT sufficient: a
## cell whose four neighbours are open can still be an articulation point, so
## dropping a solid crate on it splits one open region into two. That failure is
## invisible in every metric the generator reports - the floor count is
## unchanged, openness is unchanged - and it shows up only as bots walking a long
## way around or not at all. So every accepted prop is verified by re-running the
## connected components and comparing the main component's size: it may shrink by
## exactly the number of cells the prop occupied and no more, or the prop is
## reverted.
##
## `symmetric` commits each prop at all four mirrored cells or not at all. The
## minimal arena is the balanced default, and one crate on the human side decides
## duels; the seeded maps are meant to be lopsided and interesting, so they place
## props one at a time.
static func _place_props(grid: PackedByteArray, n: int, comp: PackedInt32Array,
		main_id: int, seed_value: int, symmetric: bool) -> Array:
	var rng := Utils.rng(seed_value * 31 + 7)
	var out: Array = []
	if main_id < 0:
		return out
	var budget := 0
	for i in comp.size():
		if comp[i] == main_id:
			budget += 1
	var max_props := 24 if symmetric else 26
	var attempts := int(n * n * 0.06)
	for _i in attempts:
		var x := rng.randi_range(2, n - 3)
		var y := rng.randi_range(2, n - 3)
		var kind := "crate" if rng.randf() < 0.55 else "barrel"
		var cells := _prop_group(Vector2i(x, y), n, symmetric)
		if not _group_placeable(grid, n, comp, main_id, cells):
			continue
		for c in cells:
			grid[c.y * n + c.x] = F_PROP
		var now := int(components(grid, n)["main_count"])
		if now != budget - cells.size():
			for c in cells:
				grid[c.y * n + c.x] = F_FLOOR
			continue
		budget = now
		for c in cells:
			out.append({"cell": c, "kind": kind})
		if out.size() >= max_props:
			break
	return out


## The cells a single prop decision occupies: one, or the four mirror images.
static func _prop_group(cell: Vector2i, n: int, symmetric: bool) -> Array[Vector2i]:
	var out: Array[Vector2i] = [cell]
	if not symmetric:
		return out
	var seen := {cell: true}
	for c: Vector2i in [
		Vector2i(n - 1 - cell.x, cell.y),
		Vector2i(cell.x, n - 1 - cell.y),
		Vector2i(n - 1 - cell.x, n - 1 - cell.y),
	]:
		if not seen.has(c):
			seen[c] = true
			out.append(c)
	return out


static func _group_placeable(grid: PackedByteArray, n: int, comp: PackedInt32Array,
		main_id: int, cells: Array[Vector2i]) -> bool:
	for c: Vector2i in cells:
		if c.x < 1 or c.y < 1 or c.x >= n - 1 or c.y >= n - 1:
			return false
		if comp[c.y * n + c.x] != main_id:
			return false
		if at(grid, n, c.x, c.y) != F_FLOOR:
			return false
		for d: Vector2i in Utils.DIRS4:
			if at(grid, n, c.x + d.x, c.y + d.y) != F_FLOOR:
				return false
	return true


## Value-noise ground variants. Per-cell `randi()` produces television snow;
## low-frequency noise produces "a dominant tone with patches", which is what
## reads as a floor.
static func _ground_variants(n: int, seed_value: int) -> PackedByteArray:
	var nz := FastNoiseLite.new()
	nz.seed = seed_value if seed_value != 0 else 0x51E1D
	nz.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	nz.frequency = 0.026
	nz.fractal_octaves = 3
	var out := PackedByteArray()
	out.resize(n * n)
	for y in n:
		for x in n:
			var v: float = (nz.get_noise_2d(float(x), float(y)) + 1.0) * 0.5
			v = pow(v, 1.6)
			out[y * n + x] = clampi(int(v * 4.0), 0, 3)
	return out


static func _spawn_sets(grid: PackedByteArray, n: int, comp: PackedInt32Array,
		main_id: int) -> Array:
	return [
		_spawns_on_side(grid, n, comp, main_id, true),
		_spawns_on_side(grid, n, comp, main_id, false),
	]


static func _spawns_on_side(_grid: PackedByteArray, n: int, comp: PackedInt32Array,
		main_id: int, left: bool) -> Array:
	var out: Array = []
	var want := 4
	var spacing := float(n) / float(want + 1)
	for i in want:
		var y := int(round(spacing * float(i + 1)))
		var found := false
		for depth in range(1, 9):
			var x := depth if left else n - 1 - depth
			if y < 0 or y >= n or x < 0 or x >= n:
				continue
			if comp[y * n + x] == main_id:
				out.append(Vector2i(x, y))
				found = true
				break
		if not found:
			# fall back: nearest reachable cell to the ideal spot
			var best := Vector2i(-1, -1)
			var best_d := 1e9
			for yy in n:
				for xx in n:
					if comp[yy * n + xx] != main_id:
						continue
					var side_ok := (xx < n / 2) if left else (xx >= n / 2)
					if not side_ok:
						continue
					var dd := absf(float(yy - y)) + absf(float(xx - (3 if left else n - 4))) * 0.4
					if dd < best_d:
						best_d = dd
						best = Vector2i(xx, yy)
			if best.x >= 0:
				out.append(best)
	return out


# ===========================================================================
# diagnostics
# ===========================================================================

## Machine-checkable map quality report. Used by the headless self-check and by
## `--dump-map`.
##
## Note the metric choice: "openness" (fraction of walkable cells) is a trap,
## because buildings are hollow and their interiors count as walkable - filling a
## map with buildings barely moves that number. Mean distance-to-nearest-wall is
## what actually detects "this map feels empty".
static func analyze(data: Dictionary) -> Dictionary:
	var n := int(data["size"])
	var grid: PackedByteArray = data["grid"]
	var info := components(grid, n)
	var comp: PackedInt32Array = data.get("comp", info["comp"])
	var counts: Dictionary = info["counts"]
	var main_id := int(info["main_id"])
	var main_count := int(info["main_count"])
	var total_floor := 0
	for k in counts.keys():
		total_floor += int(counts[k])

	var dist := _wall_distance(grid, n)
	var sum := 0.0
	var counted := 0
	var corridors := 0
	var dead_ends := 0
	for y in n:
		for x in n:
			if grid[y * n + x] != F_FLOOR:
				continue
			var d := dist[y * n + x]
			sum += float(d)
			counted += 1
			var open_neighbors := 0
			for dd: Vector2i in Utils.DIRS4:
				if at(grid, n, x + dd.x, y + dd.y) == F_FLOOR:
					open_neighbors += 1
			if open_neighbors == 2:
				corridors += 1
			elif open_neighbors == 1:
				dead_ends += 1

	var props: Array = data.get("props", [])
	var unreachable := 0
	for p in props:
		var c: Vector2i = p["cell"]
		var reachable := false
		for dd: Vector2i in Utils.DIRS4:
			var nx := c.x + dd.x
			var ny := c.y + dd.y
			if nx < 0 or ny < 0 or nx >= n or ny >= n:
				continue
			if comp[ny * n + nx] == main_id:
				reachable = true
		if not reachable:
			unreachable += 1

	return {
		"size": n,
		"floor": total_floor,
		"main_floor": main_count,
		"main_fraction": float(main_count) / maxf(1.0, float(total_floor)),
		"avg_wall_dist": sum / maxf(1.0, float(counted)),
		"corridor_cells": corridors,
		"corridor_ratio": float(corridors) / maxf(1.0, float(counted)),
		"dead_ends": dead_ends,
		"dead_end_ratio": float(dead_ends) / maxf(1.0, float(counted)),
		"props": props.size(),
		"unreachable_props": unreachable,
		"components": counts.size(),
	}


static func _wall_distance(grid: PackedByteArray, n: int) -> PackedInt32Array:
	var dist := PackedInt32Array()
	dist.resize(n * n)
	dist.fill(-1)
	var queue: Array[Vector2i] = []
	for y in n:
		for x in n:
			# props count as blockers too - a crate in the open is cover, and
			# the metric is supposed to answer "how exposed does this feel"
			if grid[y * n + x] != F_FLOOR:
				dist[y * n + x] = 0
				queue.append(Vector2i(x, y))
	var head := 0
	while head < queue.size():
		var c: Vector2i = queue[head]
		head += 1
		for d: Vector2i in Utils.DIRS4:
			var nx := c.x + d.x
			var ny := c.y + d.y
			if nx < 0 or ny < 0 or nx >= n or ny >= n:
				continue
			if dist[ny * n + nx] != -1:
				continue
			dist[ny * n + nx] = dist[c.y * n + c.x] + 1
			queue.append(Vector2i(nx, ny))
	return dist


## Render a map to a small PNG for eyeballing. Debug tooling only.
static func render_preview(data: Dictionary, path: String) -> void:
	var n := int(data["size"])
	var grid: PackedByteArray = data["grid"]
	var ground: PackedByteArray = data.get("ground", PackedByteArray())
	var cv := Canvas.new(n, n)
	for y in n:
		for x in n:
			var v := grid[y * n + x]
			var col := Color(0.10, 0.11, 0.13, 1.0)
			if v == F_FLOOR:
				var g := 0
				if ground.size() == n * n:
					g = ground[y * n + x]
				col = Color(0.14 + 0.02 * g, 0.15 + 0.02 * g, 0.17 + 0.02 * g, 1.0)
			elif v == F_WALL:
				col = Color(0.45, 0.47, 0.52, 1.0)
			elif v == F_PROP:
				col = Color(0.65, 0.45, 0.25, 1.0)
			cv.set_px(x, y, col)
	for c in data.get("humans", []):
		cv.set_px(c.x, c.y, Color(0.31, 0.84, 0.94, 1.0))
	for c in data.get("bots", []):
		cv.set_px(c.x, c.y, Color(0.94, 0.44, 0.31, 1.0))
	cv.save_png(path)


## Tiny helper so this file does not have to depend on the tools/ Python code.
class Canvas extends RefCounted:
	var w: int
	var h: int
	var px: PackedColorArray

	func _init(_w: int, _h: int) -> void:
		w = _w
		h = _h
		px.resize(w * h)
		px.fill(Color(0, 0, 0, 1))

	func set_px(x: int, y: int, c: Color) -> void:
		if x < 0 or y < 0 or x >= w or y >= h:
			return
		px[y * w + x] = c

	func save_png(path: String) -> void:
		var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
		for y in h:
			for x in w:
				img.set_pixel(x, y, px[y * w + x])
		img.save_png(path)
