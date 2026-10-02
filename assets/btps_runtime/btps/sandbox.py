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

"""Sandbox boundary: path fencing, permission gates, resource limits, audit.

Scope and honesty
-----------------
This is a **boundary enforcement** layer, not a hostile-code containment
layer. Plugin code runs in the host's Python process, and CPython cannot
meaningfully restrict in-process code that is determined to escape (no
capability-safe interpreter, no OS-level isolation here).

What BTPS therefore guarantees:

* a plugin can only touch paths the host granted, and only through this API —
  path resolution is fenced on every call, so ``../../etc/passwd`` fails
* a plugin can only use permissions it *declared in its manifest and the user
  approved*; undeclared calls raise :class:`PermissionDenied`
* resource use is bounded (wall-clock per hook, KV value size, recursion depth)
  so a buggy plugin cannot take the host down
* every denial, timeout, and oversized write lands in an audit log

What it explicitly does **not** guarantee:

* protection against a plugin that imports ``ctypes`` and calls into the OS
  directly. Hosts that need that guarantee must run plugins in a subprocess or
  a container — which BTPS supports as an alternate adapter mode.
"""

from __future__ import annotations

import json
import os
import re
import sys
import threading
import time
from contextlib import contextmanager
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Iterable, Iterator, Mapping, Sequence

from .errors import PermissionDenied, SandboxError
from .manifest import Manifest, permission_matches

__all__ = [
    "DEFAULT_LIMITS",
    "Limits",
    "AuditEntry",
    "AuditLog",
    "PathGuard",
    "PermissionGate",
    "KVStore",
    "Sandbox",
    "call_with_timeout",
    "SENSITIVE_PREFIXES",
]

SENSITIVE_PREFIXES = ("fs.write", "net.", "host.process", "host.env")


@dataclass(frozen=True)
class Limits:
    """Resource ceilings applied to plugin code.

    Defaults are tuned for interactive hosts: a hook that blocks for five
    seconds has already broken the user's experience, so that is the ceiling.
    """

    hook_timeout_seconds: float = 5.0
    hook_warn_seconds: float = 2.0
    kv_value_max_bytes: int = 64 * 1024
    kv_total_max_bytes: int = 4 * 1024 * 1024
    max_http_response_bytes: int = 8 * 1024 * 1024
    max_recursion_depth: int = 32
    max_plugin_memory_bytes: int = 256 * 1024 * 1024
    max_log_entries_per_minute: int = 600

    def to_dict(self) -> dict[str, Any]:
        return {
            "hookTimeoutSeconds": self.hook_timeout_seconds,
            "kvValueMaxBytes": self.kv_value_max_bytes,
            "kvTotalMaxBytes": self.kv_total_max_bytes,
            "maxHttpResponseBytes": self.max_http_response_bytes,
            "maxRecursionDepth": self.max_recursion_depth,
            "maxLogEntriesPerMinute": self.max_log_entries_per_minute,
        }


DEFAULT_LIMITS = Limits()


# --------------------------------------------------------------------------- #
# Audit
# --------------------------------------------------------------------------- #


@dataclass(frozen=True)
class AuditEntry:
    timestamp: float
    plugin_id: str
    kind: str  # "denied" | "timeout" | "error" | "limit" | "note"
    detail: str
    context: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {
            "timestamp": self.timestamp,
            "time": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(self.timestamp)),
            "pluginId": self.plugin_id,
            "kind": self.kind,
            "detail": self.detail,
            "context": self.context,
        }

    def __str__(self) -> str:
        stamp = time.strftime("%H:%M:%S", time.localtime(self.timestamp))
        return f"[{stamp}] {self.kind.upper():<8} {self.plugin_id}: {self.detail}"


class AuditLog:
    """Bounded, thread-safe ring buffer of security-relevant events."""

    def __init__(self, capacity: int = 2000) -> None:
        self.capacity = capacity
        self._entries: list[AuditEntry] = []
        self._lock = threading.Lock()

    def record(
        self,
        plugin_id: str,
        kind: str,
        detail: str,
        **context: Any,
    ) -> AuditEntry:
        entry = AuditEntry(time.time(), plugin_id, kind, detail, context)
        with self._lock:
            self._entries.append(entry)
            if len(self._entries) > self.capacity:
                del self._entries[: len(self._entries) - self.capacity]
        return entry

    def entries(
        self,
        *,
        plugin_id: str | None = None,
        kind: str | None = None,
    ) -> list[AuditEntry]:
        with self._lock:
            snapshot = list(self._entries)
        if plugin_id is not None:
            snapshot = [e for e in snapshot if e.plugin_id == plugin_id]
        if kind is not None:
            snapshot = [e for e in snapshot if e.kind == kind]
        return snapshot

    def clear(self, plugin_id: str | None = None) -> None:
        with self._lock:
            if plugin_id is None:
                self._entries.clear()
            else:
                self._entries = [e for e in self._entries if e.plugin_id != plugin_id]

    def to_dict(self) -> dict[str, Any]:
        with self._lock:
            snapshot = list(self._entries)
        return {"count": len(snapshot), "entries": [e.to_dict() for e in snapshot]}


