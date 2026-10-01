class_name PixelTheme
extends RefCounted
## Palette + Control theme factory, with light and dark variants.
##
## The bitmap font is authored at 8px, so every size used anywhere in the UI is a
## whole multiple of 8 (8 / 16 / 24 / 32). Non-integer scaling of a bitmap font
## makes some glyph rows 1px thicker than others, which reads as "blurry" even
## though nothing is actually filtered.
##
## The CJK fallback exists because the atlas is ASCII-only. Assigning
## `fallbacks` REPLACES Godot's implicit fallback chain, so the list has to cover
## Chinese completely or Chinese text collapses into tofu boxes.

const FONT_PATH: String = "res://assets/fonts/pixel_font.fnt"
const SIZE_BODY: int = 8
const SIZE_SMALL: int = 8
const SIZE_HEAD: int = 16
const SIZE_TITLE: int = 24
const SIZE_HERO: int = 32

static var _font: Font = null
static var _theme_dark: Theme = null
static var _theme_light: Theme = null


# ---------------------------------------------------------------------------
# palette
# ---------------------------------------------------------------------------

static func pal() -> Dictionary:
	return dark_pal() if GameConfig.dark_theme else light_pal()


static func dark_pal() -> Dictionary:
	return {
		"bg": "#0f1116",
		"panel": "#1b1e26",
		"panel2": "#232733",
		"line": "#3a4150",
		"text": "#e8eef4",
		"dim": "#8b93a1",
		"accent": "#4fd6f0",
		"accent2": "#2e93b8",
		"on_accent": "#07161c",
		"danger": "#ef5350",
		"ok": "#5ddc8a",
		"warn": "#e0b23c",
		"shadow": "#000000",
		"human": "#4fd6f0",
		"bot": "#f0714f",
	}


static func light_pal() -> Dictionary:
	return {
		"bg": "#eeeae0",
		"panel": "#ffffff",
		"panel2": "#e2ddd2",
		"line": "#b9b2a5",
		"text": "#1b1d22",
		"dim": "#6b7180",
		"accent": "#0d7d99",
		"accent2": "#0a5f75",
		"on_accent": "#ffffff",
		"danger": "#b8382f",
		"ok": "#2b7a52",
		"warn": "#9a7415",
		"shadow": "#9a9384",
		"human": "#0d7d99",
		"bot": "#c1543a",
	}


static func c(key: String) -> Color:
	return Color(String(pal().get(key, "#ff00ff")))


## Colours for text drawn straight onto the ARENA rather than onto a themed panel.
##
## Always the dark palette's values, in both themes, and that is not an oversight.
## The arena art is identical in both themes - it never reads the palette, because
## the tiles are a fixed atlas - and it is dark. So overlay text cannot follow the
## theme: in light mode `text` is `#1b1d22`, and the header lines, the countdown
## banner and the vitals readout all became near-black on a dark floor. Dark
## mode hid this, because the dark palette happens to be light-on-dark already.
##
## The distinction that matters is whether the widget supplies its own background:
## the vitals panel and the minimap do, so they use `c()`; the score, the phase,
## the banner, the kill feed and the control hint do not, so they use this.
static func overlay(key: String) -> Color:
	return Color(String(dark_pal().get(key, "#ff00ff")))


## Perceived luminance of a colour, for the tests that assert overlay text stays
## readable. Rec. 709 weights.
static func luminance(col: Color) -> float:
	return 0.2126 * col.r + 0.7152 * col.g + 0.0722 * col.b


# ---------------------------------------------------------------------------
# font
# ---------------------------------------------------------------------------

static func font() -> Font:
	if _font != null:
		return _font
	var f := load(FONT_PATH) as FontFile
	if f == null:
		push_warning("[PixelTheme] bitmap font missing, falling back to the engine font")
		_font = ThemeDB.fallback_font
		return _font
	var cjk := SystemFont.new()
	cjk.font_names = PackedStringArray([
		"Microsoft YaHei", "微软雅黑", "SimHei", "黑体", "SimSun", "宋体",
		"Noto Sans CJK SC", "Source Han Sans SC", "PingFang SC", "sans-serif",
	])
	f.fallbacks = [cjk]
	_font = f
	return _font


static func apply_font(node: Control, size: int = SIZE_BODY) -> void:
	if node == null:
		return
	var f := font()
	node.add_theme_font_override("font", f)
	node.add_theme_font_size_override("font_size", size)


static func label_settings(size: int, key: String = "text") -> LabelSettings:
	var ls := LabelSettings.new()
	ls.font = font()
	ls.font_size = size
	ls.font_color = c(key)
	ls.shadow_size = 0
	return ls


