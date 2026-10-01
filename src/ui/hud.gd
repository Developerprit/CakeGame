class_name GameHUD
extends Control
## In-match overlay. Everything the player needs while the arena already answers
## I18n.t("where is everybody") - the camera frames all fighters, so the HUD's job is
## state, not spatial awareness.
##
## Design space is 640x360: `project.godot` stretches a 640x360 viewport up to the
## window, and every font size is a whole multiple of 8 because the bitmap font is
## authored at 8px (a non-integer scale makes some glyph rows 1px thicker than
## others, which reads as blur). So every offset here is a small integer and
## nothing is scaled by a fraction.
##
## ANCHORING RULE, and it is not optional. Two halves, and the second one cost
## two widgets their entire purpose before it was found:
##
##  1. `set_anchors_and_offsets_preset(..., PRESET_MODE_MINSIZE, margin)` computes
##     the offsets from the control's minimum size *at the moment it is called*.
##     Call it before the children exist and the minimum is zero, so a bottom-left
##     panel parks its top-left on the corner and grows downward off screen, and a
##     centred box grows down-right instead of staying centred. So: build and
##     populate every widget first and anchor last, in `_anchor_all()`.
##
##  2. `PRESET_MODE_MINSIZE` does NOT honour `custom_minimum_size`. Measured on
##     4.5.1, a PanelContainer with `custom_minimum_size = (470, 316)` gets the
##     offsets of a 16x10 stub. So a widget whose size comes from
##     `custom_minimum_size`, or a container whose children only arrive later,
##     is still zero-sized even in a second pass - and the preset then parks its
##     LEFT edge on the right edge of the screen and grows rightward. The kill
##     feed measured (634,6)..(824,6) and never showed a message; the minimap
##     measured (634,354)..(726,446) and was a 6x6 sliver in the corner.
##
## Anything in case 2 uses `PixelTheme.corner_fixed` / `full_rect` / `center_fixed`
## instead of a MINSIZE preset. Numbers from `_check/probe_layout.gd`; re-run it
## after touching any anchored layout here.
##
## Layout:
##   top centre .... score, phase, match info
##   top right ..... kill feed
##   bottom left ... local fighter: health, weapon, ammo, four cooldowns
##   bottom right .. minimap
##   centre ........ countdown / round result banners, death notice

const MARGIN: int = 6
const MINIMAP_SIZE: int = 92
const FEED_W: int = 190
## Top of the kill feed. It starts below the header band rather than sharing it:
## the two are laid out from opposite ends of the same strip and nothing in the
## engine keeps them apart. See `_anchor_all`.
const FEED_TOP: int = 72
## Width of the control-hint line. It has to sit in the gap between the vitals
## panel (ends at x = 140) and the minimap (starts at 542) without relying on how
## wide the text happens to measure. See `PixelTheme.center_row_bottom`.
const HINT_W: int = 300
const HINT_H: int = 26
const HINT_BOTTOM: int = 6
## Stated width for the vitals panel. Every text inside it is clipped so the panel
## cannot widen itself: measured, the same three grid columns came to 134 px under
## the windowed text server and 150 px under the headless one, which is what
## reached across the hint's gap.
const VIT_W: int = 150
const FEED_MAX: int = 4
const FEED_LIFE: float = 5.0
const HINT_LIFE: float = 10.0

var director: MatchDirector = null

var _top: VBoxContainer = null
var _score_row: HBoxContainer = null
var _score_h: Label = null
var _score_b: Label = null
var _score_target: Label = null
var _phase: Label = null
var _match_info: Label = null

var _banner_box: VBoxContainer = null
var _banner: Label = null
var _banner_sub: Label = null
var _death: Label = null

var _vit: PanelContainer = null
var _who: Label = null
var _hp_bar: ProgressBar = null
var _hp_num: Label = null
var _weapon: Label = null
var _ammo: Label = null
var _cool: Dictionary = {}          ## action name -> {bar, value}
var _pips: Array[StringName] = []

var _minimap: HudMinimap = null
var _feed: VBoxContainer = null
var _feed_entries: Array = []       ## [{node: Label, life: float}]
var _hint: Label = null
var _hint_left: float = HINT_LIFE
var _fps: Label = null
var _last_local: ActorBody = null