# --------------------------------------------------------------------------- #
# Path fencing
# --------------------------------------------------------------------------- #


class PathGuard:
    """Confines every filesystem operation to an explicit set of roots.

    Two kinds of roots exist:

    * **read roots** — a plugin may read anything beneath them
    * **write roots** — a plugin may create/modify/delete beneath them

    Every path is resolved with :meth:`Path.resolve` *and* checked again after
    the parent directory exists, because symlinks can be introduced between the
    two operations. ``strict=False`` resolution tolerates a not-yet-created
    file, which is required for writes.
    """

    def __init__(
        self,
        read_roots: Iterable[str | os.PathLike[str]] = (),
        write_roots: Iterable[str | os.PathLike[str]] = (),
        *,
        plugin_id: str = "unknown",
        audit: AuditLog | None = None,
    ) -> None:
        self.plugin_id = plugin_id
        self.audit = audit
        self._read_roots = tuple(_canonical(p) for p in read_roots)
        self._write_roots = tuple(_canonical(p) for p in write_roots)

    @property
    def read_roots(self) -> tuple[Path, ...]:
        return self._read_roots

    @property
    def write_roots(self) -> tuple[Path, ...]:
        return self._write_roots

    def _deny(self, action: str, path: str, reason: str) -> PermissionDenied:
        if self.audit is not None:
            self.audit.record(
                self.plugin_id, "denied", f"{action} denied on {path!r}: {reason}",
                action=action, path=path, reason=reason,
            )
        return PermissionDenied(
            f"{action} denied: {reason}", plugin_id=self.plugin_id, path=path
        )

    def resolve_read(self, path: str | os.PathLike[str], *, base: str | os.PathLike[str] | None = None) -> Path:
        """Resolve ``path`` for reading, or raise :class:`PermissionDenied`."""
        candidate = self._resolve(path, base)
        if not self._within(candidate, self._read_roots):
            raise self._deny("read", str(path), "path is outside the granted read roots")
        return candidate

    def resolve_write(
        self,
        path: str | os.PathLike[str],
        *,
        base: str | os.PathLike[str] | None = None,
    ) -> Path:
        """Resolve ``path`` for writing, or raise :class:`PermissionDenied`."""
        candidate = self._resolve(path, base)
        if not self._within(candidate, self._write_roots):
            raise self._deny("write", str(path), "path is outside the granted write roots")
        return candidate

    def _resolve(
        self,
        path: str | os.PathLike[str],
        base: str | os.PathLike[str] | None,
    ) -> Path:
        raw = Path(path)
        if not raw.is_absolute():
            if base is None:
                if not self._read_roots and not self._write_roots:
                    raise SandboxError(
                        "relative path supplied but the guard has no roots to anchor it",
                        path=str(path),
                    )
                anchor = self._write_roots[0] if self._write_roots else self._read_roots[0]
            else:
                anchor = Path(base)
        else:
            anchor = Path("/")

        combined = anchor / raw if not raw.is_absolute() else raw
        # strict=False: the leaf may not exist yet (writes create it).
        resolved = Path(os.path.realpath(combined))
        return resolved

    @staticmethod
    def _within(candidate: Path, roots: Sequence[Path]) -> bool:
        for root in roots:
            try:
                candidate.relative_to(root)
                return True
            except ValueError:
                continue
        return False

    # -- convenience operations -------------------------------------------- #

    def read_bytes(self, path: str | os.PathLike[str], **kwargs: Any) -> bytes:
        keyword = kwargs.pop("base", None)
        target = self.resolve_read(path, base=keyword)
        try:
            with open(target, "rb") as handle:
                return handle.read()
        except OSError as exc:
            raise SandboxError(f"cannot read {target}: {exc}", path=str(target)) from exc

    def read_text(self, path: str | os.PathLike[str], encoding: str = "utf-8", **kwargs: Any) -> str:
        return self.read_bytes(path, **kwargs).decode(encoding)

    def write_bytes(self, path: str | os.PathLike[str], data: bytes, **kwargs: Any) -> Path:
        keyword = kwargs.pop("base", None)
        target = self.resolve_write(path, base=keyword)
        try:
            target.parent.mkdir(parents=True, exist_ok=True)
            # Re-validate after mkdir: a symlinked parent could have appeared.
            if not self._within(Path(os.path.realpath(target.parent)) / target.name, self._write_roots):
                raise self._deny("write", str(path), "parent directory resolves outside write roots")
            with open(target, "wb") as handle:
                handle.write(data)
        except OSError as exc:
            raise SandboxError(f"cannot write {target}: {exc}", path=str(target)) from exc
        return target

    def write_text(self, path: str | os.PathLike[str], text: str, encoding: str = "utf-8", **kwargs: Any) -> Path:
        return self.write_bytes(path, text.encode(encoding), **kwargs)

    def exists(self, path: str | os.PathLike[str], **kwargs: Any) -> bool:
        try:
            return self.resolve_read(path, base=kwargs.get("base")).exists()
        except PermissionDenied:
            return False

    def to_dict(self) -> dict[str, Any]:
        return {
            "pluginId": self.plugin_id,
            "readRoots": [str(p) for p in self._read_roots],
            "writeRoots": [str(p) for p in self._write_roots],
        }


