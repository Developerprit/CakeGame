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

"""BrickTile Plugin System (BTPS).

A single standard for plugin packaging and runtime, so a host platform never has
to build its own plugin system again.

Quick start
-----------
Host side — about thirty lines::

    from btps import PluginRuntime, DefaultHostAdapter

    runtime = PluginRuntime(
        adapter=DefaultHostAdapter(version="2.0.0"),
        install_root="./plugins",
    )
    runtime.restore(auto_enable=True)
    runtime.emit("host.startup")

Plugin side::

    from btps import install_context

    def btps_setup(ctx):
        install_context(ctx)
        return {"ready": True}

    def on_enable(ctx):
        ctx.log.info("enabled")

Package a plugin::

    btps pack ./my-plugin --output dist/my-plugin-1.0.0.btp

Layers
------
``L0`` format    :mod:`btps.package` — ``.btp`` container, audit, pack/extract
``L1`` resolution: :mod:`btps.manifest`, :mod:`btps.semver`, :mod:`btps.resolver`
``L2`` runtime   : :mod:`btps.runtime`, :mod:`btps.hooks`, :mod:`btps.sandbox`, :mod:`btps.api`
``L3`` host      : :mod:`btps.registry`, :mod:`btps.injector`, :mod:`btps.console`
``L4`` tooling   : :mod:`btps.cli`
"""

from __future__ import annotations

__version__ = "1.0.0"
__spec_version__ = "1.0"
__license__ = "MIT"
__author__ = "kscm (Developerprit)"

# -- L0: format ------------------------------------------------------------- #
from .errors import (
    BTPSError,
    ConflictError,
    CycleError,
    DependencyError,
    IntegrityError,
    LifecycleError,
    ManifestError,
    PackageError,
    PermissionDenied,
    SandboxError,
    SecurityViolation,
    TransportError,
    VersionError,
)

# -- L1: resolution --------------------------------------------------------- #
from .semver import Version, Range, Constraint, satisfies, max_satisfying
from .manifest import (
    Author,
    Dependency,
    HookDeclaration,
    Issue,
    Manifest,
    Severity,
    ValidationReport,
)
from .package import (
    ArchiveMember,
    AuditReport,
    BtpArchive,
    PackageInfo,
    audit_members,
    compute_digest,
    extract,
    inspect,
    open_btp,
    pack,
    sniff_container,
    stage,
    verify,
)
from .resolver import (
    Action,
    Candidate,
    ConflictDetail,
    ConstraintOrigin,
    DependencyGraph,
    InstallPlan,
    PlanStep,
    ResolutionResult,
    ResolvedNode,
    build_graph,
    detect_cycles,
    plan_sync,
    resolve,
    topological_order,
)

# -- L2: runtime ------------------------------------------------------------ #
from .api import PluginContext, build_context, current_context, install_context
from .hooks import DispatchReport, HookBus, HookContext, HookResult, Subscription
from .runtime import (
    DefaultHostAdapter,
    HostAdapter,
    LifecycleEvent,
    PluginRecord,
    PluginRuntime,
    PluginState,
    can_transition,
)
from .sandbox import (
    AuditEntry,
    AuditLog,
    KVStore,
    Limits,
    PathGuard,
    PermissionGate,
    Sandbox,
    call_with_timeout,
)

# -- L3: host integration --------------------------------------------------- #
from .injector import (
    FrameType,
    InjectFrame,
    InjectorClient,
    InjectorServer,
    InjectionTarget,
)
from .registry import HostRegistration, HostRegistry, RegistryServer, serve_registry

__all__ = [
    # meta
    "__version__",
    "__spec_version__",
    "__license__",
    "__author__",
    # errors
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
    "TransportError",
    # semver
    "Version",
    "Range",
    "Constraint",
    "satisfies",
    "max_satisfying",
    # manifest
    "Manifest",
    "Author",
    "Dependency",
    "HookDeclaration",
    "Issue",
    "Severity",
    "ValidationReport",
    # package
    "BtpArchive",
    "PackageInfo",
    "ArchiveMember",
    "AuditReport",
    "open_btp",
    "sniff_container",
    "pack",
    "verify",
    "inspect",
    "extract",
    "stage",
    "compute_digest",
    "audit_members",
    # resolver
    "Action",
    "Candidate",
    "ConflictDetail",
    "ConstraintOrigin",
    "DependencyGraph",
    "InstallPlan",
    "PlanStep",
    "ResolutionResult",
    "ResolvedNode",
    "build_graph",
    "detect_cycles",
    "topological_order",
    "resolve",
    "plan_sync",
    # runtime
    "PluginRuntime",
    "PluginRecord",
    "PluginState",
    "HostAdapter",
    "DefaultHostAdapter",
    "LifecycleEvent",
    "can_transition",
    # hooks
    "HookBus",
    "HookContext",
    "HookResult",
    "DispatchReport",
    "Subscription",
    # sandbox
    "Sandbox",
    "PathGuard",
    "PermissionGate",
    "KVStore",
    "Limits",
    "AuditLog",
    "AuditEntry",
    "call_with_timeout",
    # api
    "PluginContext",
    "build_context",
    "install_context",
    "current_context",
    # host integration
    "HostRegistry",
    "HostRegistration",
    "RegistryServer",
    "serve_registry",
    "InjectorServer",
    "InjectorClient",
    "InjectFrame",
    "FrameType",
    "InjectionTarget",
]


def __getattr__(name: str):
    """Lazily expose the console module.

    Importing it eagerly would pull in ``http.server`` for every consumer,
    including plugins that only ever touch the API surface. Deferring keeps
    ``import btps`` cheap.
    """
    if name in ("ConsoleServer", "serve_console", "DEFAULT_CONSOLE_PORT"):
        from . import console as _console

        return getattr(_console, name)
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