func _ready() -> void:
	# The HUD stays live while the tree is paused, so the pause menu sits on top
	# of a legible screen instead of a frame that stopped updating.
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	# Without this the HUD inherits from a CanvasLayer, which has no theme, so
	# every StyleBox it does not override came from the engine default: the vitals
	# panel was the stock grey box in BOTH themes and its dark text was invisible
	# on it in light mode. The four menu screens all set this; the HUD did not.
	theme = PixelTheme.get_theme()

	_build_top()
	_build_feed()
	_build_vitals()
	_build_minimap()
	_build_banner()
	_build_hint()
	_bind()
	_post_build()


## Every global hook lives here rather than in `_ready`, so a rebuild re-binds
## exactly what a fresh entry binds and nothing can be missed by one path.
func _bind() -> void:
	EventBus.kill_feed.connect(_on_kill_feed)
	EventBus.settings_changed.connect(_on_settings_changed)
	EventBus.language_changed.connect(_rebuild)


func _unbind() -> void:
	I18n.unbind_bus(self)


func _post_build() -> void:
	_anchor_all()
	_on_settings_changed()


func _rebuild(_code: String) -> void:
	# The HUD is rebuilt rather than relabelled because the phase text, the
	# ability names and the hint line are all baked in at build time. Safe
	# mid-match: the bars and labels are re-created in one synchronous block,
	# and the match state itself lives on the director, not on these widgets.
	I18n.rebuild_panel(self, _build_all, _bind, _post_build)


func _build_all() -> void:
	_build_top()
	_build_feed()
	_build_vitals()
	_build_minimap()
	_build_banner()
	_build_hint()


func _exit_tree() -> void:
	_unbind()


# ===========================================================================
# construction
# ===========================================================================

func _build_top() -> void:
	# One full-width column, each line centring itself. See `_center_line`.
	_top = VBoxContainer.new()
	_top.name = "TopBand"
	_top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_top.add_theme_constant_override("separation", 0)
	add_child(_top)

	_score_row = HBoxContainer.new()
	_score_row.name = "Score"
	_score_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_score_row.add_theme_constant_override("separation", 8)
	_top.add_child(_score_row)

	_score_h = PixelTheme.heading("0")
	_score_h.add_theme_color_override("font_color",
		Enums.team_color(Enums.Team.HUMANS))
	_score_row.add_child(_score_h)

	var dash := PixelTheme.heading("—")
	dash.add_theme_color_override("font_color", PixelTheme.overlay("dim"))
	_score_row.add_child(dash)

	_score_b = PixelTheme.heading("0")
	_score_b.add_theme_color_override("font_color",
		Enums.team_color(Enums.Team.BOTS))
	_score_row.add_child(_score_b)

	_phase = PixelTheme.body(I18n.t("LIVE"))
	_phase.name = "Phase"
	_center_line(_phase)

	# Both of these start life EMPTY and are filled in by `_update_top()` every
	# frame. An empty Label's minimum size is zero, so a `PRESET_MODE_MINSIZE`
	# anchor placed them at the centre and the text then grew RIGHTWARD from it:
	# measured, "ELIMINATION - first to 5 rounds" sat at (320,32)..(496,44) instead
	# of centred, and ran 52 px inside the kill feed's column. EXPAND_FILL plus
	# `horizontal_alignment` centres them the way `_banner_box` does - live, every
	# frame, no matter when the text arrives or how long it is.
	# Overlay colour, explicitly. `PixelTheme.body(..., true)` uses the THEME's
	# `dim`, and `_update_top()` only re-colours `_phase`, so these two kept the
	# light theme's `#6b7180` for the whole match - drawn straight onto the dark
	# arena. Luminance 0.44, which is dim enough to read as "switched off" and was
	# light enough to slip past a 0.35 readability threshold.
	_score_target = PixelTheme.body("", true)
	_score_target.name = "ScoreTarget"
	_score_target.add_theme_color_override("font_color", PixelTheme.overlay("dim"))
	_center_line(_score_target)

	_match_info = PixelTheme.body("", true)
	_match_info.name = "MatchInfo"
	_match_info.add_theme_color_override("font_color", PixelTheme.overlay("dim"))
	_center_line(_match_info)


