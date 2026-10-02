extends Node
## Autoload name: BtpsHost. No `class_name` on purpose - declaring one would
## hide the autoload singleton of the same name, and every script refers to the
## singleton, not to a class.

## CakeGame's side of the BTPS host.
##
## The plugin runtime itself lives in Python (`assets/btps_runtime/`), because
## BTPS 1.0 is a Python standard and reimplementing it in GDScript would drift
## from the spec. This node owns the *consequences*: it decides whether a
## Python exists, releases the runtime out of the pck (a packaged `res://` file
## has no real path a foreign process can open), drives the bridge, and exposes
## the three things a plugin is allowed to touch.
##
## Design rule that shapes everything below: **a broken plugin system must never
## break the game.** Every entry point degrades to "no plugins" and logs.

enum Status { OFF, NO_PYTHON, STARTING, READY, ERROR }

signal status_changed(status: int)
signal plugins_changed()

## Hooks CakeGame adds on top of the nine core ones. Must stay in sync with
## EXTRA_HOOKS in bridge.py - a plugin declaring a hook the runtime does not
## know about is rejected at registration.
const HOOK_BOT_BRAIN: String = "cakegame.bot.brain"
const HOOK_MAP_GENERATE: String = "cakegame.map.generate"
const HOOK_CONTENT: String = "cakegame.content.register"
const HOOK_TICK: String = "cakegame.tick"
const HOOK_STARTUP: String = "cakegame.startup"
const HOOK_SHUTDOWN: String = "cakegame.shutdown"

## Permission prefixes that require an explicit yes from the player. Matches
## BTPS's own sensitive list.
const SENSITIVE_PREFIXES: Array[String] = ["fs.write", "net.", "host.process", "host.env"]

const ROOT: String = "user://plugins"
const RUNTIME_DIR: String = "user://btps_runtime"
const RES_RUNTIME: String = "res://assets/btps_runtime"
const PORT_FILE: String = "user://btps_runtime/bridge.port"
const LOG_FILE: String = "user://btps_runtime/bridge.log"
const TRACE_FILE: String = "user://btps_runtime/bridge.trace"
const RUNTIME_MARKER: String = "VERSION"

const PY_PROBE_MARKER: String = "CakeGameBtpsProbe"
const TICK_INTERVAL: float = 0.5
## Frames to wait before spawning the child process.
##
## Measured: `OS.execute_with_pipe()` called from autoload `_ready` or from a
## `call_deferred` on the first frame starts a process that stays alive but
## never runs - no output, no files, nothing. Spawned a few frames later the
## identical command works. Eight frames is ~0.13 s, invisible to a player.
const BOOT_DELAY_FRAMES: int = 8
## How many times the bridge may be restarted after an unexpected death before
## the host stops trying and reports a real error. One is deliberate: it covers
## "a plugin killed the interpreter" without looping forever on a broken install.
const MAX_RESTARTS: int = 1
## How long a bridge must stay up before it is considered healthy and the restart
## budget is handed back.
##
## The obvious implementation - refund the budget the moment the bridge reaches
## LIVE - is wrong, and wrong in the worst way. A plugin that crashes the
## interpreter while it loads produces exactly this cycle: bridge starts, goes
## LIVE, plugin loads, interpreter dies, restart. Refunding on every LIVE makes
## the budget infinite, so a single bad `.btp` becomes an unbounded respawn loop
## with a Python process appearing and vanishing several times a second.
##
## A bridge that has held up for this long was not killed by startup, so giving
## the budget back then is safe: the common real case is a plugin that segfaults
## the interpreter mid-session, and it should be recoverable.
const STABLE_UPTIME: float = 30.0

var status: int = Status.OFF
var status_note: String = ""
## Interpreter plus launcher args, because `py` only works as `py -3`.
var python_path: String = ""
var python_cmd: PackedStringArray = PackedStringArray()
## Raw records from the runtime: id / version / state / permissions / manifest.
var plugins: Array[Dictionary] = []
## Plugin-provided bot brains, id -> {"plugin", "name", "desc_en", "desc_zh"}.
var brains: Dictionary = {}

var _bridge: BtpsBridge = null
var _tick_accum: float = 0.0
var _boot_countdown: int = -1
## Restart budget left after bridge deaths; reset on every successful boot.
var _restarts: int = 0
var _restart_countdown: int = -1
## How long the current bridge has been READY. Drives the STABLE_UPTIME refund.
var _live_time: float = 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_bridge = BtpsBridge.new()
	_bridge.on_event = _on_bridge_event
	_bridge.on_phase = _on_bridge_phase
	_chain_bus()
	if bool(GameConfig.get("btps_enabled")):
		request_boot()


