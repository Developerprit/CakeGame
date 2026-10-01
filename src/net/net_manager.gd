extends Node
## Session / networking facade (autoload `NetManager`).
##
## Model: **Listen Server**. The first player to create a room becomes the
## authority (host); everyone else is a client. There is no dedicated server
## anywhere — "decentralised" here means the session dies with its host.
##
## Three transports, tried in order, all exposing the SAME Godot MultiplayerAPI
## so gameplay RPC code never learns which one is active:
##   1. LAN        UDP broadcast discovery -> ENetMultiplayerPeer direct connect
##   2. P2P        Retinbox signalling exchanges public endpoints -> UDP punch
##   3. RELAY      WebSocket relay fallback (WebSocketMultiplayerPeer)
##
## Authority rule: the host simulates every AI bot and replicates their state.

const DEFAULT_PORT: int = 34567
const MAX_PLAYERS_HARD: int = 8

var mode: int = Enums.NetMode.OFFLINE
var local_peer_id: int = 1
var player_name: String = "Player"
var room_code: String = ""
var transport_label: String = "local"

var _peer_slots: Dictionary = {}   ## peer_id -> {name, team, kind, ready}


func _ready() -> void:
	player_name = GameConfig.player_name
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


func is_offline() -> bool:
	return mode == Enums.NetMode.OFFLINE


func is_host() -> bool:
	return Enums.is_host_mode(mode)


func is_client() -> bool:
	return Enums.is_client_mode(mode)


## True when this peer owns simulation of the bots.
func is_authority() -> bool:
	return is_offline() or is_host()


func mode_label() -> String:
	return Enums.net_mode_label(mode)


func peer_count() -> int:
	return _peer_slots.size()


func slots() -> Dictionary:
	return _peer_slots


func slot_of(id: int) -> Dictionary:
	return _peer_slots.get(id, {})


func local_slot() -> Dictionary:
	return slot_of(local_peer_id)


func set_offline() -> void:
	mode = Enums.NetMode.OFFLINE
	transport_label = "local"
	local_peer_id = 1
	room_code = ""
	_peer_slots.clear()
	multiplayer.multiplayer_peer = null


func set_local_slot(name_text: String, team: int, kind: int) -> void:
	_peer_slots[local_peer_id] = {
		"name": name_text,
		"team": team,
		"kind": kind,
		"ready": false,
	}
	EventBus.lobby_changed.emit()


func update_local_slot(patch: Dictionary) -> void:
	var s: Dictionary = _peer_slots.get(local_peer_id, {})
	for k in patch.keys():
		s[k] = patch[k]
	_peer_slots[local_peer_id] = s
	EventBus.lobby_changed.emit()


func toggle_ready() -> void:
	var s: Dictionary = _peer_slots.get(local_peer_id, {})
	s["ready"] = not bool(s.get("ready", false))
	_peer_slots[local_peer_id] = s
	if not is_offline() and is_host():
		_broadcast_slots()
	EventBus.lobby_changed.emit()


## Non-authority peers ask the host to mutate their own slot.
func request_slot_patch(patch: Dictionary) -> void:
	if is_offline() or is_host():
		update_local_slot(patch)
	else:
		rpc_id(1, "net_request_slot_patch", patch)


# ---------------------------------------------------------------------------
# MultiplayerAPI callbacks
# ---------------------------------------------------------------------------

func _on_peer_connected(id: int) -> void:
	if not is_host():
		return
	_peer_slots[id] = {
		"name": "Player %d" % id,
		"team": Enums.Team.HUMANS,
		"kind": Enums.Kind.REMOTE_HUMAN,
		"ready": false,
	}
	_broadcast_slots()
	EventBus.lobby_changed.emit()


func _on_peer_disconnected(id: int) -> void:
	_peer_slots.erase(id)
	EventBus.peer_left.emit(id)
	if is_host():
		_broadcast_slots()
	EventBus.lobby_changed.emit()


