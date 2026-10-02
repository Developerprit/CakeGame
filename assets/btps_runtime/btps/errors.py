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

"""BrickTile Plugin System (BTPS) — exception hierarchy.

A single root exception (``BTPSError``) lets hosts wrap every BTPS failure in
one ``except`` clause while still allowing fine-grained handling.
"""

from __future__ import annotations

from typing import Any


class BTPSError(Exception):
    """Root of every error raised by BTPS."""

    code: str = "BTPS_ERROR"

    def __init__(self, message: str, **details: Any) -> None:
        super().__init__(message)
        self.message = message
        self.details = details

    def to_dict(self) -> dict[str, Any]:
        return {"code": self.code, "message": self.message, "details": self.details}

    def __str__(self) -> str:  # pragma: no cover - trivial
        if not self.details:
            return self.message
        rendered = ", ".join(f"{k}={v!r}" for k, v in sorted(self.details.items()))
        return f"{self.message} ({rendered})"


# --------------------------------------------------------------------------- #
# Format layer (L0)
# --------------------------------------------------------------------------- #


class PackageError(BTPSError):
    """Container-level failure: unreadable, corrupt, or unsupported archive."""

    code = "BTPS_PACKAGE_ERROR"


class IntegrityError(PackageError):
    """Digest mismatch or truncated payload."""

    code = "BTPS_INTEGRITY_ERROR"


class SecurityViolation(PackageError):
    """The archive tried to escape its sandbox (traversal, symlink, bomb)."""

    code = "BTPS_SECURITY_VIOLATION"


# --------------------------------------------------------------------------- #
# Resolution layer (L1)
# --------------------------------------------------------------------------- #


class ManifestError(BTPSError):
    """``btps.json`` is missing, malformed, or semantically invalid."""

    code = "BTPS_MANIFEST_ERROR"

    def __init__(self, message: str, issues: list[Any] | None = None, **details: Any) -> None:
        super().__init__(message, **details)
        self.issues = issues or []


class VersionError(BTPSError):
    """Bad semver string or unparseable constraint."""

    code = "BTPS_VERSION_ERROR"


class DependencyError(BTPSError):
    """Dependencies cannot be satisfied."""

    code = "BTPS_DEPENDENCY_ERROR"


class ConflictError(DependencyError):
    """Two or more constraints on the same package have an empty intersection."""

    code = "BTPS_CONFLICT_ERROR"

    def __init__(
        self,
        message: str,
        package_id: str = "",
        constraints: list[Any] | None = None,
        paths: list[Any] | None = None,
        **details: Any,
    ) -> None:
        super().__init__(message, **details)
        self.package_id = package_id
        self.constraints = constraints or []
        self.paths = paths or []


class CycleError(DependencyError):
    """Dependency graph contains a cycle."""

    code = "BTPS_CYCLE_ERROR"


# --------------------------------------------------------------------------- #
# Runtime layer (L2)
# --------------------------------------------------------------------------- #


class LifecycleError(BTPSError):
    """Illegal state transition."""

    code = "BTPS_LIFECYCLE_ERROR"


class PermissionDenied(BTPSError):
    """The plugin called something it did not declare (or the user denied)."""

    code = "BTPS_PERMISSION_DENIED"


class SandboxError(BTPSError):
    """Resource limit exceeded or path escaped the fence."""

    code = "BTPS_SANDBOX_ERROR"


class HookError(BTPSError):
    """A hook handler failed."""

    code = "BTPS_HOOK_ERROR"

    def __init__(self, message: str, hook: str = "", plugin_id: str = "", **details: Any) -> None:
        super().__init__(message, **details)
        self.hook = hook
        self.plugin_id = plugin_id


# --------------------------------------------------------------------------- #
# Host integration layer (L3)
# --------------------------------------------------------------------------- #


class TransportError(BTPSError):
    """Register center / injector transport failure."""

    code = "BTPS_TRANSPORT_ERROR"


class AsyncPending(BTPSError):
    """Placeholder for operations that require a running event loop."""

    code = "BTPS_ASYNC_PENDING"


__all__ = [
    "BTPSError",
    "PackageError",
    "IntegrityError",
    "SecurityViolation",
    "ManifestError",
    "VersionError",
    "DependencyError",
    "ConflictError",
    "CycleError",
    "LifecycleError",
    "PermissionDenied",
    "SandboxError",
    "HookError",
    "TransportError",
    "AsyncPending",
]
