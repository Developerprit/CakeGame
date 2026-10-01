class_name TileSetBuilder
extends RefCounted
## Builds the arena TileSet in code from the generated sprite manifest.
##
## Why code and not a `.tres`: every fact in the tile set is derived - which
## tiles exist comes from `sprite_manifest.json`, which of them are solid comes
## from one list here, and the collision inset comes from a constant. An authored
## resource would be a second source of truth that silently drifts the first time
## `tools/gen_sprites.py` adds a tile, and the symptom would be a quietly
## non-solid wall rather than an error.
##
## Verified API behaviour (Godot 4.5, probed in headless):
##   * `TileSet.add_physics_layer()` / `add_occlusion_layer()` return **void**.
##     A new layer always lands at `count - 1`, so on a fresh TileSet the indices
##     are simply 0 and 0.
##   * `TileData.set_occluder(layer, polygon)` takes an `OccluderPolygon2D`
##     resource, NOT a `PackedVector2Array` (that was the Godot 3 signature).
##   * `TileSetAtlasSource.get_tile_data(coords, alternative)` only returns real
##     data once the source has been added to the TileSet, so the ordering in
##     `build()` is load-bearing.

const SOURCE_ID: int = 0
const PHYSICS_LAYER: int = 0
const OCCLUSION_LAYER: int = 0
const ALTERNATIVE: int = 0

## Collision is inset by this much per side rather than filling the whole cell.
## Coplanar neighbouring walls then share a small gap instead of an exactly
## coincident face, which is what stops a sliding `CharacterBody2D` from catching
## on the seam between two flush tiles.
const EDGE_INSET: float = 1.0

## Props are inset much further: a crate is a small object sitting in a cell, and
## a full-cell collider makes walking past one feel like a wall of crates.
const PROP_INSET: float = 3.0

## Occluders are separate from collision: a prop should block movement at its own
## size but only cast a small shadow.
const OCCLUDER_INSET: float = 1.0
const PROP_OCCLUDER_INSET: float = 4.0

## Tile names that stop movement. Everything else (floors, decals, hazard
## stripes, spawn pads, vents) is pure decoration and must NOT be solid. A solid
## list that accidentally includes a floor tile produces an arena where the AI
## navigates fine and the player cannot move, because the AI reads the grid while
## the player reads pixels.
const SOLID_TILES: Array[String] = [
	"wall_top", "wall_mid", "wall_bot",
	"wall_dark_top", "wall_dark_mid", "wall_dark_bot",
	"crate", "barrel", "pillar",
]

## Props, by the `kind` string MapGenerator writes into its prop list.
const PROP_TILES: Array[String] = ["crate", "barrel"]


## name -> atlas coords, straight out of the manifest.
static func name_to_coords() -> Dictionary:
	var out: Dictionary = {}
	var man := AtlasLibrary.manifest()
	var td: Dictionary = man.get("tiles", {})
	var idx: Dictionary = td.get("index", {})
	for key in idx.keys():
		var arr: Variant = idx[key]
		if typeof(arr) != TYPE_ARRAY:
			continue
		var a: Array = arr
		out[str(key)] = Vector2i(int(a[0]), int(a[1]))
	return out


## atlas coords -> name. Reverse of `name_to_coords()`.
static func coords_to_name() -> Dictionary:
	var out: Dictionary = {}
	var fwd := name_to_coords()
	for key in fwd.keys():
		out[fwd[key]] = key
	return out


## Atlas coords for a manifest tile name, with a loud failure mode. Silently
## painting `Vector2i(-1, -1)` gives an invisible tile, which reads in game as a
## map bug rather than a manifest bug.
static func coords_for(tile_name: String, index: Dictionary = {}) -> Vector2i:
	var idx := index if not index.is_empty() else name_to_coords()
	if not idx.has(tile_name):
		push_error("[TileSetBuilder] unknown tile name: %s" % tile_name)
		return Vector2i(-1, -1)
	return idx[tile_name]


