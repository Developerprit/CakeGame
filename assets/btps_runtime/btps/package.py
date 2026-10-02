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

"""``.btp`` container handling: pack, verify, extract, and audit.

The container is a ZIP archive (or optionally 7z) with a mandated layout. This
module is the only place that touches archive bytes; everything above it deals
in :class:`Manifest` objects and :class:`PackageInfo` records.

Security posture
----------------
Archives are hostile input. Every member is audited *before* a single byte is
written to disk, and each write re-validates its destination. The audit rejects:

* absolute paths and drive letters
* ``..`` traversal in any segment
* symlink / hardlink members
* uncompressed size beyond :data:`MAX_UNCOMPRESSED_TOTAL`
* per-member size beyond :data:`MAX_MEMBER_SIZE`
* compression ratio beyond :data:`MAX_COMPRESSION_RATIO` (zip-bomb defence)
* NUL bytes and control characters in names
* case-collision between member names (breaks on case-insensitive filesystems)

Reproducible builds
-------------------
:func:`pack` writes fixed timestamps and sorts members, so packing the same
source twice yields byte-identical archives. That makes digests meaningful and
lets CI assert "the published artifact came from this commit".
"""

from __future__ import annotations

import hashlib
import io
import json
import os
import shutil
import stat
import time
import zipfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable, Iterator, Mapping, Sequence

from .errors import (
    IntegrityError,
    PackageError,
    SecurityViolation,
)
from .manifest import (
    MANIFEST_FILENAME,
    Manifest,
    ValidationReport,
    validate_entry_exists,
)

__all__ = [
    "EXTENSION",
    "MANIFEST_FILENAME",
    "SIGNATURE_FILENAME",
    "MAX_MEMBER_SIZE",
    "MAX_UNCOMPRESSED_TOTAL",
    "MAX_COMPRESSION_RATIO",
    "MAX_MEMBER_COUNT",
    "ContainerKind",
    "ArchiveMember",
    "AuditReport",
    "PackageInfo",
    "BtpArchive",
    "open_btp",
    "sniff_container",
    "pack",
    "verify",
    "extract",
    "compute_digest",
    "audit_members",
    "normalise_member_name",
    "is_safe_member_name",
]

EXTENSION = ".btp"
SIGNATURE_FILENAME = "btps.sig"

#: Hard limits applied during audit. Callers may raise them for their own
#: deployments, but the defaults are intentionally conservative.
MAX_MEMBER_SIZE = 64 * 1024 * 1024  # 64 MiB
MAX_UNCOMPRESSED_TOTAL = 512 * 1024 * 1024  # 512 MiB
MAX_COMPRESSION_RATIO = 200.0
MAX_MEMBER_COUNT = 10_000

#: Directories that are part of the format contract.
RESERVED_DIRS = ("lib", "assets", "locales", "docs")

ZIP_MAGIC = b"PK\x03\x04"
ZIP_MAGIC_EMPTY = b"PK\x05\x06"
ZIP_MAGIC_SPANNED = b"PK\x07\x08"
SEVENZ_MAGIC = b"7z\xbc\xaf\x27\x1c"

#: Fixed DOS timestamp for reproducible archives (1980-01-01 00:00:00).
_FIXED_DATE_TIME = (1980, 1, 1, 0, 0, 0)


class ContainerKind(str):
    """Container format identifiers."""

    ZIP = "zip"
    SEVENZ = "7z"


# --------------------------------------------------------------------------- #
# Name handling
# --------------------------------------------------------------------------- #


def normalise_member_name(name: str) -> str:
    """Canonicalise an archive member name.

    Backslashes become forward slashes, a leading ``./`` is dropped, and
    trailing slashes on directories are removed. The result never starts with
    ``/`` and never contains an empty segment.
    """
    if not isinstance(name, str):
        raise PackageError("archive member name must be a string", name=repr(name))
    if "\x00" in name:
        raise SecurityViolation("archive member name contains a NUL byte", name=repr(name))

    candidate = name.replace("\\", "/")
    if candidate.startswith("/"):
        candidate = candidate[1:]
    while candidate.startswith("./"):
        candidate = candidate[2:]
    if candidate.endswith("/"):
        candidate = candidate.rstrip("/")
    segments = [seg for seg in candidate.split("/") if seg not in ("", ".")]
    return "/".join(segments)


