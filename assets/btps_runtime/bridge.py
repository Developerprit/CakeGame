#!/usr/bin/env python3
"""CakeGame <-> BTPS bridge.

Line-delimited JSON over stdio: one request per line, one response per line.
Every response carries the request ``id`` so the host can match them out of
order; lines without an ``id`` are unsolicited events (log / notify / ready).

All output is English - the project rule for CLI-facing tooling.

Usage::

    python bridge.py --root <install_root> [--host-version 1.0.0]

Protocol
--------
request   {"id": 1, "cmd": "list"}
response  {"id": 1, "ok": true, "result": [...]}
failure   {"id": 1, "ok": false, "error": "..."}
event     {"event": "log", "level": "warn", "plugin": "...", "msg": "..."}

Transport
---------
``--transport tcp`` (default) listens on 127.0.0.1 with an ephemeral port and
prints the port number in the ``ready`` event on stdout. This exists because
Godot's ``OS.execute_with_pipe()`` hands back the child's stdout but provides
no way to write to the child's stdin - a one-way pipe cannot carry a
request/response protocol. TCP on loopback is the smallest thing that is
actually bidirectional.

``--transport stdio`` keeps the original stdin/stdout loop, which is what the
command line tests use.
"""

from __future__ import annotations

import argparse
import inspect
import json
import os
import sys
import time
import traceback

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

# Imported at module scope because `class BridgeAdapter(DefaultHostAdapter)` is
# evaluated while the module loads. A failure here happens before any redirect,
# so it is mirrored to a crash log next to this file - otherwise the child dies
# writing its traceback into a pipe nobody drains and the host just sees a
# process that vanished.
try:
    from btps import DefaultHostAdapter, PluginRuntime  # noqa: E402
    from btps.sandbox import call_with_timeout  # noqa: E402
except Exception:  # noqa: BLE001
    try:
        with open(
            os.path.join(_HERE, "bridge.crash.log"), "w", encoding="utf-8"
        ) as _crash:
            _crash.write(traceback.format_exc())
    except OSError:
        pass
    raise

# Hooks CakeGame adds on top of the nine core ones. Declaring them here is what
# lets a plugin list them in its manifest without tripping the
# "may not subscribe to undeclared hook" guard.
EXTRA_HOOKS = (
    "cakegame.startup",
    "cakegame.shutdown",
    "cakegame.tick",
    "cakegame.match.begin",
    "cakegame.match.end",
    "cakegame.actor.damaged",
    "cakegame.actor.died",
    "cakegame.bot.brain",
    "cakegame.map.generate",
    "cakegame.content.register",
)

CAPABILITIES = (
    "host.ui.notify",
    "host.storage",
    "cakegame.bot.brain",
    "cakegame.map.generate",
    "cakegame.content.skin",
    "cakegame.content.sfx",
    "cakegame.match.read",
)

DEFAULT_TIMEOUT = 4.0


def _trace(path: str, step: str) -> None:
    """Append a startup breadcrumb. Only active when --trace-file is given."""
    if not path:
        return
    try:
        with open(path, "a", encoding="utf-8") as handle:
            handle.write("%.3f %s\n" % (time.time() % 1000.0, step))
    except OSError:
        pass


def _accepts_argument(handler) -> bool:
    """Mirror of HookBus.Subscription.accepts_argument, for a bare function."""
    try:
        signature = inspect.signature(handler)
    except (TypeError, ValueError):
        return False
    for parameter in signature.parameters.values():
        if parameter.kind is inspect.Parameter.VAR_POSITIONAL:
            return True
        if parameter.kind in (
            inspect.Parameter.POSITIONAL_ONLY,
            inspect.Parameter.POSITIONAL_OR_KEYWORD,
        ):
            return True
    return False