def _canonical(path: str | os.PathLike[str]) -> Path:
    return Path(os.path.realpath(str(path)))


# --------------------------------------------------------------------------- #
# Permission gate
# --------------------------------------------------------------------------- #


class PermissionGate:
    """Decides whether a plugin may use a permission.

    Grants come from two places: the manifest declaration (the plugin *asked*)
    and the user's approval at install time (the user *agreed*). Both are
    required. A permission that is declared but not granted is denied with a
    message that tells the user exactly what to toggle.
    """

    def __init__(
        self,
        manifest: Manifest,
        granted: Iterable[str] | None = None,
        *,
        audit: AuditLog | None = None,
        auto_grant_sensitive: bool = False,
    ) -> None:
        self.manifest = manifest
        self.plugin_id = manifest.id
        self.audit = audit
        declared = set(manifest.permissions)

        if granted is None:
            # Default policy: everything declared is granted except sensitive
            # permissions, which require an explicit user decision. This makes
            # "declare nothing scary" the path of least resistance.
            granted_set = {
                p for p in declared
                if not p.startswith(SENSITIVE_PREFIXES) or auto_grant_sensitive
            }
        else:
            granted_set = {g for g in granted if g in declared}
        self._granted = granted_set

    @property
    def declared(self) -> frozenset[str]:
        return frozenset(self.manifest.permissions)

    @property
    def granted(self) -> frozenset[str]:
        return frozenset(self._granted)

    @property
    def pending_consent(self) -> tuple[str, ...]:
        """Declared sensitive permissions still awaiting user approval."""
        return tuple(
            p for p in self.manifest.permissions
            if p not in self._granted and p.startswith(SENSITIVE_PREFIXES)
        )

    def grant(self, permission: str) -> None:
        if permission not in self.manifest.permissions:
            raise PermissionDenied(
                f"cannot grant undeclared permission {permission!r}",
                plugin_id=self.plugin_id,
                permission=permission,
                hint="the plugin must declare it in btps.json first",
            )
        self._granted.add(permission)

    def revoke(self, permission: str) -> None:
        self._granted.discard(permission)

    def check(self, permission: str, *, context: str = "") -> bool:
        """True when ``permission`` is covered by a grant."""
        if permission in self._granted:
            return True
        if not self.manifest.declares_permission(permission):
            return False
        return any(
            permission_matches(g, permission) for g in self._granted
        )

    def require(self, permission: str, *, context: str = "") -> None:
        """Raise :class:`PermissionDenied` unless ``permission`` is granted."""
        if self.check(permission):
            return
        declared = self.manifest.declares_permission(permission)
        reason = (
            "declared in the manifest but not approved by the user"
            if declared
            else "not declared in the manifest"
        )
        if self.audit is not None:
            self.audit.record(
                self.plugin_id, "denied", f"permission {permission!r} required but {reason}",
                permission=permission, context=context,
            )
        raise PermissionDenied(
            f"permission {permission!r} is not granted ({reason})",
            plugin_id=self.plugin_id,
            permission=permission,
            declared=declared,
            hint=(
                "declare it in btps.json and reinstall, then approve it in the host UI"
                if not declared
                else "approve it in the host's plugin console"
            ),
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "pluginId": self.plugin_id,
            "declared": sorted(self.declared),
            "granted": sorted(self._granted),
            "pendingConsent": list(self.pending_consent),
        }


