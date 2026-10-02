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

"""Semantic versioning (SemVer 2.0.0) parsing, comparison, and constraints.

Only the standard library is used. The module is deliberately free of IO so it
can be exhaustively unit tested and reused inside the pure resolver.

Constraint syntax
-----------------
===========================  ==========================================
``1.2.3``                    exact match
``=1.2.3``                   exact match
``>1.2.3`` ``>=1.2.3``       half-open comparison
``<1.2.3`` ``<=1.2.3``       half-open comparison
``^1.2.3``                   compatible-with (>=1.2.3, <2.0.0)
``~1.2.3``                   approximately (>=1.2.3, <1.3.0)
``1.2.*``                    wildcard
``*`` / ``latest``           any version
``>=1.2.3 <2.0.0``           space separated AND
``^1.0.0 || ^2.0.0``         double pipe OR
``>=1.2.3, <2.0.0``          comma separated AND
===========================  ==========================================

Pre-release semantics follow SemVer: ``1.0.0-alpha`` sorts *before* ``1.0.0``
and is excluded from a range unless the range itself mentions a pre-release for
the same ``major.minor.patch`` tuple.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from functools import total_ordering
from typing import Iterable, Iterator, Sequence

from .errors import VersionError

__all__ = [
    "Version",
    "Range",
    "Constraint",
    "parse_version",
    "parse_constraint",
    "parse_range",
    "satisfies",
    "max_satisfying",
    "sort_versions",
    "intersect",
]

_SEMVER_RE = re.compile(
    r"^(?P<major>0|[1-9]\d*)"
    r"\.(?P<minor>0|[1-9]\d*)"
    r"\.(?P<patch>0|[1-9]\d*)"
    r"(?:-(?P<prerelease>(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)"
    r"(?:\.(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*))?"
    r"(?:\+(?P<build>[0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*))?$"
)

_LOOSE_RE = re.compile(r"^(?P<major>\d+)(?:\.(?P<minor>\d+))?(?:\.(?P<patch>\d+))?$")

_OPS = ("<=>", ">=", "<=", "^", "~", ">", "<", "=")
_ANY = frozenset({"?", "*", "latest", "any", "x"})


# --------------------------------------------------------------------------- #
# Version
# --------------------------------------------------------------------------- #


@total_ordering
class Version:
    """An immutable SemVer 2.0.0 version.

    Build metadata (``+sha``) is retained for round-tripping but ignored for
    ordering, as required by the specification.
    """

    __slots__ = ("major", "minor", "patch", "prerelease", "build", "_raw")

    def __init__(
        self,
        major: int,
        minor: int = 0,
        patch: int = 0,
        prerelease: Sequence[str | int] | None = None,
        build: Sequence[str] | None = None,
        raw: str | None = None,
    ) -> None:
        for label, value in (("major", major), ("minor", minor), ("patch", patch)):
            if not isinstance(value, int) or value < 0:
                raise VersionError(f"{label} must be a non-negative integer", value=value)
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease: tuple[str | int, ...] = tuple(prerelease or ())
        self.build: tuple[str, ...] = tuple(build or ())
        self._raw = raw

    # -- construction ------------------------------------------------------- #

    @classmethod
    def parse(cls, text: str, *, loose: bool = False) -> "Version":
        """Parse ``text`` into a :class:`Version`.

        When ``loose`` is true, partial versions such as ``"1"`` or ``"1.2"``
        are accepted and missing components default to zero. Loose mode is used
        for constraint bounds, never for a package's declared version.
        """
        if not isinstance(text, str):
            raise VersionError("version must be a string", value=text)

        candidate = text.strip()
        if candidate.startswith("v") or candidate.startswith("V"):
            candidate = candidate[1:]

        if not candidate:
            raise VersionError("version string is empty", value=text)

        match = _SEMVER_RE.match(candidate)
        if match:
            prerelease_raw = match.group("prerelease")
            prerelease: list[str | int] = []
            if prerelease_raw:
                for part in prerelease_raw.split("."):
                    prerelease.append(int(part) if part.isdigit() else part)
            build_raw = match.group("build")
            return cls(
                int(match.group("major")),
                int(match.group("minor")),
                int(match.group("patch")),
                prerelease,
                build_raw.split(".") if build_raw else (),
                raw=text,
            )

        if loose:
            loose_match = _LOOSE_RE.match(candidate)
            if loose_match:
                return cls(
                    int(loose_match.group("major")),
                    int(loose_match.group("minor") or 0),
                    int(loose_match.group("patch") or 0),
                    raw=text,
                )

        raise VersionError(f"invalid version: {text!r}", value=text)

    # -- comparison --------------------------------------------------------- #

    def _cmp_key(self) -> tuple:
        # Pre-release sorts before the release: flag 0 for prerelease, 1 for release.
        return (
            self.major,
            self.minor,
            self.patch,
            0 if self.prerelease else 1,
            self.prerelease,
        )

    def __eq__(self, other: object) -> bool:
        if not isinstance(other, Version):
            return NotImplemented
        return self._cmp_key() == other._cmp_key()

    def __lt__(self, other: "Version") -> bool:
        if not isinstance(other, Version):
            return NotImplemented
        return self._cmp_key() < other._cmp_key()

    def __hash__(self) -> int:
        return hash((self.major, self.minor, self.patch, self.prerelease))

    # -- projection --------------------------------------------------------- #

    def bump(self, part: str) -> "Version":
        """Return a copy with ``part`` incremented and lower parts zeroed."""
        if part == "major":
            return Version(self.major + 1, 0, 0)
        if part == "minor":
            return Version(self.major, self.minor + 1, 0)
        if part == "patch":
            return Version(self.major, self.minor, self.patch + 1)
        raise VersionError(f"unknown version part: {part!r}", part=part)

    def release(self) -> "Version":
        """Drop pre-release and build metadata."""
        return Version(self.major, self.minor, self.patch)

    @property
    def core(self) -> tuple[int, int, int]:
        return (self.major, self.minor, self.patch)

    @property
    def is_prerelease(self) -> bool:
        return bool(self.prerelease)

    def _canonical(self) -> str:
        """The fully-normalised ``MAJOR.MINOR.PATCH[-pre][+build]`` form.

        This is what derived bounds and error messages use. Unlike :meth:`__str__`
        it never echoes back input text, so a loosely parsed ``"1.2"`` renders as
        ``"1.2.0"``.
        """
        text = f"{self.major}.{self.minor}.{self.patch}"
        if self.prerelease:
            text += "-" + ".".join(str(part) for part in self.prerelease)
        if self.build:
            text += "+" + ".".join(self.build)
        return text

    def __str__(self) -> str:
        """Canonical form.

        Deliberately *not* the raw input: a version parsed loosely from ``"1"``
        must not print as ``"1"`` and then fail to round-trip through strict
        parsing. Display and comparison should agree, so both use the canonical
        rendering.
        """
        return self._canonical()

    __repr__ = __str__


def parse_version(text: str, *, loose: bool = False) -> Version:
    """Module-level convenience wrapper for :meth:`Version.parse`."""
    return Version.parse(text, loose=loose)


# --------------------------------------------------------------------------- #
# Constraints
# --------------------------------------------------------------------------- #


@dataclass(frozen=True)
class Constraint:
    """A single comparator such as ``>=1.2.0`` or ``^2.0.0``.

    ``operator == "*"`` means "any version". Wildcard bounds are normalised into
    a half-open interval during parsing (``1.2.*`` becomes ``>=1.2.0 <1.3.0``),
    so this class only ever holds a real comparator plus an optional bound.

    Pre-release policy deliberately lives **outside** this class. A comparator
    answers one question — does the bound hold? — and the caller
    (:func:`satisfies`, :func:`max_satisfying`, :meth:`Range.test`) decides
    whether pre-releases are admissible at all. Putting that decision here as
    well would mean two code paths that must agree, and they would eventually
    disagree.
    """

    operator: str
    version: Version | None = None
    prerelease_tuple: tuple[int, int, int] | None = None

    def test(self, candidate: Version) -> bool:
        """Does ``candidate`` satisfy this single comparator?"""
        if self.operator == "*":
            return True
        bound = self.version
        assert bound is not None

        op = self.operator
        if op == "=":
            return candidate == bound
        if op == ">":
            return candidate > bound
        if op == ">=":
            return candidate >= bound
        if op == "<":
            return candidate < bound
        if op == "<=":
            return candidate <= bound
        raise VersionError(f"unknown operator: {op!r}", operator=op)

    @property
    def names_prerelease(self) -> bool:
        """Whether this comparator explicitly opts a tuple into pre-releases."""
        return self.prerelease_tuple is not None

    def admits_prerelease_of(self, candidate: Version) -> bool:
        """True when this comparator opens the door for ``candidate``'s tuple."""
        return (
            candidate.is_prerelease
            and self.prerelease_tuple == candidate.core
        )

    def __str__(self) -> str:
        if self.operator == "*":
            return "*"
        return f"{self.operator}{self.version}"


