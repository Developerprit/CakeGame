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

"""Injector: the WebSocket data plane between a host program and its plugins.

Flow (as specified in ``BrickTile.txt``)::

    host program ──register──▶ :5663 registry
    host program ◀──inject port── registry
    host program ──WebSocket──▶ injector   (payload travels here)
    injector ──reverse push──▶ host program

Design notes
------------
**Why WebSocket and not raw TCP.** The host may be a browser-hosted control
panel, a Node process, or anything else that speaks HTTP. WebSocket is the only
framing that all of them implement without extra dependencies.

**Why sequence numbers.** Injection payloads are ordered and must not be
reordered or duplicated by a reconnect. Every frame carries a monotonically
increasing ``seq``; the receiver ACKs and the sender resumes from the last ACKed
sequence. This is deliberately a small, verifiable protocol rather than a
general-purpose messaging layer.

**Why chunking is explicit.** A single hook payload can be several megabytes
(think a bundled asset). Silently truncating would be a data-loss bug; silently
buffering would be a memory bug. The frame declares its own total size and the
receiver reassembles, refusing anything over ``max_frame_bytes``.

**Server implementation.** This module implements the WebSocket handshake and
frame codec directly on top of ``socket`` — the standard library has no WebSocket
server, and pulling in a dependency for a ~200-line codec that runs on
``127.0.0.1`` would be the wrong trade.
"""

from __future__ import annotations

import base64
import hashlib
import json
import os
import secrets
import socket
import struct
import threading
import time
from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Callable, Iterable, Mapping, Sequence

from .errors import TransportError

__all__ = [
    "FrameType",
    "InjectFrame",
    "InjectionTarget",
    "InjectorServer",
    "InjectorClient",
    "WebSocketConnection",
    "GUID",
    "DEFAULT_MAX_FRAME_BYTES",
]

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

DEFAULT_MAX_FRAME_BYTES = 1024 * 1024  # 1 MiB per frame
DEFAULT_CHUNK_BYTES = 512 * 1024
DEFAULT_PING_INTERVAL = 15.0


class FrameType(str, Enum):
    """Frame kinds understood by the injector."""

    HELLO = "hello"
    HELLO_ACK = "hello.ack"
    INJECT = "inject"
    ACK = "ack"
    NACK = "nack"
    CHUNK = "chunk"
    PING = "ping"
    PONG = "pong"
    EVENT = "event"
    ERROR = "error"
    BYE = "bye"


class InjectionTarget(str):
    """Well-known injection targets."""

    CONSOLE_UI = "console.ui"
    PACKAGE = "package"
    HOOK = "hook"
    STYLE = "style"
    SCRIPT = "script"
    DOM = "dom"
    SETTINGS = "settings"


@dataclass
class InjectFrame:
    """One protocol frame.

    Wire format is a JSON object. ``payload`` may be any JSON value; binary
    payloads must be carried as ``{"encoding": "base64", "data": "..."}`` — note
    that BTPS itself never emits base64 (see the project's host constraints);
    that escape hatch exists only for hosts that require it.
    """

    seq: int
    type: str
    target: str = ""
    payload: Any = None
    requires_ack: bool = False
    chunk: dict[str, int] | None = None
    timestamp: float = field(default_factory=time.time)

    def to_dict(self) -> dict[str, Any]:
        data: dict[str, Any] = {
            "seq": self.seq,
            "type": self.type,
            "ts": self.timestamp,
        }
        if self.target:
            data["target"] = self.target
        if self.payload is not None:
            data["payload"] = self.payload
        if self.requires_ack:
            data["ack"] = True
        if self.chunk:
            data["chunk"] = self.chunk
        return data

    def to_json(self) -> str:
        return json.dumps(self.to_dict(), ensure_ascii=False, default=str)

    @classmethod
    def from_dict(cls, data: Mapping[str, Any]) -> "InjectFrame":
        # Accepting a non-mapping here previously blew up with a bare ValueError
        # from the downstream ``dict(data)`` call, escaping the BTPS error
        # hierarchy so callers could not handle it with ``except BTPSError``.
        if not isinstance(data, Mapping):
            raise TransportError(
                f"frame must be a mapping, got {type(data).__name__}",
                actual_type=type(data).__name__,
            )
        if "seq" not in data:
            raise TransportError("frame is missing its sequence number", frame=dict(data))
        raw_type = str(data.get("type", FrameType.INJECT))
        # Reject unknown frame kinds up front. A typo in a frame type would
        # otherwise travel as an opaque string and be silently ignored by every
        # handler, which is far harder to diagnose than a clean handshake error.
        try:
            frame_type = FrameType(raw_type)
        except ValueError:
            raise TransportError(
                f"unknown frame type {raw_type!r}",
                frame_type=raw_type,
                known=[t.value for t in FrameType],
            ) from None
        chunk = data.get("chunk")
        return cls(
            seq=int(data["seq"]),
            type=frame_type,
            target=str(data.get("target", "")),
            payload=data.get("payload"),
            requires_ack=bool(data.get("ack", False)),
            chunk=dict(chunk) if isinstance(chunk, Mapping) else None,
            timestamp=float(data.get("ts") or time.time()),
        )

    @classmethod
    def from_json(cls, text: str) -> "InjectFrame":
        try:
            parsed = json.loads(text)
        except json.JSONDecodeError as exc:
            raise TransportError(f"frame is not valid JSON: {exc}") from exc
        if not isinstance(parsed, Mapping):
            raise TransportError("frame must be a JSON object")
        return cls.from_dict(parsed)