## A Label that fills the header column and centres its own text, so its position
## never depends on whether it currently has any text to measure.
func _center_line(l: Label) -> void:
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_top.add_child(l)


func _build_feed() -> void:
	_feed = VBoxContainer.new()
	_feed.name = "KillFeed"
	_feed.alignment = BoxContainer.ALIGNMENT_BEGIN
	_feed.add_theme_constant_override("separation", 1)
	_feed.custom_minimum_size = Vector2(FEED_W, 0)
	add_child(_feed)


func _build_vitals() -> void:
	_vit = PanelContainer.new()
	_vit.name = "Vitals"
	_vit.custom_minimum_size = Vector2(VIT_W, 0)
	add_child(_vit)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 3)
	_vit.add_child(col)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	col.add_child(row)
	_who = PixelTheme.body("YOU")
	_who.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_clip(_who)
	row.add_child(_who)
	_hp_num = PixelTheme.body("100", true)
	_hp_num.custom_minimum_size = Vector2(28, 0)
	_clip(_hp_num)
	row.add_child(_hp_num)

	_hp_bar = _make_bar(Vector2(112, 7))
	col.add_child(_hp_bar)

	var wrow := HBoxContainer.new()
	wrow.add_theme_constant_override("separation", 6)
	col.add_child(wrow)
	_weapon = PixelTheme.body(I18n.t("MELEE"))
	_weapon.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_clip(_weapon)
	wrow.add_child(_weapon)
	_ammo = PixelTheme.body("", true)
	_ammo.custom_minimum_size = Vector2(30, 0)
	_clip(_ammo)
	wrow.add_child(_ammo)

	# Four cooldowns, in keyboard-bind order, so the block reads like the control
	# scheme rather than like an alphabetised list.
	_pips = [&"melee", &"gun", &"hook", &"roll"]
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 5)
	grid.add_theme_constant_override("v_separation", 1)
	col.add_child(grid)
	for key in _pips:
		var name_label := PixelTheme.body(_cool_name(key), true)
		name_label.custom_minimum_size = Vector2(34, 0)
		_clip(name_label)
		grid.add_child(name_label)
		var bar := _make_bar(Vector2(64, 5))
		grid.add_child(bar)
		var val := PixelTheme.body("", true)
		val.custom_minimum_size = Vector2(26, 0)
		_clip(val)
		val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		grid.add_child(val)
		_cool[key] = {"bar": bar, "value": val}


func _build_minimap() -> void:
	_minimap = HudMinimap.new()
	_minimap.name = "Minimap"
	_minimap.director = director
	_minimap.custom_minimum_size = Vector2(MINIMAP_SIZE, MINIMAP_SIZE)
	add_child(_minimap)


func _build_banner() -> void:
	_banner_box = VBoxContainer.new()
	_banner_box.name = "Banner"
	# A full-rect container with CENTER alignment, rather than a centred preset on
	# a shrink-wrapped box: the alignment does the centring every frame, so a
	# banner appearing later (or a two-line result) cannot drift off centre.
	_banner_box.alignment = BoxContainer.ALIGNMENT_CENTER
	_banner_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_banner_box)

	_banner = Label.new()
	_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	PixelTheme.apply_font(_banner, PixelTheme.SIZE_HERO)
	_banner.add_theme_color_override("font_color", PixelTheme.overlay("text"))
	# Drop shadow, so a 32px hero number stays legible over both a light floor and
	# a dark one without a panel behind it.
	_banner.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.55))
	_banner.add_theme_constant_override("shadow_offset_x", 2)
	_banner.add_theme_constant_override("shadow_offset_y", 2)
	_banner_box.add_child(_banner)

	_banner_sub = Label.new()
	_banner_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner_sub.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	PixelTheme.apply_font(_banner_sub, PixelTheme.SIZE_HEAD)
	_banner_sub.add_theme_color_override("font_color", PixelTheme.overlay("dim"))
	_banner_sub.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.55))
	_banner_sub.add_theme_constant_override("shadow_offset_x", 1)
	_banner_sub.add_theme_constant_override("shadow_offset_y", 1)
	_banner_box.add_child(_banner_sub)

	_death = PixelTheme.body("")
	_death.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_death.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_death.add_theme_color_override("font_color", PixelTheme.overlay("danger"))
	_death.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.55))
	_death.add_theme_constant_override("shadow_offset_x", 1)
	_death.add_theme_constant_override("shadow_offset_y", 1)
	_banner_box.add_child(_death)


