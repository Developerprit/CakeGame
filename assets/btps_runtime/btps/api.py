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

"""The unified runtime API exposed to plugin code.

Python plugins receive this object as ``ctx`` from ``btps_setup(ctx)``; the
JavaScript bridge mirrors the same shape method-for-method, so a developer who
learns one language already knows the other.

Every method that touches a privileged resource goes through the plugin's
:class:`~btps.sandbox.Sandbox`, which enforces the manifest-declared permission
set. There is deliberately no back door: no raw file handle, no unguarded
socket, no direct ``os`` access.

Example
-------
.. code-block:: python

    from btps import install_context

    def on_startup(ctx):
        ctx.log.info("hello from %s", ctx.plugin_id)
        ctx.storage.set("launches", ctx.storage.get("launches", 0) + 1)
        if ctx.has_permission("net.http:api.example.com"):
            response = ctx.net.get("https://api.example.com/ping")
            ctx.log.info("ping -> %s", response["status"])

    def btps_setup(ctx):
        install_context(ctx)      # makes `ctx` importable as `btps.api.ctx`
        return {"ready": True}
"""

from __future__ import annotations

import json
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from typing import Any, Callable, Iterable, Mapping, Sequence

from .errors import PermissionDenied, SandboxError
from .manifest import Manifest

__all__ = [
    "PluginContext",
    "HttpResponse",
    "PluginLogger",
    "StorageFacade",
    "SettingsFacade",
    "FsFacade",
    "NetFacade",
    "HostFacade",
    "EventsFacade",
    "build_context",
    "install_context",
    "current_context",
    "LOGGER_LEVELS",
]

LOGGER_LEVELS = ("debug", "info", "warn", "error")


# --------------------------------------------------------------------------- #
# Logger
# --------------------------------------------------------------------------- #


class PluginLogger:
    """``ctx.log`` — routes through the host adapter with plugin attribution.

    Supports both lazy ``%``-style formatting (``ctx.log.info("n=%d", n)``) and
    structured context (``ctx.log.info("done", elapsed=1.2)``). The two are
    distinguished by keyword: any extra positional arguments are treated as
    ``%``-format operands, which is what a developer coming from ``logging``
    expects, while keyword arguments become structured fields.
    """

    def __init__(self, adapter: Any, plugin_id: str, sandbox: Any) -> None:
        self._adapter = adapter
        self._plugin_id = plugin_id
        self._sandbox = sandbox
        self._lock = threading.Lock()
        self._window_start = time.time()
        self._window_count = 0
        self._suppressed = False

    def _emit(self, level: str, message: str, args: tuple[Any, ...], context: dict[str, Any]) -> None:
        if not self._rate_limit_ok():
            return

        text = message
        if args:
            try:
                text = message % args
            except (TypeError, ValueError):
                # A malformed format string is a plugin bug, not a host crash.
                # Include the raw operands so the message is still diagnosable.
                text = f"{message} {args!r}"

        context.setdefault("plugin_id", self._plugin_id)
        try:
            self._adapter.log(level, text, **context)
        except Exception:  # noqa: BLE001 - logging must never throw
            pass

    def _rate_limit_ok(self) -> bool:
        """Throttle runaway loggers.

        A plugin in a tight loop can otherwise fill the host's console and the
        audit log in seconds, which is indistinguishable from a hang. The limit
        is per minute, resets automatically, and is announced once.
        """
        budget = getattr(self._sandbox.limits, "max_log_entries_per_minute", 600)
        with self._lock:
            now = time.time()
            if now - self._window_start >= 60.0:
                self._window_start = now
                self._window_count = 0
                self._suppressed = False
            self._window_count += 1
            if self._window_count > budget:
                if not self._suppressed:
                    self._suppressed = True
                    self._sandbox.record(
                        "limit",
                        f"log rate exceeded {budget}/min; further logs suppressed",
                    )
                return False
            return True

    def debug(self, message: str, *args: Any, **context: Any) -> None:
        self._emit("debug", message, args, context)

    def info(self, message: str, *args: Any, **context: Any) -> None:
        self._emit("info", message, args, context)

    def warn(self, message: str, *args: Any, **context: Any) -> None:
        self._emit("warn", message, args, context)

    warning = warn

    def error(self, message: str, *args: Any, **context: Any) -> None:
        self._emit("error", message, args, context)

    def exception(self, message: str, *args: Any, **context: Any) -> None:
        import traceback

        context.setdefault("traceback", traceback.format_exc())
        self._emit("error", message, args, context)