# ---------------------------------------------------------------------------
# theme
# ---------------------------------------------------------------------------

static func get_theme() -> Theme:
	if GameConfig.dark_theme:
		if _theme_dark == null:
			_theme_dark = _build()
		return _theme_dark
	if _theme_light == null:
		_theme_light = _build()
	return _theme_light


## Called after the theme toggle so the next `get_theme()` rebuilds.
static func invalidate() -> void:
	_theme_dark = null
	_theme_light = null


static func _flat(bg_key: String, line_key: String, border_px: int = 1,
		pad_h: int = 8, pad_v: int = 5) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = c(bg_key)
	if border_px > 0:
		sb.border_color = c(line_key)
		sb.set_border_width_all(border_px)
	sb.corner_radius_top_left = 0
	sb.corner_radius_top_right = 0
	sb.corner_radius_bottom_left = 0
	sb.corner_radius_bottom_right = 0
	sb.content_margin_left = pad_h
	sb.content_margin_right = pad_h
	sb.content_margin_top = pad_v
	sb.content_margin_bottom = pad_v
	return sb


static func _build() -> Theme:
	var t := Theme.new()
	t.default_font = font()
	t.default_font_size = SIZE_BODY

	# --- Button ------------------------------------------------------------
	t.set_stylebox("normal", "Button", _flat("panel2", "line"))
	t.set_stylebox("hover", "Button", _flat("accent2", "accent"))
	t.set_stylebox("pressed", "Button", _flat("accent", "accent"))
	t.set_stylebox("focus", "Button", _flat("panel2", "accent"))
	t.set_stylebox("disabled", "Button", _flat("panel2", "line"))
	t.set_color("font_color", "Button", c("text"))
	t.set_color("font_hover_color", "Button", Color("#ffffff"))
	t.set_color("font_pressed_color", "Button", c("on_accent"))
	t.set_color("font_focus_color", "Button", c("text"))
	t.set_color("font_disabled_color", "Button", c("dim"))

	# --- Panel / containers ------------------------------------------------
	t.set_stylebox("panel", "Panel", _flat("panel", "line"))
	t.set_stylebox("panel", "PanelContainer", _flat("panel", "line"))

	# --- Label -------------------------------------------------------------
	t.set_color("font_color", "Label", c("text"))

	# --- RichTextLabel -----------------------------------------------------
	# `fit_content` is NOT a theme property but the min-height trap is real, so
	# callers are reminded in the doc comment of `make_rich_text()` below.
	t.set_stylebox("normal", "RichTextLabel", _flat("panel", "line"))
	t.set_color("default_color", "RichTextLabel", c("text"))

	# --- LineEdit ----------------------------------------------------------
	t.set_stylebox("normal", "LineEdit", _flat("bg", "line"))
	t.set_stylebox("focus", "LineEdit", _flat("bg", "accent"))
	t.set_color("font_color", "LineEdit", c("text"))
	t.set_color("font_placeholder_color", "LineEdit", c("dim"))
	t.set_color("caret_color", "LineEdit", c("accent"))
	t.set_color("selection_color", "LineEdit", c("accent2"))

	# --- OptionButton ------------------------------------------------------
	t.set_stylebox("normal", "OptionButton", _flat("panel2", "line"))
	t.set_stylebox("hover", "OptionButton", _flat("panel2", "accent"))
	t.set_stylebox("pressed", "OptionButton", _flat("accent", "accent"))
	t.set_stylebox("focus", "OptionButton", _flat("panel2", "accent"))
	t.set_color("font_color", "OptionButton", c("text"))
	t.set_color("font_hover_color", "OptionButton", c("text"))

	# --- PopupMenu ---------------------------------------------------------
	t.set_stylebox("panel", "PopupMenu", _flat("panel", "line", 1, 2, 2))
	t.set_color("font_color", "PopupMenu", c("text"))
	t.set_color("font_hover_color", "PopupMenu", c("on_accent"))
	t.set_stylebox("hover", "PopupMenu", _flat("accent", "accent", 0, 4, 3))

	# --- CheckButton / CheckBox -------------------------------------------
	for cls in ["CheckButton", "CheckBox"]:
		t.set_stylebox("normal", cls, _flat("panel2", "line"))
		t.set_stylebox("hover", cls, _flat("panel2", "accent"))
		t.set_stylebox("pressed", cls, _flat("accent", "accent"))
		t.set_stylebox("focus", cls, _flat("panel2", "accent"))
		t.set_color("font_color", cls, c("text"))
		t.set_color("font_hover_color", cls, c("text"))

	# --- Slider ------------------------------------------------------------
	t.set_stylebox("slider", "HSlider", _flat("bg", "line", 1, 0, 3))
	t.set_stylebox("grabber_area", "HSlider", _flat("accent2", "accent", 0, 0, 3))
	t.set_stylebox("grabber_area_highlight", "HSlider", _flat("accent", "accent", 0, 0, 3))

	# --- ScrollContainer / ScrollBar --------------------------------------
	t.set_stylebox("panel", "ScrollContainer", _flat("panel", "panel", 0, 0, 0))
	t.set_stylebox("scroll", "VScrollBar", _flat("panel", "panel", 0, 0, 0))
	t.set_stylebox("grabber", "VScrollBar", _flat("line", "line", 0, 0, 0))
	t.set_stylebox("grabber_highlight", "VScrollBar", _flat("accent", "accent", 0, 0, 0))

	# --- TabContainer ------------------------------------------------------
	t.set_stylebox("panel", "TabContainer", _flat("panel", "line"))
	t.set_stylebox("tab_selected", "TabContainer", _flat("accent", "accent"))
	t.set_stylebox("tab_unselected", "TabContainer", _flat("panel2", "line"))
	t.set_color("font_selected_color", "TabContainer", c("on_accent"))
	t.set_color("font_unselected_color", "TabContainer", c("text"))

	# --- ProgressBar -------------------------------------------------------
	t.set_stylebox("background", "ProgressBar", _flat("bg", "line"))
	t.set_stylebox("fill", "ProgressBar", _flat("accent", "accent"))
	t.set_color("font_color", "ProgressBar", c("text"))

	return t