func _build_hint() -> void:
	# Broken by hand rather than left to autowrap: at the stated width the wrapper
	# puts ONE word on the second line, which reads as an accident. The longest line
	# is 236 px, so it fits the 300 px row under either text server.
	_hint = PixelTheme.body(
		I18n.t("WASD move  ·  mouse aim  ·  RMB melee\nE gun  ·  LMB fire  ·  Q hook  ·  Shift roll"),
		true)
	_hint.name = "Hint"
	# On the arena, so it takes the overlay palette rather than the theme's - see
	# `PixelTheme.overlay`.
	_hint.add_theme_color_override("font_color", PixelTheme.overlay("dim"))
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# Wrapping rather than clipping: the row's width is stated, so the text wraps
	# inside it, and the row's anchor keeps it clear of the panels either side.
	# A wider text server costs it a third line, not an overlap.
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	add_child(_hint)


## Second pass. Every widget that can report a real minimum size by now does.
##
## The two exceptions are the kill feed (no children until somebody dies) and the
## minimap (sized by `custom_minimum_size`), and they are placed explicitly rather
## than through a MINSIZE preset - see the anchoring rule at the top of the file.
func _anchor_all() -> void:
	# The header band: full width, top-anchored, height from the four stacked
	# lines and growing downward. Offsets stated rather than preset-ed for the
	# usual reason - the two lines below it start empty.
	_top.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_top.offset_left = 0.0
	_top.offset_right = 0.0
	_top.offset_top = 3.0
	_top.offset_bottom = 3.0
	# Width pinned, height left to the content and growing downward from the top
	# edge, and starting BELOW the header band. Sharing the band is what actually
	# happened before: the old CENTER_TOP + MINSIZE placement put "ELIMINATION -
	# first to 5 rounds" at x 320..496 while the feed's column began at 444, so the
	# two overprinted each other by 52 px. Four feed rows run y = FEED_TOP..FEED_TOP
	# + 63, which clears both the header (ends at 64) and the minimap (starts 262).
	PixelTheme.corner_fixed(_feed, Vector2(FEED_W, 0.0),
		Control.PRESET_TOP_RIGHT, Vector2(float(MARGIN), float(FEED_TOP)))
	_vit.set_anchors_and_offsets_preset(
		Control.PRESET_BOTTOM_LEFT, Control.PRESET_MODE_MINSIZE, MARGIN)
	PixelTheme.corner_fixed(_minimap, Vector2(MINIMAP_SIZE, MINIMAP_SIZE),
		Control.PRESET_BOTTOM_RIGHT, Vector2(float(MARGIN), float(MARGIN)))
	PixelTheme.full_rect(_banner_box)
	PixelTheme.center_row_bottom(_hint, float(HINT_W), float(HINT_H),
		float(HINT_BOTTOM))


## Hold a label to its stated width. Without this a Label reports its whole text as
## its minimum, so I18n.t("MELEE") is 34 px under one text server and 38 px under the other
## and the panel around it grows to match - which is how a 140 px vitals panel
## became 150 px and reached into the gap reserved for the control hint.
func _clip(l: Label) -> void:
	l.clip_text = true


func _make_bar(min_size: Vector2) -> ProgressBar:
	var bar := ProgressBar.new()
	bar.show_percentage = false
	bar.custom_minimum_size = min_size
	bar.min_value = 0.0
	bar.max_value = 1.0
	bar.value = 1.0
	return bar


static func _cool_name(key: StringName) -> String:
	match key:
		&"melee":
			return I18n.t("MELEE")
		&"gun":
			return I18n.t("GUN")
		&"hook":
			return I18n.t("HOOK")
		&"roll":
			return I18n.t("ROLL")
	return "?"