# --------------------------------------------------------------------------- #
# Facades
# --------------------------------------------------------------------------- #


class StorageFacade:
    """``ctx.storage`` — plugin-private JSON KV with size limits."""

    def __init__(self, sandbox: Any) -> None:
        self._sandbox = sandbox
        self._kv = sandbox.storage

    def get(self, key: str, default: Any = None) -> Any:
        return self._kv.get(key, default)

    def set(self, key: str, value: Any) -> None:
        self._kv.set(key, value)

    def delete(self, key: str) -> bool:
        return self._kv.delete(key)

    def keys(self, prefix: str = "") -> list[str]:
        return self._kv.keys(prefix)

    def clear(self) -> None:
        self._kv.clear()

    def get_json(self, key: str, default: Any = None) -> Any:
        raw = self._kv.get(key)
        if raw is None:
            return default
        if isinstance(raw, str):
            try:
                return json.loads(raw)
            except json.JSONDecodeError:
                return default
        return raw


class SettingsFacade:
    """``ctx.settings`` — values the user configured in the host console."""

    def __init__(self, manifest: Manifest, values: Mapping[str, Any] | None = None) -> None:
        self._manifest = manifest
        self._values = dict(values or {})
        self._lock = threading.Lock()

    def get(self, key: str, default: Any = None) -> Any:
        with self._lock:
            if key in self._values:
                return self._values[key]
        for name, schema in self._manifest.settings.items():
            if name == key and isinstance(schema, Mapping) and "default" in schema:
                return schema["default"]
        return default

    def set(self, key: str, value: Any) -> None:
        with self._lock:
            self._values[key] = value

    def all(self) -> dict[str, Any]:
        merged = {
            name: schema["default"]
            for name, schema in self._manifest.settings.items()
            if isinstance(schema, Mapping) and "default" in schema
        }
        with self._lock:
            merged.update(self._values)
        return merged


class FsFacade:
    """``ctx.fs`` — read-only access to the package and the plugin data dir."""

    def __init__(self, sandbox: Any) -> None:
        self._sandbox = sandbox

    def read(self, path: str, *, binary: bool = False) -> Any:
        """Read a file from the package (or ``assets/`` when relative)."""
        self._sandbox.permissions.require("fs.read", context="fs.read")
        root = self._sandbox.package_root
        data = self._sandbox.paths.read_bytes(path, base=root if not path.startswith("assets/") else None)
        return data if binary else data.decode("utf-8")

    def read_asset(self, path: str, *, binary: bool = False) -> Any:
        return self._sandbox.read_asset(path, binary=binary)

    def exists(self, path: str) -> bool:
        try:
            self._sandbox.permissions.require("fs.read", context="fs.exists")
        except PermissionDenied:
            return False
        return self._sandbox.paths.exists(path, base=self._sandbox.package_root)

    def list(self, path: str = ".") -> list[str]:
        """List directory entries inside the package."""
        self._sandbox.permissions.require("fs.read", context="fs.list")
        target = self._sandbox.paths.resolve_read(path, base=self._sandbox.package_root)
        if not target.is_dir():
            return []
        return sorted(p.name for p in target.iterdir())

    def write(self, path: str, data: str | bytes, *, binary: bool = False) -> str:
        """Write into the plugin's private data directory."""
        self._sandbox.permissions.require("fs.write", context="fs.write")
        payload = data if isinstance(data, bytes) else data.encode("utf-8")
        target = self._sandbox.paths.write_bytes(path, payload, base=self._sandbox.data_root)
        return str(target)

    @property
    def data_dir(self) -> str:
        return str(self._sandbox.data_root)

    @property
    def package_dir(self) -> str:
        return str(self._sandbox.package_root)