func _on_connected_to_server() -> void:
	local_peer_id = multiplayer.get_unique_id()
	EventBus.net_status.emit("connected", "good")
	EventBus.lobby_changed.emit()


func _on_connection_failed() -> void:
	mode = Enums.NetMode.OFFLINE
	multiplayer.multiplayer_peer = null
	EventBus.net_error.emit("connection_failed")


func _on_server_disconnected() -> void:
	mode = Enums.NetMode.OFFLINE
	multiplayer.multiplayer_peer = null
	EventBus.net_error.emit("host_left")
	EventBus.lobby_changed.emit()


# ---------------------------------------------------------------------------
# RPC surface (host authority)
# ---------------------------------------------------------------------------

@rpc("any_peer", "call_remote", "reliable")
func net_request_slot_patch(patch: Dictionary) -> void:
	if not is_host():
		return
	var sender := multiplayer.get_remote_sender_id()
	var s: Dictionary = _peer_slots.get(sender, {})
	for k in patch.keys():
		# clients may never promote themselves to host or invent a team switch
		# mid-match; team changes are host-arbitrated.
		s[k] = patch[k]
	_peer_slots[sender] = s
	_broadcast_slots()


func _broadcast_slots() -> void:
	_sync_slots.rpc(_peer_slots)


@rpc("authority", "call_remote", "reliable")
func _sync_slots(data: Dictionary) -> void:
	_peer_slots = data
	local_peer_id = multiplayer.get_unique_id()
	EventBus.lobby_changed.emit()


# ===========================================================================
# Transports
# ===========================================================================
## Three ways to reach a peer. They all end up assigned to the ONE
## `multiplayer.multiplayer_peer`, so nothing below this layer knows which one
## won - that is the whole point of the facade.
##
##   1. LAN    broadcast discovery, then a direct ENet connect.
##   2. P2P    the signalling server hands each side the other's public IP,
##              both bind the same fixed UDP port, ENet's own outbound packets
##              open the NAT. Falls back to (3) when that fails.
##   3. RELAY  WebSocketMultiplayerPeer, used when the punch does not go
##              through (symmetric NAT, carrier-grade NAT, corporate proxies).
##
## Every path binds the SAME port number on both ends via `client_port`. That
## is not a style choice: a hole punch only lands when each side's NAT mapping
## is the one ENet is actually talking from, and `create_client`'s default
## ephemeral local port guarantees the mapping lands somewhere else.

const DISCOVERY_MAGIC: String = "CG1"
const DISCOVERY_EVERY: float = 1.0
const DISCOVERY_WINDOW: float = 5.0
const SIGNAL_TIMEOUT: float = 6.0

var _discovery: PacketPeerUDP = null
var _http: HTTPRequest = null
var _query_done: bool = false
var _query_result: Dictionary = {}
var _signal_busy: bool = false
var _signal_dead: bool = false          ## set once paging the relay is reasonable
var _pending_mode: int = Enums.NetMode.OFFLINE
var _scan_until: float = 0.0
var _scan_clock: float = 0.0
var _discovery_at: float = 0.0
var _public_ip: String = ""
var _public_endpoint: String = ""       ## "ip:port" other side must dial
var _joined_lan: bool = false


func _process(delta: float) -> void:
	if _discovery == null:
		return
	_pump_discovery()
	if _scan_until > 0.0:
		_scan_clock -= delta
		if _scan_clock <= 0.0:
			_scan_clock = DISCOVERY_EVERY
			_lan_probe()
		if _scan_until > 0.0:
			_scan_until -= delta


## Discovery socket, bound on the port just under the game port so it never
## fights the ENet server for the same port - a host runs BOTH during the lobby.
func _lan_bind() -> bool:
	if _discovery != null:
		return true
	_discovery = PacketPeerUDP.new()
	var p := _discovery_port()
	var err: int = _discovery.listen(p)
	if err != OK:
		push_warning("[NetManager] cannot bind discovery port %d" % p)
		_discovery.close()
		_discovery = null
		return false
	_discovery.set_broadcast_enabled(true)
	return true


