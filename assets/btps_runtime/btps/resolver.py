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

"""Dependency resolution, version unification, and install planning.

This module is **pure**: it receives candidate packages and already-installed
packages, and returns an :class:`InstallPlan`. It performs no IO, reads no
files, and mutates no state. That property is what makes the hard part —
version conflict resolution — exhaustively testable.

Algorithm
---------
1. **Collect** every reachable package id by walking ``dependencies`` from the
   requested roots. Optional dependencies are followed opportunistically: if a
   satisfying version exists it is included, otherwise the edge is dropped and
   recorded in ``skipped_optional``.
2. **Unify** constraints per package id: intersect every constraint imposed by
   every requester (the classic "single version per id" rule, npm/Cargo style).
   An empty intersection is a conflict, reported with the full requester chain
   so the user knows *who* to blame — not just that a conflict exists.
3. **Concatenate** mandatory edges only, then **detect cycles** across the
   resulting id graph.
4. **Order** the surviving nodes topologically so dependencies are installed
   before their dependents. Sibling order is lexicographic, so plans are
   deterministic across runs.
5. **Diff** against the installed set to classify each action as
   ``INSTALL`` / ``UPGRADE`` / ``DOWNGRADE`` / ``KEEP`` / ``UNINSTALL``.

Conflict messages
-----------------
A bare "no version satisfies" is useless. Every :class:`ConflictError` carries
``constraints`` (with the requesting plugin id and its requested version) and
``paths`` (the chains that led to each requester), so the CLI can print:

    com.example.util: constraints are incompatible
      - >=2.0.0 <3.0.0   required by com.acme.renderer@1.4.0
          com.acme.renderer ← com.app.main
      - >=1.5.0 <2.0.0   required by com.acme.legacy@0.9.0
          com.acme.legacy ← com.app.main
"""

from __future__ import annotations

import itertools
from collections import deque
from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Iterable, Mapping, Sequence

from .errors import ConflictError, CycleError, DependencyError
from .manifest import Dependency, Manifest
from .semver import Range, Version, intersect, max_satisfying, parse_constraint, satisfies

__all__ = [
    "Action",
    "ResolvedNode",
    "ConflictDetail",
    "InstallPlan",
    "Candidate",
    "ResolutionResult",
    "DependencyGraph",
    "build_graph",
    "detect_cycles",
    "topological_order",
    "resolve",
    "plan_sync",
]


# --------------------------------------------------------------------------- #
# Records
# --------------------------------------------------------------------------- #


class Action(str, Enum):
    """What the runtime should do with one package."""

    INSTALL = "install"
    UPGRADE = "upgrade"
    DOWNGRADE = "downgrade"
    REPAIR = "repair"  # same version, but the on-disk copy is damaged
    KEEP = "keep"
    UNINSTALL = "uninstall"

    @property
    def mutates(self) -> bool:
        return self in (
            Action.INSTALL,
            Action.UPGRADE,
            Action.DOWNGRADE,
            Action.REPAIR,
            Action.UNINSTALL,
        )


@dataclass(frozen=True)
class Candidate:
    """A package version available for resolution."""

    manifest: Manifest
    source: str = ""
    installed: bool = False

    @property
    def id(self) -> str:
        return self.manifest.id

    @property
    def version(self) -> Version:
        return self.manifest.version

    def __str__(self) -> str:
        return f"{self.id}@{self.version}"


@dataclass(frozen=True)
class ConstraintOrigin:
    """Who imposed a constraint, and via which chain."""

    requester_id: str
    requester_version: str
    constraint: str
    path: tuple[str, ...] = ()

    def to_dict(self) -> dict[str, Any]:
        return {
            "requester": f"{self.requester_id}@{self.requester_version}",
            "constraint": self.constraint,
            "path": list(self.path),
        }

    def render(self) -> str:
        chain = " ← ".join(reversed(self.path)) if self.path else self.requester_id
        return f"{self.constraint:<16} required by {self.requester_id}@{self.requester_version}\n        {chain}"


@dataclass
class ConflictDetail:
    """A package whose constraints cannot be satisfied simultaneously."""

    package_id: str
    origins: list[ConstraintOrigin] = field(default_factory=list)
    available: list[str] = field(default_factory=list)

    def render(self) -> str:
        lines = [f"{self.package_id}: constraints are incompatible"]
        for origin in self.origins:
            lines.append(f"  - {origin.render()}")
        if self.available:
            preview = ", ".join(self.available[:8])
            if len(self.available) > 8:
                preview += ", …"
            lines.append(f"    available versions: {preview}")
        else:
            lines.append("    no version of this package is available")
        return "\n".join(lines)

    def to_dict(self) -> dict[str, Any]:
        return {
            "packageId": self.package_id,
            "origins": [o.to_dict() for o in self.origins],
            "available": list(self.available),
        }