static func build() -> TileSet:
	var man := AtlasLibrary.manifest()
	var td: Dictionary = man.get("tiles", {})
	var cols := int(td.get("cols", 0))
	var rows := int(td.get("rows", 0))
	var tile_size := int(td.get("frame_w", Utils.TILE))

	var ts := TileSet.new()
	ts.tile_size = Vector2i(tile_size, tile_size)

	# Layer order is fixed by the constants above: the TileData configured at the
	# bottom of this function resolves its physics / occlusion slots against the
	# layer list as it exists at that moment.
	ts.add_physics_layer()
	ts.set_physics_layer_collision_layer(PHYSICS_LAYER, Combat.WORLD_MASK)
	ts.set_physics_layer_collision_mask(PHYSICS_LAYER, Combat.WORLD_MASK)
	ts.add_occlusion_layer()
	ts.set_occlusion_layer_light_mask(OCCLUSION_LAYER, 1)

	var atlas_path := AtlasLibrary.tiles_texture_path()
	var tex: Texture2D = null
	if ResourceLoader.exists(atlas_path):
		tex = load(atlas_path) as Texture2D
	if tex == null:
		push_error("[TileSetBuilder] tiles atlas missing (run --import?): %s" % atlas_path)
		return ts

	var src := TileSetAtlasSource.new()
	src.texture = tex
	src.texture_region_size = Vector2i(tile_size, tile_size)
	# Every cell of the atlas gets a tile, not just the ones the manifest names.
	# A region the manifest forgot to name would otherwise be an unpaintable hole
	# that only shows up in game as "why is that wall invisible".
	for y in rows:
		for x in cols:
			src.create_tile(Vector2i(x, y))
	ts.add_source(src, SOURCE_ID)

	var by_coords := coords_to_name()
	for y in rows:
		for x in cols:
			var coords := Vector2i(x, y)
			var tile_name := str(by_coords.get(coords, ""))
			if tile_name.is_empty() or not SOLID_TILES.has(tile_name):
				continue
			_configure_solid(src, coords, tile_size, _is_prop_name(tile_name))
	return ts


static func _is_prop_name(tile_name: String) -> bool:
	return PROP_TILES.has(tile_name) or tile_name == "pillar"


static func _configure_solid(src: TileSetAtlasSource, coords: Vector2i,
		tile_size: int, is_prop: bool) -> void:
	var data := src.get_tile_data(coords, ALTERNATIVE)
	if data == null:
		return
	var half := float(tile_size) * 0.5
	var h := half - (PROP_INSET if is_prop else EDGE_INSET)
	data.add_collision_polygon(PHYSICS_LAYER)
	data.set_collision_polygon_points(PHYSICS_LAYER, 0, PackedVector2Array([
		Vector2(-h, -h), Vector2(h, -h), Vector2(h, h), Vector2(-h, h),
	]))
	var oh := half - (PROP_OCCLUDER_INSET if is_prop else OCCLUDER_INSET)
	var occ := OccluderPolygon2D.new()
	occ.closed = true
	occ.polygon = PackedVector2Array([
		Vector2(-oh, -oh), Vector2(oh, -oh), Vector2(oh, oh), Vector2(-oh, oh),
	])
	data.set_occluder(OCCLUSION_LAYER, occ)


## Which manifest names must exist for the arena to be paintable. Checked by the
## headless self-check so a manifest regression fails loudly instead of turning
## every wall into nothing.
const REQUIRED_TILES: Array[String] = [
	"floor_a", "floor_b", "floor_c", "floor_d", "floor_plate", "floor_grate",
	"wall_top", "wall_mid", "wall_bot",
	"wall_dark_top", "wall_dark_mid", "wall_dark_bot",
	"crate", "barrel", "pillar",
	"spawn_human", "spawn_bot",
	"decal_crack", "decal_dot", "decal_stripe", "decal_warn",
	"hazard_h", "hazard_v", "vent",
]


static func validate() -> Array[String]:
	var problems: Array[String] = []
	var idx := name_to_coords()
	for n in REQUIRED_TILES:
		if not idx.has(n):
			problems.append("tiles atlas is missing '%s'" % n)
	return problems