def is_safe_member_name(name: str) -> bool:
    """True when ``name`` is a relative path that cannot escape its root."""
    if not name or name.startswith("/") or name.startswith("\\"):
        return False
    if "\x00" in name:
        return False
    if any(ch in name for ch in ("\r", "\n", "\t")):
        return False
    # Reject Windows drive letters and UNC prefixes.
    if len(name) >= 2 and name[1] == ":":
        return False
    if name.startswith("//"):
        return False
    segments = name.replace("\\", "/").split("/")
    return ".." not in segments and not any(seg == "" for seg in segments[:-1])


# --------------------------------------------------------------------------- #
# Records
# --------------------------------------------------------------------------- #


@dataclass(frozen=True)
class ArchiveMember:
    """One entry inside a ``.btp`` archive."""

    name: str
    size: int
    compressed_size: int
    is_dir: bool = False
    crc: int = 0

    @property
    def ratio(self) -> float:
        if self.compressed_size <= 0:
            return float(self.size) if self.size else 0.0
        return self.size / self.compressed_size

    def to_dict(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "size": self.size,
            "compressedSize": self.compressed_size,
            "isDir": self.is_dir,
            "crc32": f"{self.crc:08x}",
        }


@dataclass
class AuditReport:
    """Findings from :func:`audit_members`."""

    violations: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    total_uncompressed: int = 0
    member_count: int = 0

    @property
    def ok(self) -> bool:
        return not self.violations

    def raise_if_unsafe(self) -> None:
        if self.violations:
            summary = "; ".join(self.violations[:5])
            if len(self.violations) > 5:
                summary += f"; … and {len(self.violations) - 5} more"
            raise SecurityViolation(
                f"archive failed security audit: {summary}",
                violations=list(self.violations),
            )

    def to_dict(self) -> dict[str, Any]:
        return {
            "ok": self.ok,
            "memberCount": self.member_count,
            "totalUncompressed": self.total_uncompressed,
            "violations": list(self.violations),
            "warnings": list(self.warnings),
        }


@dataclass
class PackageInfo:
    """Everything learned about a ``.btp`` file without extracting it."""

    path: str
    container: str
    manifest: Manifest | None
    members: tuple[ArchiveMember, ...]
    digest: str
    size_bytes: int
    audit: AuditReport
    report: ValidationReport

    @property
    def id(self) -> str:
        return self.manifest.id if self.manifest else ""

    @property
    def version(self) -> str:
        return self.manifest.version_string if self.manifest else ""

    @property
    def ok(self) -> bool:
        return self.manifest is not None and self.audit.ok and self.report.ok

    def to_dict(self) -> dict[str, Any]:
        return {
            "path": self.path,
            "container": self.container,
            "sizeBytes": self.size_bytes,
            "digest": self.digest,
            "id": self.id,
            "version": self.version,
            "ok": self.ok,
            "manifest": self.manifest.to_dict() if self.manifest else None,
            "audit": self.audit.to_dict(),
            "validation": self.report.to_dict(),
            "members": [m.to_dict() for m in self.members],
        }


# --------------------------------------------------------------------------- #
# Container sniffing
# --------------------------------------------------------------------------- #


def sniff_container(path: str | os.PathLike[str] | bytes | bytearray) -> str:
    """Detect the container format from magic bytes.

    Extension is deliberately ignored: ``foo.btp`` containing a 7z stream is
    handled correctly, and a mislabelled ZIP is still readable.
    """
    if isinstance(path, (bytes, bytearray)):
        head = bytes(path[:8])
    else:
        try:
            with open(path, "rb") as handle:
                head = handle.read(8)
        except OSError as exc:
            raise PackageError(f"cannot read {path!s}: {exc}", path=str(path)) from exc

    if head[:4] in (ZIP_MAGIC, ZIP_MAGIC_EMPTY, ZIP_MAGIC_SPANNED) or head[:2] == b"PK":
        return ContainerKind.ZIP
    if head.startswith(SEVENZ_MAGIC):
        return ContainerKind.SEVENZ
    raise PackageError(
        "unrecognised container format",
        path=str(path),
        head=head.hex(),
        hint="expected a ZIP or 7z stream",
    )


