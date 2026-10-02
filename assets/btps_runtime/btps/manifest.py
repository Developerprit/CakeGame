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

"""``btps.json`` manifest: schema, parsing, and semantic validation.

The manifest is the contract between a plugin author and every conforming host.
It is validated in three tiers so that tooling can be strict while remaining
usable:

``ERROR``
    Structural or semantic problem that makes the plugin unloadable.
``WARNING``
    Loadable, but the author should be told (missing license, unknown runtime).
``INFO``
    Advisory only.

Validation never raises on WARNING/INFO — callers decide. It *does* raise
:class:`~btps.errors.ManifestError` for hard structural failures such as a
non-object root, because at that point there is nothing meaningful to report.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Iterable, Mapping, Sequence

from .errors import ManifestError
from .semver import Range, Version, parse_constraint

__all__ = [
    "MANIFEST_FILENAME",
    "MANIFEST_VERSION",
    "BTPS_SPEC_VERSION",
    "Severity",
    "Issue",
    "ValidationReport",
    "Author",
    "Dependency",
    "HookDeclaration",
    "Manifest",
    "KNOWN_PERMISSIONS",
    "KNOWN_PLATFORMS",
    "KNOWN_RUNTIMES",
    "known_hooks",
    "permission_matches",
]

MANIFEST_FILENAME = "btps.json"
MANIFEST_VERSION = 1
BTPS_SPEC_VERSION = "1.0"

#: Plugin ids are reverse-DNS-ish and restricted to a URL-safe subset so that
#: they can be used verbatim as directory names, KV keys, and URL path segments.
_ID_RE = re.compile(r"^[a-z0-9]([a-z0-9_-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9_-]*[a-z0-9])?)*$")
_PERMISSION_RE = re.compile(r"^[a-z][a-z0-9]*(\.[a-z][a-z0-9_-]*)+(:[^\s]+)?$")
_HOOK_RE = re.compile(r"^[a-z][a-zA-Z0-9]*(\.[a-zA-Z0-9_*]+)*$")

KNOWN_PLATFORMS = frozenset({"windows", "linux", "darwin", "freebsd", "android", "ios"})
KNOWN_RUNTIMES = frozenset({"python", "javascript", "typescript"})
ENTRY_RUNTIMES = frozenset({"python", "javascript", "typescript"})

#: Runtime hooks every host MUST dispatch. Hosts may add namespaced extras.
CORE_HOOKS = frozenset(
    {
        "onInstall",
        "onUpdate",
        "onEnable",
        "onDisable",
        "onUninstall",
        "onLoad",
        "host.startup",
        "host.shutdown",
        "tick",
    }
)

#: Permission namespaces understood by the reference implementation. A host may
#: support more; anything outside this set is reported as INFO, not an error.
KNOWN_PERMISSIONS = frozenset(
    {
        "fs.read",
        "fs.write",
        "net.http",
        "net.ws",
        "host.ui.notify",
        "host.ui.panel",
        "host.config.read",
        "host.config.write",
        "host.events.emit",
        "host.storage",
        "host.process.spawn",
        "host.clipboard",
        "host.env.read",
    }
)

#: Permission prefixes that require a user-facing consent prompt at install
#: time rather than being granted silently.
SENSITIVE_PERMISSION_PREFIXES = ("fs.write", "net.", "host.process", "host.env")


def known_hooks(extra: Iterable[str] = ()) -> frozenset[str]:
    """Return the set of hook names considered known, including host extras."""
    return CORE_HOOKS | frozenset(extra)


# --------------------------------------------------------------------------- #
# Reporting
# --------------------------------------------------------------------------- #


class Severity(str, Enum):
    """Validation severity, ordered from fatal to advisory."""

    ERROR = "error"
    WARNING = "warning"
    INFO = "info"

    @property
    def rank(self) -> int:
        return {"error": 0, "warning": 1, "info": 2}[self.value]


@dataclass(frozen=True)
class Issue:
    """A single validation finding tied to a manifest path."""

    severity: Severity
    path: str
    message: str
    hint: str = ""

    def to_dict(self) -> dict[str, str]:
        payload = {
            "severity": self.severity.value,
            "path": self.path,
            "message": self.message,
        }
        if self.hint:
            payload["hint"] = self.hint
        return payload

    def __str__(self) -> str:
        text = f"[{self.severity.value.upper()}] {self.path}: {self.message}"
        return f"{text} — {self.hint}" if self.hint else text


@dataclass
class ValidationReport:
    """Collected findings for one manifest."""

    issues: list[Issue] = field(default_factory=list)

    def add(
        self,
        severity: Severity,
        path: str,
        message: str,
        hint: str = "",
    ) -> None:
        self.issues.append(Issue(severity, path, message, hint))

    def error(self, path: str, message: str, hint: str = "") -> None:
        self.add(Severity.ERROR, path, message, hint)

    def warn(self, path: str, message: str, hint: str = "") -> None:
        self.add(Severity.WARNING, path, message, hint)

    def info(self, path: str, message: str, hint: str = "") -> None:
        self.add(Severity.INFO, path, message, hint)

    def extend(self, other: "ValidationReport") -> None:
        self.issues.extend(other.issues)

    @property
    def errors(self) -> list[Issue]:
        return [i for i in self.issues if i.severity is Severity.ERROR]

    @property
    def warnings(self) -> list[Issue]:
        return [i for i in self.issues if i.severity is Severity.WARNING]

    def of(self, severity: Severity) -> list[Issue]:
        return [i for i in self.issues if i.severity is severity]

    @property
    def ok(self) -> bool:
        """True when no ERROR-level finding exists."""
        return not self.errors

    def raise_if_invalid(self) -> None:
        """Raise :class:`ManifestError` summarising every ERROR finding."""
        if self.ok:
            return
        summary = "; ".join(str(issue) for issue in self.errors[:5])
        if len(self.errors) > 5:
            summary += f"; … and {len(self.errors) - 5} more"
        raise ManifestError(
            f"manifest has {len(self.errors)} error(s): {summary}",
            issues=self.errors,
        )

    def format(self) -> str:
        if not self.issues:
            return "manifest is valid"
        return "\n".join(str(issue) for issue in self.issues)

    def to_dict(self) -> dict[str, Any]:
        return {
            "ok": self.ok,
            "errors": len(self.errors),
            "warnings": len(self.warnings),
            "issues": [i.to_dict() for i in self.issues],
        }


# --------------------------------------------------------------------------- #
# Value objects
# --------------------------------------------------------------------------- #


@dataclass(frozen=True)
class Author:
    """Plugin author contact block."""

    name: str
    email: str = ""
    homepage: str = ""

    @classmethod
    def parse(cls, raw: Any, report: ValidationReport) -> "Author | None":
        if isinstance(raw, str):
            if not raw.strip():
                report.error("author", "author string is empty")
                return None
            return cls(name=raw.strip())
        if not isinstance(raw, Mapping):
            report.error("author", "author must be a string or an object")
            return None
        name = str(raw.get("name", "")).strip()
        if not name:
            report.error("author.name", "author.name is required")
        return cls(
            name=name,
            email=str(raw.get("email", "")).strip(),
            homepage=str(raw.get("homepage", "")).strip(),
        )

    def to_dict(self) -> dict[str, str]:
        payload = {"name": self.name}
        if self.email:
            payload["email"] = self.email
        if self.homepage:
            payload["homepage"] = self.homepage
        return payload

    def __str__(self) -> str:
        return self.name


@dataclass(frozen=True)
class Dependency:
    """A single dependency edge: ``package_id`` constrained by ``constraint``."""

    package_id: str
    constraint: str
    optional: bool = False

    @property
    def range(self) -> Range:
        return parse_constraint(self.constraint)

    def accepts(self, version: str | Version) -> bool:
        return self.range.test(version if isinstance(version, Version) else Version.parse(version, loose=True))

    def to_dict(self) -> dict[str, Any]:
        payload: dict[str, Any] = {"id": self.package_id, "constraint": self.constraint}
        if self.optional:
            payload["optional"] = True
        return payload

    def __str__(self) -> str:
        marker = "?" if self.optional else ""
        return f"{self.package_id}@{self.constraint}{marker}"


@dataclass(frozen=True)
class HookDeclaration:
    """A hook the plugin wants to receive.

    ``handler`` names an exported callable inside the entry module. ``priority``
    orders handlers across plugins (lower runs first). ``continue_on_error``
    keeps the dispatch chain alive after this handler fails.
    """

    name: str
    handler: str
    priority: int = 100
    continue_on_error: bool = False

    def to_dict(self) -> dict[str, Any]:
        return {
            "hook": self.name,
            "handler": self.handler,
            "priority": self.priority,
            "continueOnError": self.continue_on_error,
        }


# --------------------------------------------------------------------------- #
# Manifest
# --------------------------------------------------------------------------- #


@dataclass
class Manifest:
    """A parsed, validated ``btps.json``.

    Attributes mirror the on-disk schema one-to-one. Instances are produced by
    :meth:`parse` / :meth:`from_json` and should be treated as immutable by
    convention — the runtime never mutates a manifest after validation.
    """

    manifest_version: int
    id: str
    name: str
    version: Version
    author: Author
    description: str = ""
    license: str = ""
    homepage: str = ""

    entry: dict[str, str] = field(default_factory=dict)
    runtimes: tuple[str, ...] = ()

    dependencies: tuple[Dependency, ...] = ()
    optional_dependencies: tuple[Dependency, ...] = ()
    conflicts: dict[str, str] = field(default_factory=dict)

    permissions: tuple[str, ...] = ()
    platforms: tuple[str, ...] = ()
    host_api: str = "*"
    min_host_version: str = ""

    hooks: tuple[HookDeclaration, ...] = ()
    settings: dict[str, Any] = field(default_factory=dict)
    keywords: tuple[str, ...] = ()
    extra: dict[str, Any] = field(default_factory=dict)

    btps_version: str = BTPS_SPEC_VERSION
    source_path: str = ""

    # -- derived ------------------------------------------------------------ #

    @property
    def slug(self) -> str:
        """Filesystem-safe directory name: ``id`` with dots replaced by dashes."""
        return self.id.replace(".", "-")

    @property
    def all_dependencies(self) -> tuple[Dependency, ...]:
        return (*self.dependencies, *self.optional_dependencies)

    @property
    def version_string(self) -> str:
        return str(self.version)

    @property
    def host_api_range(self) -> Range:
        return parse_constraint(self.host_api)

    @property
    def sensitive_permissions(self) -> tuple[str, ...]:
        """Permissions that must be surfaced to the user for explicit consent."""
        return tuple(
            p for p in self.permissions if p.startswith(SENSITIVE_PERMISSION_PREFIXES)
        )

    def hook(self, name: str) -> HookDeclaration | None:
        for declaration in self.hooks:
            if declaration.name == name:
                return declaration
        return None

    def declares_permission(self, permission: str) -> bool:
        return any(permission_matches(granted, permission) for granted in self.permissions)

    def supports_platform(self, platform: str) -> bool:
        return not self.platforms or platform in self.platforms

    def supports_host_api(self, api_version: str) -> bool:
        return self.host_api_range.test(Version.parse(api_version, loose=True))

    def to_dict(self, *, include_extra: bool = True) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "manifestVersion": self.manifest_version,
            "btpsVersion": self.btps_version,
            "id": self.id,
            "name": self.name,
            "version": str(self.version),
            "author": self.author.to_dict(),
        }
        if self.description:
            payload["description"] = self.description
        if self.license:
            payload["license"] = self.license
        if self.homepage:
            payload["homepage"] = self.homepage
        if self.entry:
            payload["entry"] = dict(self.entry)
        if self.runtimes:
            payload["runtimes"] = list(self.runtimes)
        if self.dependencies:
            payload["dependencies"] = {d.package_id: d.constraint for d in self.dependencies}
        if self.optional_dependencies:
            payload["optionalDependencies"] = {
                d.package_id: d.constraint for d in self.optional_dependencies
            }
        if self.conflicts:
            payload["conflicts"] = dict(self.conflicts)
        if self.permissions:
            payload["permissions"] = list(self.permissions)
        if self.platforms:
            payload["platforms"] = list(self.platforms)
        if self.host_api != "*":
            payload["hostApi"] = self.host_api
        if self.min_host_version:
            payload["minHostVersion"] = self.min_host_version
        if self.hooks:
            payload["hooks"] = {
                h.name: {
                    "handler": h.handler,
                    "priority": h.priority,
                    **({"continueOnError": True} if h.continue_on_error else {}),
                }
                for h in self.hooks
            }
        if self.settings:
            payload["settings"] = self.settings
        if self.keywords:
            payload["keywords"] = list(self.keywords)
        if include_extra:
            payload.update(self.extra)
        return payload

    def to_json(self, *, indent: int = 2) -> str:
        return json.dumps(self.to_dict(), indent=indent, ensure_ascii=False)

    # -- parsing ------------------------------------------------------------ #

    @classmethod
    def from_json(
        cls,
        text: str,
        *,
        source: str = "",
        report: ValidationReport | None = None,
        strict: bool = True,
        extra_hooks: Iterable[str] = (),
    ) -> "Manifest":
        """Parse and validate a manifest from JSON text.

        This is the entry point for anything reading ``btps.json`` off disk or
        out of an archive. :meth:`parse` handles an already-decoded object and is
        deliberately strict about receiving one: silently accepting a string
        would turn a caller's mistake into a confusing validation failure much
        later in the pipeline.
        """
        try:
            raw = json.loads(text)
        except json.JSONDecodeError as exc:
            raise ManifestError(
                f"btps.json is not valid JSON: {exc.msg}",
                line=exc.lineno,
                column=exc.colno,
            ) from exc
        return cls.parse(
            raw,
            source=source,
            report=report,
            strict=strict,
            extra_hooks=extra_hooks,
        )

    @classmethod
    def parse(
        cls,
        raw: Any,
        *,
        source: str = "",
        report: ValidationReport | None = None,
        strict: bool = True,
        extra_hooks: Iterable[str] = (),
    ) -> "Manifest":
        """Build a :class:`Manifest` from a decoded JSON object.

        When ``strict`` is true (the default) any ERROR finding raises
        :class:`ManifestError`; pass a ``report`` to inspect findings instead of
        raising.
        """
        if not isinstance(raw, Mapping):
            raise ManifestError(
                "btps.json root must be a JSON object",
                actual_type=type(raw).__name__,
            )

        own_report = report if report is not None else ValidationReport()
        manifest = cls._build(raw, own_report, source, extra_hooks)

        if strict and report is None:
            own_report.raise_if_invalid()
        return manifest

    @classmethod
    def _build(
        cls,
        raw: Mapping[str, Any],
        report: ValidationReport,
        source: str,
        extra_hooks: Iterable[str],
    ) -> "Manifest":
        consumed: set[str] = set()

        def take(key: str, default: Any = None) -> Any:
            consumed.add(key)
            return raw.get(key, default)

        # -- identity ------------------------------------------------------- #
        manifest_version = take("manifestVersion", MANIFEST_VERSION)
        if not isinstance(manifest_version, int) or isinstance(manifest_version, bool):
            report.error("manifestVersion", "must be an integer")
            manifest_version = MANIFEST_VERSION
        elif manifest_version != MANIFEST_VERSION:
            report.error(
                "manifestVersion",
                f"unsupported manifest version {manifest_version}",
                hint=f"this BTPS build understands version {MANIFEST_VERSION}",
            )

        plugin_id = take("id")
        if not isinstance(plugin_id, str) or not plugin_id.strip():
            report.error("id", "id is required and must be a non-empty string")
            plugin_id = "invalid.plugin"
        elif not _ID_RE.match(plugin_id):
            report.error(
                "id",
                f"id {plugin_id!r} is not a valid package identifier",
                hint="use lowercase reverse-DNS form, e.g. 'com.example.myplugin'",
            )

        name = take("name")
        if not isinstance(name, str) or not name.strip():
            report.warn("name", "name is missing; falling back to id", hint="add a display name")
            name = plugin_id

        raw_version = take("version")
        if not isinstance(raw_version, str):
            report.error("version", "version is required and must be a string")
            version = Version(0, 0, 0)
        else:
            try:
                version = Version.parse(raw_version)
            except Exception:
                report.error(
                    "version",
                    f"{raw_version!r} is not a valid semantic version",
                    hint="expected MAJOR.MINOR.PATCH, e.g. '1.0.0'",
                )
                version = Version(0, 0, 0)

        author = Author.parse(take("author", {}), report)
        if author is None:
            report.error("author", "author is required")
            author = Author(name="unknown")

        # -- descriptive ---------------------------------------------------- #
        description = str(take("description", "") or "")
        license_id = str(take("license", "") or "")
        if not license_id:
            report.warn(
                "license",
                "no license declared",
                hint="declare a license so users know how they may use your plugin",
            )
        if len(description) > 2000:
            report.warn("description", "description exceeds 2000 characters")

        homepage = str(take("homepage", "") or "")

        # -- entry ---------------------------------------------------------- #
        entry_raw = take("entry")
        entry: dict[str, str] = {}
        if entry_raw is None:
            report.error(
                "entry",
                "entry is required",
                hint='e.g. { "python": "main.py" }',
            )
        elif isinstance(entry_raw, str):
            # Convenience shorthand: infer the runtime from the file extension.
            inferred = _runtime_for_path(entry_raw)
            if inferred is None:
                report.error(
                    "entry",
                    f"cannot infer a runtime for entry {entry_raw!r}",
                    hint='use the object form, e.g. { "python": "main.py" }',
                )
            else:
                entry[inferred] = entry_raw
        elif isinstance(entry_raw, Mapping):
            for runtime, path in entry_raw.items():
                if runtime not in ENTRY_RUNTIMES:
                    report.error(
                        f"entry.{runtime}",
                        f"unknown runtime {runtime!r}",
                        hint=f"supported: {', '.join(sorted(ENTRY_RUNTIMES))}",
                    )
                    continue
                if not isinstance(path, str) or not path.strip():
                    report.error(f"entry.{runtime}", "entry path must be a non-empty string")
                    continue
                # Normalise separators and a leading "./" only. Using
                # str.lstrip("./") here would silently turn "../../evil.py" into
                # "evil.py", converting a traversal attempt into a valid path —
                # exactly the wrong direction for a security-relevant field.
                normalised = path.strip().replace("\\", "/")
                while normalised.startswith("./"):
                    normalised = normalised[2:]
                segments = normalised.split("/")
                if (
                    normalised.startswith("/")
                    or "." in segments
                    or ".." in segments
                    or "" in segments
                ):
                    report.error(
                        f"entry.{runtime}",
                        "entry path must be relative and must not escape the package root",
                        hint=f"got {path!r}",
                    )
                    continue
                entry[runtime] = normalised
        else:
            report.error("entry", "entry must be an object mapping runtime to path")

        if not entry and isinstance(entry_raw, Mapping):
            report.error("entry", "entry object is empty")

        runtimes_raw = take("runtimes")
        runtimes: tuple[str, ...]
        if runtimes_raw is None:
            runtimes = tuple(sorted(entry.keys()))
        elif isinstance(runtimes_raw, list):
            collected: list[str] = []
            for item in runtimes_raw:
                if item not in KNOWN_RUNTIMES:
                    report.info(
                        "runtimes",
                        f"runtime {item!r} is not known to this BTPS build",
                        hint="the host may still support it",
                    )
                collected.append(str(item))
            runtimes = tuple(collected)
        else:
            report.error("runtimes", "runtimes must be an array")
            runtimes = tuple(sorted(entry.keys()))

        missing_entry = [r for r in runtimes if r not in entry]
        for runtime in missing_entry:
            report.error(
                "entry",
                f"runtime {runtime!r} is declared in runtimes but has no entry path",
            )

        # -- dependencies --------------------------------------------------- #
        dependencies = _parse_dependency_map(
            take("dependencies", {}), report, "dependencies", optional=False, own_id=plugin_id
        )
        optional_dependencies = _parse_dependency_map(
            take("optionalDependencies", {}),
            report,
            "optionalDependencies",
            optional=True,
            own_id=plugin_id,
        )

        declared_ids = {d.package_id for d in dependencies}
        for optional in optional_dependencies:
            if optional.package_id in declared_ids:
                report.warn(
                    "optionalDependencies",
                    f"{optional.package_id!r} is listed as both required and optional",
                    hint="the required declaration wins",
                )

        conflicts = _parse_conflict_map(take("conflicts", {}), report, own_id=plugin_id)

        # -- permissions ---------------------------------------------------- #
        permissions_raw = take("permissions", [])
        permissions: list[str] = []
        if not isinstance(permissions_raw, list):
            report.error("permissions", "permissions must be an array of strings")
        else:
            seen: set[str] = set()
            for item in permissions_raw:
                if not isinstance(item, str) or not item.strip():
                    report.error("permissions", "each permission must be a non-empty string")
                    continue
                permission = item.strip()
                if permission in seen:
                    report.warn("permissions", f"duplicate permission {permission!r}")
                    continue
                seen.add(permission)
                if not _PERMISSION_RE.match(permission):
                    report.error(
                        "permissions",
                        f"{permission!r} is not a valid permission string",
                        hint="expected 'namespace.action' or 'namespace.action:scope'",
                    )
                    continue
                if permission not in KNOWN_PERMISSIONS:
                    report.info(
                        "permissions",
                        f"{permission!r} is not in the reference permission set",
                        hint="the host must explicitly support it",
                    )
                permissions.append(permission)

        for package_id, constraint in conflicts.items():
            if package_id in declared_ids:
                report.error(
                    f"conflicts.{package_id}",
                    f"{package_id!r} cannot be a dependency and a conflict at the same time",
                )
            _ = constraint

        # -- platform / host compatibility ---------------------------------- #
        platforms_raw = take("platforms", [])
        platforms: list[str] = []
        if not isinstance(platforms_raw, list):
            report.error("platforms", "platforms must be an array of strings")
        else:
            for item in platforms_raw:
                if not isinstance(item, str):
                    report.error("platforms", "each platform must be a string")
                    continue
                normalised = item.strip().lower()
                if normalised not in KNOWN_PLATFORMS:
                    report.warn(
                        "platforms",
                        f"unknown platform {item!r}",
                        hint=f"known: {', '.join(sorted(KNOWN_PLATFORMS))}",
                    )
                platforms.append(normalised)

        host_api_raw = take("hostApi", "*")
        host_api = "*"
        if not isinstance(host_api_raw, str):
            report.error("hostApi", "hostApi must be a version constraint string")
        else:
            host_api = host_api_raw.strip() or "*"
            try:
                parse_constraint(host_api)
            except Exception as exc:
                report.error("hostApi", f"invalid hostApi constraint: {exc}")
                host_api = "*"

        min_host_version = str(take("minHostVersion", "") or "")
        if min_host_version:
            try:
                Version.parse(min_host_version, loose=True)
            except Exception:
                report.error(
                    "minHostVersion",
                    f"{min_host_version!r} is not a valid version",
                )
                min_host_version = ""

        # -- hooks ---------------------------------------------------------- #
        hooks = _parse_hooks(take("hooks", {}), report, known_hooks(extra_hooks))

        # -- misc ----------------------------------------------------------- #
        settings = take("settings", {})
        if not isinstance(settings, Mapping):
            report.error("settings", "settings must be an object")
            settings = {}

        keywords_raw = take("keywords", [])
        keywords: tuple[str, ...] = ()
        if isinstance(keywords_raw, list):
            keywords = tuple(str(k) for k in keywords_raw if isinstance(k, str))
        elif keywords_raw:
            report.warn("keywords", "keywords must be an array of strings")

        btps_version = str(take("btpsVersion", BTPS_SPEC_VERSION) or BTPS_SPEC_VERSION)
        if not btps_version.startswith("1."):
            report.warn(
                "btpsVersion",
                f"built against BTPS {btps_version}, host understands 1.x",
            )

        # Anything left over is preserved verbatim — hosts may attach their own
        # namespaced metadata without breaking older BTPS builds.
        extra = {
            key: value
            for key, value in raw.items()
            if key not in consumed and not key.startswith("$") and key != "//"
        }

        return cls(
            manifest_version=manifest_version,
            id=plugin_id,
            name=name.strip(),
            version=version,
            author=author,
            description=description,
            license=license_id,
            homepage=homepage,
            entry=entry,
            runtimes=runtimes,
            dependencies=dependencies,
            optional_dependencies=optional_dependencies,
            conflicts=conflicts,
            permissions=tuple(permissions),
            platforms=tuple(platforms),
            host_api=host_api,
            min_host_version=min_host_version,
            hooks=hooks,
            settings=dict(settings),
            keywords=keywords,
            extra=extra,
            btps_version=btps_version,
            source_path=source,
        )


# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #


def _runtime_for_path(path: str) -> str | None:
    lowered = path.lower()
    if lowered.endswith(".py"):
        return "python"
    if lowered.endswith((".ts", ".mts", ".cts")):
        return "typescript"
    if lowered.endswith((".js", ".mjs", ".cjs")):
        return "javascript"
    return None


def _parse_dependency_map(
    raw: Any,
    report: ValidationReport,
    path: str,
    *,
    optional: bool,
    own_id: str,
) -> tuple[Dependency, ...]:
    if raw is None:
        return ()
    if not isinstance(raw, Mapping):
        report.error(path, f"{path} must be an object mapping package id to constraint")
        return ()

    collected: list[Dependency] = []
    for package_id, constraint in raw.items():
        if not isinstance(package_id, str) or not _ID_RE.match(package_id):
            report.error(f"{path}.{package_id}", f"{package_id!r} is not a valid package id")
            continue
        if package_id == own_id:
            report.error(f"{path}.{package_id}", "a plugin cannot depend on itself")
            continue
        if not isinstance(constraint, str):
            report.error(
                f"{path}.{package_id}",
                "constraint must be a string",
                hint='use "*" for any version',
            )
            continue
        try:
            parse_constraint(constraint)
        except Exception as exc:
            report.error(f"{path}.{package_id}", f"invalid constraint: {exc}")
            continue
        collected.append(Dependency(package_id, constraint, optional=optional))
    return tuple(collected)


def _parse_conflict_map(raw: Any, report: ValidationReport, *, own_id: str) -> dict[str, str]:
    if raw is None:
        return {}
    if not isinstance(raw, Mapping):
        report.error("conflicts", "conflicts must be an object mapping package id to constraint")
        return {}

    collected: dict[str, str] = {}
    for package_id, constraint in raw.items():
        if not isinstance(package_id, str) or not _ID_RE.match(package_id):
            report.error(f"conflicts.{package_id}", f"{package_id!r} is not a valid package id")
            continue
        if package_id == own_id:
            report.error(f"conflicts.{package_id}", "a plugin cannot conflict with itself")
            continue
        if not isinstance(constraint, str):
            report.error(f"conflicts.{package_id}", "constraint must be a string")
            continue
        try:
            parse_constraint(constraint)
        except Exception as exc:
            report.error(f"conflicts.{package_id}", f"invalid constraint: {exc}")
            continue
        collected[package_id] = constraint
    return collected


def _parse_hooks(
    raw: Any,
    report: ValidationReport,
    known: frozenset[str],
) -> tuple[HookDeclaration, ...]:
    if raw is None:
        return ()
    if not isinstance(raw, Mapping):
        report.error("hooks", "hooks must be an object mapping hook name to declaration")
        return ()

    collected: list[HookDeclaration] = []
    seen: set[str] = set()
    for hook_name, declaration in raw.items():
        if not isinstance(hook_name, str) or not _HOOK_RE.match(hook_name):
            report.error(f"hooks.{hook_name}", f"{hook_name!r} is not a valid hook name")
            continue
        if hook_name in seen:
            report.error(f"hooks.{hook_name}", "duplicate hook declaration")
            continue
        seen.add(hook_name)

        if hook_name not in known and not hook_name.startswith("custom."):
            report.warn(
                f"hooks.{hook_name}",
                f"hook {hook_name!r} is not known to this BTPS build",
                hint="use the 'custom.' prefix for host-specific hooks",
            )

        handler = ""
        priority = 100
        continue_on_error = False

        if declaration is None or declaration is True:
            handler = _default_handler_name(hook_name)
        elif isinstance(declaration, str):
            handler = declaration
        elif isinstance(declaration, Mapping):
            raw_handler = declaration.get("handler")
            if raw_handler is None:
                handler = _default_handler_name(hook_name)
            elif not isinstance(raw_handler, str) or not raw_handler.strip():
                report.error(f"hooks.{hook_name}.handler", "handler must be a non-empty string")
                continue
            else:
                handler = raw_handler.strip()

            raw_priority = declaration.get("priority", 100)
            if not isinstance(raw_priority, int) or isinstance(raw_priority, bool):
                report.error(f"hooks.{hook_name}.priority", "priority must be an integer")
            else:
                priority = raw_priority

            raw_coe = declaration.get("continueOnError", False)
            if not isinstance(raw_coe, bool):
                report.error(f"hooks.{hook_name}.continueOnError", "must be a boolean")
            else:
                continue_on_error = raw_coe
        else:
            report.error(
                f"hooks.{hook_name}",
                "declaration must be an object, a handler name, or null",
            )
            continue

        if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", handler):
            report.error(
                f"hooks.{hook_name}.handler",
                f"{handler!r} is not a valid exported symbol name",
            )
            continue

        collected.append(
            HookDeclaration(hook_name, handler, priority, continue_on_error)
        )

    collected.sort(key=lambda h: (h.priority, h.name))
    return tuple(collected)


def _default_handler_name(hook_name: str) -> str:
    """Derive a snake_case handler name from a hook.

    ``host.startup`` → ``on_host_startup``

    A bare ``onEnable`` maps to ``on_enable`` — not ``on_on_enable``. Hooks in the
    core set are conventionally already named ``onX``, so the ``on_`` prefix is
    added only when it is not already present. ``host.*`` and ``custom.*`` hooks
    always get the prefix, since their first segment is a namespace rather than
    a verb.
    """
    # Split camelCase and dotted segments into words.
    with_separators = re.sub(r"(?<!^)(?=[A-Z])", "_", hook_name.replace(".", "_"))
    words = [w.lower() for w in re.split(r"[_\s]+", with_separators) if w]
    if not words:
        return "on_hook"

    namespaced = "." in hook_name
    if not namespaced and words[0] == "on":
        # Already an ``onXyz`` name; just re-join it as snake_case.
        return "_".join(["on", *words[1:]]) if len(words) > 1 else "on"

    return "on_" + "_".join(words)


def permission_matches(granted: str, requested: str) -> bool:
    """Does ``granted`` cover ``requested``?

    Scopes are matched hierarchically so that ``net.http:*.example.com`` covers
    ``net.http:api.example.com``, and a bare ``net.http`` covers every scope of
    that permission. A wildcard ``*`` grant covers everything.

    Matching is *case-sensitive* for scope segments and *suffix-anchored* for
    domains: ``api.example.com`` never matches ``evil-example.com``.
    """
    if granted == "*" or requested == "*":
        return granted == requested == "*" or granted == "*"
    if granted == requested:
        return True

    granted_ns, _, granted_scope = granted.partition(":")
    requested_ns, _, requested_scope = requested.partition(":")

    if granted_ns != requested_ns:
        return False
    if not granted_scope:
        # Permission granted without scope covers every scope of that namespace.
        return True
    if not requested_scope:
        return False

    if granted_scope.startswith("*."):
        suffix = granted_scope[1:]  # ".example.com"
        return requested_scope.endswith(suffix) or requested_scope == granted_scope[2:]
    return False


def validate_entry_exists(
    manifest: Manifest,
    entries: Iterable[str],
    report: ValidationReport,
) -> None:
    """Verify each declared entry path is actually present in the package.

    ``entries`` is an iterable of normalised archive member names.
    """
    available = {name.replace("\\", "/").lstrip("./") for name in entries}
    for runtime, path in manifest.entry.items():
        if path not in available:
            report.error(
                f"entry.{runtime}",
                f"entry file {path!r} is not present in the package",
                hint="check the path is relative to the package root",
            )


__all__ += ["CORE_HOOKS", "SENSITIVE_PERMISSION_PREFIXES", "validate_entry_exists"]
