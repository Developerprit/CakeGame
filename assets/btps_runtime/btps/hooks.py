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

"""Event hook bus: declaration-driven subscription, ordering, and isolation.

Design rules
------------
**Declared or rejected.** A plugin may only receive hooks it declared in
``btps.json``. Registration of an undeclared hook raises
:class:`~btps.errors.HookError`. This is not bureaucracy — it is what lets a
user read a manifest and know exactly what a plugin will do.

**Deterministic ordering.** Handlers run by ascending ``priority``, ties broken
by plugin id. Two identical installations always produce identical ordering, so
bugs reproduce.

**Isolation.** A failing handler never prevents other plugins from running and
never propagates into the host's own control flow. Failures are collected and
returned; the audit log keeps the detail.

**Interruption.** A handler returning ``False`` signals "stop the chain" — the
host decided the remaining handlers must not see this event (for example, a
``host.shutdown`` veto or a request already handled). This is distinct from an
exception, which only aborts that one handler.
"""

from __future__ import annotations

import inspect
import time
from dataclasses import dataclass, field
from typing import Any, Callable, Iterable, Iterator, Mapping, Sequence

from .errors import HookError, SandboxError
from .manifest import HookDeclaration, Manifest
from .sandbox import AuditLog, Limits, call_with_timeout

__all__ = [
    "HookContext",
    "HookResult",
    "DispatchReport",
    "Subscription",
    "HookBus",
]


@dataclass
class HookContext:
    """Mutable per-dispatch state passed to every handler.

    Handlers may read ``data`` and write to ``shared`` to communicate with later
    handlers. ``cancel()`` is the programmatic equivalent of returning ``False``
    and is preferred when the reason needs explaining.
    """

    hook: str
    data: dict[str, Any] = field(default_factory=dict)
    shared: dict[str, Any] = field(default_factory=dict)
    plugin_id: str = ""
    cancelled: bool = False
    cancel_reason: str = ""
    started_at: float = field(default_factory=time.time)

    def cancel(self, reason: str = "") -> None:
        """Stop the dispatch chain after the current handler returns."""
        self.cancelled = True
        self.cancel_reason = reason

    @property
    def elapsed(self) -> float:
        return time.time() - self.started_at

    def to_dict(self) -> dict[str, Any]:
        return {
            "hook": self.hook,
            "data": self.data,
            "shared": self.shared,
            "cancelled": self.cancelled,
            "cancelReason": self.cancel_reason,
        }


@dataclass(frozen=True)
class HookResult:
    """Outcome of one handler invocation."""

    plugin_id: str
    hook: str
    ok: bool
    returned: Any = None
    error: str = ""
    error_type: str = ""
    duration: float = 0.0
    cancelled: bool = False

    def to_dict(self) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "pluginId": self.plugin_id,
            "hook": self.hook,
            "ok": self.ok,
            "duration": round(self.duration, 4),
        }
        if self.cancelled:
            payload["cancelled"] = True
        if not self.ok:
            payload["error"] = self.error
            payload["errorType"] = self.error_type
        return payload

    def __str__(self) -> str:
        status = "ok" if self.ok else f"FAILED ({self.error_type})"
        return f"{self.plugin_id} {self.hook}: {status} in {self.duration * 1000:.1f}ms"


@dataclass
class DispatchReport:
    """Aggregate outcome of dispatching one hook to every subscriber."""

    hook: str
    results: list[HookResult] = field(default_factory=list)
    cancelled: bool = False
    cancel_reason: str = ""
    duration: float = 0.0

    @property
    def ok(self) -> bool:
        return all(r.ok for r in self.results)

    @property
    def failures(self) -> list[HookResult]:
        return [r for r in self.results if not r.ok]

    @property
    def successful(self) -> list[HookResult]:
        return [r for r in self.results if r.ok]

    def values(self) -> list[Any]:
        return [r.returned for r in self.results if r.ok]

    def to_dict(self) -> dict[str, Any]:
        return {
            "hook": self.hook,
            "ok": self.ok,
            "cancelled": self.cancelled,
            "cancelReason": self.cancel_reason,
            "duration": round(self.duration, 4),
            "results": [r.to_dict() for r in self.results],
        }

    def render(self) -> str:
        lines = [f"{self.hook} ({len(self.results)} handler(s), {self.duration * 1000:.1f}ms)"]
        for result in self.results:
            marker = "✓" if result.ok else "✗"
            lines.append(f"  {marker} {result}")
            if not result.ok:
                lines.append(f"      {result.error}")
        if self.cancelled:
            lines.append(f"  ⚠ chain cancelled: {self.cancel_reason or 'no reason given'}")
        return "\n".join(lines)


