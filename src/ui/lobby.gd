extends Control
## Room lobby: who is in the match, and how to get everybody into it.
##
## HONESTY NOTE, and it is the most important thing in this file.
## The lobby is written against the full `NetManager` surface - slots, ready
## flags, host/client roles, room codes - but only the LOCAL transport exists
## today. LAN UDP discovery, the room-code P2P hole punch and the WebSocket relay
## are separate work items, and this screen says so in the transport line instead
## of showing a green "connected" badge for a socket that does not exist. A lobby
## that lies about being connected is worse than no lobby: the player sits there
## waiting for a friend who can never appear.
##
## What genuinely works right now:
##   * the roster is real (`NetManager._peer_slots`), readiness is real
##   * the room code is real and is what a client will type once the signaling
##     server is up
##   * START launches a real match through the same code path as the main menu
##
## Layout: roster on the left, connection on the right, actions along the bottom.

const MARGIN: float = 10.0

var _rows: VBoxContainer = null
var _code_label: Label = null
var _status: Label = null
var _transport: Label = null
var _code_input: LineEdit = null
var _start: Button = null
var _ready_button: Button = null


func _ready() -> void:
	theme = PixelTheme.get_theme()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_build()

	_bind()

	if NetManager.is_offline():
		# Entering the lobby from the menu without a session yet: open a host
		# session so the room is joinable and the code means something. The
		# transport underneath is local until the network layer lands.
		NetManager.set_local_slot(GameConfig.player_name, Enums.Team.HUMANS,
			Enums.Kind.LOCAL_HUMAN)
		NetManager.room_code = NetManager.room_code \
			if not NetManager.room_code.is_empty() \
			else Utils.random_room_code(Utils.rng(absi(randi())))
	_post_build()


## Every global hook lives here rather than in `_ready`, so a rebuild re-binds
## exactly what a fresh entry binds and nothing can be missed by one path.
func _bind() -> void:
	EventBus.lobby_changed.connect(_refresh)
	EventBus.room_code_ready.connect(_on_room_code)
	EventBus.net_status.connect(_on_net_status)
	EventBus.net_error.connect(_on_net_error)
	EventBus.peer_joined.connect(_on_peer_changed)
	EventBus.peer_left.connect(_on_peer_changed)
	EventBus.language_changed.connect(_rebuild)


func _unbind() -> void:
	I18n.unbind_bus(self)


## Restores what the widgets build pass cannot know: the roster and the code
## label. Deliberately does NOT touch the network session - the host-session
## block in `_ready` is entry-only, re-running it on every language switch
## would re-slot the local player for no reason.
func _post_build() -> void:
	_refresh()
	_on_room_code(NetManager.room_code)


func _rebuild(_code: String) -> void:
	I18n.rebuild_panel(self, _build, _bind, _post_build)


func _exit_tree() -> void:
	_unbind()


# ===========================================================================
# construction
# ===========================================================================

func _build() -> void:
	var bg := ColorRect.new()
	bg.color = PixelTheme.c("bg")
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var frame := Panel.new()
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(frame)
	frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	frame.offset_left = MARGIN
	frame.offset_top = MARGIN
	frame.offset_right = -MARGIN
	frame.offset_bottom = -MARGIN

	var title := PixelTheme.heading(I18n.t("ROOM"))
	title.add_theme_color_override("font_color", PixelTheme.c("accent"))
	add_child(title)
	_abs(title, MARGIN + 18.0, MARGIN + 14.0, 300.0, 20.0)

	_build_roster()
	_build_connection()
	_build_actions()


func _build_roster() -> void:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(300, 176)
	add_child(panel)
	_abs(panel, MARGIN + 18.0, 46.0, 300.0, 176.0)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)
	panel.add_child(col)

	var head := HBoxContainer.new()
	col.add_child(head)
	var h1 := PixelTheme.body(I18n.t("SLOT"))
	h1.custom_minimum_size = Vector2(40, 0)
	head.add_child(h1)
	var h2 := PixelTheme.body(I18n.t("PLAYER"))
	h2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(h2)
	var h3 := PixelTheme.body(I18n.t("SIDE"))
	h3.custom_minimum_size = Vector2(58, 0)
	head.add_child(h3)
	var h4 := PixelTheme.body(I18n.t("READY"))
	h4.custom_minimum_size = Vector2(46, 0)
	head.add_child(h4)
	col.add_child(HSeparator.new())

	_rows = VBoxContainer.new()
	_rows.add_theme_constant_override("separation", 1)
	_col_add_scroll(col, _rows)


## A ScrollContainer with a real minimum height. Without one the roster rows get
## crushed the moment a ninth player joins, and the failure looks like "the lobby
## lost a player" rather than "the container ran out of room".
func _col_add_scroll(parent: VBoxContainer, inner: Control) -> ScrollContainer:
	var s := ScrollContainer.new()
	s.size_flags_vertical = Control.SIZE_EXPAND_FILL
	s.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	parent.add_child(s)
	s.add_child(inner)
	return s