## Queue a boot for a few frames from now. See BOOT_DELAY_FRAMES.
func request_boot() -> void:
	if status == Status.STARTING or status == Status.READY:
		return
	_boot_countdown = BOOT_DELAY_FRAMES


func _process(delta: float) -> void:
	if _bridge == null:
		return
	if _boot_countdown > 0:
		_boot_countdown -= 1
		if _boot_countdown == 0:
			boot()
	if _restart_countdown > 0:
		_restart_countdown -= 1
		if _restart_countdown == 0:
			_restart_countdown = -1
			boot()
	_bridge.poll(delta)
	if status != Status.READY:
		return
	# Only a bridge that has proven it can stay up refunds the restart budget -
	# see STABLE_UPTIME for why this is not done the moment it goes LIVE.
	_live_time += delta
	if _live_time >= STABLE_UPTIME and _restarts > 0:
		_restarts = 0
	_tick_accum += delta
	if _tick_accum >= TICK_INTERVAL:
		_tick_accum = 0.0
		emit_hook(HOOK_TICK, {"t": Time.get_ticks_msec() / 1000.0})


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		shutdown()


# --------------------------------------------------------------------------- #
# lifecycle
# --------------------------------------------------------------------------- #

func boot() -> void:
	# `STARTING` is not a reason to refuse: a restart also goes through
	# STARTING, and bailing out here would make the retry a no-op.
	if status == Status.READY:
		return
	_set_status(Status.STARTING, "")
	var found := _resolve_python()
	if found.is_empty():
		_set_status(Status.NO_PYTHON, "no usable python interpreter found")
		return
	python_cmd = found
	python_path = " ".join(found)
	var released := _release_runtime()
	if released <= 0:
		_set_status(Status.ERROR, "could not release the BTPS runtime to user://")
		return
	var script := ProjectSettings.globalize_path(RUNTIME_DIR.path_join("bridge.py"))
	if not FileAccess.file_exists(script):
		_set_status(Status.ERROR, "bridge.py missing after release")
		return
	_bridge.start(
		python_cmd,
		script,
		ProjectSettings.globalize_path(ROOT),
		ProjectSettings.globalize_path(LOG_FILE),
		ProjectSettings.globalize_path(PORT_FILE),
		ProjectSettings.globalize_path(TRACE_FILE),
	)


func shutdown() -> void:
	# Cancel a pending restart first: `shutdown()` is what the player calls to
	# turn plugins OFF, and a queued retry firing afterwards would quietly
	# resurrect a host they just closed.
	_restart_countdown = -1
	_restarts = 0
	_live_time = 0.0
	if _bridge == null:
		return
	if _bridge.is_live():
		emit_hook(HOOK_SHUTDOWN, {})
	_bridge.stop()
	_set_status(Status.OFF, "")


func set_enabled(on: bool) -> void:
	GameConfig.btps_enabled = on
	if on:
		request_boot()
	else:
		_boot_countdown = -1
		shutdown()
		_clear_plugin_state()
		plugins_changed.emit()


# --------------------------------------------------------------------------- #
# python discovery
# --------------------------------------------------------------------------- #

## Returns the interpreter plus its launcher args, or an empty array when
## nothing usable is installed.
##
## A path is only accepted if it actually prints the marker: on Windows the
## Store alias at `WindowsApps/python.exe` is a redirector that exits non-zero
## with no output, so "the file exists" proves nothing.
func _resolve_python() -> PackedStringArray:
	var configured := str(GameConfig.get("btps_python_path")).strip_edges()
	if not configured.is_empty():
		var split := configured.split(" ", false)
		if _probe(split[0], split.slice(1)):
			return PackedStringArray(split)
	for candidate in _candidates():
		if _probe(candidate[0], candidate[1]):
			var cmd := PackedStringArray([candidate[0]])
			cmd.append_array(PackedStringArray(candidate[1]))
			return cmd
	return PackedStringArray()


func _candidates() -> Array:
	var out: Array = []
	out.append(["py", ["-3"]])
	out.append(["python", []])
	out.append(["python3", []])
	for found in _installed_windows_pythons():
		out.append([found, []])
	return out