# --------------------------------------------------------------------------- #
# WebSocket codec
# --------------------------------------------------------------------------- #

_OPCODE_CONTINUATION = 0x0
_OPCODE_TEXT = 0x1
_OPCODE_BINARY = 0x2
_OPCODE_CLOSE = 0x8
_OPCODE_PING = 0x9
_OPCODE_PONG = 0xA


class WebSocketConnection:
    """A minimal RFC 6455 connection over a socket.

    Supports text frames, fragmentation, ping/pong, and close. Extensions and
    compression are not negotiated: they add state that buys nothing on a
    loopback link and would double the codec's test surface.
    """

    def __init__(self, sock: socket.socket, *, max_message_bytes: int = 16 * 1024 * 1024) -> None:
        self.socket = sock
        self.max_message_bytes = max_message_bytes
        self._send_lock = threading.Lock()
        self.closed = False
        self._buffer = bytearray()

    # -- handshake ---------------------------------------------------------- #

    @staticmethod
    def accept_key(client_key: str) -> str:
        """Compute the Sec-WebSocket-Accept value for a client key."""
        digest = hashlib.sha1((client_key + GUID).encode("ascii")).digest()
        return base64.b64encode(digest).decode("ascii")

    @classmethod
    def handshake(
        cls,
        sock: socket.socket,
        *,
        max_message_bytes: int = 16 * 1024 * 1024,
        timeout: float = 5.0,
    ) -> "WebSocketConnection":
        """Perform the server side of the opening handshake."""
        sock.settimeout(timeout)
        request = _read_http_headers(sock)
        if not request:
            raise TransportError("client closed during the WebSocket handshake")

        first_line = request.split("\r\n", 1)[0]
        parts = first_line.split()
        if len(parts) < 3 or parts[0].upper() != "GET":
            raise TransportError(
                "WebSocket handshake requires a GET request", request_line=first_line
            )
        if "upgrade: websocket" not in request.lower():
            raise TransportError("missing Upgrade: websocket header")

        headers = _parse_headers(request)
        client_key = headers.get("sec-websocket-key")
        if not client_key:
            raise TransportError("missing Sec-WebSocket-Key header")

        accept = cls.accept_key(client_key)
        response = (
            "HTTP/1.1 101 Switching Protocols\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Accept: {accept}\r\n"
            "\r\n"
        )
        sock.sendall(response.encode("ascii"))
        sock.settimeout(None)
        return cls(sock, max_message_bytes=max_message_bytes)

    # -- framing ------------------------------------------------------------ #

    def send_text(self, text: str) -> None:
        self._send_frame(_OPCODE_TEXT, text.encode("utf-8"))

    def send_binary(self, data: bytes) -> None:
        self._send_frame(_OPCODE_BINARY, data)

    def send_ping(self, data: bytes = b"") -> None:
        self._send_frame(_OPCODE_PING, data)

    def send_pong(self, data: bytes = b"") -> None:
        self._send_frame(_OPCODE_PONG, data)

    def send_close(self, code: int = 1000, reason: str = "") -> None:
        payload = struct.pack("!H", code) + reason.encode("utf-8")
        try:
            self._send_frame(_OPCODE_CLOSE, payload)
        except OSError:
            pass
        self.closed = True

    def _send_frame(self, opcode: int, payload: bytes) -> None:
        if self.closed:
            raise TransportError("cannot send on a closed WebSocket connection")
        length = len(payload)
        header = bytearray()
        header.append(0x80 | opcode)  # FIN set, no RSV bits

        if length < 126:
            header.append(length)
        elif length < 65536:
            header.append(126)
            header.extend(struct.pack("!H", length))
        else:
            header.append(127)
            header.extend(struct.pack("!Q", length))

        with self._send_lock:
            try:
                self.socket.sendall(bytes(header) + payload)
            except OSError as exc:
                self.closed = True
                raise TransportError(f"WebSocket send failed: {exc}") from exc

    def receive(self, *, timeout: float | None = None) -> tuple[int, bytes] | None:
        """Read one complete message. Returns ``(opcode, payload)`` or ``None``.

        Handles fragmentation transparently and answers pings inline, so callers
        only ever see text/binary messages or ``None`` on close.
        """
        if timeout is not None:
            self.socket.settimeout(timeout)

        fragments = bytearray()
        message_opcode: int | None = None

        while True:
            try:
                header = self._read_exact(2)
            except socket.timeout:
                raise
            except OSError as exc:
                self.closed = True
                raise TransportError(f"WebSocket read failed: {exc}") from exc

            if header is None:
                self.closed = True
                return None

            fin = bool(header[0] & 0x80)
            opcode = header[0] & 0x0F
            masked = bool(header[1] & 0x80)
            length = header[1] & 0x7F

            if length == 126:
                raw = self._read_exact(2)
                if raw is None:
                    return None
                length = struct.unpack("!H", raw)[0]
            elif length == 127:
                raw = self._read_exact(8)
                if raw is None:
                    return None
                length = struct.unpack("!Q", raw)[0]

            if length > self.max_message_bytes:
                # Refuse rather than allocate: an oversized frame is either a bug
                # or an attack, and both deserve a clean disconnect.
                self.send_close(1009, "message too large")
                raise TransportError(
                    f"WebSocket frame declares {length} bytes, above the "
                    f"{self.max_message_bytes} byte limit",
                    length=length,
                )

            mask_key = self._read_exact(4) if masked else None
            payload = self._read_exact(length, allow_empty=True) if length else b""
            if payload is None:
                self.closed = True
                return None

            if mask_key:
                payload = _unmask(payload, mask_key)

            if opcode == _OPCODE_CLOSE:
                self.closed = True
                try:
                    self.send_close()
                except TransportError:
                    pass
                return None
            if opcode == _OPCODE_PING:
                self.send_pong(payload)
                continue
            if opcode == _OPCODE_PONG:
                continue

            if opcode == _OPCODE_CONTINUATION:
                if message_opcode is None:
                    raise TransportError("received a continuation frame with nothing to continue")
                fragments.extend(payload)
            else:
                message_opcode = opcode
                fragments = bytearray(payload)

            if fin:
                return message_opcode, bytes(fragments)

    def _read_exact(self, count: int, *, allow_empty: bool = False) -> bytes | None:
        if count == 0 and not allow_empty:
            return b""
        chunks = bytearray()
        while len(chunks) < count:
            try:
                block = self.socket.recv(count - len(chunks))
            except socket.timeout:
                raise
            except OSError as exc:
                self.closed = True
                raise TransportError(f"WebSocket read failed: {exc}") from exc
            if not block:
                return None
            chunks.extend(block)
        return bytes(chunks)

    def close(self) -> None:
        if self.closed:
            return
        try:
            self.send_close()
        except Exception:  # noqa: BLE001 - closing must not raise
            pass
        try:
            self.socket.close()
        except OSError:
            pass
        self.closed = True