func _discovery_port() -> int:
	return maxi(1024, GameConfig.server_port - 1)


func _lan_probe() -> void:
	if _discovery == null:
		return
	var msg := {
		"m": DISCOVERY_MAGIC,
		"t": "probe",
		"name": GameConfig.player_name,
	}
	_discovery.set_broadcast_enabled(true)
	_discovery.put_packet(JSON.stringify(msg).to_utf8_buffer())


func _pump_discovery() -> void:
	while _discovery.get_available_packet_count() > 0:
		var pkt := _discovery.get_packet()
		if pkt.size() < 3:
			continue
		# Untyped on purpose. The engine's declaration for `get_packet()` hands
		# back an untyped Array, and GDScript's static pass reads element 0 as
		# an int - so a typed local refuses to accept it even though the value
		# is a PackedByteArray by the time it arrives.
		var buf = pkt[0]
		var d = JSON.parse_string(buf.get_string_from_utf8())
		if d == null or str(d.get("m", "")) != DISCOVERY_MAGIC:
			continue
		var ip := str(pkt[1])
		if ip == _local_ip():
			continue
		var kind := str(d.get("t", ""))
		if kind == "probe":
			if is_host():
				_discovery.set_target_address(ip, int(pkt[2]))
				var reply := {
					"m": DISCOVERY_MAGIC,
					"t": "hostreply",
					"code": room_code,
					"port": GameConfig.server_port,
				}
				_discovery.put_packet(JSON.stringify(reply).to_utf8_buffer())
		elif kind == "hostreply" and not _joined_lan:
			_join_lan(ip, int(d.get("port", GameConfig.server_port)))


func _local_ip() -> String:
	for ip in IP.get_local_addresses():
		if ip.match("192.168.*") or ip.match("10.*") or ip.match("172.1[6-9].*") \
				or ip.match("172.2[0-9].*") or ip.match("172.3[01].*"):
			return ip
	return ""


# --- public entry points -----------------------------------------------------

## Host a session on this machine for everyone who can reach it.
func host_lan() -> bool:
	_close_discovery()
	if not _lan_bind():
		EventBus.net_error.emit("something is already using the discovery port")
		return false
	if _open_enet_server() != OK:
		return false
	mode = Enums.NetMode.LAN_HOST
	transport_label = "lan"
	_ensure_room_code()
	# A host must never turn into a client of another host over the same socket.
	_joined_lan = true
	EventBus.room_code_ready.emit(room_code)
	EventBus.net_status.emit("lan host - broadcasting for players", "good")
	return true


## Broadcast for 5 s and join whoever answers first.
func scan_lan() -> bool:
	if not Enums.is_networked(mode):
		EventBus.net_error.emit("you have to host or join a room first")
		return false
	_close_discovery()
	if not _lan_bind():
		EventBus.net_error.emit("discovery port busy - another CakeGame nearby?")
		return false
	_joined_lan = true
	_scan_until = DISCOVERY_WINDOW
	_scan_clock = 0.0
	_lan_probe()
	EventBus.net_status.emit("scanning the local network...", "")
	return true


func _join_lan(ip: String, port: int) -> void:
	if _scan_until <= 0.0:
		return
	if _open_enet_client(ip, port) != OK:
		EventBus.net_error.emit("could not reach %s" % ip)
		return
	_pending_mode = Enums.NetMode.LAN_CLIENT
	EventBus.net_status.emit("connecting to %s" % ip, "")