@dataclass(frozen=True)
class HttpResponse:
    """Result of :meth:`NetFacade.get` / :meth:`NetFacade.request`."""

    status: int
    headers: dict[str, str]
    body: str
    url: str
    elapsed: float = 0.0

    @property
    def ok(self) -> bool:
        return 200 <= self.status < 300

    def json(self) -> Any:
        return json.loads(self.body)

    def to_dict(self) -> dict[str, Any]:
        return {
            "status": self.status,
            "headers": self.headers,
            "body": self.body,
            "url": self.url,
            "elapsed": self.elapsed,
        }

    def __getitem__(self, key: str) -> Any:
        return self.to_dict()[key]


class NetFacade:
    """``ctx.net`` — HTTP access gated by ``net.http:<host>`` permissions.

    Two checks run on every request:

    1. **Permission gate** — is any granted ``net.http:<pattern>`` covering the
       target host?
    2. **Live host check** — after redirects and normalisation, does the final
       host still satisfy the pattern?

    Step 2 exists because an allowed host that redirects to an arbitrary host is
    an SSRF primitive. Redirects are followed only while every hop stays inside
    the granted scope, which is why the opener is built fresh per request rather
    than reusing a shared one.
    """

    def __init__(self, sandbox: Any) -> None:
        self._sandbox = sandbox

    def _authorise(self, url: str) -> str:
        parsed = urllib.parse.urlparse(url)
        if parsed.scheme not in ("http", "https"):
            raise SandboxError(
                f"only http/https are allowed, got {parsed.scheme!r}", url=url
            )
        host = parsed.hostname or ""
        if not host:
            raise SandboxError("request URL has no host", url=url)

        candidates = [f"net.http:{host}", "net.http"]
        if host.startswith("www."):
            candidates.append(f"net.http:{host[4:]}")
        for candidate in candidates:
            if self._sandbox.check_permission(candidate):
                return host
        raise PermissionDenied(
            f"no granted permission covers host {host!r}",
            plugin_id=self._sandbox.plugin_id,
            host=host,
            url=url,
            hint=f'declare "net.http:{host}" in btps.json and approve it',
        )

    def request(
        self,
        url: str,
        *,
        method: str = "GET",
        headers: Mapping[str, str] | None = None,
        body: str | bytes | None = None,
        timeout: float = 10.0,
        max_bytes: int | None = None,
    ) -> HttpResponse:
        """Perform one HTTP request. Redirects outside the granted scope are
        rejected rather than silently followed."""
        host = self._authorise(url)
        limit = max_bytes or self._sandbox.limits.max_http_response_bytes

        request = urllib.request.Request(url, method=method.upper())
        request.add_header("User-Agent", "BTPS/1.0 (+https://btps.dev)")
        for name, value in (headers or {}).items():
            request.add_header(str(name), str(value))
        payload = body.encode("utf-8") if isinstance(body, str) else body

        class _ScopedRedirect(urllib.request.HTTPRedirectHandler):
            """Re-authorise every redirect hop against the permission set."""

            def redirect_request(inner_self, req, fp, code, msg, hdrs, newurl):  # type: ignore[no-untyped-def]
                try:
                    self._authorise(newurl)
                except PermissionDenied as exc:
                    raise urllib.error.HTTPError(
                        newurl, code,
                        f"redirect blocked by sandbox: {exc}",
                        hdrs, fp,
                    ) from exc
                return super().redirect_request(req, fp, code, msg, hdrs, newurl)

        opener = urllib.request.build_opener(
            _ScopedRedirect,
            urllib.request.HTTPSHandler(context=_ssl_context()),
        )

        started = time.time()
        try:
            with opener.open(request, data=payload, timeout=timeout) as response:
                raw = response.read(limit + 1)
                if len(raw) > limit:
                    raise SandboxError(
                        f"response exceeded the {limit} byte limit", url=url, limit=limit
                    )
                return HttpResponse(
                    status=response.status,
                    headers={k: v for k, v in response.headers.items()},
                    body=raw.decode("utf-8", errors="replace"),
                    url=response.url,
                    elapsed=time.time() - started,
                )
        except urllib.error.HTTPError as exc:
            raw = b""
            try:
                raw = exc.read(limit)
            except Exception:  # noqa: BLE001 - best effort
                pass
            return HttpResponse(
                status=exc.code,
                headers={k: v for k, v in (exc.headers or {}).items()},
                body=raw.decode("utf-8", errors="replace"),
                url=url,
                elapsed=time.time() - started,
            )
        except urllib.error.URLError as exc:
            raise SandboxError(f"network request failed: {exc.reason}", url=url) from exc

    def get(self, url: str, **kwargs: Any) -> HttpResponse:
        return self.request(url, method="GET", **kwargs)

    def post(self, url: str, body: str | bytes = "", **kwargs: Any) -> HttpResponse:
        return self.request(url, method="POST", body=body, **kwargs)

    def json(self, url: str, **kwargs: Any) -> Any:
        return self.get(url, **kwargs).json()