# --------------------------------------------------------------------------- #
# Archive
# --------------------------------------------------------------------------- #


class BtpArchive:
    """Read access to a ``.btp`` file.

    Usable as a context manager. All reads are lazy; the archive handle stays
    open until :meth:`close`.
    """

    def __init__(self, path: str | os.PathLike[str]) -> None:
        self.path = str(path)
        self.container = sniff_container(self.path)
        self._zip: zipfile.ZipFile | None = None
        self._sevenz = None
        self._names: list[str] = []
        self._members: dict[str, ArchiveMember] = {}
        self._open()

    # -- lifecycle ---------------------------------------------------------- #

    def _open(self) -> None:
        if self.container == ContainerKind.ZIP:
            try:
                self._zip = zipfile.ZipFile(self.path, "r")
            except zipfile.BadZipFile as exc:
                raise PackageError(
                    f"corrupt ZIP container: {exc}", path=self.path
                ) from exc
            for info in self._zip.infolist():
                name = normalise_member_name(info.filename)
                if not name:
                    continue
                self._names.append(name)
                self._members[name] = ArchiveMember(
                    name=name,
                    size=info.file_size,
                    compressed_size=info.compress_size,
                    is_dir=info.is_dir(),
                    crc=info.CRC,
                )
        else:
            self._open_sevenz()

    def _open_sevenz(self) -> None:
        """Open a 7z container.

        7z support requires the optional ``py7zr`` dependency. Rather than
        silently degrading, we raise a clear, actionable error.
        """
        try:
            import py7zr  # type: ignore[import-not-found]
        except ImportError as exc:  # pragma: no cover - depends on environment
            raise PackageError(
                "7z containers require the optional 'py7zr' package",
                path=self.path,
                hint="install it with: pip install py7zr — or repack as .btp (ZIP)",
            ) from exc

        try:
            self._sevenz = py7zr.SevenZipFile(self.path, mode="r")
        except Exception as exc:  # pragma: no cover - depends on archive
            raise PackageError(f"corrupt 7z container: {exc}", path=self.path) from exc

        for info in self._sevenz.list():
            name = normalise_member_name(info.filename)
            if not name:
                continue
            self._names.append(name)
            self._members[name] = ArchiveMember(
                name=name,
                size=getattr(info, "uncompressed", 0) or 0,
                compressed_size=getattr(info, "compressed", 0) or 0,
                is_dir=bool(getattr(info, "is_directory", False)),
                crc=0,
            )

    def close(self) -> None:
        if self._zip is not None:
            self._zip.close()
            self._zip = None
        if self._sevenz is not None:
            try:
                self._sevenz.close()
            finally:
                self._sevenz = None

    def __enter__(self) -> "BtpArchive":
        return self

    def __exit__(self, *exc_info: object) -> None:
        self.close()

    # -- inspection --------------------------------------------------------- #

    @property
    def names(self) -> tuple[str, ...]:
        """All member names, in archive order, normalised."""
        return tuple(self._names)

    @property
    def members(self) -> tuple[ArchiveMember, ...]:
        return tuple(self._members[name] for name in self._names)

    def has(self, name: str) -> bool:
        return normalise_member_name(name) in self._members

    def size_of(self, name: str) -> int:
        member = self._members.get(normalise_member_name(name))
        return member.size if member else 0

    def read(self, name: str) -> bytes:
        """Read one member into memory, enforcing the per-member size cap."""
        key = normalise_member_name(name)
        if key not in self._members:
            raise PackageError(f"member not found: {name!r}", name=name, path=self.path)

        declared = self._members[key].size
        if declared > MAX_MEMBER_SIZE:
            raise SecurityViolation(
                f"member {key!r} declares {declared} bytes, above the "
                f"{MAX_MEMBER_SIZE} byte limit",
                name=key,
            )

        if self._zip is not None:
            with self._zip.open(key, "r") as handle:
                data = handle.read(MAX_MEMBER_SIZE + 1)
        else:  # pragma: no cover - exercised only with py7zr installed
            buffer = io.BytesIO()
            self._sevenz.extract(targets=[key], factory=lambda member: buffer)  # type: ignore[union-attr]
            data = buffer.getvalue()

        if len(data) > MAX_MEMBER_SIZE:
            raise SecurityViolation(
                f"member {key!r} exceeded the {MAX_MEMBER_SIZE} byte limit while reading",
                name=key,
            )
        if declared and len(data) != declared:
            raise IntegrityError(
                f"member {key!r} is truncated: declared {declared}, read {len(data)}",
                name=key,
                declared=declared,
                actual=len(data),
            )
        return data

    def read_json(self, name: str) -> Any:
        raw = self.read(name)
        try:
            return json.loads(raw.decode("utf-8-sig"))
        except UnicodeDecodeError as exc:
            raise PackageError(f"member {name!r} is not valid UTF-8: {exc}", name=name) from exc
        except json.JSONDecodeError as exc:
            raise PackageError(
                f"member {name!r} is not valid JSON: {exc.msg}",
                name=name,
                line=exc.lineno,
                column=exc.colno,
            ) from exc

    def iter_chunks(self, name: str, chunk_size: int = 64 * 1024) -> Iterator[bytes]:
        """Stream a member in bounded chunks (for large assets)."""
        key = normalise_member_name(name)
        if key not in self._members:
            raise PackageError(f"member not found: {name!r}", name=name, path=self.path)
        if self._zip is None:  # pragma: no cover - 7z path
            yield self.read(key)
            return
        written = 0
        with self._zip.open(key, "r") as handle:
            while True:
                chunk = handle.read(chunk_size)
                if not chunk:
                    break
                written += len(chunk)
                if written > MAX_MEMBER_SIZE:
                    raise SecurityViolation(
                        f"member {key!r} exceeded the {MAX_MEMBER_SIZE} byte limit while streaming",
                        name=key,
                    )
                yield chunk


