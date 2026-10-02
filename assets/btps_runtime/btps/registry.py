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

"""Registration centre — the process hosts talk to before anything else.

A host program starts, registers itself on port 5663, and receives a dynamically
allocated injection port to open a WebSocket on. The registration centre keeps
that directory and nothing else: plugin payloads travel directly between the host
and its injector, never through here.

Control plane and data plane are separate on purpose. If this service is
restarted, running hosts keep working — they only need it again at startup.

Endpoints
---------
``POST /register``
    Body ``{name, hostVersion, hostApiVersion, capabilities, pid}``.
    Returns ``{hostId, injectPort, injectUrl, sessionToken, heartbeatInterval}``.
``POST /heartbeat``
    Body ``{hostId, sessionToken}``. Extends the lease.
``POST /unregister``
    Body ``{hostId, sessionToken}``. Removes the host immediately.
``GET  /hosts``
    Lists live hosts. Expired entries are pruned lazily on every read.
``GET  /hosts/<hostId>``
    One host, or 404.
``GET  /health``
    Liveness probe used by hosts before registering.
``GET  /``
    A minimal HTML index so a human hitting the port sees something useful.
"""

from __future__ import annotations

import json
import os
import secrets
import socket
import threading
import time
import uuid
from dataclasses import dataclass, field
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Callable, Iterable, Mapping
from urllib.parse import parse_qs, urlparse

from .errors import BTPSError, TransportError

__all__ = [
    "DEFAULT_REGISTRY_PORT",
    "DEFAULT_INJECT_PORT_RANGE",
    "DEFAULT_SESSION_TTL",
    "HostRegistration",
    "HostRegistry",
    "RegistryServer",
    "serve_registry",
]

DEFAULT_REGISTRY_PORT = 5663
DEFAULT_INJECT_PORT_RANGE = (10240, 65535)
DEFAULT_SESSION_TTL = 60.0
DEFAULT_HEARTBEAT_INTERVAL = 15.0

#: Version of the registration wire format. Bumped only on breaking changes.
PROTOCOL_VERSION = 1


# --------------------------------------------------------------------------- #
# Records
# --------------------------------------------------------------------------- #


@dataclass
class HostRegistration:
    """A host program currently known to the registry."""

    host_id: str
    name: str
    host_version: str
    host_api_version: str
    capabilities: tuple[str, ...]
    pid: int
    inject_port: int
    session_token: str
    registered_at: float
    last_seen: float
    metadata: dict[str, Any] = field(default_factory=dict)

    @property
    def inject_url(self) -> str:
        """WebSocket URL the host should connect back to."""
        return f"ws://127.0.0.1:{self.inject_port}"

    @property
    def age(self) -> float:
        return time.time() - self.registered_at

    def to_dict(self, *, include_token: bool = False) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "hostId": self.host_id,
            "name": self.name,
            "hostVersion": self.host_version,
            "hostApiVersion": self.host_api_version,
            "capabilities": list(self.capabilities),
            "pid": self.pid,
            "injectPort": self.inject_port,
            "injectUrl": self.inject_url,
            "registeredAt": self.registered_at,
            "lastSeen": self.last_seen,
            "ageSeconds": round(self.age, 1),
        }
        if include_token:
            payload["sessionToken"] = self.session_token
        if self.metadata:
            payload["metadata"] = self.metadata
        return payload

    def __str__(self) -> str:
        return f"{self.name}@{self.host_version} pid={self.pid} → :{self.inject_port}"


# --------------------------------------------------------------------------- #
# Registry
# --------------------------------------------------------------------------- #