# --------------------------------------------------------------------------- #
# KV storage
# --------------------------------------------------------------------------- #


class KVStore:
    """A plugin-private JSON key/value store with size limits.

    Storage is a single JSON file under the host's data directory. Writes are
    atomic (temp file + ``os.replace``) so a crash mid-write cannot corrupt the
    store, and the whole file is bounded by ``kv_total_max_bytes``.
    """

    _KEY_RE = re.compile(r"^[A-Za-z0-9_.\-]{1,128}$")

    def __init__(
        self,
        path: str | os.PathLike[str],
        *,
        limits: Limits = DEFAULT_LIMITS,
        plugin_id: str = "unknown",
        audit: AuditLog | None = None,
    ) -> None:
        self.path = Path(path)
        self.limits = limits
        self.plugin_id = plugin_id
        self.audit = audit
        self._lock = threading.RLock()
        self._data: dict[str, Any] = {}
        self._load()

    def _load(self) -> None:
        if not self.path.is_file():
            return
        try:
            raw = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            # A corrupt store is recoverable: start clean rather than crash the
            # host. The previous file is preserved with a .corrupt suffix.
            try:
                self.path.replace(self.path.with_suffix(self.path.suffix + ".corrupt"))
            except OSError:
                pass
            if self.audit is not None:
                self.audit.record(
                    self.plugin_id, "error",
                    f"KV store {self.path.name} was unreadable and has been reset",
                )
            return
        if isinstance(raw, dict):
            self._data = raw

    def _flush(self) -> None:
        payload = json.dumps(self._data, ensure_ascii=False, indent=2).encode("utf-8")
        if len(payload) > self.limits.kv_total_max_bytes:
            if self.audit is not None:
                self.audit.record(
                    self.plugin_id, "limit",
                    f"KV store would exceed {self.limits.kv_total_max_bytes} bytes",
                )
            raise SandboxError(
                f"KV store would exceed its {self.limits.kv_total_max_bytes} byte budget",
                plugin_id=self.plugin_id,
                attempted=len(payload),
            )
        self.path.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.path.with_suffix(self.path.suffix + ".tmp")
        temporary.write_bytes(payload)
        os.replace(temporary, self.path)

    def _validate_key(self, key: str) -> str:
        if not isinstance(key, str) or not self._KEY_RE.match(key):
            raise SandboxError(
                "invalid KV key",
                key=repr(key),
                hint="keys must be 1–128 chars of A-Z a-z 0-9 _ . -",
            )
        return key

    def get(self, key: str, default: Any = None) -> Any:
        with self._lock:
            return self._data.get(self._validate_key(key), default)

    def set(self, key: str, value: Any) -> None:
        key = self._validate_key(key)
        encoded = json.dumps(value, ensure_ascii=False).encode("utf-8")
        if len(encoded) > self.limits.kv_value_max_bytes:
            if self.audit is not None:
                self.audit.record(
                    self.plugin_id, "limit",
                    f"KV value for {key!r} is {len(encoded)} bytes",
                    key=key, size=len(encoded),
                )
            raise SandboxError(
                f"KV value for {key!r} exceeds the {self.limits.kv_value_max_bytes} byte limit",
                plugin_id=self.plugin_id,
                key=key,
                size=len(encoded),
            )
        with self._lock:
            self._data[key] = value
            self._flush()

    def delete(self, key: str) -> bool:
        with self._lock:
            existed = self._data.pop(self._validate_key(key), None) is not None
            if existed:
                self._flush()
            return existed

    def keys(self, prefix: str = "") -> list[str]:
        with self._lock:
            return sorted(k for k in self._data if k.startswith(prefix))

    def clear(self) -> None:
        with self._lock:
            self._data.clear()
            self._flush()

    def as_dict(self) -> dict[str, Any]:
        with self._lock:
            return dict(self._data)

    def __contains__(self, key: str) -> bool:
        return key in self._data

    def __len__(self) -> int:
        return len(self._data)


# --------------------------------------------------------------------------- #
# Timeout helper
# --------------------------------------------------------------------------- #