static func _fill(col: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = col
	return sb


# ===========================================================================
# per-frame
# ===========================================================================

func _process(delta: float) -> void:
	if director == null:
		return
	_tick_feed(delta)
	_tick_hint(delta)
	_update_top()
	_update_vitals()
	_update_banner()
	if _minimap != null:
		_minimap.director = director
		_minimap.queue_redraw()
	if _fps != null:
		_fps.text = I18n.t("%d fps") % Engine.get_frames_per_second()


func _update_top() -> void:
	_score_h.text = "%d" % director.score_of(Enums.Team.HUMANS)
	_score_b.text = "%d" % director.score_of(Enums.Team.BOTS)
	_phase.text = director.phase_label()
	if director.phase == Enums.MatchPhase.COUNTDOWN:
		_phase.add_theme_color_override("font_color", PixelTheme.overlay("warn"))
	elif director.phase == Enums.MatchPhase.MATCH_OVER:
		_phase.add_theme_color_override("font_color", PixelTheme.overlay("accent"))
	else:
		_phase.add_theme_color_override("font_color", PixelTheme.overlay("dim"))

	if GameConfig.respawn_enabled:
		_score_target.text = I18n.t("DEATHMATCH  ·  first to %d kills") % director.target
	else:
		_score_target.text = I18n.t("ELIMINATION  ·  first to %d rounds") % director.target
	_match_info.text = I18n.t("seed %d  ·  %d human vs %d bot") % [
		director.map_seed, director.team_size(Enums.Team.HUMANS),
		director.team_size(Enums.Team.BOTS)]


func _update_vitals() -> void:
	var body := director.local_actor
	if body == null or not is_instance_valid(body):
		_vit.visible = false
		return
	_vit.visible = true
	if body != _last_local:
		_last_local = body
		_who.text = body.display_name.to_upper()

	var frac := clampf(body.hp / maxf(1.0, body.max_hp), 0.0, 1.0)
	_hp_bar.value = frac
	_hp_num.text = "%d" % roundi(maxf(0.0, body.hp))
	var hp_col := PixelTheme.c("ok")
	if frac <= 0.3:
		hp_col = PixelTheme.c("danger")
	elif frac <= 0.6:
		hp_col = PixelTheme.c("warn")
	_hp_bar.add_theme_stylebox_override("fill", _fill(hp_col))

	if body.weapon == Enums.Weapon.GUN:
		_weapon.text = I18n.t("RELOADING") if body.reload_left > 0.0 else I18n.t("GUN")
		_ammo.text = I18n.t("%d / %d") % [body.mag, Balance.GUN_MAG]
	else:
		_weapon.text = I18n.t("MELEE")
		_ammo.text = "RMB"

	for key in _pips:
		var entry: Dictionary = _cool[key]
		var bar: ProgressBar = entry["bar"]
		var val: Label = entry["value"]
		var left := _cooldown_left(body, key)
		var total := _cooldown_total(key)
		var ready := left <= 0.0
		bar.value = 1.0 if ready else 1.0 - (left / maxf(0.001, total))
		val.text = I18n.t("OK") if ready else "%.1f" % left
		bar.add_theme_stylebox_override("fill",
			_fill(PixelTheme.c("ok") if ready else PixelTheme.c("warn")))
		val.add_theme_color_override("font_color",
			PixelTheme.c("dim") if ready else PixelTheme.c("warn"))


## Readiness is computed from the *remaining* cooldown rather than from a "was it
## fired" flag, so the bars fill smoothly and a HUD attached late still shows the
## correct state instead of claiming everything is ready.
func _cooldown_left(body: ActorBody, key: StringName) -> float:
	match key:
		&"melee":
			return body.melee_cd
		&"gun":
			return body.gun_cd
		&"hook":
			return body.hook_cd
		&"roll":
			return body.roll_cd
	return 0.0


func _cooldown_total(key: StringName) -> float:
	match key:
		&"melee":
			return Balance.MELEE_COOLDOWN
		&"gun":
			return Balance.GUN_COOLDOWN
		&"hook":
			return Balance.HOOK_COOLDOWN
		&"roll":
			return Balance.ROLL_COOLDOWN
	return 1.0


func _update_banner() -> void:
	if director.phase == Enums.MatchPhase.COUNTDOWN:
		_banner.text = "%d" % maxi(1, director.countdown_left())
		_banner.add_theme_color_override("font_color", PixelTheme.overlay("accent"))
		_banner_sub.text = I18n.t("GET READY")
		_death.text = ""
		return
	if director.phase == Enums.MatchPhase.ROUND_OVER:
		# Deliberately not naming a winner in words: the score row above already
		# flipped, and a banner repeating it adds reading without adding
		# information.
		_banner.text = I18n.t("ROUND OVER")
		_banner.add_theme_color_override("font_color", PixelTheme.overlay("warn"))
		_banner_sub.text = ""
		_death.text = ""
		return
	if director.phase == Enums.MatchPhase.MATCH_OVER:
		var winner := Enums.Team.HUMANS if director.score_of(Enums.Team.HUMANS) \
				>= director.target else Enums.Team.BOTS
		_banner.text = "VICTORY" if winner == Enums.Team.HUMANS else I18n.t("DEFEAT")
		_banner.add_theme_color_override("font_color", Enums.team_color(winner))
		_banner_sub.text = I18n.t("%s WIN   %d — %d") % [
			Enums.team_name(winner), director.score_of(winner),
			director.score_of(1 - winner)]
		_death.text = I18n.t("ESC  ·  rematch or main menu")
		_death.add_theme_color_override("font_color", PixelTheme.overlay("dim"))
		return

	_banner.text = ""
	_banner_sub.text = ""
	var body := director.local_actor
	if body != null and is_instance_valid(body) and not body.alive:
		var wait := director.respawn_left(body)
		if wait > 0.0:
			_death.text = I18n.t("DOWN  ·  back in %.1fs") % wait
		else:
			_death.text = I18n.t("ELIMINATED  ·  watch the round play out")
		_death.add_theme_color_override("font_color", PixelTheme.overlay("danger"))
	else:
		_death.text = ""


func _tick_hint(delta: float) -> void:
	if _hint == null or _hint_left <= 0.0:
		return
	_hint_left -= delta
	_hint.visible = _hint_left > 0.0
	_hint.modulate = Color(1, 1, 1, clampf(_hint_left / 2.0, 0.0, 1.0))


func _tick_feed(delta: float) -> void:
	if _feed_entries.is_empty():
		return
	var survivors: Array = []
	for e in _feed_entries:
		e["life"] = float(e["life"]) - delta
		var node: Label = e["node"]
		if not is_instance_valid(node):
			continue
		if float(e["life"]) <= 0.0:
			node.queue_free()
			continue
		# Fade over the last second rather than popping out of existence.
		node.modulate = Color(1, 1, 1, clampf(float(e["life"]), 0.0, 1.0))
		survivors.append(e)
	_feed_entries = survivors


# ===========================================================================
# events
# ===========================================================================

func _on_kill_feed(attacker_name: String, victim_name: String, kind: int,
		team_attacker: int, team_victim: int) -> void:
	if _feed == null:
		return
	var line := Label.new()
	line.text = "%s  ✕  %s   %s" % [attacker_name, victim_name, _kind_label(kind)]
	line.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	PixelTheme.apply_font(line, PixelTheme.SIZE_SMALL)
	# A Label reports its full text width as its minimum, so one 40-character
	# player name would widen the feed past its anchored box - and because the box
	# is pinned by its RIGHT edge, it would grow leftward across the score row.
	# Clipping drops the minimum to zero and the name loses its tail instead.
	line.clip_text = true
	line.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	line.add_theme_color_override("font_color", Enums.team_color(team_attacker))
	line.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.6))
	line.add_theme_constant_override("shadow_offset_x", 1)
	line.add_theme_constant_override("shadow_offset_y", 1)
	# The victim's side rides along in the tooltip rather than in the text: "who
	# died" is already the second name, and a per-word colour split inside one
	# Label is not possible without a RichTextLabel per feed line.
	line.tooltip_text = "%s (%s) killed %s (%s)" % [
		attacker_name, Enums.team_name(team_attacker),
		victim_name, Enums.team_name(team_victim)]
	_feed.add_child(line)
	_feed_entries.append({"node": line, "life": FEED_LIFE})
	while _feed_entries.size() > FEED_MAX:
		var oldest: Dictionary = _feed_entries.pop_front()
		var n: Node = oldest["node"]
		if is_instance_valid(n):
			n.queue_free()