class HostRegistry:
    """In-memory directory of live hosts.

    Not persisted: a registry entry is a *live* fact, not durable data. If the
    registry restarts, hosts re-register on their next start or reconnect, and a
    stale entry pointing at a dead port is worse than a missing one.
    """

    def __init__(
        self,
        *,
        session_ttl: float = DEFAULT_SESSION_TTL,
        port_range: tuple[int, int] = DEFAULT_INJECT_PORT_RANGE,
        heartbeat_interval: float = DEFAULT_HEARTBEAT_INTERVAL,
        max_hosts: int = 64,
    ) -> None:
        self.session_ttl = session_ttl
        self.port_range = port_range
        self.heartbeat_interval = heartbeat_interval
        self.max_hosts = max_hosts
        self._hosts: dict[str, HostRegistration] = {}
        self._allocated: set[int] = set()
        self._lock = threading.RLock()

    # -- lifecycle ---------------------------------------------------------- #

    def register(
        self,
        *,
        name: str,
        host_version: str = "0.0.0",
        host_api_version: str = "1.0.0",
        capabilities: Iterable[str] = (),
        pid: int = 0,
        metadata: Mapping[str, Any] | None = None,
        recycle_pid: bool = True,
    ) -> HostRegistration:
        """Allocate an injection port and issue a session token.

        Re-registering with the same PID replaces the previous entry. A host that
        crashed and restarted gets a fresh registration rather than accumulating
        orphans, and the old port is released back to the pool.
        """
        if not name or not str(name).strip():
            raise TransportError("host name is required", name=name)

        with self._lock:
            self._prune_locked()

            if recycle_pid and pid:
                for existing in list(self._hosts.values()):
                    if existing.pid == pid and existing.name == name:
                        self._release_locked(existing)

            if len(self._hosts) >= self.max_hosts:
                raise TransportError(
                    f"registry is full ({self.max_hosts} hosts)",
                    hint="unregister stale hosts or raise max_hosts",
                )

            host_id = uuid.uuid4().hex
            inject_port = self._allocate_port_locked()
            token = secrets.token_urlsafe(32)
            now = time.time()

            registration = HostRegistration(
                host_id=host_id,
                name=str(name).strip(),
                host_version=str(host_version),
                host_api_version=str(host_api_version),
                capabilities=tuple(str(c) for c in capabilities),
                pid=int(pid or os.getpid()),
                inject_port=inject_port,
                session_token=token,
                registered_at=now,
                last_seen=now,
                metadata=dict(metadata or {}),
            )
            self._hosts[host_id] = registration
            return registration

    def heartbeat(self, host_id: str, session_token: str) -> bool:
        """Extend a host's lease. False when the host or token is unknown."""
        with self._lock:
            registration = self._hosts.get(host_id)
            if registration is None:
                return False
            if not secrets.compare_digest(registration.session_token, session_token):
                return False
            registration.last_seen = time.time()
            return True

    def unregister(self, host_id: str, session_token: str) -> bool:
        with self._lock:
            registration = self._hosts.get(host_id)
            if registration is None:
                return False
            if not secrets.compare_digest(registration.session_token, session_token):
                return False
            self._release_locked(registration)
            return True

    def _release_locked(self, registration: HostRegistration) -> None:
        self._hosts.pop(registration.host_id, None)
        self._allocated.discard(registration.inject_port)

    # -- queries ------------------------------------------------------------ #

    def get(self, host_id: str) -> HostRegistration | None:
        with self._lock:
            self._prune_locked()
            return self._hosts.get(host_id)

    def find_by_name(self, name: str) -> HostRegistration | None:
        with self._lock:
            self._prune_locked()
            for registration in self._hosts.values():
                if registration.name == name:
                    return registration
            return None

    def list(self) -> list[HostRegistration]:
        with self._lock:
            self._prune_locked()
            return sorted(self._hosts.values(), key=lambda r: r.registered_at)

    def count(self) -> int:
        with self._lock:
            self._prune_locked()
            return len(self._hosts)

    def prune(self) -> list[HostRegistration]:
        """Drop hosts that missed their lease. Returns what was removed."""
        with self._lock:
            return self._prune_locked()

    def _prune_locked(self) -> list[HostRegistration]:
        cutoff = time.time() - self.session_ttl
        expired = [
            registration
            for registration in self._hosts.values()
            if registration.last_seen < cutoff
        ]
        for registration in expired:
            self._release_locked(registration)
        return expired

    # -- port allocation ---------------------------------------------------- #

    def _allocate_port_locked(self) -> int:
        """Find a free port that is also actually bindable.

        Checking ``is_available`` here means the host does not discover on
        connect that its assigned port was taken — a failure mode that is very
        hard to diagnose from the host's side.
        """
        low, high = self.port_range
        span = high - low
        if span <= 0:
            raise TransportError(
                "invalid injection port range", port_range=self.port_range
            )

        start = secrets.randbelow(span)
        for offset in range(span):
            candidate = low + (start + offset) % span
            if candidate in self._allocated:
                continue
            if not _port_is_free(candidate):
                continue
            self._allocated.add(candidate)
            return candidate

        raise TransportError(
            "no free injection port available in the configured range",
            port_range=self.port_range,
            allocated=len(self._allocated),
        )

    def describe(self) -> dict[str, Any]:
        with self._lock:
            self._prune_locked()
            hosts = [r.to_dict() for r in sorted(self._hosts.values(), key=lambda r: r.registered_at)]
            allocated = len(self._allocated)
        return {
            "protocolVersion": PROTOCOL_VERSION,
            "hostCount": len(hosts),
            "allocatedPorts": allocated,
            "sessionTtlSeconds": self.session_ttl,
            "heartbeatIntervalSeconds": self.heartbeat_interval,
            "portRange": list(self.port_range),
            "hosts": hosts,
        }