def open_btp(path: str | os.PathLike[str]) -> BtpArchive:
    """Open a ``.btp`` file. Prefer the context-manager form."""
    return BtpArchive(path)


# --------------------------------------------------------------------------- #
# Audit
# --------------------------------------------------------------------------- #


def audit_members(
    members: Sequence[ArchiveMember],
    *,
    max_member_size: int = MAX_MEMBER_SIZE,
    max_total: int = MAX_UNCOMPRESSED_TOTAL,
    max_ratio: float = MAX_COMPRESSION_RATIO,
    max_count: int = MAX_MEMBER_COUNT,
) -> AuditReport:
    """Security-audit archive members without extracting anything."""
    report = AuditReport(member_count=len(members))
    total = 0
    seen_lower: dict[str, str] = {}

    if len(members) > max_count:
        report.violations.append(
            f"archive has {len(members)} members, above the limit of {max_count}"
        )

    for member in members:
        name = member.name

        if not is_safe_member_name(name):
            report.violations.append(f"unsafe member path: {name!r}")
            continue

        if not member.is_dir:
            total += member.size

            if member.size > max_member_size:
                report.violations.append(
                    f"member {name!r} is {member.size} bytes, above the "
                    f"{max_member_size} byte limit"
                )
            if member.compressed_size > 0 and member.ratio > max_ratio:
                report.violations.append(
                    f"member {name!r} has compression ratio {member.ratio:.1f}:1, "
                    f"above the {max_ratio}:1 limit (possible zip bomb)"
                )
            if member.size > 0 and member.compressed_size == 0:
                report.warnings.append(
                    f"member {name!r} reports data but zero compressed size"
                )

        lowered = name.lower()
        if lowered in seen_lower and seen_lower[lowered] != name:
            report.violations.append(
                f"members {seen_lower[lowered]!r} and {name!r} collide on "
                "case-insensitive filesystems"
            )
        seen_lower[lowered] = name

    report.total_uncompressed = total
    if total > max_total:
        report.violations.append(
            f"total uncompressed size is {total} bytes, above the "
            f"{max_total} byte limit"
        )
    return report


