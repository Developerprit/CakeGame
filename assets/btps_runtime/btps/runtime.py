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

"""The plugin runtime: state machine, module loading, and lifecycle operations.

Everything a host needs is reachable through :class:`PluginRuntime`. A minimal
host integration is roughly thirty lines::

    from btps import PluginRuntime, HostAdapter

    runtime = PluginRuntime(adapter=MyHostAdapter(), install_root="./plugins")
    runtime.install("hello-1.0.0.btp")
    runtime.disable("com.example.hello")

The state machine is enforced, not advisory. Illegal transitions raise
:class:`~btps.errors.LifecycleError` instead of silently doing something
surprising, because a plugin that is "enabled" but not loaded is a bug that
otherwise surfaces much later as a confusing no-op.
"""

from __future__ import annotations

import importlib.util
import json
import os
import shutil
import sys
import threading
import time
import uuid
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path
from typing import Any, Callable, Iterable, Mapping, Protocol, Sequence, runtime_checkable

from . import package as packaging
from .errors import BTPSError, LifecycleError, ManifestError, PackageError
from .hooks import DispatchReport, HookBus
from .manifest import Manifest
from .resolver import Action, Candidate, InstallPlan, PlanStep
from .sandbox import AuditLog, Limits, Sandbox

__all__ = [
    "PluginState",
    "HostAdapter",
    "DefaultHostAdapter",
    "PluginRecord",
    "LifecycleEvent",
    "PluginRuntime",
]


class PluginState(str, Enum):
    """Lifecycle states. See ``Planning/Planning.md`` §6 for the diagram."""

    DISCOVERED = "discovered"
    RESOLVED = "resolved"
    INSTALLED = "installed"
    LOADED = "loaded"
    ENABLED = "enabled"
    DISABLED = "disabled"
    FAILED = "failed"

    @property
    def is_terminal(self) -> bool:
        return self is PluginState.FAILED


#: Legal transitions, keyed by source state.
TRANSITIONS: dict[PluginState, frozenset[PluginState]] = {
    PluginState.DISCOVERED: frozenset({PluginState.RESOLVED, PluginState.FAILED}),
    PluginState.RESOLVED: frozenset({PluginState.INSTALLED, PluginState.FAILED}),
    PluginState.INSTALLED: frozenset(
        {PluginState.LOADED, PluginState.FAILED, PluginState.DISCOVERED}
    ),
    PluginState.LOADED: frozenset(
        {PluginState.ENABLED, PluginState.FAILED, PluginState.INSTALLED}
    ),
    PluginState.ENABLED: frozenset(
        {PluginState.DISABLED, PluginState.FAILED, PluginState.LOADED}
    ),
    PluginState.DISABLED: frozenset(
        {
            PluginState.ENABLED,
            PluginState.FAILED,
            PluginState.LOADED,
            PluginState.DISCOVERED,
            # A disabled plugin can be reloaded or reinstalled. Omitting this
            # made ``reload()`` on a disabled plugin explode with an illegal
            # transition, because reload drops back to INSTALLED before the
            # module is re-imported.
            PluginState.INSTALLED,
        }
    ),
    PluginState.FAILED: frozenset(
        {PluginState.DISCOVERED, PluginState.RESOLVED, PluginState.LOADED, PluginState.DISABLED}
    ),
}


def can_transition(source: PluginState, target: PluginState) -> bool:
    """Whether ``source → target`` is a legal lifecycle move."""
    if source is target:
        return True
    return target in TRANSITIONS.get(source, frozenset())


# --------------------------------------------------------------------------- #
# Host adapter
# --------------------------------------------------------------------------- #


@runtime_checkable
class HostAdapter(Protocol):
    """The single interface a host platform must implement.

    Everything else — manifests, dependency resolution, sandboxing, hooks,
    install transactions — comes from BTPS.
    """

    def host_version(self) -> str:
        """Host release version, e.g. ``"2.4.1"``."""
        ...

    def host_api_version(self) -> str:
        """BTPS-facing API version the host implements, e.g. ``"1.2.0"``."""
        ...

    def capability(self, name: str) -> bool:
        """Whether the host supports a named capability."""
        ...

    def log(self, level: str, message: str, **context: Any) -> None:
        """Receive a log line attributed to a plugin."""
        ...

    def notify(self, title: str, body: str, **context: Any) -> None:
        """Show a user-visible notification."""
        ...


class DefaultHostAdapter:
    """A working adapter that logs to stderr and buffers notifications.

    Useful for CLI runs, tests, and as a template for real hosts.
    """

    def __init__(
        self,
        *,
        version: str = "1.0.0",
        api_version: str = "1.0.0",
        capabilities: Iterable[str] = ("host.ui.notify", "host.storage"),
        stream: Any = None,
    ) -> None:
        self._version = version
        self._api_version = api_version
        self._capabilities = frozenset(capabilities)
        self._stream = stream if stream is not None else sys.stderr
        self.notifications: list[tuple[str, str]] = []

    def host_version(self) -> str:
        return self._version

    def host_api_version(self) -> str:
        return self._api_version

    def capability(self, name: str) -> bool:
        return name in self._capabilities

    def log(self, level: str, message: str, **context: Any) -> None:
        plugin = context.get("plugin_id", "-")
        suffix = ""
        if context:
            suffix = " " + json.dumps(
                {k: v for k, v in context.items() if k != "plugin_id"},
                ensure_ascii=False,
                default=str,
            )
            if suffix == " {}":
                suffix = ""
        try:
            print(f"[{level.upper():<7}] {plugin}: {message}{suffix}", file=self._stream)
        except (OSError, ValueError):
            pass  # A broken log stream must never break the runtime.

    def notify(self, title: str, body: str, **context: Any) -> None:
        self.notifications.append((title, body))
        self.log("notify", f"{title} — {body}", **context)