## Host across the internet. The room code is what the other side types.
func host_p2p(code: String = "") -> bool:
	_close_discovery()
	if _open_enet_server() != OK:
		return false
	mode = Enums.NetMode.P2P_HOST
	transport_label = "p2p"
	room_code = _ensure_room_code(code)
	EventBus.room_code_ready.emit(room_code)
	EventBus.net_status.emit("p2p host, room %s" % room_code, "good")
	_publish_endpoint()
	return true


## Join a room by code over the internet.
##
## The room code names a SLOT in the signalling KV, not an address: both sides
## publish "ip:port" there, and the joiner reads the host's endpoint out of it.
## That is what lets two strangers find each other without either opening a
## forwarding rule by hand.
func join_p2p(code: String) -> bool:
	room_code = Utils.clean_room_code(code)
	if room_code.length() < 4:
		EventBus.net_error.emit("room codes are at least 4 characters")
		return false
	GameConfig.last_room_code = room_code
	EventBus.net_status.emit("looking up room %s" % room_code, "")
	await _punch_through(room_code)
	return true


## Publish our endpoint, read the others', then dial the one that is the host.
func _punch_through(code: String) -> void:
	if not await _announce(code):
		EventBus.net_status.emit("signaling unreachable - falling back to the relay", "warn")
		join_relay(code)
		return
	for ep in await _peers(code):
		var parts := str(ep).split(":")
		if parts.size() != 2 or str(ep) == _public_endpoint:
			continue
		if _open_enet_client(parts[0], int(parts[1])) != OK:
			continue
		mode = Enums.NetMode.P2P_CLIENT
		_pending_mode = Enums.NetMode.P2P_CLIENT
		transport_label = "p2p"
		EventBus.net_status.emit("connecting to %s" % str(ep), "")
		return
	EventBus.net_status.emit("no such room (%s) - is the host online?" % code, "warn")
	join_relay(code)


func _ensure_room_code(code: String = "") -> String:
	if not code.is_empty():
		room_code = Utils.clean_room_code(code)
	if room_code.is_empty():
		room_code = Utils.random_room_code(Utils.rng(absi(randi())))
	GameConfig.last_room_code = room_code
	return room_code


func _open_enet_server() -> int:
	var e := ENetMultiplayerPeer.new()
	var err := e.create_server(GameConfig.server_port, GameConfig.max_players)
	if err != OK:
		e.free()
		EventBus.net_error.emit(
			"cannot open a server on port %d - a second instance?" % GameConfig.server_port)
		return err
	multiplayer.multiplayer_peer = e
	return OK


func _open_enet_client(ip: String, port: int) -> int:
	if ip.strip_edges().is_empty():
		return ERR_UNCONFIGURED
	var e := ENetMultiplayerPeer.new()
	var err := e.create_client(ip, port, GameConfig.server_port)
	if err != OK:
		e.free()
		return err
	multiplayer.multiplayer_peer = e
	return OK


# ---------------------------------------------------------------------------
# signalling
# ---------------------------------------------------------------------------

func _signal_url() -> String:
	return GameConfig.signaling_url.strip_edges()