def _audit_zip_directory(path: str) -> AuditReport:
    """Audit a ZIP on disk including symlink detection via external attributes."""
    report = AuditReport()
    # The magic bytes said "ZIP" but the central directory may still be absent
    # (a truncated download, a file that merely *starts* with PK\\x03\\x04).
    # Leaking ``zipfile.BadZipFile`` would escape the BTPS error hierarchy, so
    # callers could never handle it with a single ``except BTPSError``.
    try:
        archive = zipfile.ZipFile(path, "r")
    except (zipfile.BadZipFile, OSError, EOFError) as exc:
        raise PackageError(
            f"not a readable ZIP container: {exc}",
            details={"path": str(path)},
        ) from exc
    with archive:
        members: list[ArchiveMember] = []
        for info in archive.infolist():
            name = normalise_member_name(info.filename)
            if not name:
                continue
            members.append(
                ArchiveMember(
                    name=name,
                    size=info.file_size,
                    compressed_size=info.compress_size,
                    is_dir=info.is_dir(),
                    crc=info.CRC,
                )
            )
            mode = info.external_attr >> 16
            if mode and stat.S_ISLNK(mode):
                report.violations.append(f"symlink member is not allowed: {name!r}")
            if info.flag_bits & 0x1:
                report.warnings.append(
                    f"member {name!r} is encrypted; BTPS cannot verify encrypted payloads"
                )
    inner = audit_members(members)
    report.violations.extend(inner.violations)
    report.warnings.extend(inner.warnings)
    report.total_uncompressed = inner.total_uncompressed
    report.member_count = inner.member_count
    return report


# --------------------------------------------------------------------------- #
# Digest
# --------------------------------------------------------------------------- #


def compute_digest(path: str | os.PathLike[str], algorithm: str = "sha256") -> str:
    """Stream a file through a hash and return ``"<algo>:<hex>"``."""
    try:
        hasher = hashlib.new(algorithm)
    except ValueError as exc:
        raise PackageError(f"unknown hash algorithm: {algorithm!r}") from exc

    try:
        with open(path, "rb") as handle:
            for block in iter(lambda: handle.read(1024 * 1024), b""):
                hasher.update(block)
    except OSError as exc:
        raise PackageError(f"cannot hash {path!s}: {exc}", path=str(path)) from exc
    return f"{algorithm}:{hasher.hexdigest()}"


def verify_digest(path: str | os.PathLike[str], expected: str) -> bool:
    """Compare a file's digest with an ``"<algo>:<hex>"`` string."""
    if ":" not in expected:
        raise IntegrityError(
            f"malformed digest {expected!r}", hint="expected the form 'sha256:<hex>'"
        )
    algorithm, _, _ = expected.partition(":")
    return compute_digest(path, algorithm) == expected


# --------------------------------------------------------------------------- #
# Pack
# --------------------------------------------------------------------------- #


