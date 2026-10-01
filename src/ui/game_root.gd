extends Node2D
## Scene assembly for a live match.
##
## The scene file is almost empty on purpose - a Node2D with this script and
## nothing else. Every node below is built here, in code, for the same reason
## `TileSetBuilder` builds the tile set in code instead of shipping a `.tres`:
## a hand-authored node tree is a second source of truth that silently disagrees
## with the scripts the moment somebody renames a node, and the failure mode is
## `get_node()` returning null at runtime rather than a compile error.
##
## Resulting tree:
##   Game                       <- this script
##   |- World
##   |  |- Arena                <- floors, walls, nav, spawn pads
##   |  |- Actors               <- PlayerActor / BotActor live here
##   |  \- Projectiles          <- bullets and hooks, by group lookup
##   |- CameraRig               <- frames every living actor, dynamic zoom
##   |- MatchDirector           <- roster, rounds, scoreboard
##   \- HUDLayer (CanvasLayer)
##      |- HUD
##      \- PauseMenu

const ACTORS_GROUP: StringName = &"actors_layer"
const PROJECTILES_GROUP: StringName = &"projectile_layer"

var arena: Arena = null
var actors_layer: Node2D = null
var projectiles_layer: Node2D = null
var rig: CameraRig = null
var director: MatchDirector = null
var hud: GameHUD = null
var pause_menu: PauseMenu = null


func _ready() -> void:
	_build()


func _build() -> void:
	var world := Node2D.new()
	world.name = "World"
	add_child(world)

	arena = Arena.new()
	arena.name = "Arena"
	world.add_child(arena)

	actors_layer = Node2D.new()
	actors_layer.name = "Actors"
	actors_layer.add_to_group(ACTORS_GROUP)
	world.add_child(actors_layer)

	projectiles_layer = Node2D.new()
	projectiles_layer.name = "Projectiles"
	# `ActorBody.fire_bullet()` / `fire_hook()` resolve their parent by looking up
	# this group and fall back to `get_tree().current_scene`. Registering the
	# group keeps every projectile in one layer instead of scattering them as
	# siblings of the arena, which is what the fallback would do.
	projectiles_layer.add_to_group(PROJECTILES_GROUP)
	projectiles_layer.z_index = 1
	world.add_child(projectiles_layer)

	rig = CameraRig.new()
	rig.name = "CameraRig"
	add_child(rig)

	director = MatchDirector.new()
	director.name = "MatchDirector"
	add_child(director)

	var hud_layer := CanvasLayer.new()
	hud_layer.name = "HUDLayer"
	hud_layer.layer = 10
	add_child(hud_layer)

	hud = GameHUD.new()
	hud.name = "HUD"
	hud.director = director
	hud_layer.add_child(hud)

	pause_menu = PauseMenu.new()
	pause_menu.name = "PauseMenu"
	pause_menu.director = director
	pause_menu.game_root = self
	hud_layer.add_child(pause_menu)

	director.configure(arena, actors_layer, projectiles_layer)
	director.start()

	# The camera has to frame the finished spawn set, not an empty arena. Doing
	# this after `start()` also means a rematch snaps to the new pads rather than
	# gliding across the map.
	rig.snap_now()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"pause") and pause_menu != null:
		pause_menu.toggle()
		get_viewport().set_input_as_handled()


## Called by the pause menu. Restarts the match in place - a new seed, a full
## scoreboard reset - without a scene reload, so the fade never has to cover it.
func restart_match() -> void:
	if director == null:
		return
	director.start(true)
	if rig != null:
		rig.snap_now()