def _write(payload: dict) -> None:
    try:
        sys.stdout.write(json.dumps(payload, ensure_ascii=False, default=str) + "\n")
        sys.stdout.flush()
    except (OSError, ValueError):
        pass  # A broken pipe means the host is gone; nothing useful to do.


class BridgeAdapter(DefaultHostAdapter):
    """Routes plugin log/notify calls back to the host as events.

    ``emit`` is rebound to the active transport once the host connects - on
    loopback TCP that means the socket, because anything written to stdout
    after the handshake would eventually fill the pipe and stall the process.
    """

    def __init__(self, emit=None, **kwargs) -> None:
        super().__init__(**kwargs)
        self.emit = emit if emit is not None else _write

    def log(self, level: str, message: str, **context) -> None:
        self.emit(
            {
                "event": "log",
                "level": str(level),
                "plugin": str(context.get("plugin_id", "-")),
                "msg": str(message),
            }
        )

    def notify(self, title: str, body: str, **context) -> None:
        self.emit(
            {
                "event": "notify",
                "title": str(title),
                "body": str(body),
                "plugin": str(context.get("plugin_id", "-")),
            }
        )


class Bridge:
    def __init__(self, install_root: str, host_version: str) -> None:
        self.root = install_root
        self.host_version = host_version
        self.runtime: PluginRuntime | None = None

    # ------------------------------------------------------------------ #
    # lifecycle
    # ------------------------------------------------------------------ #
    def init(self, auto_enable: bool = True) -> dict:
        os.makedirs(self.root, exist_ok=True)
        self.runtime = PluginRuntime(
            adapter=BridgeAdapter(version=self.host_version, api_version="1.0.0"),
            install_root=self.root,
            extra_hooks=EXTRA_HOOKS,
        )
        restored = self.runtime.restore(auto_enable=auto_enable)
        return {
            "root": self.root,
            "restored": [r.id for r in restored],
            "enabled": [r.id for r in restored if r.is_enabled],
        }

    def _rt(self) -> PluginRuntime:
        if self.runtime is None:
            raise RuntimeError("bridge not initialised")
        return self.runtime

    # ------------------------------------------------------------------ #
    # commands
    # ------------------------------------------------------------------ #
    def cmd_ping(self, args: dict) -> dict:
        import btps

        return {"pong": True, "btps": btps.__version__, "python": sys.version.split()[0]}

    def cmd_init(self, args: dict) -> dict:
        return self.init(auto_enable=bool(args.get("auto_enable", True)))

    def cmd_list(self, args: dict) -> dict:
        records = self._rt().list()
        return {"plugins": [r.to_dict(include_manifest=True) for r in records]}

    def cmd_install(self, args: dict) -> dict:
        path = str(args.get("path", ""))
        if not path:
            raise ValueError("install requires 'path'")
        granted = [str(p) for p in args.get("granted", [])]
        record = self._rt().install(
            path,
            granted_permissions=granted,
            auto_enable=bool(args.get("auto_enable", False)),
            overwrite=bool(args.get("overwrite", False)),
        )
        return {"plugin": record.to_dict(include_manifest=True)}

    def cmd_enable(self, args: dict) -> dict:
        record = self._rt().enable(str(args.get("id", "")))
        return {"plugin": record.to_dict(include_manifest=True)}

    def cmd_disable(self, args: dict) -> dict:
        record = self._rt().disable(str(args.get("id", "")))
        return {"plugin": record.to_dict(include_manifest=True)}

    def cmd_uninstall(self, args: dict) -> dict:
        self._rt().uninstall(str(args.get("id", "")), keep_data=bool(args.get("keep_data", False)))
        return {"uninstalled": str(args.get("id", ""))}

    def cmd_grant(self, args: dict) -> dict:
        record = self._rt().get(str(args.get("id", "")))
        if record is None or record.sandbox is None:
            raise RuntimeError("plugin is not loaded")
        for permission in args.get("permissions", []):
            record.sandbox.permissions.grant(str(permission))
        return {"granted": list(record.sandbox.permissions.granted)}

    def cmd_emit(self, args: dict) -> dict:
        hook = str(args.get("hook", ""))
        data = args.get("data") or {}
        report = self._rt().emit(hook, **data)
        return {"report": report.to_dict()}

    def cmd_invoke(self, args: dict) -> dict:
        """Call the handler a plugin declared for one of CakeGame's hooks."""
        plugin_id = str(args.get("plugin", ""))
        hook = str(args.get("hook", ""))
        payload = args.get("args") or {}
        timeout = float(args.get("timeout", DEFAULT_TIMEOUT))

        record = self._rt().get(plugin_id)
        if record is None:
            raise RuntimeError("no such plugin: %s" % plugin_id)
        if not record.is_enabled:
            raise RuntimeError("plugin %s is not enabled" % plugin_id)
        # Manifest.hooks is a tuple of HookDeclaration, not a mapping.
        declaration = None
        for candidate in record.manifest.hooks:
            if getattr(candidate, "name", None) == hook:
                declaration = candidate
                break
        if declaration is None:
            raise RuntimeError("plugin %s does not declare hook %s" % (plugin_id, hook))

        handler_name = getattr(declaration, "handler", None)
        if not handler_name:
            raise RuntimeError("hook %s has no handler name" % hook)
        function = getattr(record.module, handler_name, None)
        if function is None:
            raise RuntimeError(
                "hook %s declares handler %r, which the entry module does not export"
                % (hook, handler_name)
            )

        # Same calling convention HookBus uses: a handler that declares a
        # positional parameter gets exactly one argument, and a zero-argument
        # handler gets none. For CakeGame's own hooks that argument is the
        # payload dict, not the plugin context - the host defines the shape.
        if _accepts_argument(function):
            call = lambda: function(payload)  # noqa: E731
        else:
            call = lambda: function()  # noqa: E731

        result = call_with_timeout(
            call,
            timeout,
            plugin_id=plugin_id,
            hook=hook,
            audit=self._rt().audit,
        )
        return {"result": result}

    def cmd_shutdown(self, args: dict) -> dict:
        try:
            if self.runtime is not None:
                self.runtime.emit("host.shutdown")
        except Exception:  # noqa: BLE001 - shutdown must not raise
            pass
        return {"bye": True}