func _build_connection() -> void:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(258, 176)
	add_child(panel)
	panel.set_anchors_and_offsets_preset(
		Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE, 0)
	panel.offset_left = -258.0 - MARGIN - 18.0
	panel.offset_right = -MARGIN - 18.0
	panel.offset_top = 46.0

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 3)
	panel.add_child(col)

	var head := PixelTheme.body(I18n.t("ROOM CODE"))
	head.add_theme_color_override("font_color", PixelTheme.c("accent"))
	col.add_child(head)

	_code_label = Label.new()
	_code_label.text = "------"
	PixelTheme.apply_font(_code_label, PixelTheme.SIZE_TITLE)
	_code_label.add_theme_color_override("font_color", PixelTheme.c("text"))
	_code_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(_code_label)

	var hint := PixelTheme.body(I18n.t("read this out, or paste it below"), true)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(hint)
	col.add_child(HSeparator.new())

	var join_row := HBoxContainer.new()
	join_row.add_theme_constant_override("separation", 4)
	col.add_child(join_row)
	_code_input = LineEdit.new()
	_code_input.placeholder_text = I18n.t("CODE")
	_code_input.max_length = 8
	_code_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	join_row.add_child(_code_input)
	var join := Button.new()
	join.text = I18n.t("JOIN")
	join.pressed.connect(_join_room)
	join_row.add_child(join)

	# Two buttons side by side instead of one stacked row: the panel is 258 px
	# wide, so a second full-width button would have pushed everything past the
	# 176 px panel height and the transport line off the bottom.
	var net_row := HBoxContainer.new()
	net_row.add_theme_constant_override("separation", 4)
	col.add_child(net_row)

	var lan := Button.new()
	lan.text = I18n.t("SCAN LAN")
	lan.tooltip_text = I18n.t("UDP broadcast discovery on the local network")
	lan.pressed.connect(_scan_lan)
	lan.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	net_row.add_child(lan)

	var	p2p := Button.new()
	p2p.text = I18n.t("HOST P2P")
	p2p.tooltip_text = I18n.t("open the room over the internet and print the code")
	p2p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	p2p.pressed.connect(_host_p2p)
	net_row.add_child(p2p)

	col.add_child(HSeparator.new())
	_transport = PixelTheme.body("", true)
	_transport.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(_transport)

	_status = PixelTheme.body("", true)
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(_status)


## The whole bottom of the screen is ONE row: the three actions, a flexible gap,
## then the hint. Two separately corner-anchored things would be free to meet in
## the middle, and at 640 px they would - the three buttons alone are 312 px and
## the old hint was 335 px.
func _build_actions() -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	add_child(row)

	_ready_button = Button.new()
	_ready_button.text = I18n.t("READY")
	_ready_button.custom_minimum_size = Vector2(96, 22)
	_ready_button.pressed.connect(_toggle_ready)
	row.add_child(_ready_button)

	_start = Button.new()
	_start.text = I18n.t("START MATCH")
	_start.custom_minimum_size = Vector2(120, 22)
	_start.pressed.connect(_start_match)
	row.add_child(_start)

	var leave := Button.new()
	leave.text = I18n.t("LEAVE")
	leave.custom_minimum_size = Vector2(84, 22)
	leave.pressed.connect(_leave)
	row.add_child(leave)

	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(gap)

	# Short version on screen, full sentence in the tooltip. The roster already
	# shows every empty slot as "- (bot) / BOTS / auto", so the long form was
	# explaining something the panel next to it says better.
	var hint := PixelTheme.body(I18n.t("empty slots fill with bots"), true)
	hint.tooltip_text = I18n.t("START uses everyone in the room; empty human slots are filled with bots.")
	row.add_child(hint)

	# Placement LAST, all four offsets at once, via the helper. This used to run
	# before the buttons were added, so `PRESET_MODE_MINSIZE` baked a zero-height
	# row that the buttons then grew downward - rendering at y = 360..382 in a
	# 360 px tall space, i.e. completely off screen. START MATCH was unreachable.
	PixelTheme.bottom_row(row, 22.0, MARGIN + 18.0, MARGIN + 14.0)


func _abs(c: Control, x: float, y: float, w: float, h: float) -> void:
	c.set_anchors_and_offsets_preset(
		Control.PRESET_TOP_LEFT, Control.PRESET_MODE_MINSIZE, 0)
	c.offset_left = x
	c.offset_top = y
	c.offset_right = x + w
	c.offset_bottom = y + h


# ===========================================================================
# roster
# ===========================================================================