class Range:
    """A disjunction (OR) of conjunctions (AND) of :class:`Constraint`.

    Pre-release policy is enforced here, at the single point every caller passes
    through, rather than inside each comparator:

    * a stable candidate always matches normally
    * a pre-release candidate matches only when some comparator in the satisfied
      group explicitly names a pre-release for the same ``major.minor.patch``
      tuple, or when :meth:`test` is called with ``include_prerelease=True``

    The flag is a parameter rather than an attribute so callers cannot forget
    which policy a shared ``Range`` object was built with.
    """

    __slots__ = ("groups", "_raw")

    def __init__(self, groups: Sequence[Sequence[Constraint]], raw: str = "") -> None:
        self.groups: tuple[tuple[Constraint, ...], ...] = tuple(
            tuple(group) for group in groups
        )
        if not self.groups:
            raise VersionError("constraint has no comparator groups", value=raw)
        self._raw = raw or str(self)

    @classmethod
    def any(cls) -> "Range":
        return cls([[Constraint("*")]], raw="*")

    def test(self, candidate: Version, *, include_prerelease: bool = False) -> bool:
        """True when *any* conjunction group is fully satisfied."""
        for group in self.groups:
            if not all(comparator.test(candidate) for comparator in group):
                continue
            if candidate.is_prerelease and not include_prerelease:
                if not any(c.admits_prerelease_of(candidate) for c in group):
                    continue
            return True
        return False

    def __contains__(self, candidate: Version) -> bool:
        return self.test(candidate)

    def __str__(self) -> str:
        if self._raw:
            return self._raw
        return " || ".join(
            " ".join(str(c) for c in group) for group in self.groups
        )

    def __repr__(self) -> str:
        return f"Range({str(self)!r})"

    @property
    def is_any(self) -> bool:
        return (
            len(self.groups) == 1
            and len(self.groups[0]) == 1
            and self.groups[0][0].operator == "*"
        )