@dataclass(frozen=True)
class ResolvedNode:
    """One package pinned to a concrete version by the resolver."""

    package_id: str
    version: Version
    candidate: Candidate
    related: tuple[ConstraintOrigin, ...] = ()
    optional: bool = False

    @property
    def manifest(self) -> Manifest:
        return self.candidate.manifest

    def to_dict(self) -> dict[str, Any]:
        return {
            "id": self.package_id,
            "version": str(self.version),
            "source": self.candidate.source,
            "optional": self.optional,
            "requestedBy": [o.to_dict() for o in self.related],
        }

    def __str__(self) -> str:
        return f"{self.package_id}@{self.version}"


@dataclass
class PlanStep:
    """A single unit of work in an install plan."""

    action: Action
    node: ResolvedNode
    previous_version: str = ""
    reason: str = ""

    def to_dict(self) -> dict[str, Any]:
        return {
            "action": self.action.value,
            "id": self.node.package_id,
            "version": str(self.node.version),
            "previousVersion": self.previous_version,
            "reason": self.reason,
        }

    def __str__(self) -> str:
        if self.previous_version:
            return f"{self.action.value:<9} {self.node.package_id} {self.previous_version} → {self.node.version}"
        return f"{self.action.value:<9} {self.node.package_id} {self.node.version}"