func _refresh() -> void:
	for c in _rows.get_children():
		c.queue_free()

	var slots := NetManager.slots()
	var ids: Array = slots.keys()
	ids.sort()
	var total := maxi(GameConfig.max_players, ids.size() + GameConfig.bot_slots)
	for i in total:
		var peer_id := -1
		var slot: Dictionary = {}
		if i < ids.size():
			peer_id = ids[i]
			slot = slots[peer_id]
		_add_row(i, peer_id, slot)

	# Empty human rows are shown as bots so the roster always describes the match
	# that START will actually launch - the same "empty slots fill with bots" rule
	# the director applies.
	_code_label.text = NetManager.room_code if not NetManager.room_code.is_empty() \
		else "------"
	# No `.to_lower()` here: the mode is one of the `transport:` table's `%s`
	# substitutions, and lower-casing it produced the English "off line" sitting
	# inside an otherwise Chinese line.
	_transport.text = I18n.t("transport: %s   ·   %s") % [
		NetManager.mode_label(), _transport_note()]
	_ready_button.text = I18n.t("READY") if not _local_ready() else "READY  *"
	_start.disabled = not _can_start()


func _add_row(index: int, peer_id: int, slot: Dictionary) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 0)
	_rows.add_child(row)

	var n := PixelTheme.body("%d" % (index + 1), true)
	n.custom_minimum_size = Vector2(40, 0)
	row.add_child(n)

	var who := PixelTheme.body("- (bot)")
	who.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if not slot.is_empty():
		who.text = str(slot.get("name", "?"))
		if peer_id == NetManager.local_peer_id:
			who.text += "  (you)"
		who.add_theme_color_override("font_color", PixelTheme.c("text"))
	else:
		who.add_theme_color_override("font_color", PixelTheme.c("dim"))
	row.add_child(who)

	# Empty rows are described as what they will become, not as blanks: the
	# director fills unoccupied human slots with bots, so "bot / auto" is the
	# truthful description of a row with nobody in it.
	var team_text := I18n.t("BOTS")
	var team_col := PixelTheme.c("dim")
	var ready_text := I18n.t("auto")
	if not slot.is_empty():
		var side := int(slot.get("team", Enums.Team.HUMANS))
		team_text = I18n.t("HUMANS") if side == Enums.Team.HUMANS else I18n.t("BOTS")
		team_col = Enums.team_color(side)
		ready_text = I18n.t("yes") if bool(slot.get(I18n.t("ready"), false)) else I18n.t("no")
	var team := PixelTheme.body(team_text)
	team.custom_minimum_size = Vector2(58, 0)
	team.add_theme_color_override("font_color", team_col)
	row.add_child(team)

	var ready := PixelTheme.body(ready_text, true)
	ready.custom_minimum_size = Vector2(46, 0)
	row.add_child(ready)


func _local_ready() -> bool:
	return bool(NetManager.local_slot().get(I18n.t("ready"), false))


func _can_start() -> bool:
	if not NetManager.is_host() and not NetManager.is_offline():
		return false
	if not _local_ready():
		return false
	for id in NetManager.slots().keys():
		if not bool(NetManager.slots()[id].get(I18n.t("ready"), false)):
			return false
	return true


# ===========================================================================
# actions
# ===========================================================================

func _toggle_ready() -> void:
	NetManager.toggle_ready()
	_refresh()


func _start_match() -> void:
	SceneRouter.to_game()


func _join_room() -> void:
	var code := Utils.clean_room_code(_code_input.text)
	if code.length() < 4:
		_on_net_error(I18n.t("room codes are at least 4 characters"))
		return
	if NetManager.is_offline():
		_on_net_error(I18n.t("open a room first - HOST P2P next to SCAN LAN"))
		return
	# The code names a slot in the signalling KV. A short code never reaches the
	# server, so it is caught here instead of producing a I18n.t("no such room") that is
	# actually a typo.
	NetManager.join_p2p(code)


func _transport_note() -> String:
	if NetManager.is_offline():
		return I18n.t("local only")
	var pref := GameConfig.preferred_transport.strip_edges().to_lower()
	if pref in [I18n.t("lan"), I18n.t("p2p"), I18n.t("relay")]:
		return I18n.t("forced to %s") % pref
	return I18n.t("tries UDP punch, then the relay")


func _scan_lan() -> void:
	NetManager.scan_lan()


func _host_p2p() -> void:
	if NetManager.is_offline():
		_on_net_error(I18n.t("go back to the menu and open the room first"))
		return
	NetManager.host_p2p(NetManager.room_code)


func _leave() -> void:
	SceneRouter.to_menu()


func _on_room_code(code: String) -> void:
	if _code_label != null:
		_code_label.text = code if not code.is_empty() else "------"


func _on_net_status(text: String, quality: String) -> void:
	if _status != null:
		_status.text = "%s (%s)" % [text, quality]


func _on_net_error(text: String) -> void:
	if _status != null:
		_status.text = text
		_status.add_theme_color_override("font_color", PixelTheme.c("warn"))


func _on_peer_changed(_id: int, _info: Dictionary = {}) -> void:
	_refresh()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"pause"):
		_leave()
		get_viewport().set_input_as_handled()