## Scans the per-user Python install directory and returns the highest version
## first. Cheap: one directory read, no process spawning.
func _installed_windows_pythons() -> PackedStringArray:
	var base := "C:/Users/%s/AppData/Local/Programs/Python" % OS.get_environment("USERNAME")
	var out := PackedStringArray()
	var dir := DirAccess.open(base)
	if dir == null:
		return out
	var found: Array = []
	for sub in dir.get_directories():
		if not sub.begins_with("Python"):
			continue
		var exe := base.path_join(sub).path_join("python.exe")
		if FileAccess.file_exists(exe):
			found.append(exe)
	found.sort()
	found.reverse()
	for f in found:
		out.append(f)
	return out


func _probe(exe: String, prefix: Array) -> bool:
	var args := PackedStringArray(prefix)
	args.append("-c")
	args.append("print('%s')" % PY_PROBE_MARKER)
	var out: Array = []
	var code := OS.execute(exe, args, out, true)
	if code != 0 or out.is_empty():
		return false
	return str(out[0]).strip_edges().find(PY_PROBE_MARKER) >= 0


# --------------------------------------------------------------------------- #
# runtime release
# --------------------------------------------------------------------------- #

## Copy the vendored runtime out of the pck into user://. Returns the number of
## files written, or -1 on failure. Skipped when the marker already matches.
func _release_runtime() -> int:
	var marker_src := RES_RUNTIME.path_join(RUNTIME_MARKER)
	var marker_dst := RUNTIME_DIR.path_join(RUNTIME_MARKER)
	var want := FileAccess.get_file_as_string(marker_src).strip_edges()
	if not want.is_empty() and FileAccess.file_exists(marker_dst):
		if FileAccess.get_file_as_string(marker_dst).strip_edges() == want:
			return 1
	if DirAccess.open(RES_RUNTIME) == null:
		push_error("[BtpsHost] runtime missing at %s" % RES_RUNTIME)
		return -1
	var written := _copy_tree(RES_RUNTIME, RUNTIME_DIR)
	if written <= 0:
		return -1
	var marker := FileAccess.open(marker_dst, FileAccess.WRITE)
	if marker != null:
		marker.store_string(want)
		marker.close()
	return written


func _copy_tree(from: String, to: String) -> int:
	var dir := DirAccess.open(from)
	if dir == null:
		return 0
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(to))
	var count := 0
	for f in dir.get_files():
		if not (f.ends_with(".py") or f.ends_with(".md") or f.ends_with(".json") or f == RUNTIME_MARKER):
			continue
		var bytes := FileAccess.get_file_as_bytes(from.path_join(f))
		if bytes.is_empty() and not FileAccess.file_exists(from.path_join(f)):
			continue
		var handle := FileAccess.open(to.path_join(f), FileAccess.WRITE)
		if handle == null:
			continue
		handle.store_buffer(bytes)
		handle.close()
		count += 1
	for sub in dir.get_directories():
		count += _copy_tree(from.path_join(sub), to.path_join(sub))
	return count


# --------------------------------------------------------------------------- #
# bridge plumbing
# --------------------------------------------------------------------------- #

func _on_bridge_phase(phase: int) -> void:
	match phase:
		BtpsBridge.Phase.LIVE:
			_set_status(Status.READY, "")
			_live_time = 0.0
			refresh()
			emit_hook(HOOK_STARTUP, {"version": _game_version()})
		BtpsBridge.Phase.DEAD:
			_handle_bridge_death()
		BtpsBridge.Phase.IDLE:
			# `stop()` lands here too, so this cannot assume the bridge crashed.
			# A shutdown the player asked for is not a failure and must not put the
			# panel into an error state; only the DEAD path above may escalate.
			pass
		_:
			pass


## Restart the bridge once after an unexpected death.
##
## The plugin runtime lives in a child process, so a plugin that segfaults the
## interpreter takes nothing down with it - but it does take the plugin system
## down, and the player would otherwise have to restart the game to get it back.
## One retry covers the overwhelmingly common case (a plugin killed its own
## interpreter) without papering over a genuinely broken install: a second death
## is a real error and is reported as one.
##
## Restarting is deliberately deferred by a few frames rather than done inline.
## `_on_bridge_phase` runs inside `BtpsBridge.poll()`, and `boot()` from there
## would start a new child process in the middle of tearing the old one down.
func _handle_bridge_death() -> void:
	var was_enabled := bool(GameConfig.get("btps_enabled"))
	if not was_enabled:
		# The player turned plugins off, which is what asked for the death.
		_set_status(Status.OFF, "")
		return
	# A brain pointing at a bridge that no longer exists is worse than no brain:
	# every think would enqueue a request that can never be answered. Drop them
	# before the restart so a plugin's bot vanishes from the dropdown instead of
	# standing there inert.
	_clear_plugin_state()
	if _restarts >= MAX_RESTARTS:
		_set_status(Status.ERROR, _bridge.last_error)
		return
	_restarts += 1
	_set_status(Status.STARTING, "")
	_restart_countdown = BOOT_DELAY_FRAMES