@dataclass
class InstallPlan:
    """The complete, ordered result of resolution."""

    steps: list[PlanStep] = field(default_factory=list)
    skipped_optional: list[tuple[str, str]] = field(default_factory=list)
    conflicts: list[ConflictDetail] = field(default_factory=list)
    order: list[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return not self.conflicts

    @property
    def mutating(self) -> list[PlanStep]:
        return [s for s in self.steps if s.action.mutates]

    @property
    def installs(self) -> list[PlanStep]:
        return [s for s in self.steps if s.action is Action.INSTALL]

    @property
    def removals(self) -> list[PlanStep]:
        return [s for s in self.steps if s.action is Action.UNINSTALL]

    def raise_if_conflicted(self) -> None:
        if not self.conflicts:
            return
        rendered = "\n".join(detail.render() for detail in self.conflicts)
        first = self.conflicts[0]
        raise ConflictError(
            f"{len(self.conflicts)} package(s) could not be resolved:\n{rendered}",
            package_id=first.package_id,
            constraints=[o.to_dict() for o in first.origins],
            paths=[list(o.path) for o in first.origins],
            conflicts=[d.to_dict() for d in self.conflicts],
        )

    def to_dict(self) -> dict[str, Any]:
        return {
            "ok": self.ok,
            "order": list(self.order),
            "steps": [s.to_dict() for s in self.steps],
            "skippedOptional": [
                {"id": pid, "constraint": constraint}
                for pid, constraint in self.skipped_optional
            ],
            "conflicts": [c.to_dict() for c in self.conflicts],
        }

    def render(self) -> str:
        if not self.steps and not self.conflicts:
            return "nothing to do"
        lines = [str(step) for step in self.steps]
        for package_id, constraint in self.skipped_optional:
            lines.append(f"skip      {package_id} {constraint} (optional, unavailable)")
        for detail in self.conflicts:
            lines.append(detail.render())
        return "\n".join(lines)


@dataclass
class ResolutionResult:
    """Outcome of :func:`resolve`: the plan plus diagnostic detail."""

    plan: InstallPlan
    graph: "DependencyGraph"
    candidates: dict[str, list[Candidate]] = field(default_factory=dict)
    roots: tuple[str, ...] = ()

    @property
    def ok(self) -> bool:
        return self.plan.ok

    def to_dict(self) -> dict[str, Any]:
        return {
            "ok": self.ok,
            "roots": list(self.roots),
            "plan": self.plan.to_dict(),
            "graph": self.graph.to_dict(),
        }


# --------------------------------------------------------------------------- #
# Graph
# --------------------------------------------------------------------------- #


@dataclass
class DependencyGraph:
    """A directed graph over package ids with edge annotations.

    Edges point from a *dependent* to its *dependency*. ``metadata`` records the
    constraint and origin for each edge, which is what powers conflict reports.
    """

    nodes: dict[str, Manifest] = field(default_factory=dict)
    #: adjacency: id -> {dependency_id: [ConstraintOrigin, ...]}
    edges: dict[str, dict[str, list[ConstraintOrigin]]] = field(default_factory=dict)
    #: optional edges, kept separate so cycle detection can ignore them
    optional_edges: dict[str, dict[str, list[ConstraintOrigin]]] = field(default_factory=dict)
    roots: tuple[str, ...] = ()

    def add_node(self, manifest: Manifest) -> None:
        self.nodes.setdefault(manifest.id, manifest)
        self.edges.setdefault(manifest.id, {})
        self.optional_edges.setdefault(manifest.id, {})

    def add_edge(
        self,
        source_id: str,
        target_id: str,
        origin: ConstraintOrigin,
        *,
        optional: bool = False,
    ) -> None:
        bucket = self.optional_edges if optional else self.edges
        self.edges.setdefault(source_id, {})
        bucket.setdefault(source_id, {}).setdefault(target_id, []).append(origin)

    def dependents_of(self, package_id: str) -> list[str]:
        """Ids that depend on ``package_id`` (reverse edges), mandatory only."""
        return sorted(
            source
            for source, targets in self.edges.items()
            if package_id in targets
        )

    def dependencies_of(self, package_id: str) -> list[str]:
        bucket = self.edges.get(package_id, {})
        return sorted(bucket.keys())

    def constraints_on(self, package_id: str) -> list[ConstraintOrigin]:
        collected: list[ConstraintOrigin] = []
        for targets in self.edges.values():
            collected.extend(targets.get(package_id, ()))
        for targets in self.optional_edges.values():
            collected.extend(targets.get(package_id, ()))
        return collected

    def all_edges(self, *, include_optional: bool = True) -> list[tuple[str, str]]:
        pairs: list[tuple[str, str]] = []
        for source, targets in self.edges.items():
            pairs.extend((source, target) for target in targets)
        if include_optional:
            for source, targets in self.optional_edges.items():
                pairs.extend((source, target) for target in targets)
        return pairs

    def to_dict(self) -> dict[str, Any]:
        return {
            "nodes": sorted(self.nodes),
            "roots": list(self.roots),
            "edges": [
                {"from": source, "to": target}
                for source, target in sorted(set(self.all_edges()))
            ],
        }

    def render(self) -> str:
        lines: list[str] = []
        for source in sorted(self.edges):
            targets = self.edges[source]
            if not targets:
                continue
            lines.append(f"{source}")
            for target in sorted(targets):
                for origin in targets[target]:
                    lines.append(f"  └─ {target} {origin.constraint}")
        return "\n".join(lines) if lines else "(empty graph)"


def build_graph(
    manifests: Mapping[str, Manifest] | Iterable[Manifest],
    *,
    roots: Sequence[str] | None = None,
    follow_optional: bool = True,
) -> DependencyGraph:
    """Build a graph from a pool of known manifests.

    Edges are only created for dependencies that exist in the pool. Missing
    dependencies are simply absent from the graph; :func:`resolve` reports them
    as conflicts with origin detail.
    """
    pool: dict[str, Manifest] = {}
    if isinstance(manifests, Mapping):
        pool.update(manifests)
    else:
        for manifest in manifests:
            pool[manifest.id] = manifest

    graph = DependencyGraph()
    for manifest in pool.values():
        graph.add_node(manifest)

    graph.roots = tuple(roots) if roots else tuple(sorted(pool))

    for manifest in pool.values():
        for dependency in manifest.dependencies:
            if dependency.package_id not in pool:
                continue
            origin = ConstraintOrigin(
                requester_id=manifest.id,
                requester_version=manifest.version_string,
                constraint=dependency.constraint,
                path=(manifest.id, dependency.package_id),
            )
            graph.add_edge(manifest.id, dependency.package_id, origin)
        if follow_optional:
            for dependency in manifest.optional_dependencies:
                if dependency.package_id not in pool:
                    continue
                origin = ConstraintOrigin(
                    requester_id=manifest.id,
                    requester_version=manifest.version_string,
                    constraint=dependency.constraint,
                    path=(manifest.id, dependency.package_id),
                )
                graph.add_edge(
                    manifest.id, dependency.package_id, origin, optional=True
                )
    return graph


def detect_cycles(graph: DependencyGraph, *, include_optional: bool = False) -> list[list[str]]:
    """Find dependency cycles via iterative Tarjan SCC.

    Returns one list per cycle, each rotated to start at its lexicographically
    smallest member so reports are stable. Self-loops count as cycles.
    """
    nodes = sorted(graph.nodes)
    index_of: dict[str, int] = {}
    lowlink: dict[str, int] = {}
    on_stack: set[str] = set()
    stack: list[str] = []
    counter = itertools.count()
    cycles: list[list[str]] = []

    def neighbours(node: str) -> list[str]:
        bucket = graph.edges.get(node, {})
        out = list(bucket.keys())
        if include_optional:
            out.extend(graph.optional_edges.get(node, {}).keys())
        return out

    for start in nodes:
        if start in index_of:
            continue
        # Explicit work stack: (node, iterator over neighbours)
        work: list[tuple[str, list[str], int]] = [(start, neighbours(start), 0)]
        index_of[start] = next(counter)
        lowlink[start] = index_of[start]
        stack.append(start)
        on_stack.add(start)

        while work:
            node, nbrs, position = work[-1]
            if position < len(nbrs):
                work[-1] = (node, nbrs, position + 1)
                neighbour = nbrs[position]
                if neighbour not in index_of:
                    index_of[neighbour] = next(counter)
                    lowlink[neighbour] = index_of[neighbour]
                    stack.append(neighbour)
                    on_stack.add(neighbour)
                    work.append((neighbour, neighbours(neighbour), 0))
                elif neighbour in on_stack:
                    lowlink[node] = min(lowlink[node], index_of[neighbour])
                continue

            work.pop()
            if work:
                parent = work[-1][0]
                lowlink[parent] = min(lowlink[parent], lowlink[node])

            if lowlink[node] == index_of[node]:
                component: list[str] = []
                while True:
                    member = stack.pop()
                    on_stack.discard(member)
                    component.append(member)
                    if member == node:
                        break
                if len(component) > 1:
                    cycles.append(_rotate(component))
                elif any(node in neighbours(node) for _ in [0]):
                    cycles.append(component)  # self-loop

    cycles.sort()
    return cycles


def _rotate(component: Sequence[str]) -> list[str]:
    ordered = sorted(component)
    smallest = ordered[0]
    index = list(component).index(smallest)
    rotated = list(component[index:]) + list(component[:index])
    return rotated


def topological_order(
    graph: DependencyGraph,
    *,
    subset: Iterable[str] | None = None,
) -> list[str]:
    """Order ids so that every dependency precedes its dependents.

    Deterministic: ties are broken lexicographically. Raises
    :class:`~btps.errors.CycleError` when a cycle is present.
    """
    included = set(subset) if subset is not None else set(graph.nodes)
    in_degree: dict[str, int] = {node: 0 for node in included}
    dependents: dict[str, set[str]] = {node: set() for node in included}

    for source in inclusive_sorted(included):
        for target in graph.edges.get(source, {}):
            if target not in included:
                continue
            # Edge source → target means source depends on target, so target
            # must come first: increment the source's in-degree.
            in_degree[source] = in_degree.get(source, 0) + 1
            dependents.setdefault(target, set()).add(source)

    ready = deque(sorted(node for node, degree in in_degree.items() if degree == 0))
    order: list[str] = []
    while ready:
        node = ready.popleft()
        order.append(node)
        for dependent in sorted(dependents.get(node, ())):
            in_degree[dependent] -= 1
            if in_degree[dependent] == 0:
                ready.append(dependent)
        # Keep the queue sorted so the result never depends on insertion luck.
        ready = deque(sorted(ready))

    if len(order) != len(included):
        remaining = sorted(included - set(order))
        cycles = detect_cycles(graph)
        raise CycleError(
            f"dependency cycle detected among: {', '.join(sorted(cycle[0] for cycle in cycles)) or ', '.join(remaining)}",
            remaining=remaining,
            cycles=cycles,
        )
    return order


def inclusive_sorted(items: Iterable[str]) -> list[str]:
    """``sorted`` that tolerates a set input without losing determinism."""
    return sorted(set(items))


# --------------------------------------------------------------------------- #
# Resolution
# --------------------------------------------------------------------------- #


def resolve(
    candidates: Iterable[Candidate],
    *,
    roots: Sequence[str] = (),
    installed: Mapping[str, str] | None = None,
    require_roots: bool = True,
    allow_prerelease: bool = False,
    dropped: Iterable[str] = (),
) -> ResolutionResult:
    """Resolve a set of candidates into an :class:`InstallPlan`.

    Parameters
    ----------
    candidates:
        Every package version the caller can reach. Multiple versions of the
        same id are expected — unification picks one.
    roots:
        Package ids the user explicitly asked for. When empty, the roots are
        inferred as candidates nothing else depends on.
    installed:
        Mapping of ``id -> version`` currently on disk. Drives the
        INSTALL/UPGRADE/DOWNGRADE/KEEP classification and the removal of
        packages that are no longer required.
    require_roots:
        When true, a requested root with no available candidate is a conflict.
    allow_prerelease:
        Permit pre-release versions to satisfy constraints.
    dropped:
        Previously installed ids the caller has already decided to remove.
    """
    pool: dict[str, list[Candidate]] = {}
    for candidate in candidates:
        pool.setdefault(candidate.id, []).append(candidate)
    for versions in pool.values():
        versions.sort(key=lambda c: c.version, reverse=True)

    installed_map = dict(installed or {})

    # -- 1. Determine roots ------------------------------------------------- #
    if not roots:
        depended: set[str] = set()
        for versions in pool.values():
            for candidate in versions:
                for dependency in candidate.manifest.all_dependencies:
                    depended.add(dependency.package_id)
        roots = tuple(sorted(set(pool) - depended))
    root_ids = tuple(roots)

    # -- 2. Walk the graph, collecting constraints -------------------------- #
    # constraint_map: id -> list[ConstraintOrigin]
    constraint_map: dict[str, list[ConstraintOrigin]] = {}
    reachable: set[str] = set()
    skipped_optional: list[tuple[str, str]] = []

    # Resolve a single id against everything known about it so far.
    def choose(package_id: str, origins: list[ConstraintOrigin]) -> Candidate | None:
        """Highest candidate satisfying every constraint seen so far.

        An empty constraint set means "no requirement was imposed" — for a root
        that is the user themselves, and for an optional dependency it is the
        default policy. Returning ``None`` there would silently drop the package
        from the plan, so we deliberately fall through to "any version".
        """
        return resolve_once(pool, origins, allow_prerelease, package_id=package_id)

    conflict_details: list[ConflictDetail] = []
    # Roots the caller demanded but that are absent from the pool. Tracked
    # separately because "no candidate exists" is only an error when the caller
    # said the root was required.
    conflict_ids_forced: set[str] = set()
    resolved: dict[str, ResolvedNode] = {}
    visiting: set[str] = set()

    def visit(package_id: str, origin: ConstraintOrigin | None, chain: tuple[str, ...], optional: bool) -> None:
        """Depth-first walk that unifies constraints as it goes.

        Re-visiting a node re-checks it against the newly discovered constraint;
        when the pinned version no longer satisfies, the node is re-resolved.
        """
        if origin is not None:
            constraint_map.setdefault(package_id, []).append(origin)

        origins = constraint_map.setdefault(package_id, [])
        versions = pool.get(package_id, [])

        if not versions:
            # Leave the node unresolved; conflict reporting happens below.
            return

        chosen = choose(package_id, origins)
        if chosen is None:
            return

        previous = resolved.get(package_id)
        if previous is not None and previous.version == chosen.version:
            return  # nothing changed, stop recursing

        resolved[package_id] = ResolvedNode(
            package_id=package_id,
            version=chosen.version,
            candidate=chosen,
            related=tuple(origins),
            optional=optional,
        )
        reachable.add(package_id)

        if package_id in visiting:
            return  # cycle guard; detect_cycles reports it properly afterwards
        visiting.add(package_id)
        try:
            for dependency in chosen.manifest.dependencies:
                child_chain = (*chain, dependency.package_id)
                visit(
                    dependency.package_id,
                    ConstraintOrigin(
                        requester_id=chosen.id,
                        requester_version=str(chosen.version),
                        constraint=dependency.constraint,
                        path=child_chain,
                    ),
                    child_chain,
                    optional,
                )
        finally:
            visiting.discard(package_id)

    for root in root_ids:
        if root not in pool and require_roots:
            # Record the unsatisfiable root so the conflict reporter can name
            # it. ``require_roots=False`` means "this root is optional too" —
            # the caller is asking "install it if you can, say nothing if you
            # cannot", so a missing root must not surface as a conflict.
            constraint_map.setdefault(root, [])
            conflict_ids_forced.add(root)
            continue
        visit(root, None, (root,), False)

    # Optional dependencies are attempted after the mandatory closure is stable.
    for package_id in sorted(list(resolved)):
        node = resolved.get(package_id)
        if node is None:
            continue
        for dependency in node.manifest.optional_dependencies:
            if dependency.package_id in resolved:
                continue
            if dependency.package_id not in pool:
                skipped_optional.append((dependency.package_id, dependency.constraint))
                continue
            origin = ConstraintOrigin(
                requester_id=node.package_id,
                requester_version=node.version,
                constraint=dependency.constraint,
                path=(node.package_id, dependency.package_id),
            )
            visit(dependency.package_id, origin, (node.package_id, dependency.package_id), True)
            if dependency.package_id not in resolved:
                skipped_optional.append((dependency.package_id, dependency.constraint))

    # -- 3. Report conflicts ------------------------------------------------ #
    # A package is conflicted when it was required by somebody but no version
    # satisfies the unified constraint set — or when the pool has no entry.
    all_required: set[str] = set(constraint_map) | set(root_ids) | set(resolved)
    for package_id in sorted(all_required):
        origins = constraint_map.get(package_id, [])
        if not origins and package_id not in root_ids:
            continue
        # An absent root the caller did not insist on is simply "not available";
        # reporting it as a conflict would make require_roots=False useless.
        if package_id in root_ids and package_id not in pool:
            if package_id in conflict_ids_forced:
                conflict_details.append(
                    ConflictDetail(package_id=package_id, origins=list(origins), available=[])
                )
            continue
        chosen = resolve_once(pool, origins, allow_prerelease, package_id=package_id)
        if chosen is not None:
            continue
        versions = pool.get(package_id, [])
        conflict_details.append(
            ConflictDetail(
                package_id=package_id,
                origins=list(origins),
                available=[str(c.version) for c in versions],
            )
        )
        resolved.pop(package_id, None)
        reachable.discard(package_id)

    # -- 3b. Declared mutual exclusions ------------------------------------- #
    # The ``conflicts`` map in a manifest is a *hard* statement of intent: this
    # plugin refuses to coexist with those. It is checked against the resolved
    # set rather than during the walk because a conflict is a property of the
    # final selection, not of any single dependency edge — and because ignoring
    # it would let two mutually exclusive plugins load in one host and corrupt
    # each other's state at runtime.
    for package_id in sorted(list(resolved)):
        node = resolved.get(package_id)
        if node is None:
            continue  # already removed by an earlier conflict rule
        for other_id, constraint in node.manifest.conflicts.items():
            other = resolved.get(other_id)
            if other is None:
                continue
            if not satisfies(str(other.version), constraint):
                continue
            conflict_details.append(
                ConflictDetail(
                    package_id=package_id,
                    origins=[
                        ConstraintOrigin(
                            requester_id=package_id,
                            requester_version=str(node.version),
                            constraint=constraint,
                            path=(package_id, other_id),
                        )
                    ],
                    available=[str(other.version)],
                )
            )
            resolved.pop(other_id, None)
            reachable.discard(other_id)

    # -- 4. Conflict and cycle detection on the resolved set ---------------- #
    conflict_ids = {d.package_id for d in conflict_details}

    graph = DependencyGraph()
    for package_id, node in resolved.items():
        graph.add_node(node.manifest)
    graph.roots = root_ids

    for source_id, node in resolved.items():
        if source_id in conflict_ids:
            continue
        for dependency in node.manifest.dependencies:
            if dependency.package_id not in resolved:
                continue
            if dependency.package_id in conflict_ids:
                continue
            origin = ConstraintOrigin(
                requester_id=source_id,
                requester_version=node.version,
                constraint=dependency.constraint,
                path=(source_id, dependency.package_id),
            )
            graph.add_edge(source_id, dependency.package_id, origin)

    plan = InstallPlan(conflicts=conflict_details, skipped_optional=sorted(set(skipped_optional)))

    if conflict_details:
        # Order what we *can* order, for useful partial reporting.
        try:
            partial = topological_order(graph)
        except CycleError:
            partial = sorted(resolved)
        plan.order = partial
        return ResolutionResult(
            plan=plan, graph=graph, candidates=pool, roots=root_ids
        )

    cycles = detect_cycles(graph)
    if cycles:
        rendered = "; ".join(" → ".join(cycle) for cycle in cycles)
        raise CycleError(
            f"dependency cycles are not supported: {rendered}",
            cycles=cycles,
        )

    order = topological_order(graph)
    plan.order = order

    for package_id in order:
        node = resolved[package_id]
        current = installed_map.get(package_id)

        if current is None:
            action = Action.INSTALL
            reason = "not installed"
        else:
            try:
                current_version = Version.parse(current, loose=True)
            except Exception:
                current_version = None
            if current_version is None:
                action = Action.REPAIR
                reason = f"unreadable installed version {current!r}"
            elif current_version < node.version:
                action = Action.UPGRADE
                reason = f"newer version available than {current}"
            elif current_version > node.version:
                action = Action.DOWNGRADE
                reason = f"pinned to a version older than {current}"
            else:
                action = Action.KEEP
                reason = "already at the resolved version"

        plan.steps.append(
            PlanStep(
                action=action,
                node=node,
                previous_version=current or "",
                reason=reason,
            )
        )

    # Anything installed that is absent from the resolution is an orphan: the
    # host has it on disk but nothing asks for it any more. ``dropped`` names
    # the ids the caller has *already decided* to remove, so those are reported
    # as removals too rather than silently left behind.
    for package_id in sorted(set(installed_map) - set(resolved)):
        plan.steps.append(
            PlanStep(
                action=Action.UNINSTALL,
                node=ResolvedNode(
                    package_id=package_id,
                    version=Version.parse(installed_map[package_id], loose=True),
                    candidate=Candidate(
                        manifest=_orphan_manifest(package_id, installed_map[package_id]),
                        installed=True,
                    ),
                ),
                previous_version=installed_map[package_id],
                reason="no longer required by any installed package",
            )
        )

    return ResolutionResult(
        plan=plan, graph=graph, candidates=pool, roots=root_ids
    )


def resolve_once(
    pool: Mapping[str, Sequence[Candidate]],
    origins: Sequence[ConstraintOrigin],
    allow_prerelease: bool,
    *,
    package_id: str = "",
) -> Candidate | None:
    """Re-evaluate one package against a constraint set. Shared by the walker
    and the conflict reporter so both agree on what "satisfiable" means.

    ``package_id`` is authoritative when supplied. Deriving the id from
    ``origins[0]`` alone silently returned ``None`` whenever a package was
    requested with *no* constraints at all — which is exactly the case for
    every root, since the user's own request imposes no constraint. That turned
    "install this package" into a phantom conflict.
    """
    target = package_id or (origins[0].package_id if origins else "")
    versions = pool.get(target, [])
    if not versions:
        return None

    combined: Range | None = None
    for origin in origins:
        try:
            single = parse_constraint(origin.constraint)
        except Exception:
            continue
        combined = single if combined is None else intersect(combined, single)

    if combined is None:
        # No usable constraints: every version in the pool satisfies, so pick
        # the highest (respecting the pre-release policy).
        best = max_satisfying(
            [c.version for c in versions],
            Range.any(),
            include_prerelease=allow_prerelease,
        )
    else:
        best = max_satisfying(
            [c.version for c in versions], combined, include_prerelease=allow_prerelease
        )
    if best is None:
        return None
    for candidate in versions:
        if candidate.version == best:
            return candidate
    return None  # pragma: no cover


def _orphan_manifest(package_id: str, version: str) -> Manifest:
    """Synthesise a minimal manifest so orphans can travel through the plan."""
    from .manifest import Author

    try:
        parsed = Version.parse(version, loose=True)
    except Exception:
        parsed = Version(0, 0, 0)
    return Manifest(
        manifest_version=1,
        id=package_id,
        name=package_id,
        version=parsed,
        author=Author(name="unknown"),
    )


def plan_sync(
    candidates: Iterable[Candidate],
    installed: Mapping[str, str],
    *,
    roots: Sequence[str] = (),
    prune: bool = True,
    allow_prerelease: bool = False,
) -> InstallPlan:
    """Convenience wrapper: resolve and, when ``prune`` is false, drop all
    UNINSTALL steps so the plan only adds and updates."""
    result = resolve(
        candidates,
        roots=roots,
        installed=installed,
        allow_prerelease=allow_prerelease,
    )
    if not prune:
        result.plan.steps = [s for s in result.plan.steps if s.action is not Action.UNINSTALL]
    return result.plan