# --------------------------------------------------------------------------- #
# Records
# --------------------------------------------------------------------------- #


@dataclass
class LifecycleEvent:
    """One transition in a plugin's life, for audit and UI timelines."""

    plugin_id: str
    from_state: PluginState
    to_state: PluginState
    at: float = field(default_factory=time.time)
    detail: str = ""

    def to_dict(self) -> dict[str, Any]:
        return {
            "pluginId": self.plugin_id,
            "from": self.from_state.value,
            "to": self.to_state.value,
            "at": self.at,
            "time": time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(self.at)),
            "detail": self.detail,
        }

    def __str__(self) -> str:
        return f"{self.plugin_id}: {self.from_state.value} → {self.to_state.value}"


@dataclass
class PluginRecord:
    """Everything the runtime knows about one installed plugin."""

    manifest: Manifest
    state: PluginState = PluginState.DISCOVERED
    install_path: str = ""
    entry_path: str = ""
    module: Any = None
    namespace: dict[str, Any] = field(default_factory=dict)
    sandbox: Sandbox | None = None
    error: str = ""
    installed_at: float = 0.0
    updated_at: float = 0.0
    enabled_at: float = 0.0
    history: list[LifecycleEvent] = field(default_factory=list)
    metadata: dict[str, Any] = field(default_factory=dict)

    @property
    def id(self) -> str:
        return self.manifest.id

    @property
    def version(self) -> str:
        return self.manifest.version_string

    @property
    def is_enabled(self) -> bool:
        return self.state is PluginState.ENABLED

    @property
    def is_running(self) -> bool:
        return self.state in (PluginState.ENABLED, PluginState.LOADED)

    def to_dict(self, *, include_manifest: bool = True) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "id": self.id,
            "version": self.version,
            "state": self.state.value,
            "installPath": self.install_path,
            "entryPath": self.entry_path,
            "error": self.error,
            "installedAt": self.installed_at,
            "updatedAt": self.updated_at,
            "enabledAt": self.enabled_at,
            "permissions": list(self.manifest.permissions),
            "pendingConsent": list(self.sandbox.permissions.pending_consent) if self.sandbox else [],
            "history": [event.to_dict() for event in self.history[-20:]],
        }
        if include_manifest:
            payload["manifest"] = self.manifest.to_dict()
        return payload


# --------------------------------------------------------------------------- #
# Runtime
# --------------------------------------------------------------------------- #