def pack(
    source: str | os.PathLike[str],
    output: str | os.PathLike[str] | None = None,
    *,
    compresslevel: int = 9,
    overwrite: bool = False,
    extra_files: Mapping[str, bytes] | None = None,
    deterministic: bool = True,
) -> PackageInfo:
    """Build a ``.btp`` archive from a source directory.

    The manifest is validated first; an invalid manifest aborts packing so that
    an unusable package can never be published.

    Returns a :class:`PackageInfo` describing the produced archive.
    """
    src = Path(source)
    if not src.is_dir():
        raise PackageError(f"source must be a directory: {src}", path=str(src))

    manifest_path = src / MANIFEST_FILENAME
    if not manifest_path.is_file():
        raise PackageError(
            f"{MANIFEST_FILENAME} not found in {src}",
            path=str(src),
            hint="every .btp package requires a btps.json at its root",
        )

    try:
        manifest_text = manifest_path.read_text(encoding="utf-8-sig")
    except OSError as exc:
        raise PackageError(f"cannot read {manifest_path}: {exc}") from exc

    report = ValidationReport()
    manifest = Manifest.from_json(
        manifest_text, source=str(manifest_path), strict=False, report=report
    )

    # Collect the file list up front so entry-existence can be checked.
    collected: list[tuple[str, Path]] = []
    for root, dirs, files in os.walk(src):
        dirs[:] = sorted(
            d for d in dirs if not d.startswith(".") and d != "__pycache__"
        )
        for filename in sorted(files):
            if filename.endswith((".pyc", ".pyo")):
                continue
            absolute = Path(root) / filename
            relative = absolute.relative_to(src).as_posix()
            if not is_safe_member_name(relative):
                report.warn(
                    "files", f"skipping unsafe path {relative!r}"
                )
                continue
            collected.append((relative, absolute))

    validate_entry_exists(manifest, [name for name, _ in collected], report)

    extra_payloads: dict[str, bytes] = dict(extra_files or {})
    for name in extra_payloads:
        if not is_safe_member_name(normalise_member_name(name)):
            raise SecurityViolation(f"extra file path is unsafe: {name!r}", name=name)

    report.raise_if_invalid()
    for issue in report.warnings:
        _ = issue  # surfaced through PackageInfo.report

    if output is None:
        output = Path.cwd() / f"{manifest.slug}-{manifest.version}.btp"
    out_path = Path(output)
    if out_path.exists() and not overwrite:
        raise PackageError(
            f"output already exists: {out_path}",
            path=str(out_path),
            hint="pass overwrite=True to replace it",
        )
    out_path.parent.mkdir(parents=True, exist_ok=True)

    # Member order: manifest first (streaming-friendly), then lexicographic.
    ordered: list[tuple[str, bytes | Path]] = [(MANIFEST_FILENAME, manifest_text.encode("utf-8"))]
    for name, absolute in sorted(collected):
        if name == MANIFEST_FILENAME:
            continue
        ordered.append((name, absolute))
    for name in sorted(extra_payloads):
        ordered.append((normalise_member_name(name), extra_payloads[name]))

    try:
        with zipfile.ZipFile(
            out_path,
            "w",
            compression=zipfile.ZIP_DEFLATED,
            compresslevel=compresslevel,
            allowZip64=True,
        ) as archive:
            for name, payload in ordered:
                info = zipfile.ZipInfo(filename=name)
                info.compress_type = zipfile.ZIP_DEFLATED
                if deterministic:
                    # Fixed timestamp → byte-identical archives across builds.
                    info.date_time = _FIXED_DATE_TIME
                else:
                    info.date_time = time.localtime()[:6]
                info.external_attr = 0o644 << 16
                if isinstance(payload, Path):
                    with open(payload, "rb") as handle:
                        data = handle.read()
                else:
                    data = payload
                archive.writestr(info, data)
    except OSError as exc:
        raise PackageError(f"cannot write {out_path}: {exc}", path=str(out_path)) from exc

    digest = compute_digest(out_path)
    # Write the sidecar signature so consumers can detect tampering without
    # trusting the archive's internal integrity checks.
    try:
        (out_path.parent / f"{out_path.name}.sig").write_text(
            json.dumps({"digest": digest, "id": manifest.id, "version": manifest.version_string}, indent=2),
            encoding="utf-8",
        )
    except OSError:
        # A missing sidecar is a warning, never a failure: the archive is valid.
        pass

    return inspect(out_path)


# --------------------------------------------------------------------------- #
# Verify / inspect
# --------------------------------------------------------------------------- #


def inspect(
    path: str | os.PathLike[str],
    *,
    extra_hooks: Iterable[str] = (),
) -> PackageInfo:
    """Open a ``.btp`` and gather everything about it without extracting."""
    target = Path(path)
    if not target.is_file():
        raise PackageError(f"package not found: {target}", path=str(target))

    container = sniff_container(target)
    audit = _audit_zip_directory(str(target)) if container == ContainerKind.ZIP else AuditReport()

    members: tuple[ArchiveMember, ...] = ()
    manifest: Manifest | None = None
    report = ValidationReport()

    archive = BtpArchive(target)
    try:
        members = archive.members
        if container == ContainerKind.SEVENZ:
            audit = audit_members(members)

        if not archive.has(MANIFEST_FILENAME):
            report.error(
                MANIFEST_FILENAME,
                f"{MANIFEST_FILENAME} is missing from the package root",
                hint="every .btp package must contain a btps.json at its root",
            )
        else:
            raw = archive.read_json(MANIFEST_FILENAME)
            manifest = Manifest.parse(
                raw,
                source=str(target),
                strict=False,
                report=report,
                extra_hooks=extra_hooks,
            )
            validate_entry_exists(manifest, archive.names, report)

            # Verify the sidecar digest when the packer left one behind.
            signature_path = target.parent / f"{target.name}.sig"
            if signature_path.is_file():
                try:
                    recorded = json.loads(signature_path.read_text(encoding="utf-8"))
                except (OSError, json.JSONDecodeError):
                    report.warn(SIGNATURE_FILENAME, "sidecar signature is unreadable")
                else:
                    expected = str(recorded.get("digest", ""))
                    if expected and compute_digest(target) != expected:
                        report.error(
                            SIGNATURE_FILENAME,
                            "package digest does not match the recorded signature",
                            hint="the file changed after it was packed",
                        )
    finally:
        archive.close()

    audit.raise_if_unsafe()

    return PackageInfo(
        path=str(target),
        container=container,
        manifest=manifest,
        members=members,
        digest=compute_digest(target),
        size_bytes=target.stat().st_size,
        audit=audit,
        report=report,
    )