def _port_is_free(port: int, host: str = "127.0.0.1") -> bool:
    """True when nothing is listening on ``port``."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        try:
            probe.bind((host, port))
            return True
        except OSError:
            return False


# --------------------------------------------------------------------------- #
# HTTP surface
# --------------------------------------------------------------------------- #

_INDEX_HTML = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<title>BTPS Registration Centre</title>
<style>
  :root{color-scheme:light dark}
  body{font:14px/1.6 ui-monospace,SFMono-Regular,Menlo,monospace;margin:0;padding:2rem;
       background:#fafafa;color:#18181b}
  @media(prefers-color-scheme:dark){body{background:#0b0b0d;color:#e4e4e7}}
  h1{font-size:1.1rem;letter-spacing:.02em;margin:0 0 1rem}
  code{background:rgba(128,128,128,.15);padding:.1em .35em;border-radius:3px}
  table{border-collapse:collapse;width:100%;margin-top:1rem}
  th,td{text-align:left;padding:.4rem .6rem;border-bottom:1px solid rgba(128,128,128,.25)}
  th{font-weight:600;font-size:.85rem;text-transform:uppercase;letter-spacing:.06em;opacity:.7}
  .empty{opacity:.6;font-style:italic;margin-top:1rem}
</style></head><body>
<h1>BTPS Registration Centre</h1>
<p>Control plane only. Plugin payloads never pass through this port.</p>
<p>Endpoints: <code>POST /register</code> <code>POST /heartbeat</code>
<code>POST /unregister</code> <code>GET /hosts</code> <code>GET /health</code></p>
<div id="hosts" class="empty">loading…</div>
<script>
async function refresh(){
  const target = document.getElementById('hosts');
  try{
    const data = await (await fetch('/hosts')).json();
    if(!data.hosts.length){ target.className='empty';
      target.textContent='no hosts registered'; return; }
    target.className='';
    target.innerHTML = '<table><thead><tr><th>Host</th><th>Version</th>'
      + '<th>PID</th><th>Inject port</th><th>Age</th></tr></thead><tbody>'
      + data.hosts.map(h=>`<tr><td>${h.name}</td><td>${h.hostVersion}</td>`
      + `<td>${h.pid}</td><td>${h.injectPort}</td><td>${h.ageSeconds}s</td></tr>`).join('')
      + '</tbody></table>';
  }catch(e){ target.textContent = 'error: ' + e.message; }
}
refresh(); setInterval(refresh, 3000);
</script></body></html>
"""