class Subscription:
    """A registered handler for one hook."""

    __slots__ = (
        "plugin_id",
        "hook",
        "handler",
        "priority",
        "continue_on_error",
        "declaration",
        "plugin_context",
    )

    def __init__(
        self,
        plugin_id: str,
        hook: str,
        handler: Callable[..., Any],
        priority: int = 100,
        continue_on_error: bool = False,
        declaration: HookDeclaration | None = None,
        plugin_context: Any = None,
    ) -> None:
        self.plugin_id = plugin_id
        self.hook = hook
        self.handler = handler
        self.priority = priority
        self.continue_on_error = continue_on_error
        self.declaration = declaration
        #: The plugin's runtime context. Handlers that declare a parameter
        #: receive *this*, not the internal :class:`HookContext`, because a
        #: plugin author expects ``ctx.storage`` — not host bookkeeping.
        self.plugin_context = plugin_context

    @property
    def sort_key(self) -> tuple[int, str]:
        return (self.priority, self.plugin_id)

    def accepts_argument(self) -> bool:
        """Whether the handler wants a single positional argument."""
        try:
            signature = inspect.signature(self.handler)
        except (TypeError, ValueError):
            return False
        for parameter in signature.parameters.values():
            if parameter.kind == parameter.VAR_POSITIONAL:
                return True
            if parameter.kind in (
                parameter.POSITIONAL_ONLY,
                parameter.POSITIONAL_OR_KEYWORD,
            ):
                return True
        return False

    # Backwards-compatible alias for callers written against the first draft.
    accepts_context = accepts_argument

    def __repr__(self) -> str:  # pragma: no cover - debug aid
        return f"<Subscription {self.plugin_id}:{self.hook} p={self.priority}>"