def _split_wildcard(part: str) -> list[str]:
    """Expand ``1.2.*`` / ``1.x`` into an explicit comparator pair."""
    parts = part.split(".")
    trimmed: list[str] = []
    for index, chunk in enumerate(parts):
        if chunk.lower() in ("*", "x", "X"):
            break
        trimmed.append(chunk)
    if not trimmed:
        return ["*"]
    if len(trimmed) == 1:
        return [f">={trimmed[0]}.0.0", f"<{int(trimmed[0]) + 1}.0.0"]
    if len(trimmed) == 2:
        return [f">={trimmed[0]}.{trimmed[1]}.0", f"<{trimmed[0]}.{int(trimmed[1]) + 1}.0"]
    return [".".join(trimmed)]


def _version_to_str(version: Version) -> str:
    """Render a :class:`Version` in a form that survives a round trip.

    ``Version.__str__`` returns the original text it was parsed from, which for
    a loose bound like ``"1.2"`` is already non-canonical. Re-parsing that text
    with ``loose=True`` produces the same object, so this is safe — but the
    canonical form is what we actually want for derived bounds such as the upper
    limit of ``^1.2``.
    """
    if version is None:  # pragma: no cover - defensive
        raise VersionError("cannot render a null version")
    return version._canonical()


def _parse_bound(text: str, context: str) -> Version:
    """Parse a constraint bound.

    Bound text is always *raw text from the constraint string*, never an
    already-parsed version. Routing every bound through this one helper is what
    keeps ``prerelease_tuple`` meaningful: parsing the same string twice with
    different flags is how the pre-release hint silently went missing.
    """
    try:
        return Version.parse(text, loose=True)
    except VersionError as exc:
        raise VersionError(
            f"cannot parse constraint bound {text!r} in {context!r}",
            value=text,
        ) from exc


def _parse_group(text: str) -> list[Constraint]:
    tokens: list[str] = []
    rebuilt = text.replace(",", " ")
    for chunk in rebuilt.split():
        expanded = _split_wildcard(chunk) if "*" in chunk or chunk.lower().endswith("x") else [chunk]
        tokens.extend(expanded)

    constraints: list[Constraint] = []
    for token in tokens:
        token = token.strip()
        if not token:
            continue
        if token in _ANY:
            constraints.append(Constraint("*"))
            continue

        operator = "="
        bound_text = token
        for candidate_op in _OPS:
            if token.startswith(candidate_op):
                operator = candidate_op
                bound_text = token[len(candidate_op) :]
                break

        bound_text = bound_text.strip()
        if not bound_text or bound_text in _ANY:
            constraints.append(Constraint("*"))
            continue

        bound = _parse_bound(bound_text, text)

        # A constraint that explicitly names a pre-release opts that exact
        # major.minor.patch tuple into pre-releases. Everything else stays on
        # stable releases only, so a stray `-rc.1` can never be pulled in by
        # accident.
        prerelease_hint = bound.core if bound.is_prerelease else None

        if operator == "^":
            # ^1.2.3 -> >=1.2.3 <2.0.0 ; ^0.2.3 -> >=0.2.3 <0.3.0 ; ^0.0.3 -> =0.0.3
            if bound.major > 0:
                upper = Version(bound.major + 1, 0, 0)
            elif bound.minor > 0:
                upper = Version(0, bound.minor + 1, 0)
            else:
                upper = Version(0, 0, bound.patch + 1)
            constraints.append(Constraint(">=", bound, prerelease_hint))
            constraints.append(Constraint("<", upper, prerelease_hint))
        elif operator == "~":
            # ~1.2.3 -> >=1.2.3 <1.3.0 ; ~1 -> >=1.0.0 <2.0.0 ; ~1.2 -> >=1.2.0 <1.3.0
            upper = Version(bound.major, bound.minor + 1, 0)
            constraints.append(Constraint(">=", bound, prerelease_hint))
            constraints.append(Constraint("<", upper, prerelease_hint))
        else:
            constraints.append(Constraint(operator, bound, prerelease_hint))

    if not constraints:
        constraints.append(Constraint("*"))
    return constraints


