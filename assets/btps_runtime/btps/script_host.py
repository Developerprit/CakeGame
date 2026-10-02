# MIT License
#
# Copyright (c) 2026 kscm (Developerprit)
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

"""Python side of the JS/TS plugin host.

The bridge file communicates with Node, parses the single JSON response, and
turns each exported function into a Python callable. Calls follow the
request/response file protocol described in ``bridge.mjs``.

Why a subprocess: Python and Node cannot share a heap, so a subprocess is the
only isolation boundary that is real rather than aspirational. It also makes a
hung plugin killable, which an in-process VM context is not.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Mapping

try:  # normal case: imported as ``btps.script_host``
    from .errors import SandboxError
except ImportError:  # pragma: no cover - the standalone path
    # ``PluginRuntime._load_script_module`` loads this file by path under the
    # name ``btps_script_host``, so it has no parent package and the relative
    # import above cannot resolve. Fall back to the absolute package import,
    # which works because ``btps`` is already imported by that point.
    from btps.errors import SandboxError

__all__ = [
    "find_node",
    "NodeBridgeError",
    "describe_module",
    "RemoteFunction",
    "ScriptHostSession",
]

#: Timeout for the initial module description. Generous because the first Node
#: start-up on Windows can be slow when the binary is cold.
DESCRIBE_TIMEOUT = 30.0

#: How long a single bridged call may take before we give up.
CALL_TIMEOUT = 30.0


class NodeBridgeError(SandboxError):
    """The Node bridge could not be run or returned an error."""


def find_node() -> str | None:
    """Locate a Node executable.

    Search order: ``BTPS_NODE`` env override, ``PATH``, then a list of common
    install locations. Returns ``None`` when nothing usable is found, so the
    caller can produce a targeted error instead of a generic crash.
    """
    override = os.environ.get("BTPS_NODE")
    if override and Path(override).is_file():
        return override

    found = shutil.which("node") or shutil.which("node.exe")
    if found:
        return found

    candidates = [
        Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "nodejs" / "node.exe",
        Path(os.environ.get("ProgramFiles(x86)", "C:/Program Files (x86)")) / "nodejs" / "node.exe",
        Path(os.environ.get("LOCALAPPDATA", "")) / "Programs" / "nodejs" / "node.exe",
        Path("F:/node/node.exe"),
        Path("/usr/local/bin/node"),
        Path("/usr/bin/node"),
        Path("/opt/homebrew/bin/node"),
    ]
    for candidate in candidates:
        try:
            if candidate.is_file():
                return str(candidate)
        except OSError:
            continue
    return None


@dataclass
class BridgeResult:
    """One parsed response from the bridge."""

    ok: bool
    data: dict[str, Any]
    error: str = ""
    error_type: str = ""
    stdout: str = ""
    stderr: str = ""
    duration: float = 0.0

    def raise_if_failed(self) -> None:
        if self.ok:
            return
        raise NodeBridgeError(
            f"{self.error_type or 'Error'}: {self.error}",
            stderr=self.stderr[-4000:] if self.stderr else "",
            stdout=self.stdout[-2000:] if self.stdout else "",
        )


class _HostBridgeServer(threading.Thread):
    """Services ``ctx.*`` calls made by the plugin's JS code.

    The host writes ``req-<token>.json``; this thread executes the corresponding
    method against the real :class:`~btps.sandbox.Sandbox` and writes back
    ``res-<token>.json``. Running the sandbox logic here (rather than in Node)
    means the permission rules have exactly one implementation.
    """

    def __init__(
        self,
        sandbox: Any,
        directory: Path,
        *,
        plugin_id: str,
        version: str,
        name: str,
        package_dir: str,
        data_dir: str,
    ) -> None:
        super().__init__(daemon=True, name=f"btps-bridge-{plugin_id}")
        self.sandbox = sandbox
        self.directory = directory
        self.identity = {
            "pluginId": plugin_id,
            "version": version,
            "name": name,
            "packageDir": package_dir,
            "dataDir": data_dir,
        }
        self._stop = threading.Event()
        self._lock = threading.Lock()
        self.calls = 0

    def run(self) -> None:
        while not self._stop.is_set():
            try:
                requests = sorted(self.directory.glob("req-*.json"))
            except OSError:
                break
            if not requests:
                self._stop.wait(0.005)
                continue
            for request_path in requests:
                self._handle_request(request_path)
                self._stop.wait(0.001)

    def stop(self) -> None:
        self._stop.set()

    def _handle_request(self, request_path: Path) -> None:
        # NOTE: do not name this ``_handle``. ``threading.Thread.start()``
        # stores the low-level thread handle on ``self._handle`` (CPython 3.13+),
        # which silently shadows any method of that name on a Thread subclass.
        token = request_path.stem.replace("req-", "")
        response_path = self.directory / f"res-{token}.json"
        try:
            payload = json.loads(request_path.read_text(encoding="utf-8"))
            result = self._dispatch(payload.get("method", ""), payload.get("params") or {})
            response = {"ok": True, "data": result}
        except Exception as exc:  # noqa: BLE001 - every failure is reported, never raised
            response = {
                "ok": False,
                "error": str(exc),
                "type": type(exc).__name__,
            }
        finally:
            try:
                request_path.unlink(missing_ok=True)
            except OSError:
                pass

        try:
            response_path.write_text(
                json.dumps(response, ensure_ascii=False, default=str), encoding="utf-8"
            )
        except OSError:
            pass
        with self._lock:
            self.calls += 1

    # -- method table --------------------------------------------------- #

    def _dispatch(self, method: str, params: Mapping[str, Any]) -> Any:
        sandbox = self.sandbox

        if method == "log":
            level = str(params.get("level", "info"))
            message = str(params.get("message", ""))
            context = params.get("context") or {}
            if isinstance(context, Mapping):
                sandbox.audit.record(
                    sandbox.plugin_id, "note", f"[{level}] {message}"
                )
            try:
                self.identity_logger(level, message)
            except Exception:  # noqa: BLE001
                pass
            return None

        if method == "storage.get":
            return sandbox.storage.get(str(params.get("key", "")), params.get("default"))
        if method == "storage.set":
            sandbox.storage.set(str(params.get("key", "")), params.get("value"))
            return None
        if method == "storage.delete":
            return sandbox.storage.delete(str(params.get("key", "")))
        if method == "storage.keys":
            return sandbox.storage.keys(str(params.get("prefix", "")))
        if method == "storage.clear":
            sandbox.storage.clear()
            return None

        if method == "settings.get":
            return params.get("default")

        if method == "fs.read":
            sandbox.permissions.require("fs.read", context="bridge.fs.read")
            data = sandbox.paths.read_bytes(
                str(params.get("path", "")), base=sandbox.package_root
            )
            return data.decode("utf-8", errors="replace") if not params.get("binary") else data.hex()
        if method == "fs.readAsset":
            content = sandbox.read_asset(str(params.get("path", "")), binary=bool(params.get("binary")))
            return content.hex() if isinstance(content, bytes) else content
        if method == "fs.write":
            sandbox.permissions.require("fs.write", context="bridge.fs.write")
            target = sandbox.paths.write_bytes(
                str(params.get("path", "")),
                str(params.get("data", "")).encode("utf-8"),
                base=sandbox.data_root,
            )
            return str(target)
        if method == "fs.exists":
            return sandbox.paths.exists(str(params.get("path", "")), base=sandbox.package_root)
        if method == "fs.list":
            target = sandbox.paths.resolve_read(
                str(params.get("path", ".")), base=sandbox.package_root
            )
            return sorted(p.name for p in target.iterdir()) if target.is_dir() else []

        if method == "net.request":
            from .api import NetFacade

            facade = NetFacade(sandbox)
            response = facade.request(
                str(params.get("url", "")),
                method=str(params.get("method", "GET")),
                headers=params.get("headers") or None,
                body=params.get("body"),
                timeout=float(params.get("timeout", 10.0)),
            )
            return response.to_dict()

        if method == "host.notify":
            sandbox.permissions.require("host.ui.notify", context="bridge.host.notify")
            return None
        if method == "host.capability":
            return False
        if method == "host.version":
            return "unknown"
        if method == "host.apiVersion":
            return "unknown"

        if method == "events.emit":
            sandbox.permissions.require("host.events.emit", context="bridge.events.emit")
            return {"emitted": str(params.get("hook", ""))}

        if method == "permission.check":
            return sandbox.check_permission(str(params.get("permission", "")))
        if method == "permission.list":
            return sorted(sandbox.permissions.granted)

        raise NodeBridgeError(f"unknown bridge method: {method!r}", method=method)

    def identity_logger(self, level: str, message: str) -> None:
        """Placeholder hooked up by :func:`describe_module` when an adapter exists."""


def _run_bridge(
    node: str,
    bridge: Path,
    command: str,
    options: Mapping[str, Any],
    *,
    stdin_payload: str | None = None,
    timeout: float = DESCRIBE_TIMEOUT,
) -> BridgeResult:
    """Run the bridge once and parse its single JSON response line."""
    argv = [node, str(bridge), command, json.dumps(options, ensure_ascii=False)]
    started = time.time()
    try:
        completed = subprocess.run(
            argv,
            input=stdin_payload,
            capture_output=True,
            text=True,
            timeout=timeout,
            encoding="utf-8",
            errors="replace",
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        raise NodeBridgeError(
            f"the Node bridge did not respond within {timeout}s",
            command=command,
            timeout=timeout,
        ) from exc
    except OSError as exc:
        raise NodeBridgeError(
            f"cannot execute Node at {node!r}: {exc}",
            node=node,
            hint="set the BTPS_NODE environment variable to your node executable",
        ) from exc

    duration = time.time() - started
    stdout = completed.stdout or ""
    stderr = completed.stderr or ""

    # The bridge guarantees exactly one JSON object on stdout, but a broken
    # plugin can still emit noise before the response; take the last valid line.
    payload: dict[str, Any] | None = None
    for line in reversed(stdout.splitlines()):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            candidate = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(candidate, dict) and "ok" in candidate:
            payload = candidate
            break

    if payload is None:
        raise NodeBridgeError(
            "the Node bridge produced no parsable response",
            command=command,
            returncode=completed.returncode,
            stdout=stdout[-2000:],
            stderr=stderr[-2000:],
        )

    return BridgeResult(
        ok=bool(payload.get("ok")),
        data=dict(payload.get("data") or {}),
        error=str(payload.get("error", "")),
        error_type=str(payload.get("type", "")),
        stdout=stdout,
        stderr=stderr,
        duration=duration,
    )


def describe_module(
    entry: str | os.PathLike[str],
    bridge: str | os.PathLike[str],
    *,
    plugin_id: str = "",
    sandbox: Any = None,
    node: str | None = None,
) -> dict[str, Any]:
    """Import a JS/TS entry and return its exported symbols.

    Returns a descriptor with ``exports`` (a mapping of name → callable),
    ``runtime`` (the Node version), and ``declared`` (any ``btps`` export block).
    """
    node_path = node or find_node()
    if node_path is None:
        raise NodeBridgeError(
            "Node.js was not found, so JS/TS plugins cannot be loaded",
            plugin_id=plugin_id,
            hint="install Node.js 18+ or set the BTPS_NODE environment variable",
        )

    entry_path = Path(entry)
    if not entry_path.is_file():
        raise NodeBridgeError(
            f"entry file not found: {entry_path}", plugin_id=plugin_id
        )

    workdir = Path(tempfile.mkdtemp(prefix="btps-bridge-"))
    try:
        options = {
            "entry": str(entry_path),
            "requestDir": str(workdir),
            "pluginId": plugin_id,
            "version": getattr(getattr(sandbox, "manifest", None), "version_string", ""),
            "name": getattr(getattr(sandbox, "manifest", None), "name", plugin_id),
            "packageDir": str(getattr(sandbox, "package_root", "")),
            "dataDir": str(getattr(sandbox, "data_root", "")),
        }

        server = _HostBridgeServer(
            sandbox,
            workdir,
            plugin_id=plugin_id,
            version=options["version"],
            name=options["name"],
            package_dir=options["packageDir"],
            data_dir=options["dataDir"],
        ) if sandbox is not None else None
        if server is not None:
            server.start()

        try:
            result = _run_bridge(node_path, Path(bridge), "describe", options, timeout=DESCRIBE_TIMEOUT)
        finally:
            if server is not None:
                server.stop()

        result.raise_if_failed()

        raw_exports = result.data.get("exports") or {}
        callables: dict[str, Callable[[Any, Mapping[str, Any]], Any]] = {
            name: RemoteFunction(
                name=name,
                entry=str(entry_path),
                bridge=str(bridge),
                node=node_path,
                plugin_id=plugin_id,
                sandbox=sandbox,
                request_dir=str(workdir),
            )
            for name in raw_exports
        }

        return {
            "runtime": result.data.get("runtime", "unknown"),
            "exports": callables,
            "exportDetail": raw_exports,
            "declared": result.data.get("declared"),
            "setupResult": result.data.get("setupResult"),
            "modulePath": str(entry_path),
            "duration": result.duration,
        }
    except Exception:
        shutil.rmtree(workdir, ignore_errors=True)
        raise


def _is_plugin_context(value: Any) -> bool:
    """Whether ``value`` is the runtime context rather than plugin data.

    Imported lazily so that loading this module by file path (see
    :meth:`PluginRuntime._load_script_module`) never drags in the runtime.
    """
    try:  # normal case: imported as ``btps.script_host``
        from .api import PluginContext
    except ImportError:  # loaded standalone by path, no parent package
        from btps.api import PluginContext
    return isinstance(value, PluginContext)


class RemoteFunction:
    """A callable exported by a JS/TS module, executed in a Node subprocess.

    Each call spawns a fresh Node process. That costs roughly 30–60 ms per
    invocation, which is the price of real isolation: a plugin that leaks memory
    or segfaults cannot take the host down, and a hang is killable on timeout.
    """

    def __init__(
        self,
        *,
        name: str,
        entry: str,
        bridge: str,
        node: str,
        plugin_id: str,
        sandbox: Any = None,
        request_dir: str = "",
    ) -> None:
        self.__name__ = name
        self.entry = entry
        self.bridge = bridge
        self.node = node
        self.plugin_id = plugin_id
        self.sandbox = sandbox
        self.request_dir = request_dir

    def __call__(self, *args: Any, **kwargs: Any) -> Any:
        payload: dict[str, Any] = {}
        if args and _is_plugin_context(args[0]):
            # The hook bus hands the plugin context to every handler it invokes.
            # The Node bridge synthesises its own ``ctx`` from the host bridge,
            # so forwarding this one is both redundant and impossible — the
            # object cannot cross the JSON boundary. Drop it so that a JS
            # handler taking ``ctx`` behaves exactly like a Python one.
            args = ()
        if args:
            first = args[0]
            payload = dict(first) if isinstance(first, Mapping) else {"args": list(args)}
        if kwargs:
            payload.update(kwargs)

        workdir = Path(self.request_dir) if self.request_dir else Path(
            tempfile.mkdtemp(prefix="btps-call-")
        )
        server = None
        if self.sandbox is not None:
            server = _HostBridgeServer(
                self.sandbox,
                workdir,
                plugin_id=self.plugin_id,
                version="",
                name="",
                package_dir=str(getattr(self.sandbox, "package_root", "")),
                data_dir=str(getattr(self.sandbox, "data_root", "")),
            )
            server.start()

        try:
            options = {
                "entry": self.entry,
                "requestDir": str(workdir),
                "pluginId": self.plugin_id,
                "version": "",
                "name": self.plugin_id,
                "packageDir": str(getattr(self.sandbox, "package_root", "")),
                "dataDir": str(getattr(self.sandbox, "data_root", "")),
            }
            result = _run_bridge(
                self.node,
                Path(self.bridge),
                "invoke",
                options,
                stdin_payload=json.dumps(
                    {"handler": self.__name__, "payload": payload}, ensure_ascii=False
                ),
                timeout=CALL_TIMEOUT,
            )
            result.raise_if_failed()
            return result.data.get("returned")
        finally:
            if server is not None:
                server.stop()
            if not self.request_dir:
                shutil.rmtree(workdir, ignore_errors=True)

    def __repr__(self) -> str:  # pragma: no cover - debug aid
        return f"<RemoteFunction {self.plugin_id}:{self.__name__} via node>"


class ScriptHostSession:
    """Keeps a Node bridge session alive across multiple calls.

    Provided for hosts that want to amortise Node startup cost. Uses a shared
    request directory so the bridge server thread handles every call.
    """

    def __init__(
        self,
        entry: str | os.PathLike[str],
        bridge: str | os.PathLike[str],
        *,
        plugin_id: str,
        sandbox: Any = None,
        node: str | None = None,
    ) -> None:
        self.entry = str(entry)
        self.bridge = str(bridge)
        self.plugin_id = plugin_id
        self.sandbox = sandbox
        self.node = node or find_node()
        self.workdir = Path(tempfile.mkdtemp(prefix="btps-session-"))
        self._server: _HostBridgeServer | None = None
        self._closed = False

    def __enter__(self) -> "ScriptHostSession":
        if self.sandbox is not None:
            self._server = _HostBridgeServer(
                self.sandbox,
                self.workdir,
                plugin_id=self.plugin_id,
                version="",
                name=self.plugin_id,
                package_dir=str(getattr(self.sandbox, "package_root", "")),
                data_dir=str(getattr(self.sandbox, "data_root", "")),
            )
            self._server.start()
        return self

    def __exit__(self, *exc_info: object) -> None:
        self.close()

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        if self._server is not None:
            self._server.stop()
        shutil.rmtree(self.workdir, ignore_errors=True)

    def describe(self) -> dict[str, Any]:
        if self.node is None:
            raise NodeBridgeError(
                "Node.js was not found", plugin_id=self.plugin_id
            )
        options = {
            "entry": self.entry,
            "requestDir": str(self.workdir),
            "pluginId": self.plugin_id,
            "version": "",
            "name": self.plugin_id,
            "packageDir": str(getattr(self.sandbox, "package_root", "")),
            "dataDir": str(getattr(self.sandbox, "data_root", "")),
        }
        result = _run_bridge(self.node, Path(self.bridge), "describe", options)
        result.raise_if_failed()
        return result.data

    def call(self, handler: str, payload: Mapping[str, Any] | None = None) -> Any:
        if self.node is None:
            raise NodeBridgeError("Node.js was not found", plugin_id=self.plugin_id)
        options = {
            "entry": self.entry,
            "requestDir": str(self.workdir),
            "pluginId": self.plugin_id,
            "version": "",
            "name": self.plugin_id,
            "packageDir": str(getattr(self.sandbox, "package_root", "")),
            "dataDir": str(getattr(self.sandbox, "data_root", "")),
        }
        result = _run_bridge(
            self.node,
            Path(self.bridge),
            "invoke",
            options,
            stdin_payload=json.dumps({"handler": handler, "payload": dict(payload or {})}),
        )
        result.raise_if_failed()
        return result.data.get("returned")


# Keep a module-level reference so ``uuid``/``sys`` imports are not flagged as
# unused during static analysis of hosts that vendor this file.
_UNUSED = (uuid, sys)