class PluginRuntime:
    """Loads, enables, disables, updates, and uninstalls plugins.

    Thread-safety: public methods take a re-entrant lock. Hook dispatch happens
    *outside* the lock so a slow plugin cannot deadlock the host.
    """

    def __init__(
        self,
        *,
        adapter: HostAdapter | None = None,
        install_root: str | os.PathLike[str] = "plugins",
        data_root: str | os.PathLike[str] | None = None,
        staging_root: str | os.PathLike[str] | None = None,
        limits: Limits | None = None,
        audit: AuditLog | None = None,
        extra_hooks: Iterable[str] = (),
        platform: str | None = None,
    ) -> None:
        self.adapter: HostAdapter = adapter if adapter is not None else DefaultHostAdapter()
        self.install_root = Path(install_root).resolve()
        self.data_root = (
            Path(data_root).resolve() if data_root is not None else self.install_root / ".data"
        )
        self.staging_root = (
            Path(staging_root).resolve()
            if staging_root is not None
            else self.install_root / ".staging"
        )
        self.limits = limits or Limits()
        self.audit = audit if audit is not None else AuditLog()
        self.hooks = HookBus(limits=self.limits, audit=self.audit, extra_hooks=extra_hooks)
        self.platform = platform or _detect_platform()

        self._records: dict[str, PluginRecord] = {}
        self._lock = threading.RLock()
        self._state_file = self.install_root / "btps.state.json"

        for directory in (self.install_root, self.data_root, self.staging_root):
            directory.mkdir(parents=True, exist_ok=True)

    # ------------------------------------------------------------------ #
    # Introspection
    # ------------------------------------------------------------------ #

    @property
    def records(self) -> dict[str, PluginRecord]:
        with self._lock:
            return dict(self._records)

    def get(self, plugin_id: str) -> PluginRecord | None:
        with self._lock:
            return self._records.get(plugin_id)

    def list(
        self,
        *,
        state: PluginState | None = None,
        enabled_only: bool = False,
    ) -> list[PluginRecord]:
        with self._lock:
            collected = list(self._records.values())
        if state is not None:
            collected = [r for r in collected if r.state is state]
        if enabled_only:
            collected = [r for r in collected if r.is_enabled]
        collected.sort(key=lambda r: r.id)
        return collected

    def require(self, plugin_id: str) -> PluginRecord:
        record = self.get(plugin_id)
        if record is None:
            raise LifecycleError(
                f"plugin {plugin_id!r} is not known to this runtime",
                plugin_id=plugin_id,
                known=sorted(self._records),
            )
        return record

    def installed_versions(self) -> dict[str, str]:
        with self._lock:
            return {pid: rec.version for pid, rec in self._records.items()}

    def summary(self) -> dict[str, Any]:
        with self._lock:
            by_state: dict[str, int] = {}
            for record in self._records.values():
                by_state[record.state.value] = by_state.get(record.state.value, 0) + 1
        return {
            "installRoot": str(self.install_root),
            "dataRoot": str(self.data_root),
            "platform": self.platform,
            "hostVersion": self.adapter.host_version(),
            "hostApiVersion": self.adapter.host_api_version(),
            "count": len(self._records),
            "byState": by_state,
            "hooks": self.hooks.hooks(),
            "auditEntries": len(self.audit.entries()),
        }

    # ------------------------------------------------------------------ #
    # Discovery
    # ------------------------------------------------------------------ #

    def discover(self, search_roots: Iterable[str | os.PathLike[str]] | None = None) -> list[packaging.PackageInfo]:
        """Scan directories for ``.btp`` files without installing anything."""
        roots = [Path(r) for r in (search_roots or [self.install_root])]
        found: list[packaging.PackageInfo] = []
        for root in roots:
            if not root.is_dir():
                continue
            for path in sorted(root.glob(f"*{packaging.EXTENSION}")):
                try:
                    found.append(packaging.inspect(path))
                except BTPSError as exc:
                    self.adapter.log(
                        "warn", f"skipping unreadable package {path.name}: {exc}"
                    )
        return found

    def plan(
        self,
        package_paths: Sequence[str | os.PathLike[str]],
        *,
        prune: bool = False,
    ) -> InstallPlan:
        """Resolve a set of packages against what is currently installed."""
        candidates: list[Candidate] = []
        for path in package_paths:
            info = packaging.inspect(path)
            info.report.raise_if_invalid()
            assert info.manifest is not None
            candidates.append(Candidate(manifest=info.manifest, source=str(path)))

        # Installed packages participate as candidates so that updates and
        # downgrades can be reasoned about without re-downloading anything.
        for record in self.list():
            if record.manifest.id in {c.id for c in candidates}:
                continue
            candidates.append(
                Candidate(
                    manifest=record.manifest,
                    source=record.install_path,
                    installed=True,
                )
            )

        from .resolver import resolve

        result = resolve(
            candidates,
            installed=self.installed_versions(),
            roots=[c.id for c in candidates if not c.installed] or None,
        )
        result.plan.raise_if_conflicted()
        if not prune:
            result.plan.steps = [
                step for step in result.plan.steps if step.action is not Action.UNINSTALL
            ]
        return result.plan

    def apply(
        self,
        plan: InstallPlan,
        *,
        auto_enable: bool = True,
        granted_permissions: Mapping[str, Iterable[str]] | None = None,
    ) -> list[PluginRecord]:
        """Execute an install plan in dependency order.

        Ordering matters and is already correct: the resolver topologically
        sorted the steps so a dependency is installed before its dependent.
        """
        plan.raise_if_conflicted()
        touched: list[PluginRecord] = []
        grants = dict(granted_permissions or {})

        for step in plan.mutating:
            try:
                if step.action is Action.UNINSTALL:
                    self.uninstall(step.node.package_id)
                    continue
                record = self.install(
                    step.node.candidate.source,
                    granted_permissions=grants.get(step.node.package_id),
                    auto_enable=auto_enable,
                )
                touched.append(record)
            except BTPSError as exc:
                self.adapter.log(
                    "error",
                    f"failed to apply {step.action.value} for "
                    f"{step.node.package_id}: {exc}",
                )
                self.audit.record(
                    step.node.package_id, "error",
                    f"install plan step failed: {exc}",
                )
                raise
        return touched

    # ------------------------------------------------------------------ #
    # Install
    # ------------------------------------------------------------------ #

    def install(
        self,
        package_path: str | os.PathLike[str],
        *,
        granted_permissions: Iterable[str] | None = None,
        auto_enable: bool = False,
        overwrite: bool = False,
    ) -> PluginRecord:
        """Install a ``.btp`` package.

        The install is transactional: the package is staged, validated, and only
        then moved into place. A failure at any point leaves the previous
        installation untouched.
        """
        source = Path(package_path)
        info = packaging.inspect(source)
        info.report.raise_if_invalid()
        manifest = info.manifest
        assert manifest is not None

        self._check_platform(manifest)

        with self._lock:
            existing = self._records.get(manifest.id)
            if existing is not None and not overwrite:
                if existing.version == manifest.version_string:
                    raise LifecycleError(
                        f"{manifest.id}@{manifest.version_string} is already installed",
                        plugin_id=manifest.id,
                        state=existing.state.value,
                        hint="pass overwrite=True, or use update()",
                    )

            # Resolve dependencies against what is already present.
            missing = self._unsatisfied_dependencies(manifest)
            if missing:
                raise LifecycleError(
                    f"cannot install {manifest.id}: unsatisfied dependencies "
                    f"({', '.join(missing)})",
                    plugin_id=manifest.id,
                    missing=missing,
                    hint="install the missing packages first, or use apply() for an ordered plan",
                )

            if existing is not None and existing.is_running:
                # A running plugin must be stopped before its files move.
                self.disable(manifest.id)

            target_dir = self.install_root / f"{manifest.slug}-{manifest.version_string}"

        try:
            staged_manifest, staged_dir = packaging.stage(source, self.staging_root)
        except BTPSError:
            raise

        try:
            if target_dir.exists():
                if not overwrite and existing is None:
                    raise LifecycleError(
                        f"install directory already exists: {target_dir}",
                        plugin_id=manifest.id,
                        path=str(target_dir),
                    )
                shutil.rmtree(target_dir, ignore_errors=True)

            # Move the staged tree into place. Same volume → atomic rename.
            shutil.move(str(staged_dir), str(target_dir))
        except OSError as exc:
            shutil.rmtree(staged_dir, ignore_errors=True)
            raise PackageError(
                f"cannot move staged package into {target_dir}: {exc}",
                plugin_id=manifest.id,
                path=str(target_dir),
            ) from exc

        install_path = target_dir
        entry_relative = self._pick_entry(staged_manifest)
        entry_path = install_path / entry_relative

        data_dir = self.data_root / manifest.slug
        sandbox = Sandbox(
            staged_manifest,
            package_root=install_path,
            data_root=data_dir,
            granted_permissions=granted_permissions,
            limits=self.limits,
            audit=self.audit,
        )

        with self._lock:
            previous_state = existing.state if existing else PluginState.DISCOVERED
            record = PluginRecord(
                manifest=staged_manifest,
                state=PluginState.INSTALLED,
                install_path=str(install_path),
                entry_path=str(entry_path),
                sandbox=sandbox,
                installed_at=time.time(),
                updated_at=time.time(),
                history=list(existing.history) if existing else [],
                metadata=dict(existing.metadata) if existing else {},
            )
            self._transition(record, PluginState.INSTALLED, f"installed from {source.name}")
            self._records[manifest.id] = record

        if sandbox.permissions.pending_consent:
            self.adapter.notify(
                f"{manifest.name} needs approval",
                "Permissions awaiting your decision: "
                + ", ".join(sandbox.permissions.pending_consent),
                plugin_id=manifest.id,
            )

        self.adapter.log(
            "info",
            f"installed {manifest.id}@{manifest.version_string}",
            plugin_id=manifest.id,
        )
        self.dispatch("onInstall", {"manifest": manifest.to_dict(), "previousState": previous_state.value})
        self._save_state()

        if auto_enable:
            self.enable(manifest.id)
        return record

    def _unsatisfied_dependencies(self, manifest: Manifest) -> list[str]:
        """Ids that are missing or version-mismatched among required deps."""
        missing: list[str] = []
        for dependency in manifest.dependencies:
            record = self._records.get(dependency.package_id)
            if record is None:
                missing.append(f"{dependency.package_id}{dependency.constraint}")
                continue
            if not dependency.accepts(record.manifest.version):
                missing.append(
                    f"{dependency.package_id}{dependency.constraint} "
                    f"(have {record.version})"
                )
        for conflicted, constraint in manifest.conflicts.items():
            record = self._records.get(conflicted)
            if record is None:
                continue
            try:
                from .semver import satisfies

                if satisfies(record.manifest.version, constraint):
                    missing.append(
                        f"conflict: {conflicted}{constraint} (have {record.version})"
                    )
            except BTPSError:
                continue
        return missing

    def _check_platform(self, manifest: Manifest) -> None:
        if not manifest.supports_platform(self.platform):
            raise LifecycleError(
                f"{manifest.id} does not support platform {self.platform!r}",
                plugin_id=manifest.id,
                platform=self.platform,
                supported=list(manifest.platforms),
            )
        host_api = self.adapter.host_api_version()
        if not manifest.supports_host_api(host_api):
            raise LifecycleError(
                f"{manifest.id} requires host API {manifest.host_api}, host provides {host_api}",
                plugin_id=manifest.id,
                required=manifest.host_api,
                actual=host_api,
            )
        if manifest.min_host_version:
            from .semver import Version

            try:
                required = Version.parse(manifest.min_host_version, loose=True)
                actual = Version.parse(self.adapter.host_version(), loose=True)
            except BTPSError:
                return
            if actual < required:
                raise LifecycleError(
                    f"{manifest.id} requires host version >= {manifest.min_host_version}, "
                    f"host is {self.adapter.host_version()}",
                    plugin_id=manifest.id,
                    required=manifest.min_host_version,
                    actual=self.adapter.host_version(),
                )

    @staticmethod
    def _pick_entry(manifest: Manifest) -> str:
        """Choose which entry to load, honouring the host's own runtime order."""
        for runtime in ("python", "typescript", "javascript"):
            if runtime in manifest.entry:
                return manifest.entry[runtime]
        if not manifest.entry:
            raise ManifestError(
                f"{manifest.id} declares no entry point", plugin_id=manifest.id
            )
        return next(iter(manifest.entry.values()))

    # ------------------------------------------------------------------ #
    # Load
    # ------------------------------------------------------------------ #

    def load(self, plugin_id: str) -> PluginRecord:
        """Import the plugin's entry module and bind its declared hooks."""
        with self._lock:
            record = self.require(plugin_id)
            if record.state in (PluginState.LOADED, PluginState.ENABLED):
                return record
            if not can_transition(record.state, PluginState.LOADED):
                raise LifecycleError(
                    f"cannot load {plugin_id} from state {record.state.value}",
                    plugin_id=plugin_id,
                    state=record.state.value,
                )

        entry = Path(record.entry_path)
        if not entry.is_file():
            self._fail(record, f"entry file is missing: {entry}")
            raise LifecycleError(
                f"entry file is missing for {plugin_id}: {entry}",
                plugin_id=plugin_id,
                path=str(entry),
            )

        suffix = entry.suffix.lower()
        if suffix == ".py":
            namespace = self._load_python_module(record, entry)
        elif suffix in (".js", ".mjs", ".cjs", ".ts", ".mts", ".cts"):
            namespace = self._load_script_module(record, entry)
        else:
            self._fail(record, f"unsupported entry type {suffix!r}")
            raise LifecycleError(
                f"unsupported entry type for {plugin_id}: {suffix!r}",
                plugin_id=plugin_id,
                path=str(entry),
            )

        record.namespace = namespace
        # Expose the plugin's own metadata on the module for convenience.
        namespace.setdefault("__btps_manifest__", record.manifest)
        namespace.setdefault("__btps_plugin_id__", plugin_id)

        # The context is built once and shared by ``btps_setup`` and every hook
        # handler, so ``ctx.storage`` in a handler is the same object the setup
        # hook received. Rebuilding per hook would silently lose in-memory state.
        plugin_context = self._api_for(record)

        setup = namespace.get("btps_setup")
        if callable(setup):
            try:
                result = setup(plugin_context)
                if isinstance(result, Mapping):
                    record.metadata.update(result)
            except Exception as exc:  # noqa: BLE001 - plugin faults are isolated
                self._fail(record, f"btps_setup failed: {type(exc).__name__}: {exc}")
                raise LifecycleError(
                    f"btps_setup failed for {plugin_id}: {exc}",
                    plugin_id=plugin_id,
                ) from exc

        try:
            registered = self.hooks.register_plugin(
                record.manifest, namespace, plugin_context=plugin_context
            )
        except BTPSError as exc:
            self._fail(record, str(exc))
            raise

        with self._lock:
            self._transition(
                record,
                PluginState.LOADED,
                f"loaded {len(registered)} hook binding(s) from {entry.name}",
            )
        self.adapter.log(
            "info",
            f"loaded {plugin_id} ({len(registered)} hook(s))",
            plugin_id=plugin_id,
        )
        self.dispatch("onLoad", {"manifest": record.manifest.to_dict()})
        return record

    def _load_python_module(self, record: PluginRecord, entry: Path) -> dict[str, Any]:
        """Import a Python entry file as an isolated module.

        The module is registered under a namespaced name so two plugins with a
        ``main.py`` cannot collide. ``sys.path`` is *not* extended, so importing
        a sibling file requires an explicit relative import path — deliberate,
        since silently polluting ``sys.path`` is how plugin systems leak.
        """
        module_name = f"btps_plugins.{record.manifest.slug.replace('-', '_')}"
        spec = importlib.util.spec_from_file_location(module_name, entry)
        if spec is None or spec.loader is None:
            raise LifecycleError(
                f"cannot create a module spec for {entry}",
                plugin_id=record.id,
                path=str(entry),
            )

        module = importlib.util.module_from_spec(spec)
        module.__btps_plugin_id__ = record.id  # type: ignore[attr-defined]
        module.__btps_package_root__ = str(Path(record.install_path))  # type: ignore[attr-defined]

        # Make `import btps` work even when the host vendored the library.
        existing = sys.modules.get(module_name)
        sys.modules[module_name] = module
        try:
            spec.loader.exec_module(module)
        except Exception as exc:  # noqa: BLE001 - load faults are reported, not raised raw
            if existing is not None:
                sys.modules[module_name] = existing
            else:
                sys.modules.pop(module_name, None)
            self._fail(record, f"import failed: {type(exc).__name__}: {exc}")
            raise LifecycleError(
                f"cannot import plugin entry {entry}: {type(exc).__name__}: {exc}",
                plugin_id=record.id,
                path=str(entry),
            ) from exc

        record.module = module
        return dict(vars(module))

    def _load_script_module(self, record: PluginRecord, entry: Path) -> dict[str, Any]:
        """Load a JS/TS entry through the Node bridge.

        The bridge executes the module in a Node context and hands back its
        exported symbols as a JSON descriptor. Handlers proxied this way are
        subprocess-backed callables, which is the strongest isolation BTPS
        offers today.
        """
        bridge = Path(__file__).with_name("node_bridge") / "bridge.mjs"
        if not bridge.is_file():  # pragma: no cover - packaging fault
            raise LifecycleError(
                "the Node bridge is not present in this BTPS installation",
                plugin_id=record.id,
                expected=str(bridge),
            )

        helper = Path(__file__).with_name("script_host.py")
        if not helper.is_file():  # pragma: no cover - packaging fault
            raise LifecycleError(
                "the script host helper is not present in this BTPS installation",
                plugin_id=record.id,
                expected=str(helper),
            )

        import importlib.util as _il

        helper_spec = _il.spec_from_file_location("btps_script_host", helper)
        if helper_spec is None or helper_spec.loader is None:  # pragma: no cover
            raise LifecycleError("cannot load the script host helper", plugin_id=record.id)
        helper_module = _il.module_from_spec(helper_spec)
        # Register before executing. ``@dataclass`` (and anything else that
        # resolves a class by ``cls.__module__``) looks the module up in
        # ``sys.modules``; without this the lookup returns None and decoration
        # fails with "'NoneType' object has no attribute '__dict__'".
        sys.modules[helper_spec.name] = helper_module
        try:
            helper_spec.loader.exec_module(helper_module)
        except BaseException:
            sys.modules.pop(helper_spec.name, None)
            raise

        descriptor = helper_module.describe_module(
            entry=entry,
            bridge=bridge,
            plugin_id=record.id,
            sandbox=record.sandbox,
        )
        namespace = dict(descriptor.get("exports", {}))
        namespace["__btps_runtime__"] = descriptor.get("runtime", "unknown")
        namespace["__btps_descriptor__"] = descriptor
        return namespace

    # ------------------------------------------------------------------ #
    # Enable / disable
    # ------------------------------------------------------------------ #

    def enable(self, plugin_id: str, *, auto_load: bool = True) -> PluginRecord:
        """Activate a plugin: load if needed, then fire ``onEnable``."""
        record = self.require(plugin_id)

        if record.state is PluginState.ENABLED:
            return record
        if auto_load and record.state not in (PluginState.LOADED, PluginState.DISABLED):
            if record.state is PluginState.INSTALLED:
                record = self.load(plugin_id)

        if not can_transition(record.state, PluginState.ENABLED):
            raise LifecycleError(
                f"cannot enable {plugin_id} from state {record.state.value}",
                plugin_id=plugin_id,
                state=record.state.value,
                hint="load() the plugin first",
            )

        # Dependencies must be enabled before their dependent: enabling in
        # reverse order would let a plugin run without its prerequisites.
        for dependency in record.manifest.dependencies:
            dependency_record = self._records.get(dependency.package_id)
            if dependency_record is None:
                raise LifecycleError(
                    f"cannot enable {plugin_id}: dependency {dependency.package_id} "
                    "is not installed",
                    plugin_id=plugin_id,
                    missing=dependency.package_id,
                )
            if not dependency_record.is_enabled:
                self.enable(dependency.package_id)

        report = self.dispatch("onEnable", {"manifest": record.manifest.to_dict()})
        if report.failures:
            detail = "; ".join(f"{f.plugin_id}: {f.error}" for f in report.failures)
            self._fail(record, f"onEnable failed: {detail}")
            raise LifecycleError(
                f"onEnable hook failed for {plugin_id}: {detail}",
                plugin_id=plugin_id,
            )

        with self._lock:
            record.enabled_at = time.time()
            self._transition(record, PluginState.ENABLED, "enabled")
        self.adapter.log("info", f"enabled {plugin_id}", plugin_id=plugin_id)
        self._save_state()
        return record

    def disable(self, plugin_id: str) -> PluginRecord:
        """Deactivate a plugin, firing ``onDisable`` before teardown."""
        record = self.require(plugin_id)

        if record.state is PluginState.DISABLED:
            return record
        if not can_transition(record.state, PluginState.DISABLED):
            raise LifecycleError(
                f"cannot disable {plugin_id} from state {record.state.value}",
                plugin_id=plugin_id,
                state=record.state.value,
            )

        # Dependents must be disabled first, or they would keep running against
        # a plugin that is about to be torn down.
        for dependent in self._enabled_dependents(plugin_id):
            self.disable(dependent)

        report = self.dispatch("onDisable", {"manifest": record.manifest.to_dict()})
        if report.failures:
            # Teardown continues regardless: refusing to disable because a hook
            # threw would trap the user in a state they cannot leave.
            self.adapter.log(
                "warn",
                f"{plugin_id} onDisable reported errors but teardown continued",
                plugin_id=plugin_id,
            )

        removed = self.hooks.unregister_plugin(plugin_id)
        with self._lock:
            self._transition(
                record, PluginState.DISABLED, f"disabled, {removed} hook(s) released"
            )
            record.enabled_at = 0.0
        self.adapter.log("info", f"disabled {plugin_id}", plugin_id=plugin_id)
        self._save_state()
        return record

    def _enabled_dependents(self, plugin_id: str) -> list[str]:
        return sorted(
            record.id
            for record in self.list(enabled_only=True)
            if any(d.package_id == plugin_id for d in record.manifest.dependencies)
        )

    def enable_all(self) -> list[PluginRecord]:
        """Enable every installed plugin, dependencies first."""
        order = self._dependency_order()
        results: list[PluginRecord] = []
        for plugin_id in order:
            record = self._records.get(plugin_id)
            if record is None or record.is_enabled:
                continue
            try:
                results.append(self.enable(plugin_id))
            except BTPSError as exc:
                self.adapter.log(
                    "error", f"could not enable {plugin_id}: {exc}", plugin_id=plugin_id
                )
        return results

    def disable_all(self) -> list[PluginRecord]:
        """Disable every enabled plugin, dependents first."""
        order = list(reversed(self._dependency_order()))
        results: list[PluginRecord] = []
        for plugin_id in order:
            record = self._records.get(plugin_id)
            if record is None or not record.is_enabled:
                continue
            try:
                results.append(self.disable(plugin_id))
            except BTPSError as exc:
                self.adapter.log(
                    "error", f"could not disable {plugin_id}: {exc}", plugin_id=plugin_id
                )
        return results

    def _dependency_order(self) -> list[str]:
        """Topologically sort installed plugins; dependencies come first."""
        from .resolver import DependencyGraph, topological_order

        graph = DependencyGraph()
        for record in self._records.values():
            graph.add_node(record.manifest)
        for record in self._records.values():
            for dependency in record.manifest.dependencies:
                if dependency.package_id not in self._records:
                    continue
                from .resolver import ConstraintOrigin

                graph.add_edge(
                    record.id,
                    dependency.package_id,
                    ConstraintOrigin(
                        record.id,
                        record.version,
                        dependency.constraint,
                        (record.id, dependency.package_id),
                    ),
                )
        try:
            return topological_order(graph)
        except BTPSError:
            return sorted(self._records)

    # ------------------------------------------------------------------ #
    # Update / uninstall
    # ------------------------------------------------------------------ #

    def update(
        self,
        package_path: str | os.PathLike[str],
        *,
        granted_permissions: Iterable[str] | None = None,
        keep_state: bool = True,
    ) -> PluginRecord:
        """Install a newer version over an existing one, with rollback.

        The old version is moved aside rather than deleted. If the new version
        fails to load or enable, the old tree is restored, so a bad update
        cannot brick the host.
        """
        info = packaging.inspect(package_path)
        info.report.raise_if_invalid()
        new_manifest = info.manifest
        assert new_manifest is not None

        existing = self.get(new_manifest.id)
        if existing is None:
            raise LifecycleError(
                f"{new_manifest.id} is not installed; use install() instead",
                plugin_id=new_manifest.id,
            )

        from .semver import Version

        old_version = Version.parse(existing.version, loose=True)
        if new_manifest.version <= old_version:
            raise LifecycleError(
                f"refusing to update {new_manifest.id} from {existing.version} "
                f"to {new_manifest.version_string}: not a newer version",
                plugin_id=new_manifest.id,
                current=existing.version,
                candidate=new_manifest.version_string,
            )

        was_enabled = existing.is_enabled
        if was_enabled:
            self.disable(new_manifest.id)

        old_path = Path(existing.install_path)
        backup_path = old_path.with_name(old_path.name + f".bak-{uuid.uuid4().hex[:8]}")

        try:
            if old_path.exists():
                shutil.move(str(old_path), str(backup_path))
        except OSError as exc:
            raise PackageError(
                f"cannot back up {old_path}: {exc}", plugin_id=new_manifest.id
            ) from exc

        try:
            record = self.install(
                package_path,
                granted_permissions=granted_permissions,
                auto_enable=False,
                overwrite=True,
            )
            record.metadata["previousVersion"] = existing.version
            self.dispatch(
                "onUpdate",
                {
                    "from": existing.version,
                    "to": record.version,
                    "manifest": record.manifest.to_dict(),
                },
            )
            if was_enabled:
                self.enable(record.id)
        except Exception:
            # Rollback: remove the half-installed version and restore the old tree.
            self.adapter.log(
                "error",
                f"update of {new_manifest.id} failed; rolling back to {existing.version}",
                plugin_id=new_manifest.id,
            )
            failed = self._records.get(new_manifest.id)
            if failed is not None:
                shutil.rmtree(failed.install_path, ignore_errors=True)
                self._records.pop(new_manifest.id, None)
            if backup_path.exists():
                shutil.move(str(backup_path), str(old_path))
                restored = self.load(new_manifest.id) if False else None
                _ = restored
                # Re-register from disk so the record matches the restored tree.
                try:
                    self._restore_record(old_path, existing)
                except BTPSError:
                    pass
                if was_enabled:
                    try:
                        self.enable(new_manifest.id)
                    except BTPSError:
                        pass
            raise
        else:
            shutil.rmtree(backup_path, ignore_errors=True)
            self._save_state()
            return record

    def _restore_record(self, path: Path, previous: PluginRecord) -> PluginRecord:
        """Rebuild a record from an on-disk package after a rollback."""
        manifest_path = path / "btps.json"
        if not manifest_path.is_file():
            raise PackageError(f"restored package has no manifest: {path}")
        manifest = Manifest.from_json(manifest_path.read_text(encoding="utf-8-sig"))
        sandbox = Sandbox(
            manifest,
            package_root=path,
            data_root=self.data_root / manifest.slug,
            limits=self.limits,
            audit=self.audit,
        )
        record = PluginRecord(
            manifest=manifest,
            state=PluginState.INSTALLED,
            install_path=str(path),
            entry_path=str(path / self._pick_entry(manifest)),
            sandbox=sandbox,
            installed_at=previous.installed_at,
            updated_at=time.time(),
            history=list(previous.history),
            metadata=dict(previous.metadata),
        )
        self._records[manifest.id] = record
        self.load(manifest.id)
        return record

    def uninstall(self, plugin_id: str, *, keep_data: bool = False) -> None:
        """Remove a plugin, firing ``onUninstall`` before deleting anything."""
        record = self.require(plugin_id)

        for dependent in self._enabled_dependents(plugin_id):
            raise LifecycleError(
                f"cannot uninstall {plugin_id}: {dependent} depends on it",
                plugin_id=plugin_id,
                dependent=dependent,
                hint=f"uninstall {dependent} first, or disable it and retry",
            )

        if record.is_enabled:
            self.disable(plugin_id)

        self.dispatch("onUninstall", {"manifest": record.manifest.to_dict(), "keepData": keep_data})

        self.hooks.unregister_plugin(plugin_id)

        install_path = Path(record.install_path)
        if install_path.exists():
            try:
                shutil.rmtree(install_path)
            except OSError as exc:
                raise PackageError(
                    f"cannot remove {install_path}: {exc}",
                    plugin_id=plugin_id,
                    path=str(install_path),
                ) from exc

        if not keep_data:
            data_path = self.data_root / record.manifest.slug
            if data_path.exists():
                shutil.rmtree(data_path, ignore_errors=True)
            cache_path = data_path / "cache"
            if cache_path.exists():
                shutil.rmtree(cache_path, ignore_errors=True)

        # Drop the module so a reinstall picks up the new code.
        module_name = f"btps_plugins.{record.manifest.slug.replace('-', '_')}"
        sys.modules.pop(module_name, None)

        with self._lock:
            self._records.pop(plugin_id, None)
        self.audit.record(
            plugin_id, "note",
            f"uninstalled (data {'kept' if keep_data else 'removed'})",
        )
        self.adapter.log("info", f"uninstalled {plugin_id}", plugin_id=plugin_id)
        self._save_state()

    def reload(self, plugin_id: str) -> PluginRecord:
        """Disable, re-import, and re-enable — the dev-loop operation."""
        record = self.require(plugin_id)
        was_enabled = record.is_enabled
        if record.state is PluginState.ENABLED:
            self.disable(plugin_id)

        module_name = f"btps_plugins.{record.manifest.slug.replace('-', '_')}"
        sys.modules.pop(module_name, None)

        with self._lock:
            self._transition(record, PluginState.INSTALLED, "reload requested")
        self.load(plugin_id)
        if was_enabled:
            self.enable(plugin_id)
        return self.require(plugin_id)

    # ------------------------------------------------------------------ #
    # Dispatch / API
    # ------------------------------------------------------------------ #

    def dispatch(
        self,
        hook: str,
        data: Mapping[str, Any] | None = None,
        *,
        timeout: float | None = None,
    ) -> DispatchReport:
        """Fire a hook across every subscriber. Never raises on handler error."""
        report = self.hooks.dispatch(hook, data, timeout=timeout)
        if report.failures:
            self.adapter.log(
                "warn",
                f"hook {hook!r}: {len(report.failures)} of {len(report.results)} handler(s) failed",
            )
        return report

    def emit(self, hook: str, **data: Any) -> DispatchReport:
        return self.dispatch(hook, data)

    def _api_for(self, record: PluginRecord) -> Any:
        """Build the ``btps.api`` context object handed to a plugin."""
        from . import api as api_module

        return api_module.build_context(self, record)

    # ------------------------------------------------------------------ #
    # State persistence
    # ------------------------------------------------------------------ #

    def _transition(self, record: PluginRecord, target: PluginState, detail: str = "") -> None:
        source = record.state
        if not can_transition(source, target):
            raise LifecycleError(
                f"illegal transition for {record.id}: {source.value} → {target.value}",
                plugin_id=record.id,
                source=source.value,
                target=target.value,
            )
        record.state = target
        record.history.append(LifecycleEvent(record.id, source, target, detail=detail))
        if target is PluginState.INSTALLED:
            record.error = ""

    def _fail(self, record: PluginRecord, message: str) -> None:
        record.error = message
        try:
            self._transition(record, PluginState.FAILED, message)
        except LifecycleError:
            record.state = PluginState.FAILED
        self.audit.record(record.id, "error", message)
        self.adapter.log("error", message, plugin_id=record.id)

    def _save_state(self) -> None:
        """Persist which plugins are installed and which are enabled.

        State is a convenience, not the source of truth: the source of truth is
        the on-disk packages. A lost state file means plugins are discovered as
        installed-but-disabled, which is always recoverable.
        """
        payload = {
            "version": 1,
            "savedAt": time.time(),
            "plugins": [
                {
                    "id": record.id,
                    "version": record.version,
                    "state": record.state.value,
                    "installPath": record.install_path,
                    "metadata": record.metadata,
                }
                for record in sorted(self._records.values(), key=lambda r: r.id)
            ],
        }
        try:
            temporary = self._state_file.with_suffix(".tmp")
            temporary.write_text(
                json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8"
            )
            os.replace(temporary, self._state_file)
        except OSError as exc:
            self.adapter.log("warn", f"could not persist runtime state: {exc}")

    def restore(self, *, auto_enable: bool = False) -> list[PluginRecord]:
        """Rebuild runtime records from disk.

        Called at host startup. Every ``*.btp`` in the install root and every
        extracted package directory is inspected; corrupted entries are skipped
        with a log line rather than aborting startup.
        """
        wanted_states: dict[str, str] = {}
        if self._state_file.is_file():
            try:
                saved = json.loads(self._state_file.read_text(encoding="utf-8"))
                for entry in saved.get("plugins", []):
                    wanted_states[str(entry.get("id", ""))] = str(entry.get("state", ""))
            except (OSError, json.JSONDecodeError):
                self.adapter.log("warn", "runtime state file was unreadable; rebuilding")

        restored: list[PluginRecord] = []

        for directory in sorted(self.install_root.iterdir()):
            if not directory.is_dir() or directory.name.startswith("."):
                continue
            manifest_path = directory / "btps.json"
            if not manifest_path.is_file():
                continue
            try:
                manifest = Manifest.from_json(manifest_path.read_text(encoding="utf-8-sig"))
                sandbox = Sandbox(
                    manifest,
                    package_root=directory,
                    data_root=self.data_root / manifest.slug,
                    limits=self.limits,
                    audit=self.audit,
                )
                record = PluginRecord(
                    manifest=manifest,
                    state=PluginState.INSTALLED,
                    install_path=str(directory),
                    entry_path=str(directory / self._pick_entry(manifest)),
                    sandbox=sandbox,
                    installed_at=directory.stat().st_mtime,
                    updated_at=directory.stat().st_mtime,
                )
                self._records[manifest.id] = record
                restored.append(record)
            except BTPSError as exc:
                self.adapter.log(
                    "warn", f"skipping {directory.name}: {exc}", plugin_id=directory.name
                )

        should_enable = (
            {pid for pid, state in wanted_states.items() if state == "enabled"}
            if wanted_states
            else set()
        )
        for record in restored:
            if auto_enable or record.id in should_enable:
                try:
                    self.load(record.id)
                    self.enable(record.id)
                except BTPSError as exc:
                    self.adapter.log(
                        "error", f"could not activate {record.id}: {exc}", plugin_id=record.id
                    )

        self.adapter.log(
            "info", f"restored {len(restored)} plugin(s) from {self.install_root}"
        )
        return restored

    # ------------------------------------------------------------------ #
    # Diagnostics
    # ------------------------------------------------------------------ #

    def doctor(self) -> dict[str, Any]:
        """Health check the host can surface in its console."""
        problems: list[dict[str, Any]] = []
        for record in self.list():
            if record.state is PluginState.FAILED:
                problems.append(
                    {"pluginId": record.id, "kind": "failed", "detail": record.error}
                )
            elif record.state is PluginState.ENABLED and record.error:
                problems.append(
                    {"pluginId": record.id, "kind": "degraded", "detail": record.error}
                )
            if record.sandbox and record.sandbox.permissions.pending_consent:
                problems.append(
                    {
                        "pluginId": record.id,
                        "kind": "needs-consent",
                        "detail": ", ".join(record.sandbox.permissions.pending_consent),
                    }
                )

        denied = self.audit.entries(kind="denied")
        timeouts = self.audit.entries(kind="timeout")
        return {
            "ok": not problems,
            "problems": problems,
            "deniedCalls": len(denied),
            "timeouts": len(timeouts),
            "summary": self.summary(),
        }


def _detect_platform() -> str:
    """Map ``sys.platform`` onto the platform identifiers used in manifests."""
    if sys.platform.startswith("win"):
        return "windows"
    if sys.platform == "darwin":
        return "darwin"
    if sys.platform.startswith("linux"):
        return "linux"
    if sys.platform.startswith("freebsd"):
        return "freebsd"
    return sys.platform