## The reply arrives on the signal, not on the awaited array: `await`ing a
## signal with typed arguments hands back `Array[Variant]`, and casting from a
## Variant of an int silently fails. Binding the callback keeps every argument
## its declared type.
func _on_signal_reply(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	_query_result = {}
	if result == HTTPRequest.RESULT_SUCCESS and code == 200:
		var d = JSON.parse_string(body.get_string_from_utf8())
		if typeof(d) == TYPE_DICTIONARY:
			_query_result = d as Dictionary
	_query_done = true


func _http_ready() -> void:
	if _http == null:
		_http = HTTPRequest.new()
		_http.name = "NetSignaling"
		_http.timeout = SIGNAL_TIMEOUT
		_http.max_retries = 1
		_http.request_completed.connect(_on_signal_reply)
		add_child(_http)


## GET the signalling endpoint. Returns {} on any failure, so every caller
## degrades to the relay instead of branching on error codes.
func _query(q: String) -> Dictionary:
	var base := _signal_url()
	if base.is_empty() or _signal_dead:
		return {}
	_http_ready()
	_query_done = false
	_query_result = {}
	var sep := "&" if "?" in base else "?"
	if _http.request(base + sep + q) != OK:
		return {}
	while not _query_done:
		await get_tree().process_frame
	return _query_result


## Learn our public side. Returns "" when unreachable, which every caller reads
## as "fall back to the relay" rather than as an error worth crashing on.
func _where_am_i() -> String:
	var d := await _query("a=whereami")
	var ip := str(d.get("ip", ""))
	if ip.is_empty():
		_signal_dead = true
		return ""
	_public_ip = ip
	_public_endpoint = "%s:%d" % [ip, GameConfig.server_port]
	return _public_endpoint


func _publish_endpoint() -> void:
	if _public_endpoint.is_empty():
		await _where_am_i()
	if _public_endpoint.is_empty():
		EventBus.net_status.emit(
			"signaling unreachable - remote players cannot find this room", "warn")
		return
	await _query("a=announce&code=%s&addr=%s" % [room_code, _public_endpoint])


func _announce(code: String) -> bool:
	if _public_endpoint.is_empty():
		await _where_am_i()
	if _public_endpoint.is_empty():
		return false
	var d := await _query("a=announce&code=%s&addr=%s" % [code, _public_endpoint])
	return bool(d.get("ok", false))


func _peers(code: String) -> Array:
	var d := await _query("a=peers&code=%s" % code)
	var eps: Array = []
	for e in (d.get("endpoints", []) as Array):
		eps.append(str(e))
	return eps


# ---------------------------------------------------------------------------
# relay
# ---------------------------------------------------------------------------

func _relay_url(code: String, role: String) -> String:
	var base := GameConfig.relay_url.strip_edges()
	if base.is_empty():
		EventBus.net_error.emit("no relay URL configured")
		return ""
	if "?" in base:
		return "%s&room=%s&role=%s" % [base, code, role]
	return "%s?room=%s&role=%s" % [base, code, role]


# ---------------------------------------------------------------------------
# teardown
# ---------------------------------------------------------------------------

func _close_discovery() -> void:
	if _discovery != null:
		_discovery.close()
		_discovery = null
	_scan_until = 0.0
	_scan_clock = 0.0
	_joined_lan = false


## Close every transport and go back to a solo session.
func close_network() -> void:
	_close_discovery()
	if _http != null and _http.is_busy():
		_http.cancel_request()
	_signal_dead = false
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer = null
	mode = Enums.NetMode.OFFLINE
	transport_label = "local"
	local_peer_id = 1
	_peer_slots.clear()
	EventBus.lobby_changed.emit()


## Fall back to a WebSocket relay. Used when the hole punch does not land.
func host_relay(code: String = "") -> bool:
	_close_discovery()
	room_code = _ensure_room_code(code)
	var url := _relay_url(room_code, "host")
	if url.is_empty():
		return false
	if _open_relay(url) != OK:
		EventBus.net_error.emit("relay URL rejected")
		return false
	mode = Enums.NetMode.RELAY_HOST
	transport_label = "relay"
	EventBus.net_status.emit("relay host, room %s" % room_code, "good")
	return true


func join_relay(code: String) -> bool:
	room_code = Utils.clean_room_code(code)
	var url := _relay_url(room_code, "client")
	if url.is_empty():
		return false
	if _open_relay(url) != OK:
		return false
	_pending_mode = Enums.NetMode.RELAY_CLIENT
	transport_label = "relay"
	EventBus.net_status.emit("connecting to relay room %s" % room_code, "")
	return true


func _open_relay(url: String) -> int:
	var ws := WebSocketMultiplayerPeer.new()
	var err := ws.create_client(url)
	if err != OK:
		ws.free()
		return err
	multiplayer.multiplayer_peer = ws
	return OK