COMMANDS = {
    "ping": Bridge.cmd_ping,
    "init": Bridge.cmd_init,
    "list": Bridge.cmd_list,
    "install": Bridge.cmd_install,
    "enable": Bridge.cmd_enable,
    "disable": Bridge.cmd_disable,
    "uninstall": Bridge.cmd_uninstall,
    "grant": Bridge.cmd_grant,
    "emit": Bridge.cmd_emit,
    "invoke": Bridge.cmd_invoke,
    "shutdown": Bridge.cmd_shutdown,
}


def serve(bridge: Bridge, reader, emit_line) -> bool:
    """Serve requests until EOF. Returns False when a shutdown was requested."""
    for raw in reader:
        line = raw.strip()
        if not line:
            continue
        request_id = None
        try:
            request = json.loads(line)
            request_id = request.get("id")
            command = str(request.get("cmd", ""))
            handler = COMMANDS.get(command)
            if handler is None:
                raise RuntimeError("unknown command: %s" % command)
            result = handler(bridge, request.get("args") or {})
            emit_line({"id": request_id, "ok": True, "result": result})
            if command == "shutdown":
                return False
        except Exception as exc:  # noqa: BLE001 - one bad request must not kill the bridge
            emit_line(
                {
                    "id": request_id,
                    "ok": False,
                    "error": "%s: %s" % (type(exc).__name__, exc),
                    "trace": traceback.format_exc().splitlines()[-3:],
                }
            )
    return True


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="CakeGame BTPS bridge")
    parser.add_argument("--root", required=True, help="plugin install root")
    parser.add_argument("--host-version", default="1.0.0")
    parser.add_argument("--auto-enable", action="store_true")
    parser.add_argument(
        "--transport", choices=("tcp", "stdio"), default="tcp", help="how the host talks to us"
    )
    parser.add_argument("--log-file", default="", help="redirect stderr here (keeps pipes from filling)")
    parser.add_argument(
        "--port-file",
        default="",
        help="write the listening port here once bound; the host polls this file",
    )
    parser.add_argument("--trace-file", default="", help="append startup breadcrumbs here")
    opts = parser.parse_args(argv)
    if opts.trace_file:
        try:
            open(opts.trace_file, "w").close()  # one run per file
        except OSError:
            pass
    _trace(opts.trace_file, "argv parsed")

    if opts.log_file:
        try:
            handle = open(opts.log_file, "a", encoding="utf-8", errors="replace")
            sys.stderr = handle
            # stdout goes to the file too, and this is not cosmetic. Godot's
            # `execute_with_pipe` gives us a pipe it never drains, and a child
            # that writes to it after the main loop is running can block on the
            # write and never reach the code that publishes its port. Every
            # handshake value therefore travels through files instead.
            sys.stdout = handle
        except OSError:
            pass

    _trace(opts.trace_file, "runtime created")
    bridge = Bridge(opts.root, opts.host_version)
    try:
        ready = bridge.init(auto_enable=opts.auto_enable or True)
        _trace(opts.trace_file, "restore done")
    except Exception as exc:  # noqa: BLE001
        _write({"event": "fatal", "msg": "%s" % exc})
        return 1

    import btps

    hello = {
        "event": "ready",
        "btps": btps.__version__,
        "python": sys.version.split()[0],
        "root": ready["root"],
        "enabled": ready["enabled"],
    }

    if opts.transport == "stdio":
        _write(hello)
        serve(bridge, sys.stdin, _write)
        return 0

    import socket

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", 0))
    server.listen(1)
    host, port = server.getsockname()[:2]

    hello["port"] = port
    hello["host"] = host
    _trace(opts.trace_file, "bound on %d" % port)
    _write(hello)  # The host reads the port off stdout, then connects.

    # The port file is the handshake. JSON, not a bare number, so the host can
    # also learn the runtime version and skip a second round trip. Written and
    # fsync'd before anything that could block.
    if opts.port_file:
        try:
            directory = os.path.dirname(os.path.abspath(opts.port_file))
            if directory:
                os.makedirs(directory, exist_ok=True)
            with open(opts.port_file, "w", encoding="utf-8") as handle:
                json.dump(
                    {"port": port, "host": host, "btps": btps.__version__,
                     "python": sys.version.split()[0]},
                    handle,
                )
                handle.flush()
                os.fsync(handle.fileno())
        except OSError as exc:
            _write({"event": "log", "level": "warn", "plugin": "-", "msg": "port file: %s" % exc})

    try:
        while True:
            connection, _address = server.accept()
            stream = connection.makefile("rw", encoding="utf-8", errors="replace")
            bridge_adapter = getattr(bridge.runtime, "adapter", None)
            if bridge_adapter is not None:
                # Plugin log/notify lines go down the socket so they never
                # interleave with the stdout handshake.
                bridge_adapter.emit = lambda payload: _write_line(stream, payload)
            try:
                if not serve(bridge, stream, lambda payload: _write_line(stream, payload)):
                    break
            finally:
                try:
                    connection.close()
                except OSError:
                    pass
    except KeyboardInterrupt:  # pragma: no cover
        pass
    finally:
        try:
            server.close()
        except OSError:
            pass
    return 0


def _write_line(stream, payload: dict) -> None:
    try:
        stream.write(json.dumps(payload, ensure_ascii=False, default=str) + "\n")
        stream.flush()
    except (OSError, ValueError):
        pass


if __name__ == "__main__":
    sys.exit(main())