class HookBus:
    """Central registry and dispatcher for plugin hooks.

    The bus is deliberately synchronous. Plugin hooks are not the place for
    concurrency: a hook that blocks already blocks the host, and hiding that
    behind a task queue would make timeouts meaningless.
    """

    def __init__(
        self,
        *,
        limits: Limits | None = None,
        audit: AuditLog | None = None,
        extra_hooks: Iterable[str] = (),
    ) -> None:
        self.limits = limits
        self.audit = audit if audit is not None else AuditLog()
        self.extra_hooks = frozenset(extra_hooks)
        self._subscriptions: dict[str, list[Subscription]] = {}
        self._plugin_hooks: dict[str, set[str]] = {}
        self._manifests: dict[str, Manifest] = {}

    # -- registration ------------------------------------------------------- #

    def register_plugin(
        self,
        manifest: Manifest,
        namespace: Mapping[str, Any],
        *,
        declared_only: bool = True,
        plugin_context: Any = None,
    ) -> list[Subscription]:
        """Bind a plugin's exported symbols to its declared hooks.

        ``namespace`` is the entry module's globals (or an equivalent dict).
        Only symbols named by the manifest are bound; a declaration pointing at
        a missing symbol raises :class:`HookError` immediately, because a
        silently missing hook is far harder to debug than a failed load.

        ``plugin_context`` is the object handed to handlers that declare a
        parameter. When omitted, the internal dispatch context is passed instead,
        which is only appropriate for host-internal subscriptions.
        """
        self._manifests[manifest.id] = manifest
        self.unregister_plugin(manifest.id)

        registered: list[Subscription] = []
        for declaration in manifest.hooks:
            if declared_only and declaration.name not in (
                set(self._subscriptions) | set(self.extra_hooks) | {d.name for d in manifest.hooks}
            ):
                # declared_only is satisfied by construction: every declaration
                # is in manifest.hooks. Kept for clarity of intent.
                pass

            handler = namespace.get(declaration.handler)
            if handler is None:
                raise HookError(
                    f"hook {declaration.name!r} declares handler "
                    f"{declaration.handler!r}, which the entry module does not export",
                    hook=declaration.name,
                    plugin_id=manifest.id,
                )
            if not callable(handler):
                raise HookError(
                    f"hook {declaration.name!r} points at {declaration.handler!r}, "
                    f"which is {type(handler).__name__}, not callable",
                    hook=declaration.name,
                    plugin_id=manifest.id,
                )

            subscription = Subscription(
                plugin_id=manifest.id,
                hook=declaration.name,
                handler=handler,
                priority=declaration.priority,
                continue_on_error=declaration.continue_on_error,
                declaration=declaration,
                plugin_context=plugin_context,
            )
            self._subscriptions.setdefault(declaration.name, []).append(subscription)
            registered.append(subscription)

        for hook in self._subscriptions:
            self._subscriptions[hook].sort(key=lambda s: s.sort_key)

        self._plugin_hooks[manifest.id] = {s.hook for s in registered}
        return registered

    def subscribe(
        self,
        plugin_id: str,
        hook: str,
        handler: Callable[..., Any],
        *,
        priority: int = 100,
        continue_on_error: bool = False,
        declared: bool = False,
    ) -> Subscription:
        """Imperative subscription for host-internal use.

        Plugin code must go through :meth:`register_plugin` so the manifest gate
        cannot be bypassed; hosts subscribing their own handlers set
        ``declared=True``.
        """
        manifest = self._manifests.get(plugin_id)
        if not declared:
            if manifest is not None and manifest.hook(hook) is None:
                raise HookError(
                    f"plugin {plugin_id!r} may not subscribe to undeclared hook {hook!r}",
                    hook=hook,
                    plugin_id=plugin_id,
                    hint="add it to the 'hooks' object in btps.json",
                )
            if manifest is None:
                raise HookError(
                    f"plugin {plugin_id!r} is not registered; call register_plugin first",
                    hook=hook,
                    plugin_id=plugin_id,
                )

        subscription = Subscription(
            plugin_id, hook, handler, priority, continue_on_error
        )
        self._subscriptions.setdefault(hook, []).append(subscription)
        self._subscriptions[hook].sort(key=lambda s: s.sort_key)
        self._plugin_hooks.setdefault(plugin_id, set()).add(hook)
        return subscription

    def unregister_plugin(self, plugin_id: str) -> int:
        """Remove every subscription belonging to ``plugin_id``."""
        removed = 0
        for hook in list(self._subscriptions):
            kept = [s for s in self._subscriptions[hook] if s.plugin_id != plugin_id]
            removed += len(self._subscriptions[hook]) - len(kept)
            if kept:
                self._subscriptions[hook] = kept
            else:
                del self._subscriptions[hook]
        self._plugin_hooks.pop(plugin_id, None)
        return removed

    # -- inspection --------------------------------------------------------- #

    def hooks(self) -> list[str]:
        return sorted(self._subscriptions)

    def subscribers(self, hook: str) -> list[Subscription]:
        return list(self._subscriptions.get(hook, ()))

    def has_subscribers(self, hook: str) -> bool:
        return bool(self._subscriptions.get(hook))

    def plugin_hooks(self, plugin_id: str) -> set[str]:
        return set(self._plugin_hooks.get(plugin_id, ()))

    def describe(self) -> dict[str, Any]:
        return {
            hook: [
                {
                    "pluginId": s.plugin_id,
                    "priority": s.priority,
                    "continueOnError": s.continue_on_error,
                }
                for s in subs
            ]
            for hook, subs in sorted(self._subscriptions.items())
        }

    # -- dispatch ----------------------------------------------------------- #

    def dispatch(
        self,
        hook: str,
        data: Mapping[str, Any] | None = None,
        *,
        timeout: float | None = None,
        stop_on_error: bool = False,
    ) -> DispatchReport:
        """Run every subscriber of ``hook`` in priority order.

        Never raises because of a handler failure. Returns a
        :class:`DispatchReport` describing what happened. Callers that need to
        fail hard should inspect ``report.ok``.
        """
        started = time.time()
        report = DispatchReport(hook=hook)
        subscriptions = self._subscriptions.get(hook)
        if not subscriptions:
            report.duration = time.time() - started
            return report

        context = HookContext(hook=hook, data=dict(data or {}))
        budget = timeout if timeout is not None else (
            self.limits.hook_timeout_seconds if self.limits else 5.0
        )

        for subscription in subscriptions:
            result = self._invoke(subscription, context, budget)
            report.results.append(result)

            if result.cancelled:
                report.cancelled = True
                report.cancel_reason = context.cancel_reason
                break

            if not result.ok:
                if stop_on_error and not subscription.continue_on_error:
                    break
                continue

        report.duration = time.time() - started
        return report

    def _invoke(
        self,
        subscription: Subscription,
        context: HookContext,
        budget: float,
    ) -> HookResult:
        context.plugin_id = subscription.plugin_id
        wants_argument = subscription.accepts_argument()
        argument = (
            subscription.plugin_context
            if subscription.plugin_context is not None
            else context
        )
        started = time.time()

        def call() -> Any:
            if wants_argument:
                return subscription.handler(argument)
            return subscription.handler()

        try:
            returned = call_with_timeout(
                call,
                budget,
                plugin_id=subscription.plugin_id,
                hook=subscription.hook,
                audit=self.audit,
            )
        except SandboxError as exc:
            return HookResult(
                plugin_id=subscription.plugin_id,
                hook=subscription.hook,
                ok=False,
                error=str(exc),
                error_type="Timeout",
                duration=time.time() - started,
            )
        except Exception as exc:  # noqa: BLE001 - isolation is the point
            if self.audit is not None:
                self.audit.record(
                    subscription.plugin_id,
                    "error",
                    f"hook {subscription.hook!r} raised {type(exc).__name__}: {exc}",
                    hook=subscription.hook,
                )
            return HookResult(
                plugin_id=subscription.plugin_id,
                hook=subscription.hook,
                ok=False,
                error=str(exc),
                error_type=type(exc).__name__,
                duration=time.time() - started,
            )

        cancelled = returned is False or context.cancelled
        if context.cancelled and not context.cancel_reason:
            context.cancel_reason = f"cancelled by {subscription.plugin_id}"

        return HookResult(
            plugin_id=subscription.plugin_id,
            hook=subscription.hook,
            ok=True,
            returned=returned,
            duration=time.time() - started,
            cancelled=cancelled,
        )

    # -- convenience -------------------------------------------------------- #

    def emit(self, hook: str, **data: Any) -> DispatchReport:
        """Shorthand for :meth:`dispatch` with keyword data."""
        return self.dispatch(hook, data)

    def first_value(self, hook: str, data: Mapping[str, Any] | None = None, default: Any = None) -> Any:
        """First non-``None`` return value — handy for `*_canHandle` style hooks."""
        for result in self.dispatch(hook, data).results:
            if result.ok and result.returned is not None:
                return result.returned
        return default

    def any_true(self, hook: str, data: Mapping[str, Any] | None = None) -> bool:
        """True when any handler returned a truthy value (veto/vote patterns)."""
        return any(bool(r.returned) for r in self.dispatch(hook, data).results if r.ok)

    def all_true(self, hook: str, data: Mapping[str, Any] | None = None) -> bool:
        """True when every handler returned truthy and none cancelled."""
        report = self.dispatch(hook, data)
        if report.cancelled:
            return False
        ordered = [r for r in report.results if r.ok]
        return bool(ordered) and all(bool(r.returned) for r in ordered)

    def __contains__(self, hook: str) -> bool:
        return hook in self._subscriptions

    def __len__(self) -> int:
        return sum(len(subs) for subs in self._subscriptions.values())
