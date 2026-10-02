class_name BtpsBridge
extends RefCounted

## Transport to the Python side of the BTPS host.
##
## Why loopback TCP and not a pipe: `OS.execute_with_pipe()` hands back the
## child's stdout but gives us no way to write to its stdin, and a one-way pipe
## cannot carry a request/response protocol. So `bridge.py` binds an ephemeral
## port on 127.0.0.1, drops the number into a port file, and we connect to it.
##
## Polling is caller driven (no threads): the owner calls `poll()` from
## `_process`, which is what keeps reads and writes on the main thread.

enum Phase { IDLE, WAITING_PORT, CONNECTING, LIVE, DEAD }

const CONNECT_TIMEOUT: float = 20.0
const REQUEST_TIMEOUT: float = 8.0

## Set by the owner. Called with a Dictionary for unsolicited events
## (`log` / `notify` / `fatal`). Never called with a request response.
var on_event: Callable
## Set by the owner. Called with (phase) whenever the phase changes.
var on_phase: Callable

var phase: int = Phase.IDLE
var last_error: String = ""

var _pid: int = 0
var _stdio: FileAccess = null
var _log_path: String = ""
var _port_path: String = ""
var _peer: StreamPeerTCP = null
var _rx: String = ""
var _outbox: Array[Dictionary] = []
var _pending: Dictionary = {}
var _next_id: int = 1
var _waited: float = 0.0


## `python_cmd` is the interpreter plus any launcher arguments (`py -3`): those
## belong to the interpreter, not to the script, and dropping them makes the
## launcher fail with "no installed Python found".
func start(python_cmd: PackedStringArray, script_path: String, root: String,
		log_path: String, port_path: String, trace_path: String = "") -> bool:
	if phase == Phase.LIVE or phase == Phase.CONNECTING or phase == Phase.WAITING_PORT:
		return true
	if python_cmd.is_empty():
		_fail("no python command given")
		return false
	_port_path = port_path
	if FileAccess.file_exists(port_path):
		DirAccess.remove_absolute(port_path)
	DirAccess.make_dir_recursive_absolute(root.get_base_dir())

	var args := PackedStringArray(python_cmd)
	args.append_array(PackedStringArray([
		script_path,
		"--root", root,
		"--transport", "tcp",
		"--log-file", log_path,
		"--port-file", port_path,
	]))
	if not trace_path.is_empty():
		args.append("--trace-file")
		args.append(trace_path)
	print("[btps] spawn: %s | port-file=%s | root=%s" % [
		" ".join(args), port_path, root])
	# `create_process`, not `execute_with_pipe`.
	#
	# A pipe we never drain is a liability: with execute_with_pipe the child
	# stayed alive but never ran a single line while the host's main loop was
	# turning, and only started working when the main thread was busy-waiting.
	# The bridge does not need a pipe - the handshake is a file and everything
	# after it is a socket - so the child is simply detached.
	_pid = OS.create_process(python_cmd[0], args.slice(1))
	if _pid < 0:
		_fail("could not start the python bridge process")
		return false
	_log_path = log_path
	# The stdio handle is intentionally left unread: everything after the
	# handshake travels over the socket, and a full pipe would stall the child.
	_set_phase(Phase.WAITING_PORT)
	_waited = 0.0
	return true


func stop() -> void:
	if _peer != null and _peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		# Best effort: the process is about to be signalled anyway, and a failed
		# write here must not prevent the cleanup below.
		_peer.put_data((JSON.stringify({"id": _next_id, "cmd": "shutdown", "args": {}}) + "\n").to_utf8_buffer())
		_next_id += 1
	_peer = null
	if _pid != 0 and OS.is_process_running(_pid):
		OS.kill(_pid)
	_pid = 0
	_pending.clear()
	_outbox.clear()
	_set_phase(Phase.IDLE)


func is_live() -> bool:
	return phase == Phase.LIVE


## Fire a command. `callback` receives (ok: bool, result: Variant, error: String).
func request(cmd: String, args: Dictionary = {}, callback: Callable = Callable()) -> void:
	var envelope := {"id": _next_id, "cmd": cmd, "args": args}
	_next_id += 1
	if phase == Phase.LIVE:
		_write(envelope, callback)
	else:
		_outbox.append({"env": envelope, "cb": callback})


func poll(delta: float) -> void:
	match phase:
		Phase.WAITING_PORT:
			_waited += delta
			if FileAccess.file_exists(_port_path):
				var port := _read_port()
				if port > 0:
					_connect(port)
					return
			if _waited > CONNECT_TIMEOUT:
				_fail("the bridge never published its port (%s)" % _last_words())
		Phase.CONNECTING:
			_waited += delta
			_peer.poll()
			var state := _peer.get_status()
			if state == StreamPeerTCP.STATUS_CONNECTED:
				_set_phase(Phase.LIVE)
				_flush_outbox()
			elif state == StreamPeerTCP.STATUS_ERROR:
				_fail("could not connect to the bridge socket")
			elif _waited > CONNECT_TIMEOUT:
				_fail("timed out connecting to the bridge socket")
		Phase.LIVE:
			_peer.poll()
			if _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
				_fail("the bridge process went away")
				return
			_drain()
			_reap_requests(delta)
		_:
			pass


