class_name Fx
extends RefCounted
## Transient visual effects: one-shot sprite bursts and floating damage numbers.
##
## Everything here is client-side eye candy and never influences simulation, so
## it is safe for these to be spawned independently on every peer.

const FX_FPS: float = 20.0


## Find (or fall back to) the container transient effects are parented under.
static func _layer(context: Node) -> Node:
	if context == null or context.get_tree() == null:
		return null
	var l := context.get_tree().get_first_node_in_group(&"fx_layer")
	if l != null:
		return l
	return context.get_tree().current_scene


class FxSprite extends Sprite2D:
	## Walks the fx atlas row once and then frees itself.
	var fx_name: String = ""
	var frames: int = 1
	var fps: float = FX_FPS
	var clock: float = 0.0
	var loops: bool = false

	func _process(delta: float) -> void:
		clock += delta
		var idx := int(clock * fps)
		if loops:
			texture = AtlasLibrary.fx_frame(fx_name, posmod(idx, maxi(1, frames)))
			return
		if idx >= frames:
			queue_free()
			return
		texture = AtlasLibrary.fx_frame(fx_name, idx)


class FloatingText extends Node2D:
	var life: float = Balance.DMG_NUMBER_LIFE
	var elapsed: float = 0.0
	var vel: Vector2 = Vector2(0.0, -26.0)

	func _process(delta: float) -> void:
		elapsed += delta
		if elapsed >= life:
			queue_free()
			return
		position += vel * delta
		vel = vel.move_toward(Vector2(0.0, -4.0), 70.0 * delta)
		var k: float = elapsed / life
		modulate.a = clampf(1.0 - k * k, 0.0, 1.0)


static func burst(context: Node, fx_name: String, pos: Vector2,
		scale_mul: float = 1.0, rot: float = 0.0, tint: Color = Color.WHITE,
		fps: float = FX_FPS, loops: bool = false) -> void:
	var layer := _layer(context)
	if layer == null:
		return
	if AtlasLibrary.fx_frame(fx_name, 0) == null:
		return
	var s := FxSprite.new()
	s.fx_name = fx_name
	s.frames = maxi(1, AtlasLibrary.fx_count(fx_name))
	s.fps = fps
	s.loops = loops
	s.texture = AtlasLibrary.fx_frame(fx_name, 0)
	s.global_position = pos
	s.rotation = rot
	s.scale = Vector2.ONE * scale_mul
	s.modulate = tint
	s.z_index = 3
	layer.add_child(s)


static func damage_number(context: Node, pos: Vector2, amount: float,
		kind: int, crit: bool = false) -> void:
	if not GameConfig.damage_numbers:
		return
	var layer := _layer(context)
	if layer == null:
		return
	var p := PixelTheme.pal()
	var col := Color(String(p["text"]))
	var size := PixelTheme.SIZE_HEAD
	match kind:
		Enums.DamageKind.MELEE:
			col = Color(String(p["warn"]))
			size = PixelTheme.SIZE_HEAD
		Enums.DamageKind.BULLET:
			col = Color(String(p["text"]))
			size = PixelTheme.SIZE_BODY + 4
		Enums.DamageKind.HOOK:
			col = Color(String(p["accent"]))
			size = PixelTheme.SIZE_BODY + 4
		Enums.DamageKind.ENVIRONMENT:
			col = Color(String(p["dim"]))
	if crit:
		col = Color(String(p["danger"]))
		size = PixelTheme.SIZE_TITLE

	var f := FloatingText.new()
	var l := Label.new()
	l.text = str(int(round(amount)))
	var ls := LabelSettings.new()
	ls.font = PixelTheme.font()
	ls.font_size = size
	ls.font_color = col
	ls.outline_size = 2
	ls.outline_color = Color(0.0, 0.0, 0.0, 0.8)
	l.label_settings = ls
	l.position = Vector2(-28.0, -14.0)
	l.size = Vector2(56.0, 20.0)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	f.add_child(l)
	f.global_position = pos + Vector2(0.0, -8.0)
	f.z_index = 6
	f.vel = Vector2(randf_range(-10.0, 10.0), -34.0)
	layer.add_child(f)


## Impact puff: picks the right atlas row for the surface that was hit.
static func impact(context: Node, pos: Vector2, on_flesh: bool, dir: Vector2) -> void:
	burst(context, "blood" if on_flesh else "spark", pos, 0.75 if on_flesh else 0.85,
		dir.angle(), Color.WHITE, 22.0)


static func muzzle(context: Node, pos: Vector2, dir: Vector2, big: bool = false) -> void:
	burst(context, "muzzle", pos, 0.9 if big else 0.7, dir.angle(), Color.WHITE, 34.0)