def _ssl_context() -> Any:
    """A default TLS context, kept in one place so hosts can override it."""
    import ssl

    return ssl.create_default_context()


class HostFacade:
    """``ctx.host`` — the small, stable bridge to host capabilities."""

    def __init__(self, runtime: Any, manifest: Manifest, sandbox: Any) -> None:
        self._runtime = runtime
        self._manifest = manifest
        self._sandbox = sandbox

    def notify(self, title: str, body: str = "", **context: Any) -> None:
        self._sandbox.permissions.require("host.ui.notify", context="host.notify")
        context.setdefault("plugin_id", self._manifest.id)
        self._runtime.adapter.notify(title, body, **context)

    def has_capability(self, name: str) -> bool:
        try:
            return bool(self._runtime.adapter.capability(name))
        except Exception:  # noqa: BLE001 - adapters are host code
            return False

    @property
    def version(self) -> str:
        return self._runtime.adapter.host_version()

    @property
    def api_version(self) -> str:
        return self._runtime.adapter.host_api_version()

    def log(self, message: str, level: str = "info", **context: Any) -> None:
        context.setdefault("plugin_id", self._manifest.id)
        self._runtime.adapter.log(level, message, **context)


class EventsFacade:
    """``ctx.events`` — emit and subscribe to hooks at runtime.

    Emitting a ``custom.*`` event requires the ``host.events.emit`` permission.
    Subscribing at runtime is rejected unless the hook was declared in the
    manifest — the same gate that applies at load time, enforced again here so a
    plugin cannot slip past it later.
    """

    def __init__(self, runtime: Any, manifest: Manifest, sandbox: Any) -> None:
        self._runtime = runtime
        self._manifest = manifest
        self._sandbox = sandbox

    def emit(self, hook: str, **payload: Any) -> Any:
        self._sandbox.permissions.require("host.events.emit", context="events.emit")
        payload.setdefault("_source", self._manifest.id)
        report = self._runtime.dispatch(hook, payload)
        return report.to_dict()

    def on(self, hook: str, handler: Callable[..., Any], *, priority: int = 100) -> bool:
        from .errors import HookError

        try:
            self._runtime.hooks.subscribe(
                self._manifest.id, hook, handler, priority=priority, declared=False
            )
            return True
        except HookError as exc:
            self._sandbox.record(
                "denied", f"runtime subscription to {hook!r} refused: {exc}"
            )
            raise

    def off(self, hook: str) -> int:
        """Remove every subscription this plugin holds for ``hook``."""
        subs = [
            s for s in self._runtime.hooks.subscribers(hook)
            if s.plugin_id == self._manifest.id
        ]
        bus = self._runtime.hooks
        for subscription in subs:
            current = bus._subscriptions.get(hook, [])
            if subscription in current:
                current.remove(subscription)
        return len(subs)


# --------------------------------------------------------------------------- #
# Context
# --------------------------------------------------------------------------- #