def call_with_timeout(
    function: Callable[[], Any],
    timeout: float,
    *,
    plugin_id: str = "unknown",
    hook: str = "",
    audit: AuditLog | None = None,
) -> Any:
    """Run ``function`` with a wall-clock timeout.

    Uses a daemon thread rather than ``signal.alarm`` because signals only work
    on the main thread of the main interpreter — and hooks frequently run on a
    worker thread.

    The timeout abandons the thread: the callee keeps running until it returns.
    This is a deliberate trade-off. A hard kill is impossible in-process, and
    pretending otherwise would be dishonest; the audit log records the overrun
    so hosts can disable a misbehaving plugin.
    """
    if timeout <= 0:
        return function()

    result: list[Any] = []
    failure: list[BaseException] = []
    done = threading.Event()

    def runner() -> None:
        try:
            result.append(function())
        except BaseException as exc:  # noqa: BLE001 - re-raised in caller
            failure.append(exc)
        finally:
            done.set()

    thread = threading.Thread(target=runner, daemon=True, name=f"btps-hook-{plugin_id}")
    thread.start()

    if not done.wait(timeout):
        if audit is not None:
            audit.record(
                plugin_id, "timeout",
                f"hook {hook or '<anonymous>'} exceeded {timeout}s",
                hook=hook, timeout=timeout,
            )
        raise SandboxError(
            f"hook {hook or '<anonymous>'} exceeded the {timeout}s time budget",
            plugin_id=plugin_id,
            hook=hook,
            timeout=timeout,
        )

    if failure:
        raise failure[0]
    return result[0] if result else None


# --------------------------------------------------------------------------- #
# Composite sandbox
# --------------------------------------------------------------------------- #


class Sandbox:
    """Per-plugin bundle of guard, gate, storage, and limits.

    This is the object handed to ``btps.api.ctx`` so plugin code has a single,
    obvious entry point for every privileged operation.
    """

    def __init__(
        self,
        manifest: Manifest,
        *,
        package_root: str | os.PathLike[str],
        data_root: str | os.PathLike[str],
        granted_permissions: Iterable[str] | None = None,
        limits: Limits = DEFAULT_LIMITS,
        audit: AuditLog | None = None,
    ) -> None:
        self.manifest = manifest
        self.plugin_id = manifest.id
        self.limits = limits
        self.audit = audit if audit is not None else AuditLog()

        package = _canonical(package_root)
        data = _canonical(data_root)
        data.mkdir(parents=True, exist_ok=True)

        self.package_root = package
        self.data_root = data
        self.cache_root = data / "cache"
        self.cache_root.mkdir(parents=True, exist_ok=True)

        # Read: the package itself (minus write access) plus the plugin's data.
        # Write: only the plugin's own data directory and its cache.
        self.paths = PathGuard(
            read_roots=[package, data],
            write_roots=[data],
            plugin_id=self.plugin_id,
            audit=self.audit,
        )
        self.permissions = PermissionGate(
            manifest,
            granted_permissions,
            audit=self.audit,
        )
        self.storage = KVStore(
            data / "storage.json",
            limits=limits,
            plugin_id=self.plugin_id,
            audit=self.audit,
        )
        self._depth = 0

    # -- helpers ------------------------------------------------------------ #

    @contextmanager
    def depth(self, label: str) -> Iterator[None]:
        """Track nesting so runaway recursion fails instead of crashing."""
        self._depth += 1
        try:
            if self._depth > self.limits.max_recursion_depth:
                raise SandboxError(
                    f"maximum recursion depth ({self.limits.max_recursion_depth}) exceeded",
                    plugin_id=self.plugin_id,
                    label=label,
                )
            yield
        finally:
            self._depth -= 1

    def read_asset(self, relative_path: str, *, binary: bool = False) -> Any:
        """Read a file from the package's ``assets/`` directory."""
        self.permissions.require("fs.read", context="read_asset")
        target = self.package_root / "assets" / relative_path
        data = self.paths.read_bytes(target)
        return data if binary else data.decode("utf-8")

    def require(self, permission: str, *, context: str = "") -> None:
        self.permissions.require(permission, context=context)

    def check_permission(self, permission: str, *, context: str = "") -> bool:
        return self.permissions.check(permission, context=context)

    def record(self, kind: str, detail: str, **context: Any) -> None:
        self.audit.record(self.plugin_id, kind, detail, **context)

    def resolve_package_path(self, relative_path: str) -> Path:
        """Resolve a path *inside the package* (read-only, always allowed)."""
        return self.paths.resolve_read(self.package_root / relative_path)

    def envelope(self) -> dict[str, Any]:
        """Machine-readable summary for the host console."""
        return {
            "pluginId": self.plugin_id,
            "packageRoot": str(self.package_root),
            "dataRoot": str(self.data_root),
            "limits": self.limits.to_dict(),
            "permissions": self.permissions.to_dict(),
            "paths": self.paths.to_dict(),
            "storageKeys": len(self.storage),
        }

    def __repr__(self) -> str:  # pragma: no cover - debug aid
        return f"<Sandbox {self.plugin_id} perms={len(self.permissions.granted)}>"