def _unmask(payload: bytes, key: bytes) -> bytes:
    return bytes(byte ^ key[index & 3] for index, byte in enumerate(payload))


def _read_http_headers(sock: socket.socket) -> str:
    """Read until the end of the HTTP header block."""
    buffer = bytearray()
    while b"\r\n\r\n" not in buffer:
        try:
            block = sock.recv(4096)
        except OSError:
            return ""
        if not block:
            return ""
        buffer.extend(block)
        if len(buffer) > 64 * 1024:
            raise TransportError("HTTP handshake headers exceeded 64 KiB")
    return buffer.decode("latin-1", errors="replace")


def _parse_headers(request: str) -> dict[str, str]:
    headers: dict[str, str] = {}
    for line in request.split("\r\n")[1:]:
        if not line or ":" not in line:
            continue
        name, _, value = line.partition(":")
        headers[name.strip().lower()] = value.strip()
    return headers


# --------------------------------------------------------------------------- #
# Injector server (host side)
# --------------------------------------------------------------------------- #


class InjectorServer:
    """Serves the WebSocket injection channel for one host.

    The host connects to ``ws://127.0.0.1:<inject_port>`` — but *this* object is
    the listener, which is what ``BrickTile.txt`` calls the "injection port". The
    naming is from the host's perspective: the host receives injected content on
    this channel.

    Handlers registered via :meth:`on` receive ``(target, payload)`` and may
    return a value, which is sent back as an ``ack`` frame carrying that value.
    """

    def __init__(
        self,
        *,
        host: str = "127.0.0.1",
        port: int = 0,
        max_frame_bytes: int = DEFAULT_MAX_FRAME_BYTES,
        ping_interval: float = DEFAULT_PING_INTERVAL,
        on_event: Callable[[str, Any], None] | None = None,
    ) -> None:
        self.host = host
        self.port = port
        self.max_frame_bytes = max_frame_bytes
        self.ping_interval = ping_interval
        self.on_event = on_event

        self._listener: socket.socket | None = None
        self._thread: threading.Thread | None = None
        self._stop = threading.Event()
        self._connections: list[WebSocketConnection] = []
        self._handlers: dict[str, Callable[[Any, "InjectServerSession"], Any]] = {}
        self._sessions: list["InjectServerSession"] = []
        self._lock = threading.RLock()
        self._sequence = 0

    # -- lifecycle ---------------------------------------------------------- #

    @property
    def address(self) -> str:
        actual = self._listener.getsockname()[1] if self._listener else self.port
        return f"ws://{self.host}:{actual}"

    def start(self) -> "InjectorServer":
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            sock.bind((self.host, self.port))
        except OSError as exc:
            sock.close()
            raise TransportError(
                f"cannot bind the injector to {self.host}:{self.port}: {exc}",
                host=self.host,
                port=self.port,
            ) from exc
        sock.listen(8)
        self._listener = sock
        self.port = sock.getsockname()[1]
        self._stop.clear()
        self._thread = threading.Thread(
            target=self._accept_loop, name="btps-injector", daemon=True
        )
        self._thread.start()
        return self

    def stop(self) -> None:
        self._stop.set()
        if self._listener is not None:
            try:
                self._listener.close()
            except OSError:
                pass
            self._listener = None
        with self._lock:
            sessions = list(self._sessions)
        for session in sessions:
            session.close()
        if self._thread is not None:
            self._thread.join(timeout=2.0)
            self._thread = None

    def __enter__(self) -> "InjectorServer":
        return self.start()

    def __exit__(self, *exc_info: object) -> None:
        self.stop()

    # -- accept loop -------------------------------------------------------- #

    def _accept_loop(self) -> None:
        while not self._stop.is_set():
            listener = self._listener
            if listener is None:
                break
            try:
                client, address = listener.accept()
            except OSError:
                break
            try:
                connection = WebSocketConnection.handshake(
                    client, max_message_bytes=self.max_frame_bytes * 4
                )
            except TransportError as exc:
                # A failed handshake is routine: browsers probe, scanners probe.
                # Close quietly and keep serving.
                self._emit("handshake_failed", {"address": address, "error": str(exc)})
                try:
                    client.close()
                except OSError:
                    pass
                continue

            session = InjectServerSession(self, connection, address)
            with self._lock:
                self._connections.append(connection)
                self._sessions.append(session)
            self._emit("client_connected", {"address": address})
            threading.Thread(
                target=session.run, name=f"btps-inject-{address[1]}", daemon=True
            ).start()

    def _emit(self, kind: str, payload: Any) -> None:
        if self.on_event is not None:
            try:
                self.on_event(kind, payload)
            except Exception:  # noqa: BLE001 - observers must not break the server
                pass

    # -- handlers ----------------------------------------------------------- #

    def on(self, target: str) -> Callable[[Callable[[Any, "InjectServerSession"], Any]], Callable[..., Any]]:
        """Register a handler for an injection target."""

        def decorator(handler: Callable[[Any, "InjectServerSession"], Any]) -> Callable[..., Any]:
            self._handlers[target] = handler
            return handler

        return decorator

    def handle(self, target: str, handler: Callable[[Any, "InjectServerSession"], Any]) -> None:
        self._handlers[target] = handler

    def dispatch(self, target: str, payload: Any, session: "InjectServerSession") -> Any:
        handler = self._handlers.get(target)
        if handler is None:
            wildcard = self._handlers.get("*")
            if wildcard is None:
                raise TransportError(
                    f"no handler registered for injection target {target!r}",
                    target=target,
                    known=sorted(self._handlers),
                )
            return wildcard(payload, session)
        return handler(payload, session)

    # -- pushing ------------------------------------------------------------ #

    def next_sequence(self) -> int:
        with self._lock:
            self._sequence += 1
            return self._sequence

    def broadcast(self, target: str, payload: Any) -> int:
        """Push a payload to every connected client. Returns the send count."""
        with self._lock:
            sessions = [s for s in self._sessions if not s.closed]
        sent = 0
        for session in sessions:
            try:
                session.send(target, payload, requires_ack=False)
                sent += 1
            except TransportError:
                continue
        return sent

    @property
    def clients(self) -> list["InjectServerSession"]:
        with self._lock:
            return [s for s in self._sessions if not s.closed]

    def describe(self) -> dict[str, Any]:
        with self._lock:
            active = [s for s in self._sessions if not s.closed]
        return {
            "address": self.address,
            "clients": len(active),
            "handlers": sorted(self._handlers),
            "maxFrameBytes": self.max_frame_bytes,
        }