class PluginContext:
    """The object handed to plugin code as ``ctx``.

    Attributes are deliberately plain and discoverable: ``log``, ``storage``,
    ``settings``, ``fs``, ``net``, ``host``, ``events``, plus identity fields.
    A developer should be able to guess the API rather than read the source.
    """

    def __init__(
        self,
        runtime: Any,
        manifest: Manifest,
        sandbox: Any,
        *,
        settings: Mapping[str, Any] | None = None,
    ) -> None:
        self._runtime = runtime
        self._manifest = manifest
        self._sandbox = sandbox

        self.manifest = manifest
        self.id = manifest.id
        self.plugin_id = manifest.id
        self.version = manifest.version_string
        self.name = manifest.name
        self.package_dir = str(sandbox.package_root)
        self.data_dir = str(sandbox.data_root)

        self.log = PluginLogger(runtime.adapter, manifest.id, sandbox)
        self.storage = StorageFacade(sandbox)
        self.settings = SettingsFacade(manifest, settings)
        self.fs = FsFacade(sandbox)
        self.net = NetFacade(sandbox)
        self.host = HostFacade(runtime, manifest, sandbox)
        self.events = EventsFacade(runtime, manifest, sandbox)

    # -- introspection ------------------------------------------------------ #

    def has_permission(self, permission: str) -> bool:
        """Check a permission without raising — the guard-and-degrade pattern."""
        return self._sandbox.check_permission(permission)

    def require_permission(self, permission: str) -> None:
        """Raise :class:`PermissionDenied` unless granted."""
        self._sandbox.permissions.require(permission)

    @property
    def permissions(self) -> list[str]:
        return list(self._manifest.permissions)

    @property
    def granted_permissions(self) -> list[str]:
        return sorted(self._sandbox.permissions.granted)

    # -- storage shorthand -------------------------------------------------- #

    def get(self, key: str, default: Any = None) -> Any:
        return self.storage.get(key, default)

    def set(self, key: str, value: Any) -> None:
        self.storage.set(key, value)

    # -- lifecycle ---------------------------------------------------------- #

    def dispatch(self, hook: str, **payload: Any) -> dict[str, Any]:
        """Fire a hook from inside plugin code."""
        return self.events.emit(hook, **payload)

    def timer(self, seconds: float, callback: Callable[[], Any], *, name: str = "") -> threading.Timer:
        """Schedule a one-shot callback.

        The timer is a daemon thread, so a plugin that forgets to cancel one
        cannot keep the host process alive after shutdown.
        """
        handle = threading.Timer(seconds, callback)
        handle.daemon = True
        handle.name = f"btps-timer-{self.id}-{name or 'timer'}"
        handle.start()
        return handle

    def __repr__(self) -> str:  # pragma: no cover - debug aid
        return f"<PluginContext {self.id}@{self.version} perms={len(self.permissions)}>"


# --------------------------------------------------------------------------- #
# Context installation (for `from btps.api import ctx`)
# --------------------------------------------------------------------------- #

_ACTIVE_CONTEXT: PluginContext | None = None
_CONTEXT_LOCK = threading.Lock()


def install_context(context: PluginContext) -> None:
    """Make ``context`` available as ``btps.api.ctx``.

    Called by well-behaved plugins from ``btps_setup``. Kept as an explicit step
    rather than an implicit side effect so that importing ``btps.api`` never has
    surprising global consequences.
    """
    global _ACTIVE_CONTEXT
    with _CONTEXT_LOCK:
        _ACTIVE_CONTEXT = context


def current_context() -> PluginContext:
    """Return the active context, or raise with a clear explanation."""
    with _CONTEXT_LOCK:
        context = _ACTIVE_CONTEXT
    if context is None:
        raise SandboxError(
            "no plugin context is active",
            hint=(
                "call btps.install_context(ctx) from your btps_setup(ctx) hook, "
                "or use the ctx argument directly"
            ),
        )
    return context


def build_context(
    runtime: Any,
    record: Any,
    *,
    settings: Mapping[str, Any] | None = None,
) -> PluginContext:
    """Construct the context for an installed plugin record."""
    if record.sandbox is None:
        from .sandbox import Sandbox

        record.sandbox = Sandbox(
            record.manifest,
            package_root=record.install_path or ".",
            data_root=runtime.data_root / record.manifest.slug,
            limits=runtime.limits,
            audit=runtime.audit,
        )
    return PluginContext(runtime, record.manifest, record.sandbox, settings=settings)


class _ContextProxy:
    """Module-level ``ctx`` that resolves to the active context on attribute access.

    Enables ``from btps.api import ctx`` at import time — before any plugin is
    set up — while still failing loudly and usefully if used too early.
    """

    def __getattr__(self, name: str) -> Any:
        if name.startswith("__") and name.endswith("__"):
            raise AttributeError(name)
        return getattr(current_context(), name)

    def __repr__(self) -> str:  # pragma: no cover - debug aid
        try:
            return repr(current_context())
        except SandboxError:
            return "<btps.api.ctx (inactive)>"


ctx: PluginContext = _ContextProxy()  # type: ignore[assignment]