# ---------------------------------------------------------------------------
# helpers for the layout traps this project has hit before
# ---------------------------------------------------------------------------

## A RichTextLabel whose minimum height is `0` by default will be crushed to
## nothing inside a VBoxContainer and the page will look empty. Always set
## `fit_content` and an autowrap mode.
static func make_rich_text(bbcode: String = "") -> RichTextLabel:
	var r := RichTextLabel.new()
	r.bbcode_enabled = true
	r.fit_content = true
	r.scroll_active = false
	r.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	r.text = bbcode
	apply_font(r, SIZE_BODY)
	return r


## Place a Control in a corner with a real pixel offset.
## `set_anchors_preset()` + `position = ...` does NOT mean "N px from that
## corner" - `Control.position` is relative to the parent's top-left, so that
## combination happily pushes controls off screen.
##
## Only safe for a Control whose size is driven by its content AND whose children
## already exist. For anything with a `custom_minimum_size`, use `center_fixed`,
## `center_content` or `bottom_row` below instead - see `center_fixed`.
static func corner(ctrl: Control, preset: int, margin: int = 8) -> void:
	ctrl.set_anchors_and_offsets_preset(preset, Control.PRESET_MODE_MINSIZE, margin)


## Centre a Control of a known size. Offsets are stated explicitly, and that is
## the whole point.
##
## `set_anchors_and_offsets_preset(PRESET_CENTER, PRESET_MODE_MINSIZE)` reads as
## "centre it at its own size" and is not: measured on 4.5.1, `MINSIZE` does NOT
## honour `custom_minimum_size`. A `PanelContainer` with
## `custom_minimum_size = (470, 316)` and a theme StyleBox got offsets
## (-8, -5, 8, 5) - the StyleBox content margins, doubled - i.e. a 16x10 stub
## pinned at the centre. The panel then grew down-right from there as its
## children arrived and finished up spanning (312,175)..(782,491) inside a
## 640x360 design space: more than half of it off screen, including the only
## CLOSE button. Numbers from `_check/probe_layout.gd`; re-run it after touching
## any anchored layout in this project.
static func center_fixed(ctrl: Control, size: Vector2) -> void:
	ctrl.set_anchors_preset(Control.PRESET_CENTER)
	ctrl.offset_left = -size.x * 0.5
	ctrl.offset_top = -size.y * 0.5
	ctrl.offset_right = size.x * 0.5
	ctrl.offset_bottom = size.y * 0.5


## Same, sized from the content. MUST be called AFTER the children are added:
## before that the content minimum is (0,0), the preset offsets are zero, and the
## control grows downward from the centre line until it is off the bottom edge.
static func center_content(ctrl: Control) -> void:
	center_fixed(ctrl, ctrl.get_combined_minimum_size())