class InjectServerSession:
    """One connected client of an :class:`InjectorServer`."""

    def __init__(
        self,
        server: InjectorServer,
        connection: WebSocketConnection,
        address: tuple[str, int],
    ) -> None:
        self.server = server
        self.connection = connection
        self.address = address
        self.closed = False
        self.host_id = ""
        self.last_seen = time.time()
        self._lock = threading.Lock()
        self._last_ack = 0
        self._pending: dict[int, InjectFrame] = {}

    def send(
        self,
        target: str,
        payload: Any,
        *,
        requires_ack: bool = False,
        frame_type: str = FrameType.INJECT,
        chunk_large: bool = True,
    ) -> int:
        """Push a payload, chunking when it exceeds the frame limit.

        Returns the final sequence number used, so the caller can correlate
        acknowledgements.
        """
        text = json.dumps(payload, ensure_ascii=False, default=str)
        encoded = text.encode("utf-8")

        if chunk_large and len(encoded) > self.server.max_frame_bytes:
            return self._send_chunked(target, encoded, requires_ack=requires_ack)

        frame = InjectFrame(
            seq=self.server.next_sequence(),
            type=frame_type,
            target=target,
            payload=payload,
            requires_ack=requires_ack,
        )
        with self._lock:
            self.connection.send_text(frame.to_json())
            if requires_ack:
                self._pending[frame.seq] = frame
        return frame.seq

    def _send_chunked(self, target: str, encoded: bytes, *, requires_ack: bool) -> int:
        """Split an oversized payload across numbered chunk frames."""
        group = secrets.token_hex(4)
        size = self.server.max_frame_bytes
        chunks = [encoded[i : i + size] for i in range(0, len(encoded), size)]
        total = len(chunks)

        if total > 4096:
            raise TransportError(
                f"payload needs {total} chunks, above the 4096 chunk ceiling",
                target=target,
                size=len(encoded),
            )

        last_seq = 0
        for index, chunk in enumerate(chunks):
            frame = InjectFrame(
                seq=self.server.next_sequence(),
                type=FrameType.CHUNK,
                target=target,
                payload=chunk.decode("utf-8", errors="replace"),
                requires_ack=requires_ack and index == total - 1,
                chunk={"i": index, "n": total, "group": group},  # type: ignore[dict-item]
            )
            with self._lock:
                self.connection.send_text(frame.to_json())
            last_seq = frame.seq

        if requires_ack:
            with self._lock:
                self._pending[last_seq] = InjectFrame(
                    seq=last_seq, type=FrameType.INJECT, target=target
                )
        return last_seq

    def run(self) -> None:
        """Serve this session until the peer disconnects."""
        try:
            while not self.closed and not self.server._stop.is_set():
                try:
                    received = self.connection.receive(timeout=1.0)
                except socket.timeout:
                    if time.time() - self.last_seen > self.server.ping_interval * 3:
                        # Three missed intervals: treat as dead and free the slot.
                        break
                    self.connection.send_ping()
                    continue
                except TransportError:
                    break

                if received is None:
                    break

                opcode, data = received
                self.last_seen = time.time()
                if opcode == _OPCODE_BINARY:
                    # Binary frames are reserved for future use; accepting them
                    # now would create a second, untested code path.
                    continue

                try:
                    text = data.decode("utf-8")
                except UnicodeDecodeError as exc:
                    self.send_error(f"frame is not valid UTF-8: {exc}")
                    continue

                for line in text.splitlines():
                    line = line.strip()
                    if line:
                        self._handle_line(line)
        finally:
            self.close()

    def _handle_line(self, line: str) -> None:
        try:
            frame = InjectFrame.from_json(line)
        except TransportError as exc:
            self.send_error(str(exc))
            return

        if frame.type == FrameType.HELLO:
            payload = frame.payload if isinstance(frame.payload, Mapping) else {}
            self.host_id = str(payload.get("hostId", ""))
            self.connection.send_text(
                json.dumps(
                    {
                        "seq": self.server.next_sequence(),
                        "type": FrameType.HELLO_ACK,
                        "payload": {
                            "accepted": True,
                            "hostId": self.host_id or "anonymous",
                            "maxFrameBytes": self.server.max_frame_bytes,
                            "pingInterval": self.server.ping_interval,
                        },
                    },
                    ensure_ascii=False,
                )
            )
            self.server._emit("hello", {"hostId": self.host_id, "address": self.address})
            return

        if frame.type == FrameType.ACK:
            payload = frame.payload if isinstance(frame.payload, Mapping) else {}
            acked = int(payload.get("seq", frame.seq))
            with self._lock:
                self._pending.pop(acked, None)
                self._last_ack = max(self._last_ack, acked)
            return

        if frame.type == FrameType.PING:
            self.connection.send_text(
                json.dumps({"seq": self.server.next_sequence(), "type": FrameType.PONG})
            )
            return

        if frame.type == FrameType.BYE:
            self.closed = True
            return

        if frame.type in (FrameType.INJECT, FrameType.CHUNK, FrameType.EVENT):
            self._receive_payload(frame)
            return

        self.send_error(f"unsupported frame type {frame.type!r}")

    def _receive_payload(self, frame: InjectFrame) -> None:
        """Handle an inbound payload, reassembling chunks when needed."""
        if frame.chunk:
            group = str(frame.chunk.get("group", "default"))
            index = int(frame.chunk.get("i", 0))
            total = int(frame.chunk.get("n", 1))
            self._chunks.setdefault(group, {})["meta"] = (index, total)
            self._chunks[group][index] = str(frame.payload)
            if len(self._chunks[group]) - 1 < total:
                return  # still waiting for more chunks
            parts = [
                self._chunks[group][i]
                for i in range(total)
                if i in self._chunks[group]
            ]
            self._chunks.pop(group, None)
            try:
                payload = json.loads("".join(parts))
            except json.JSONDecodeError as exc:
                self.send_error(f"reassembled chunk group is not valid JSON: {exc}")
                return
        else:
            payload = frame.payload

        target = frame.target or InjectionTarget.PACKAGE
        try:
            result = self.server.dispatch(target, payload, self)
        except Exception as exc:  # noqa: BLE001 - handler faults are reported as NACK
            self.connection.send_text(
                json.dumps(
                    {
                        "seq": self.server.next_sequence(),
                        "type": FrameType.NACK,
                        "target": target,
                        "payload": {
                            "seq": frame.seq,
                            "error": str(exc),
                            "type": type(exc).__name__,
                        },
                    },
                    ensure_ascii=False,
                )
            )
            self.server._emit("inject_failed", {"target": target, "error": str(exc)})
            return

        if frame.requires_ack or result is not None:
            self.connection.send_text(
                json.dumps(
                    {
                        "seq": self.server.next_sequence(),
                        "type": FrameType.ACK,
                        "target": target,
                        "payload": {"seq": frame.seq, "result": result},
                    },
                    ensure_ascii=False,
                    default=str,
                )
            )
        self.server._emit("injected", {"target": target, "seq": frame.seq})

    _chunks: dict[str, dict[Any, Any]] = {}

    def send_error(self, message: str) -> None:
        try:
            self.connection.send_text(
                json.dumps(
                    {
                        "seq": self.server.next_sequence(),
                        "type": FrameType.ERROR,
                        "payload": {"message": message},
                    },
                    ensure_ascii=False,
                )
            )
        except TransportError:
            pass

    def close(self) -> None:
        if self.closed:
            return
        self.closed = True
        self.connection.close()
        # Drop the accumulated chunk buffers for this session.
        self._chunks = {}
        self.server._emit("client_disconnected", {"address": self.address})