# --------------------------------------------------------------------------- #
# internals
# --------------------------------------------------------------------------- #

## The port file holds JSON (`{"port": n, ...}`); a bare integer is accepted
## too so an older runtime still handshakes.
func _read_port() -> int:
	var text := FileAccess.get_file_as_string(_port_path).strip_edges()
	if text.is_empty():
		return 0
	var parsed: Variant = JSON.parse_string(text)
	if parsed != null and typeof(parsed) == TYPE_DICTIONARY:
		return int((parsed as Dictionary).get("port", 0))
	if text.is_valid_int():
		return int(text)
	return 0


func _connect(port: int) -> void:
	_peer = StreamPeerTCP.new()
	# No set_no_delay() here: the socket is not open until connect_to_host has
	# been polled, and calling it early logs a spurious engine error. Loopback
	# latency is irrelevant at this message rate anyway.
	var err := _peer.connect_to_host("127.0.0.1", port)
	if err != OK:
		_fail("connect_to_host failed: %d" % err)
		return
	_waited = 0.0
	_set_phase(Phase.CONNECTING)


func _write(envelope: Dictionary, callback: Callable) -> void:
	var ident: int = int(envelope["id"])
	_pending[ident] = {"cb": callback, "t": 0.0, "cmd": str(envelope.get("cmd", ""))}
	var line := JSON.stringify(envelope) + "\n"
	var err := _peer.put_data(line.to_utf8_buffer())
	if err != OK:
		_pending.erase(ident)
		if callback.is_valid():
			callback.call(false, null, "socket write failed (%d)" % err)


func _flush_outbox() -> void:
	for item in _outbox:
		_write(item["env"], item["cb"])
	_outbox.clear()


func _drain() -> void:
	var available := _peer.get_available_bytes()
	if available <= 0:
		return
	var got := _peer.get_data(available)
	if got[0] != OK:
		return
	_rx += (got[1] as PackedByteArray).get_string_from_utf8()
	var cut := _rx.find("\n")
	while cut >= 0:
		var line := _rx.substr(0, cut).strip_edges()
		_rx = _rx.substr(cut + 1)
		if line != "":
			_handle_line(line)
		cut = _rx.find("\n")


func _handle_line(line: String) -> void:
	var parsed: Variant = JSON.parse_string(line)
	if parsed == null or typeof(parsed) != TYPE_DICTIONARY:
		return
	var message := parsed as Dictionary
	if message.has("event"):
		if on_event.is_valid():
			on_event.call(message)
		return
	var ident: int = int(message.get("id", 0))
	if not _pending.has(ident):
		return
	var slot: Dictionary = _pending[ident]
	_pending.erase(ident)
	var cb: Callable = slot.get("cb", Callable())
	if not cb.is_valid():
		return
	if bool(message.get("ok", false)):
		cb.call(true, message.get("result", null), "")
	else:
		cb.call(false, null, str(message.get("error", "unknown error")))


func _reap_requests(delta: float) -> void:
	for ident in _pending.keys():
		var slot: Dictionary = _pending[ident]
		slot["t"] = float(slot.get("t", 0.0)) + delta
		if float(slot["t"]) > REQUEST_TIMEOUT:
			_pending.erase(ident)
			var cb: Callable = slot.get("cb", Callable())
			if cb.is_valid():
				cb.call(false, null, "timed out waiting for '%s'" % slot.get("cmd", "?"))
	# Iterating a Dictionary while erasing is safe in GDScript, but the erase
	# above invalidates nothing else, so no second pass is needed.


## Whatever the child said before giving up. Read once, at the end: a pipe we
## never drain is otherwise a mystery when startup fails.
func _last_words() -> String:
	var bits: Array[String] = []
	if _pid != 0:
		bits.append("alive=%s" % str(OS.is_process_running(_pid)))
	if _stdio != null and not _stdio.eof_reached():
		for _i in 4:
			var line := _stdio.get_line()
			if line.is_empty():
				break
			bits.append(line)
	if FileAccess.file_exists(_log_path):
		var tail := FileAccess.get_file_as_string(_log_path).strip_edges()
		if not tail.is_empty():
			bits.append(tail.right(300))
	return " | ".join(bits) if not bits.is_empty() else "no output at all"


func _fail(reason: String) -> void:
	last_error = reason
	stop()
	_set_phase(Phase.DEAD)


func _set_phase(next: int) -> void:
	if phase == next:
		return
	phase = next
	if on_phase.is_valid():
		on_phase.call(next)