def verify(path: str | os.PathLike[str]) -> PackageInfo:
    """Validate a ``.btp`` end to end.

    Raises :class:`~btps.errors.SecurityViolation` for hostile archives and
    :class:`~btps.errors.ManifestError` for invalid manifests. Returns the full
    :class:`PackageInfo` on success so callers can act on the findings.
    """
    info = inspect(path)
    info.report.raise_if_invalid()
    return info


# --------------------------------------------------------------------------- #
# Extract
# --------------------------------------------------------------------------- #


def extract(
    source: str | os.PathLike[str],
    destination: str | os.PathLike[str],
    *,
    overwrite: bool = False,
    verify_manifest: bool = True,
) -> Manifest | None:
    """Extract a ``.btp`` into ``destination``.

    The archive is fully audited before the first write, so a rejected package
    never leaves partial files behind. Each destination path is re-validated at
    write time to close the TOCTOU window between audit and extraction.
    """
    info = inspect(source)
    if verify_manifest:
        info.report.raise_if_invalid()

    dest_root = Path(destination).resolve()
    dest_root.mkdir(parents=True, exist_ok=True)

    archive = BtpArchive(source)
    try:
        for member in archive.members:
            if member.is_dir:
                continue
            target = _resolve_inside(dest_root, member.name)
            if target.exists() and not overwrite:
                raise PackageError(
                    f"refusing to overwrite existing file: {target}",
                    path=str(target),
                    hint="pass overwrite=True to replace it",
                )
            target.parent.mkdir(parents=True, exist_ok=True)
            with open(target, "wb") as handle:
                for chunk in archive.iter_chunks(member.name):
                    handle.write(chunk)
    finally:
        archive.close()

    return info.manifest


def _resolve_inside(root: Path, member_name: str) -> Path:
    """Resolve ``member_name`` under ``root``, rejecting any escape."""
    if not is_safe_member_name(member_name):
        raise SecurityViolation(
            f"refusing to extract unsafe path: {member_name!r}", name=member_name
        )
    candidate = (root / member_name).resolve()
    try:
        candidate.relative_to(root)
    except ValueError as exc:
        raise SecurityViolation(
            f"path {member_name!r} escapes the destination directory",
            name=member_name,
            destination=str(root),
        ) from exc
    return candidate


# --------------------------------------------------------------------------- #
# Unpack to a staging directory (install support)
# --------------------------------------------------------------------------- #


def stage(
    source: str | os.PathLike[str],
    staging_root: str | os.PathLike[str],
    *,
    clean: bool = True,
) -> tuple[Manifest, Path]:
    """Extract a package into a fresh staging directory.

    Returns ``(manifest, staging_dir)``. The caller is responsible for moving
    the directory into place and for deleting the staging area on failure —
    BTPS deliberately does not hide that decision.
    """
    info = inspect(source)
    info.report.raise_if_invalid()
    assert info.manifest is not None  # guaranteed when the report is clean

    base = Path(staging_root)
    base.mkdir(parents=True, exist_ok=True)
    target = base / f"{info.manifest.slug}-{info.manifest.version_string}"

    if target.exists():
        if not clean:
            raise PackageError(
                f"staging directory already exists: {target}",
                path=str(target),
            )
        shutil.rmtree(target, ignore_errors=True)

    extract(source, target, overwrite=True, verify_manifest=False)
    return info.manifest, target