def parse_constraint(text: str | None) -> Range:
    """Parse a constraint string into a :class:`Range`.

    ``None`` and ``""`` both mean "any version", which keeps manifests terse.
    """
    if text is None:
        return Range.any()
    if not isinstance(text, str):
        raise VersionError("constraint must be a string", value=text)
    stripped = text.strip()
    if not stripped:
        return Range.any()
    if stripped in _ANY:
        return Range.any()

    groups: list[list[Constraint]] = []
    for chunk in stripped.split("||"):
        chunk = chunk.strip()
        if not chunk:
            continue
        groups.append(_parse_group(chunk))
    if not groups:
        raise VersionError(f"empty constraint: {text!r}", value=text)
    return Range(groups, raw=stripped)


# Documentation alias: `parse_constraint` and `parse_range` are the same thing.
parse_range = parse_constraint


def satisfies(
    version: str | Version,
    constraint: str | Range | None,
    *,
    include_prerelease: bool = False,
) -> bool:
    """Return True when ``version`` falls inside ``constraint``.

    Set ``include_prerelease`` to allow a pre-release candidate to match a range
    that does not explicitly name one. Off by default: silently resolving to an
    unstable build is the kind of surprise that only shows up in production.
    """
    parsed_version = version if isinstance(version, Version) else Version.parse(version, loose=True)
    parsed_range = parse_constraint(constraint) if not isinstance(constraint, Range) else constraint
    return parsed_range.test(parsed_version, include_prerelease=include_prerelease)


def sort_versions(versions: Iterable[str | Version], *, descending: bool = False) -> list[Version]:
    """Sort versions ascending (or descending), ignoring build metadata."""
    parsed: list[Version] = [
        v if isinstance(v, Version) else Version.parse(v, loose=True) for v in versions
    ]
    parsed.sort(reverse=descending)
    return parsed


def max_satisfying(
    versions: Iterable[str | Version],
    constraint: str | Range | None,
    *,
    include_prerelease: bool = False,
) -> Version | None:
    """Highest version matching ``constraint``.

    Pre-release versions are excluded by default. They are admitted in exactly
    two cases: ``include_prerelease`` is true, or the constraint itself names a
    pre-release on the same ``major.minor.patch`` tuple.

    The caller-facing flag is applied here rather than duplicated inside
    :class:`Constraint`, so there is one place that decides pre-release policy
    and one place to reason about when it is wrong.
    """
    parsed_range = parse_constraint(constraint) if not isinstance(constraint, Range) else constraint
    best: Version | None = None
    for raw in versions:
        candidate = raw if isinstance(raw, Version) else Version.parse(raw, loose=True)
        if not parsed_range.test(candidate, include_prerelease=include_prerelease):
            continue
        if best is None or candidate > best:
            best = candidate
    return best


def intersect(left: str | Range | None, right: str | Range | None) -> Range:
    """Cartesian AND of two ranges, preserving OR semantics of both sides.

    Used by the resolver to merge every constraint imposed on a package. The
    result may be unsatisfiable — callers detect that by finding no candidate
    version, which produces a far better error message than an early failure.
    """
    left_range = parse_constraint(left) if not isinstance(left, Range) else left
    right_range = parse_constraint(right) if not isinstance(right, Range) else right

    if left_range.is_any:
        return right_range
    if right_range.is_any:
        return left_range

    groups: list[list[Constraint]] = []
    for left_group in left_range.groups:
        for right_group in right_range.groups:
            groups.append([*left_group, *right_group])
    return Range(groups, raw=f"({left_range}) AND ({right_range})")