class RegistryServer:
    """HTTP server exposing a :class:`HostRegistry` on port 5663."""

    def __init__(
        self,
        registry: HostRegistry | None = None,
        *,
        host: str = "127.0.0.1",
        port: int = DEFAULT_REGISTRY_PORT,
        on_event: Callable[[str, Any], None] | None = None,
    ) -> None:
        self.registry = registry if registry is not None else HostRegistry()
        self.host = host
        self.port = port
        self.on_event = on_event
        self._server: ThreadingHTTPServer | None = None
        self._thread: threading.Thread | None = None

    # -- lifecycle ---------------------------------------------------------- #

    @property
    def address(self) -> str:
        actual = self._server.server_address[1] if self._server else self.port
        return f"http://{self.host}:{actual}"

    def start(self, *, background: bool = True) -> "RegistryServer":
        """Bind and start serving. ``port=0`` picks any free port (useful in tests)."""
        handler = self._make_handler()

        class _Server(ThreadingHTTPServer):
            daemon_threads = True
            allow_reuse_address = True

        try:
            self._server = _Server((self.host, self.port), handler)
        except OSError as exc:
            raise TransportError(
                f"cannot bind the registration centre to {self.host}:{self.port}: {exc}",
                host=self.host,
                port=self.port,
                hint="another process may already own the port",
            ) from exc

        self.port = self._server.server_address[1]

        if background:
            self._thread = threading.Thread(
                target=self._server.serve_forever,
                name="btps-registry",
                daemon=True,
            )
            self._thread.start()
        return self

    def serve_forever(self) -> None:
        if self._server is None:
            self.start(background=False)
        assert self._server is not None
        self._server.serve_forever()

    def stop(self) -> None:
        if self._server is not None:
            self._server.shutdown()
            self._server.server_close()
            self._server = None
        if self._thread is not None:
            self._thread.join(timeout=2.0)
            self._thread = None

    def __enter__(self) -> "RegistryServer":
        return self.start()

    def __exit__(self, *exc_info: object) -> None:
        self.stop()

    # -- request handling --------------------------------------------------- #

    def _make_handler(server_self) -> type[BaseHTTPRequestHandler]:  # noqa: N805
        registry = server_self.registry
        on_event = server_self.on_event

        class Handler(BaseHTTPRequestHandler):
            server_version = "BTPS-Registry/1.0"
            protocol_version = "HTTP/1.1"

            # -- helpers ------------------------------------------------ #

            def _send_json(self, payload: Any, status: int = HTTPStatus.OK) -> None:
                body = json.dumps(payload, ensure_ascii=False, default=str).encode("utf-8")
                self.send_response(status)
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "no-store")
                self.send_header("Access-Control-Allow-Origin", "*")
                self.end_headers()
                self.wfile.write(body)

            def _send_html(self, text: str, status: int = HTTPStatus.OK) -> None:
                body = text.encode("utf-8")
                self.send_response(status)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def _read_json(self) -> dict[str, Any]:
                length = int(self.headers.get("Content-Length") or 0)
                if length <= 0:
                    return {}
                if length > 1_000_000:
                    raise TransportError("request body too large", size=length)
                raw = self.rfile.read(length)
                try:
                    parsed = json.loads(raw.decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                    raise TransportError(f"request body is not valid JSON: {exc}") from exc
                if not isinstance(parsed, dict):
                    raise TransportError("request body must be a JSON object")
                return parsed

            def _error(self, exc: Exception, status: int = HTTPStatus.BAD_REQUEST) -> None:
                self._send_json(
                    {
                        "ok": False,
                        "error": str(exc),
                        "type": type(exc).__name__,
                    },
                    status,
                )

            def log_message(self, fmt: str, *args: Any) -> None:  # noqa: A003
                # Quieter than the default: the registry is polled frequently and
                # a line per poll drowns the host's own logs.
                if on_event is not None:
                    on_event("http", {"format": fmt, "args": args})

            # -- verbs -------------------------------------------------- #

            def do_OPTIONS(self) -> None:  # noqa: N802
                self.send_response(HTTPStatus.NO_CONTENT)
                self.send_header("Access-Control-Allow-Origin", "*")
                self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
                self.send_header("Access-Control-Allow-Headers", "Content-Type")
                self.send_header("Content-Length", "0")
                self.end_headers()

            def do_GET(self) -> None:  # noqa: N802
                parsed = urlparse(self.path)
                route = parsed.path.rstrip("/") or "/"

                if route == "/":
                    self._send_html(_INDEX_HTML)
                    return

                if route == "/health":
                    self._send_json(
                        {
                            "ok": True,
                            "service": "btps-registry",
                            "protocolVersion": PROTOCOL_VERSION,
                            "hostCount": registry.count(),
                            "heartbeatInterval": registry.heartbeat_interval,
                            "sessionTtl": registry.session_ttl,
                        }
                    )
                    return

                if route == "/hosts":
                    query = parse_qs(parsed.query)
                    if query.get("name"):
                        found = registry.find_by_name(query["name"][0])
                        if found is None:
                            self._error(
                                TransportError(f"no host named {query['name'][0]!r}"),
                                HTTPStatus.NOT_FOUND,
                            )
                            return
                        self._send_json({"ok": True, "host": found.to_dict()})
                        return
                    self._send_json({"ok": True, **registry.describe()})
                    return

                if route.startswith("/hosts/"):
                    host_id = route.split("/", 2)[2]
                    registration = registry.get(host_id)
                    if registration is None:
                        self._error(
                            TransportError(f"unknown host {host_id!r}"),
                            HTTPStatus.NOT_FOUND,
                        )
                        return
                    self._send_json({"ok": True, "host": registration.to_dict()})
                    return

                self._error(
                    TransportError(f"no route for GET {route}"), HTTPStatus.NOT_FOUND
                )

            def do_POST(self) -> None:  # noqa: N802
                route = urlparse(self.path).path.rstrip("/") or "/"
                try:
                    body = self._read_json()
                except Exception as exc:  # noqa: BLE001 - transport faults are reported
                    self._error(exc)
                    return

                if route == "/register":
                    try:
                        registration = registry.register(
                            name=str(body.get("name", "")),
                            host_version=str(body.get("hostVersion", "0.0.0")),
                            host_api_version=str(body.get("hostApiVersion", "1.0.0")),
                            capabilities=body.get("capabilities") or (),
                            pid=int(body.get("pid") or 0),
                            metadata=body.get("metadata") or {},
                        )
                    except BTPSError as exc:
                        self._error(exc, HTTPStatus.CONFLICT)
                        return

                    if on_event is not None:
                        on_event("registered", registration)

                    self._send_json(
                        {
                            "ok": True,
                            "protocolVersion": PROTOCOL_VERSION,
                            "hostId": registration.host_id,
                            "sessionToken": registration.session_token,
                            "injectPort": registration.inject_port,
                            "injectUrl": registration.inject_url,
                            "heartbeatInterval": registry.heartbeat_interval,
                            "sessionTtl": registry.session_ttl,
                        },
                        HTTPStatus.CREATED,
                    )
                    return

                if route == "/heartbeat":
                    ok = registry.heartbeat(
                        str(body.get("hostId", "")), str(body.get("sessionToken", ""))
                    )
                    if not ok:
                        self._error(
                            TransportError("unknown host or invalid session token"),
                            HTTPStatus.UNAUTHORIZED,
                        )
                        return
                    self._send_json(
                        {
                            "ok": True,
                            "nextHeartbeatIn": registry.heartbeat_interval,
                        }
                    )
                    return

                if route == "/unregister":
                    ok = registry.unregister(
                        str(body.get("hostId", "")), str(body.get("sessionToken", ""))
                    )
                    if on_event is not None:
                        on_event("unregistered", body.get("hostId"))
                    self._send_json({"ok": ok})
                    return

                self._error(
                    TransportError(f"no route for POST {route}"), HTTPStatus.NOT_FOUND
                )

        return Handler


def serve_registry(
    *,
    host: str = "127.0.0.1",
    port: int = DEFAULT_REGISTRY_PORT,
    session_ttl: float = DEFAULT_SESSION_TTL,
) -> RegistryServer:
    """Bind and start the registration centre in a background thread."""
    registry = HostRegistry(session_ttl=session_ttl)
    return RegistryServer(registry, host=host, port=port).start()