## Forget every plugin-derived thing the host is holding.
##
## Called on death and on disable. `BotRegistry` is the important half: it is a
## static table, so a stale entry there outlives the plugin it names and the
## Settings dropdown would keep offering a bot that cannot be created.
func _clear_plugin_state() -> void:
	plugins.clear()
	brains.clear()
	BotRegistry.sync_plugin_brains(brains)


func _on_bridge_event(message: Dictionary) -> void:
	var kind := str(message.get("event", ""))
	if kind == "log":
		print("[btps:%s] %s" % [message.get("plugin", "-"), message.get("msg", "")])
	elif kind == "notify":
		EventBus.net_status.emit("%s: %s" % [message.get("title", ""), message.get("body", "")])
	elif kind == "fatal":
		_set_status(Status.ERROR, str(message.get("msg", "")))


func _game_version() -> String:
	var info: Variant = ProjectSettings.get_setting("application/config/version", "1.0.0")
	return str(info)


func _set_status(next: int, note: String) -> void:
	status = next
	status_note = note
	status_changed.emit(next)


# --------------------------------------------------------------------------- #
# plugin management
# --------------------------------------------------------------------------- #

func refresh() -> void:
	if _bridge == null or not _bridge.is_live():
		return
	_bridge.request("list", {}, func(ok: bool, result: Variant, _error: String) -> void:
		if not ok:
			return
		# `result` arrives as an untyped Array; copy element by element rather
		# than assigning, which GDScript refuses (Array -> Array[Dictionary]).
		plugins.clear()
		for record in (result.get("plugins", []) as Array):
			plugins.append(record as Dictionary)
		_reindex_brains()
		plugins_changed.emit()
	)


func _reindex_brains() -> void:
	brains.clear()
	for record in plugins:
		if str(record.get("state", "")) != "enabled":
			continue
		var manifest: Dictionary = record.get("manifest", {})
		# Reuse `hook_names` instead of reading `hooks` inline: the bridge hands
		# back whatever shape the manifest used, and a bare `Array` annotation on a
		# mapping raises a hard type error that aborts reindexing every brain.
		if not hook_names(manifest).has(HOOK_BOT_BRAIN):
			continue
		var pid := str(record.get("id", ""))
		brains[pid] = {
			"plugin": pid,
			"name": "%s (plugin)" % str(manifest.get("name", pid)),
			"desc_en": str(manifest.get("description", "Bot brain provided by a plugin.")),
			"desc_zh": "由插件提供的 Bot 大脑：%s" % str(manifest.get("description", "")),
		}
	BotRegistry.sync_plugin_brains(brains)


## Install a `.btp`. `granted` is the permission set the player agreed to.
func install(path: String, granted: PackedStringArray = PackedStringArray(),
		done: Callable = Callable()) -> void:
	if _bridge == null or not _bridge.is_live():
		_reject(done, "plugin host is not running")
		return
	_bridge.request("install", {
		"path": ProjectSettings.globalize_path(path),
		"granted": granted,
		"auto_enable": true,
	}, func(ok: bool, _result: Variant, error: String) -> void:
		if ok:
			refresh()
		if done.is_valid():
			done.call(ok, error)
	)


func set_enabled_state(plugin_id: String, on: bool, done: Callable = Callable()) -> void:
	if _bridge == null or not _bridge.is_live():
		_reject(done, "plugin host is not running")
		return
	_bridge.request("enable" if on else "disable", {"id": plugin_id},
		func(ok: bool, _result: Variant, error: String) -> void:
			if ok:
				refresh()
			if done.is_valid():
				done.call(ok, error)
	)


func uninstall(plugin_id: String, done: Callable = Callable()) -> void:
	if _bridge == null or not _bridge.is_live():
		_reject(done, "plugin host is not running")
		return
	_bridge.request("uninstall", {"id": plugin_id}, func(ok: bool, _r: Variant, error: String) -> void:
		if ok:
			refresh()
		if done.is_valid():
			done.call(ok, error)
	)


func grant(plugin_id: String, permissions: PackedStringArray) -> void:
	if _bridge == null or not _bridge.is_live():
		return
	_bridge.request("grant", {"id": plugin_id, "permissions": permissions},
		func(_ok: bool, _r: Variant, _e: String) -> void:
			refresh()
	)


func _reject(done: Callable, why: String) -> void:
	if done.is_valid():
		done.call(false, why)