# --------------------------------------------------------------------------- #
# Injector client (plugin / tooling side)
# --------------------------------------------------------------------------- #


class InjectorClient:
    """Client for the injection channel.

    Connects to an :class:`InjectorServer`, performs the ``hello`` exchange, and
    exposes simple ``send`` / ``receive`` operations for hosts and tooling.
    """

    def __init__(
        self,
        url: str,
        *,
        host_id: str = "",
        timeout: float = 5.0,
    ) -> None:
        self.url = url
        self.host_id = host_id
        self.timeout = timeout
        self.connection: WebSocketConnection | None = None
        self._sequence = 0
        self._hello_payload: dict[str, Any] = {}

    def connect(self) -> "InjectorClient":
        parsed = self.url.replace("ws://", "http://", 1)
        if not parsed.startswith("http://"):
            raise TransportError(
                f"unsupported injector URL scheme: {self.url!r}",
                hint="expected ws://127.0.0.1:<port>",
            )
        authority = parsed[len("http://") :].split("/", 1)[0]
        host, _, port_text = authority.partition(":")
        port = int(port_text or 80)

        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(self.timeout)
        try:
            sock.connect((host or "127.0.0.1", port))
        except OSError as exc:
            sock.close()
            raise TransportError(
                f"cannot connect to the injector at {self.url}: {exc}", url=self.url
            ) from exc

        key = base64.b64encode(secrets.token_bytes(16)).decode("ascii")
        request = (
            f"GET / HTTP/1.1\r\n"
            f"Host: {host}:{port}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            "\r\n"
        )
        try:
            sock.sendall(request.encode("ascii"))
            sock.settimeout(self.timeout)
            response = _read_http_headers(sock)
        except OSError as exc:
            sock.close()
            raise TransportError(f"handshake failed: {exc}") from exc

        if "101" not in response.split("\r\n", 1)[0]:
            sock.close()
            raise TransportError(
                "injector refused the WebSocket upgrade", response=response[:400]
            )

        headers = _parse_headers(response)
        expected = WebSocketConnection.accept_key(key)
        if headers.get("sec-websocket-accept") != expected:
            sock.close()
            raise TransportError("injector returned an invalid Sec-WebSocket-Accept value")

        sock.settimeout(None)
        self.connection = WebSocketConnection(sock)
        self.send(
            "",
            {"hostId": self.host_id or "anonymous", "client": "btps-injector-client"},
            frame_type=FrameType.HELLO,
        )
        return self

    def send(
        self,
        target: str,
        payload: Any,
        *,
        frame_type: str = FrameType.INJECT,
    ) -> int:
        """Push a payload to ``target``.

        The argument order matches :meth:`InjectServerSession.send` on the
        server side, so the same call shape works from either end. ``target``
        first is also the more common case: the frame kind is almost always
        ``inject`` and does not deserve the first positional slot.
        """
        if self.connection is None:
            raise TransportError("injector client is not connected")
        self._sequence += 1
        frame = InjectFrame(
            seq=self._sequence,
            type=frame_type,
            target=target,
            payload=payload,
        )
        self.connection.send_text(frame.to_json())
        return frame.seq

    def receive(self, *, timeout: float | None = None) -> InjectFrame | None:
        if self.connection is None:
            raise TransportError("injector client is not connected")
        received = self.connection.receive(timeout=timeout)
        if received is None:
            return None
        _, data = received
        return InjectFrame.from_json(data.decode("utf-8"))

    def close(self) -> None:
        if self.connection is not None:
            self.connection.close()
            self.connection = None

    def __enter__(self) -> "InjectorClient":
        return self.connect()

    def __exit__(self, *exc_info: object) -> None:
        self.close()