## Pin a Control of a known size into a corner. `inset` is the distance from the
## two edges meeting at that corner, so a top-right widget can sit 6 px from the
## right edge and 72 px down: `Vector2(6, 72)`.
## `size.y == 0` means "height comes from the content, growing away from the
## anchored edge" - which is only sane for the two TOP presets.
##
## Replaces `set_anchors_and_offsets_preset(preset, PRESET_MODE_MINSIZE, margin)`
## for anything that (a) gets its size from `custom_minimum_size`, or (b) is a
## container whose children only arrive later. Both cases have a minimum size of
## zero at anchor time, and the preset then parks the control's *left* edge on the
## right edge of the screen and lets it grow rightward: the HUD kill feed measured
## (634,6)..(824,6) and the minimap (634,354)..(726,446) inside a 640x360 space.
## The kill feed therefore never showed a single message and the minimap was a
## 6x6 sliver in the corner.
static func corner_fixed(ctrl: Control, size: Vector2, preset: int,
		inset: Vector2) -> void:
	ctrl.custom_minimum_size = size
	ctrl.set_anchors_preset(preset)
	var mx := inset.x
	var my := inset.y
	match preset:
		Control.PRESET_TOP_LEFT:
			ctrl.offset_left = mx
			ctrl.offset_top = my
			ctrl.offset_right = mx + size.x
			ctrl.offset_bottom = my + size.y
		Control.PRESET_TOP_RIGHT:
			ctrl.offset_left = -(mx + size.x)
			ctrl.offset_top = my
			ctrl.offset_right = -mx
			ctrl.offset_bottom = my + size.y
		Control.PRESET_BOTTOM_LEFT:
			ctrl.offset_left = mx
			ctrl.offset_top = -(my + size.y)
			ctrl.offset_right = mx + size.x
			ctrl.offset_bottom = -my
		Control.PRESET_BOTTOM_RIGHT:
			ctrl.offset_left = -(mx + size.x)
			ctrl.offset_top = -(my + size.y)
			ctrl.offset_right = -mx
			ctrl.offset_bottom = -my
		_:
			push_error("[PixelTheme] corner_fixed got a non-corner preset")


## A centred single-line row of a STATED width, `bottom` px above the bottom edge.
##
## For a line drawn in the gap between two corner panels. A MINSIZE preset sizes
## such a row to its own text, and the SAME string measures about 5% wider under
## the headless text server than under the windowed one - 364 px against 332 px
## for the HUD's control hint. That 5% was the entire margin: the hint closed on
## the vitals panel and overlapped it. Stating the width, and bounding the panel
## on the other side of the gap, keeps the two apart under either text server.
## Both halves are needed; fixing only the hint moved the overlap from 2 px to
## 6 px, because the panel had widened by 10 px.
static func center_row_bottom(ctrl: Control, width: float, height: float,
		bottom: float) -> void:
	ctrl.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	ctrl.offset_left = -width * 0.5
	ctrl.offset_right = width * 0.5
	ctrl.offset_top = -(bottom + height)
	ctrl.offset_bottom = -bottom


## A Control stretched over the whole parent. Explicit, because a MINSIZE preset
## on a container whose children arrive later leaves it zero-sized.
static func full_rect(ctrl: Control) -> void:
	ctrl.set_anchors_preset(Control.PRESET_FULL_RECT)
	ctrl.offset_left = 0.0
	ctrl.offset_top = 0.0
	ctrl.offset_right = 0.0
	ctrl.offset_bottom = 0.0
##
## Pin a Control to the bottom of the parent as a full-width row, with both ends
## held back from the frame by `side` and the row lifted off the bottom by
## `bottom`.
##
## All four offsets are written, and that is deliberate. An anchored row placed
## before its children exist gets a zero-height rect, and the engine then grows
## it *downward*: the lobby's READY / START MATCH / LEAVE row rendered at
## y = 360..382 in a 360 px tall space - entirely off screen, so a match could not
## be started. Setting `offset_bottom` alone is not a fix either; on a control
## whose height is clamped to a minimum, the engine silently recomputes it.
static func bottom_row(ctrl: Control, height: float, side: float, bottom: float) -> void:
	ctrl.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	ctrl.offset_left = side
	ctrl.offset_right = -side
	ctrl.offset_top = -(bottom + height)
	ctrl.offset_bottom = -bottom


static func title(text: String) -> Label:
	var l := Label.new()
	l.text = text
	apply_font(l, SIZE_TITLE)
	l.add_theme_color_override("font_color", c("accent"))
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	return l


static func heading(text: String) -> Label:
	var l := Label.new()
	l.text = text
	apply_font(l, SIZE_HEAD)
	l.add_theme_color_override("font_color", c("text"))
	return l


static func body(text: String, dim: bool = false) -> Label:
	var l := Label.new()
	l.text = text
	apply_font(l, SIZE_BODY)
	l.add_theme_color_override("font_color", c("dim") if dim else c("text"))
	return l