# --------------------------------------------------------------------------- #
# hooks and capabilities
# --------------------------------------------------------------------------- #

func emit_hook(hook: String, data: Dictionary = {}) -> void:
	if _bridge == null or not _bridge.is_live():
		return
	_bridge.request("emit", {"hook": hook, "data": data})


## True when at least one enabled plugin declares `hook`.
func declares(hook: String) -> bool:
	for record in plugins:
		if str(record.get("state", "")) != "enabled":
			continue
		if hook_names(record.get("manifest", {})).has(hook):
			return true
	return false


## Hook names from a serialised manifest.
##
## `Manifest.to_dict()` emits hooks as a mapping (name -> declaration) while a
## hand-written manifest may use an array of objects, so both shapes have to be
## read. Getting this wrong is a runtime type error, not a graceful miss, and it
## fires inside the bot's decision function.
static func hook_names(manifest: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	var raw: Variant = manifest.get("hooks", [])
	if typeof(raw) == TYPE_DICTIONARY:
		for key in (raw as Dictionary):
			out.append(str(key))
	elif typeof(raw) == TYPE_ARRAY:
		for entry in (raw as Array):
			if typeof(entry) == TYPE_DICTIONARY:
				out.append(str((entry as Dictionary).get("name", "")))
			else:
				out.append(str(entry))
	return out


## Call one plugin's handler for `hook`. Callback gets (ok, result, error).
func invoke(plugin_id: String, hook: String, args: Dictionary = {},
		done: Callable = Callable(), timeout: float = 1.0) -> void:
	if _bridge == null or not _bridge.is_live():
		if done.is_valid():
			done.call(false, null, "plugin host is not running")
		return
	_bridge.request("invoke", {
		"plugin": plugin_id,
		"hook": hook,
		"args": args,
		"timeout": timeout,
	}, done)


func plugins_for_hook(hook: String) -> PackedStringArray:
	var out := PackedStringArray()
	for record in plugins:
		if str(record.get("state", "")) != "enabled":
			continue
		var manifest: Dictionary = record.get("manifest", {})
		if hook_names(manifest).has(hook):
			out.append(str(record.get("id", "")))
	return out


## Split a manifest's permissions into the ones that need asking about.
func sensitive_permissions(manifest: Dictionary) -> PackedStringArray:
	var out := PackedStringArray()
	for p in manifest.get("permissions", []):
		var name := str(p)
		for prefix in SENSITIVE_PREFIXES:
			if name.begins_with(prefix):
				out.append(name)
				break
	return out


# --------------------------------------------------------------------------- #
# scanning: read a .btp without python
# --------------------------------------------------------------------------- #

## List `*.btp` sitting in `user://plugins`, with their manifest if readable.
## This is how the UI shows "what would I be installing" before committing.
func scan_packages() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var dir := DirAccess.open(ROOT)
	if dir == null:
		return out
	for f in dir.get_files():
		if not f.ends_with(".btp"):
			continue
		var full := ROOT.path_join(f)
		var manifest := read_manifest(full)
		out.append({
			"path": full,
			"file": f,
			"manifest": manifest,
			"readable": not manifest.is_empty(),
		})
	return out


func read_manifest(btp_path: String) -> Dictionary:
	var reader := ZIPReader.new()
	var err := reader.open(ProjectSettings.globalize_path(btp_path))
	if err != OK:
		reader.close()
		return {}
	var raw := reader.read_file("btps.json", false)
	reader.close()
	if raw.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(raw.get_string_from_utf8())
	if parsed == null or typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return parsed as Dictionary


# --------------------------------------------------------------------------- #
# event bus bridge
# --------------------------------------------------------------------------- #

func _chain_bus() -> void:
	EventBus.actor_died.connect(func(actor: Node, killer: Node, kind: int) -> void:
		emit_hook("cakegame.actor.died", {
			"name": actor.name if actor != null else "",
			"team": int(actor.get("team")) if actor != null else -1,
			"killer": killer.name if killer != null else "",
			"kind": kind,
		})
	)
	EventBus.actor_damaged.connect(func(actor: Node, amount: float, kind: int, source: Node) -> void:
		emit_hook("cakegame.actor.damaged", {
			"name": actor.name if actor != null else "",
			"amount": amount,
			"kind": kind,
			"source": source.name if source != null else "",
		})
	)
	EventBus.match_started.connect(func(_mode: int) -> void:
		emit_hook("cakegame.match.begin", {})
	)
	EventBus.match_finished.connect(func(winner: int) -> void:
		emit_hook("cakegame.match.end", {"winner": winner})
	)