static func _kind_label(kind: int) -> String:
	match kind:
		Enums.DamageKind.MELEE:
			return "melee"
		Enums.DamageKind.BULLET:
			return "shot"
		Enums.DamageKind.HOOK:
			return "hook"
		Enums.DamageKind.ENVIRONMENT:
			return "arena"
	return "?"


func _on_settings_changed() -> void:
	# A dark/light toggle rebuilds the Theme; this node has to pick the new one up
	# or it keeps painting the old palette for the rest of the match.
	theme = PixelTheme.get_theme()
	if GameConfig.show_fps:
		if _fps == null:
			_fps = PixelTheme.body("", true)
			add_child(_fps)
			_fps.add_theme_color_override("font_color", PixelTheme.overlay("dim"))
			_fps.set_anchors_and_offsets_preset(
				Control.PRESET_TOP_LEFT, Control.PRESET_MODE_MINSIZE, 4)
	elif _fps != null:
		_fps.queue_free()
		_fps = null


# ===========================================================================
# minimap
# ===========================================================================

## The whole arena, drawn from the grid, with fighter dots on top.
##
## Painted into a size x size Image once per map and blitted, instead of drawing
## one rect per cell: the seeded arena is 56x56, and 3136 `draw_rect` calls every
## frame to fill a 92 px widget is not a trade worth taking. Nearest filtering
## keeps it crisp, which is the point of a pixel-art minimap.
class HudMinimap extends Control:
	var director: MatchDirector = null
	var _tex: ImageTexture = null
	var _key: String = ""

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

	func _draw() -> void:
		if director == null or director.arena == null:
			return
		var arena: Arena = director.arena
		if arena.size <= 0:
			return
		_ensure_texture(arena)
		var box := Rect2(Vector2.ZERO, size)
		if _tex != null:
			draw_texture_rect(_tex, box, false)
		draw_rect(box, PixelTheme.c("line"), false, 1.0)

		var scale := size.x / float(arena.size)
		for a in director.actors:
			if not is_instance_valid(a) or not a.alive:
				continue
			var p := box.position + (a.global_position / float(Utils.TILE)) * scale
			var r := 2.0 if a.is_local else 1.5
			var col := Enums.team_color(a.team)
			if a.is_local:
				# The local fighter gets a hard outline. At 1-2 px a plain team
				# coloured dot is indistinguishable from a team-mate's.
				draw_rect(Rect2(p.x - r - 1.0, p.y - r - 1.0,
					(r + 1.0) * 2.0, (r + 1.0) * 2.0), Color(0, 0, 0, 0.85), true)
				col = Color.WHITE
			draw_rect(Rect2(p.x - r, p.y - r, r * 2.0, r * 2.0), col, true)

	## Rebuild only when the map changes. The key includes the palette so a
	## light/dark toggle repaints the minimap too.
	func _ensure_texture(arena: Arena) -> void:
		var key := "%d:%d:%s" % [arena.map_seed, arena.size,
			"d" if GameConfig.dark_theme else "l"]
		if key == _key and _tex != null:
			return
		_key = key
		var n := arena.size
		var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
		var floor_col := PixelTheme.c("panel")
		var wall_col := PixelTheme.c("dim")
		var prop_col := PixelTheme.c("warn")
		for y in n:
			for x in n:
				var v := MapGenerator.at(arena.grid, n, x, y)
				var c := wall_col
				if v == MapGenerator.F_FLOOR:
					c = floor_col
				elif v == MapGenerator.F_PROP:
					c = prop_col
				img.set_pixel(x, y, c)
		_tex = ImageTexture.create_from_image(img)
