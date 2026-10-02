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

"""``btps`` command line interface.

All output is English, as required for CLI tools in this project. Exit codes:

``0`` success · ``1`` usage error · ``2`` package/manifest failure ·
``3`` dependency or conflict failure · ``4`` runtime/lifecycle failure

Commands
--------
``btps init <dir>``          scaffold a plugin project
``btps pack <dir>``          build a ``.btp`` archive
``btps verify <file>``       validate a ``.btp`` without extracting
``btps inspect <file>``      show manifest, members, and audit results
``btps list <dir>``          discover ``.btp`` files in a directory
``btps install <file>``      install into a runtime directory
``btps uninstall <id>``      remove an installed plugin
``btps enable|disable <id>`` change plugin state
``btps info <id>``           show one installed plugin
``btps plan <file>...``      dry-run dependency resolution
``btps doctor``              health check
``btps registry``            run the registration centre (5663)
``btps console``             run the unified console (6818)
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import textwrap
import time
from pathlib import Path
from typing import Any, Iterable, Sequence

from . import __version__
from .errors import BTPSError
from .manifest import MANIFEST_FILENAME, Manifest, ValidationReport
from .package import EXTENSION, extract, inspect, pack, stage
from .registry import DEFAULT_REGISTRY_PORT, RegistryServer, serve_registry
from .runtime import DefaultHostAdapter, PluginRuntime

__all__ = ["main", "build_parser"]

EXIT_OK = 0
EXIT_USAGE = 1
EXIT_PACKAGE = 2
EXIT_DEPENDENCY = 3
EXIT_RUNTIME = 4


# --------------------------------------------------------------------------- #
# Terminal helpers
# --------------------------------------------------------------------------- #


class Style:
    """ANSI styling that degrades to plain text when colour is unavailable."""

    def __init__(self, enabled: bool | None = None) -> None:
        if enabled is None:
            enabled = (
                sys.stdout.isatty()
                and os.environ.get("NO_COLOR") is None
                and os.environ.get("TERM") != "dumb"
            )
        self.enabled = enabled

    def _wrap(self, code: str, text: str) -> str:
        return f"\x1b[{code}m{text}\x1b[0m" if self.enabled else text

    def bold(self, text: str) -> str:
        return self._wrap("1", text)

    def dim(self, text: str) -> str:
        return self._wrap("2", text)

    def red(self, text: str) -> str:
        return self._wrap("31", text)

    def green(self, text: str) -> str:
        return self._wrap("32", text)

    def yellow(self, text: str) -> str:
        return self._wrap("33", text)

    def cyan(self, text: str) -> str:
        return self._wrap("36", text)


def _human_size(size: int) -> str:
    value = float(size)
    for unit in ("B", "KiB", "MiB", "GiB"):
        if value < 1024 or unit == "GiB":
            return f"{value:.1f} {unit}" if unit != "B" else f"{int(value)} B"
        value /= 1024
    return f"{size} B"


def _print_issues(report: ValidationReport, style: Style) -> None:
    for issue in report.issues:
        tag = {
            "error": style.red("error"),
            "warning": style.yellow("warn "),
            "info": style.dim("info "),
        }[issue.severity.value]
        print(f"  {tag} {issue.path}: {issue.message}")
        if issue.hint:
            print(f"        {style.dim(issue.hint)}")


# --------------------------------------------------------------------------- #
# Commands
# --------------------------------------------------------------------------- #

_MANIFEST_TEMPLATE = """{{
  "$schema": "https://btps.dev/schema/btps-1.0.json",
  "manifestVersion": 1,
  "btpsVersion": "1.0",

  "id": "{plugin_id}",
  "name": "{plugin_name}",
  "version": "0.1.0",
  "author": {{ "name": "{author}" }},
  "description": "{description}",
  "license": "MIT",

  "entry": {{ "python": "main.py" }},
  "runtimes": ["python"],

  "dependencies": {{}},
  "permissions": ["host.storage"],

  "platforms": ["windows", "linux", "darwin"],
  "hostApi": ">=1.0.0",
  "minHostVersion": "1.0.0",

  "hooks": {{
    "onEnable": {{ "handler": "on_enable" }},
    "onDisable": {{ "handler": "on_disable" }}
  }},

  "settings": {{}},
  "keywords": []
}}
"""

_ENTRY_TEMPLATE = '''"""Entry module for {plugin_name}.

The host calls ``btps_setup(ctx)`` once, at load time, before any hook fires.
Use it to install the context and return any metadata you want the host to see.
"""

from btps import install_context

ctx = None


def btps_setup(context):
    """Called once when the plugin is loaded."""
    global ctx
    ctx = context
    install_context(context)
    ctx.log.info("loaded %s v%s", ctx.name, ctx.version)
    return {{"ready": True}}


def on_enable(context):
    """Called when the plugin is enabled."""
    context.log.info("enabled")
    launches = context.storage.get("launches", 0)
    context.storage.set("launches", launches + 1)


def on_disable(context):
    """Called just before the plugin is disabled."""
    context.log.info("disabled")
'''

_README_TEMPLATE = """# {plugin_name}

{description}

## Layout

```
btps.json    manifest — id, version, entry, hooks, permissions
main.py      entry module, exports btps_setup + one function per declared hook
README.md    this file
```

## Build

```bash
btps pack . --output {plugin_id}-0.1.0.btp
btps verify {plugin_id}-0.1.0.btp
```

## Install

```bash
btps install {plugin_id}-0.1.0.btp --root ./plugins --enable
```
"""


def cmd_init(args: argparse.Namespace, style: Style) -> int:
    """Scaffold a minimal, immediately-packable plugin project."""
    target = Path(args.directory)
    if target.exists() and any(target.iterdir()) and not args.force:
        print(
            style.red(f"refusing to write into a non-empty directory: {target}"),
            file=sys.stderr,
        )
        print("  pass --force to overwrite the template files", file=sys.stderr)
        return EXIT_USAGE

    target.mkdir(parents=True, exist_ok=True)
    plugin_id = args.id or f"com.example.{target.name.lower().replace(' ', '-')}"
    plugin_name = args.name or target.name
    author = args.author or os.environ.get("USER") or os.environ.get("USERNAME") or "unknown"

    files = {
        MANIFEST_FILENAME: _MANIFEST_TEMPLATE.format(
            plugin_id=plugin_id,
            plugin_name=plugin_name,
            author=author,
            description=args.description or "A BrickTile plugin.",
        ),
        "main.py": _ENTRY_TEMPLATE.format(plugin_name=plugin_name),
        "README.md": _README_TEMPLATE.format(
            plugin_id=plugin_id,
            plugin_name=plugin_name,
            description=args.description or "A BrickTile plugin.",
        ),
    }
    if args.runtime in ("javascript", "typescript"):
        extension = "ts" if args.runtime == "typescript" else "js"
        files.pop("main.py")
        files[f"main.{extension}"] = _JS_ENTRY_TEMPLATE.format(plugin_name=plugin_name)
        manifest = json.loads(files[MANIFEST_FILENAME])
        manifest["entry"] = {args.runtime: f"main.{extension}"}
        manifest["runtimes"] = [args.runtime]
        manifest["hooks"] = {
            "onEnable": {"handler": "onEnable"},
            "onDisable": {"handler": "onDisable"},
        }
        files[MANIFEST_FILENAME] = json.dumps(manifest, indent=2, ensure_ascii=False) + "\n"

    for name, content in files.items():
        path = target / name
        if path.exists() and not args.force:
            print(f"  {style.dim('skip')}    {name} (exists)")
            continue
        path.write_text(content, encoding="utf-8")
        print(f"  {style.green('create')}  {name}")

    print()
    print(f"{style.bold('scaffolded')} {plugin_id} in {target}")
    print(f"  next: {style.cyan(f'btps pack {target}')}")
    return EXIT_OK


_JS_ENTRY_TEMPLATE = """/**
 * Entry module for {plugin_name}.
 *
 * Export one function per hook declared in btps.json. `btps.setup` runs once at
 * load time and receives the same context object every hook handler gets.
 */

export const btps = {{
  setup(ctx) {{
    ctx.log.info(`loaded ${{ctx.name}} v${{ctx.version}}`);
    return {{ ready: true }};
  }},
}};

export function onEnable(ctx) {{
  ctx.log.info('enabled');
  const launches = ctx.storage.get('launches', 0);
  ctx.storage.set('launches', launches + 1);
}}

export function onDisable(ctx) {{
  ctx.log.info('disabled');
}}
"""


def cmd_pack(args: argparse.Namespace, style: Style) -> int:
    source = Path(args.directory)
    output = Path(args.output) if args.output else None

    try:
        info = pack(
            source,
            output,
            compresslevel=args.compress_level,
            overwrite=args.force,
            deterministic=not args.no_deterministic,
        )
    except BTPSError as exc:
        print(style.red(f"pack failed: {exc}"), file=sys.stderr)
        if getattr(exc, "issues", None):
            for issue in exc.issues:
                print(f"  {issue}", file=sys.stderr)
        return EXIT_PACKAGE

    assert info.manifest is not None
    print(f"{style.bold('packed')} {info.manifest.id}@{info.manifest.version_string}")
    print(f"  file      {info.path}")
    print(f"  container {info.container}")
    print(f"  size      {_human_size(info.size_bytes)}")
    print(f"  digest    {info.digest}")
    print(f"  members   {len(info.members)}")
    if info.report.warnings:
        print()
        print(style.yellow(f"{len(info.report.warnings)} warning(s):"))
        _print_issues(info.report, style)
    return EXIT_OK


def cmd_verify(args: argparse.Namespace, style: Style) -> int:
    for target in args.files:
        try:
            info = inspect(target)
        except BTPSError as exc:
            print(f"{style.red('FAIL')} {target}: {exc}", file=sys.stderr)
            return EXIT_PACKAGE

        if info.ok:
            print(f"{style.green('OK')}   {target}")
        else:
            print(f"{style.red('FAIL')} {target}")
            _print_issues(info.report, style)
            return EXIT_PACKAGE

        if info.report.issues:
            _print_issues(info.report, style)

    return EXIT_OK


def cmd_inspect(args: argparse.Namespace, style: Style) -> int:
    try:
        info = inspect(args.file)
    except BTPSError as exc:
        print(style.red(f"inspect failed: {exc}"), file=sys.stderr)
        return EXIT_PACKAGE

    if args.json:
        print(json.dumps(info.to_dict(), indent=2, ensure_ascii=False))
        return EXIT_OK

    print(f"{style.bold('package')}  {info.path}")
    print(f"  container  {info.container}")
    print(f"  size       {_human_size(info.size_bytes)}")
    print(f"  digest     {info.digest}")
    print(f"  members    {len(info.members)}")
    print()

    if info.manifest is None:
        print(style.red("no valid manifest found"))
        _print_issues(info.report, style)
        return EXIT_PACKAGE

    manifest = info.manifest
    print(f"{style.bold('manifest')}")
    rows = [
        ("id", manifest.id),
        ("name", manifest.name),
        ("version", manifest.version_string),
        ("author", str(manifest.author)),
        ("license", manifest.license or style.dim("(none)")),
        ("description", manifest.description or style.dim("(none)")),
        ("hostApi", manifest.host_api),
        ("platforms", ", ".join(manifest.platforms) or "any"),
    ]
    for label, value in rows:
        print(f"  {label:<12} {value}")

    print()
    print(f"{style.bold('entry')}")
    for runtime, path in manifest.entry.items():
        available = "✓" if info.manifest and any(m.name == path for m in info.members) else "✗"
        print(f"  {available} {runtime:<12} {path}")

    if manifest.dependencies or manifest.optional_dependencies:
        print()
        print(f"{style.bold('dependencies')}")
        for dependency in manifest.dependencies:
            print(f"  - {dependency}")
        for dependency in manifest.optional_dependencies:
            print(f"  - {dependency} {style.dim('(optional)')}")
    if manifest.conflicts:
        print()
        print(f"{style.bold('conflicts')}")
        for package_id, constraint in manifest.conflicts.items():
            print(f"  - {package_id}{constraint}")

    if manifest.permissions:
        print()
        print(f"{style.bold('permissions')}")
        for permission in manifest.permissions:
            marker = style.yellow("⚠") if permission.startswith(
                ("fs.write", "net.", "host.process", "host.env")
            ) else " "
            print(f"  {marker} {permission}")

    if manifest.hooks:
        print()
        print(f"{style.bold('hooks')}")
        for hook in manifest.hooks:
            flag = " (continue on error)" if hook.continue_on_error else ""
            print(f"  - {hook.name:<18} p={hook.priority:<5} {hook.handler}{flag}")

    if info.audit.violations:
        print()
        print(style.red(f"audit: {len(info.audit.violations)} violation(s)"))
        for violation in info.audit.violations:
            print(f"  - {violation}")

    if info.report.issues:
        print()
        print(style.bold("validation"))
        _print_issues(info.report, style)

    if args.members:
        print()
        print(f"{style.bold('members')} ({len(info.members)})")
        for member in info.members:
            if member.is_dir:
                continue
            print(f"  {_human_size(member.size):>10}  {member.name}")

    return EXIT_OK if info.ok else EXIT_PACKAGE


def cmd_list(args: argparse.Namespace, style: Style) -> int:
    roots = [Path(r) for r in (args.directories or ["."])]
    found: list[Any] = []
    for root in roots:
        if root.is_file() and root.suffix == EXTENSION:
            candidates = [root]
        elif root.is_dir():
            candidates = sorted(root.glob(f"*{EXTENSION}"))
        else:
            print(style.red(f"not found: {root}"), file=sys.stderr)
            return EXIT_USAGE

        for path in candidates:
            try:
                found.append(inspect(path))
            except BTPSError as exc:
                print(f"{style.red('unreadable')} {path.name}: {exc}", file=sys.stderr)

    if not found:
        print(style.dim("no packages found"))
        return EXIT_OK

    if args.json:
        print(json.dumps([p.to_dict() for p in found], indent=2, ensure_ascii=False))
        return EXIT_OK

    print(f"{'ID':<32} {'VERSION':<12} {'SIZE':>10}  FILE")
    for info in found:
        size = _human_size(info.size_bytes)
        state = style.green("ok") if info.ok else style.red("bad")
        identifier = info.id or style.red("<invalid>")
        print(f"{identifier:<32} {info.version:<12} {size:>10}  {Path(info.path).name}  {state}")
    print()
    print(style.dim(f"{len(found)} package(s)"))
    return EXIT_OK


def _make_runtime(args: argparse.Namespace, style: Style) -> PluginRuntime:
    root = Path(args.root)
    adapter = DefaultHostAdapter(version=args.host_version)
    return PluginRuntime(
        adapter=adapter,
        install_root=root,
        data_root=root / ".data",
        staging_root=root / ".staging",
    )


def cmd_install(args: argparse.Namespace, style: Style) -> int:
    runtime = _make_runtime(args, style)
    try:
        record = runtime.install(
            args.file,
            auto_enable=args.enable,
            overwrite=args.force,
        )
    except BTPSError as exc:
        print(style.red(f"install failed: {exc}"), file=sys.stderr)
        return EXIT_RUNTIME

    print(f"{style.green('installed')} {record.id}@{record.version}")
    print(f"  path   {record.install_path}")
    print(f"  state  {record.state.value}")
    if record.manifest.permissions:
        print()
        print("  permissions:")
        for permission in record.manifest.permissions:
            print(f"    - {permission}")
    if record.sandbox and record.sandbox.permissions.pending_consent:
        print()
        print(style.yellow("  awaiting your approval:"))
        for permission in record.sandbox.permissions.pending_consent:
            print(f"    ! {permission}")
    return EXIT_OK


def cmd_uninstall(args: argparse.Namespace, style: Style) -> int:
    runtime = _make_runtime(args, style)
    runtime.restore(auto_enable=False)
    try:
        runtime.uninstall(args.plugin_id, keep_data=args.keep_data)
    except BTPSError as exc:
        print(style.red(f"uninstall failed: {exc}"), file=sys.stderr)
        return EXIT_RUNTIME
    print(
        f"{style.green('uninstalled')} {args.plugin_id}"
        + (style.dim(" (data kept)") if args.keep_data else style.dim(" (data removed)"))
    )
    return EXIT_OK


def _set_state(args: argparse.Namespace, style: Style, action: str) -> int:
    runtime = _make_runtime(args, style)
    runtime.restore(auto_enable=False)
    try:
        record = runtime.enable(args.plugin_id) if action == "enable" else runtime.disable(args.plugin_id)
    except BTPSError as exc:
        print(style.red(f"{action} failed: {exc}"), file=sys.stderr)
        return EXIT_RUNTIME
    print(f"{style.green(action + 'd')} {record.id} → {record.state.value}")
    return EXIT_OK


def cmd_enable(args: argparse.Namespace, style: Style) -> int:
    return _set_state(args, style, "enable")


def cmd_disable(args: argparse.Namespace, style: Style) -> int:
    return _set_state(args, style, "disable")


def cmd_info(args: argparse.Namespace, style: Style) -> int:
    runtime = _make_runtime(args, style)
    runtime.restore(auto_enable=False)

    records = runtime.list()
    if args.plugin_id:
        record = runtime.get(args.plugin_id)
        if record is None:
            print(style.red(f"plugin not installed: {args.plugin_id}"), file=sys.stderr)
            print(style.dim(f"  known: {', '.join(r.id for r in records) or '(none)'}"), file=sys.stderr)
            return EXIT_RUNTIME
        records = [record]

    if not records:
        print(style.dim("no plugins installed"))
        return EXIT_OK

    for index, record in enumerate(records):
        if index:
            print()
        if args.json:
            print(json.dumps(record.to_dict(), indent=2, ensure_ascii=False))
            continue
        print(f"{style.bold(record.manifest.name)} {style.dim(record.id)}")
        print(f"  version    {record.version}")
        print(f"  state      {record.state.value}")
        print(f"  path       {record.install_path}")
        if record.error:
            print(f"  {style.red('error')}      {record.error}")
        if record.manifest.permissions:
            print(f"  permissions")
            for permission in record.manifest.permissions:
                granted = (
                    record.sandbox
                    and record.sandbox.permissions.check(permission)
                )
                print(f"    {'✓' if granted else '✗'} {permission}")
        hooks = runtime.hooks.plugin_hooks(record.id)
        if hooks:
            print(f"  hooks      {', '.join(sorted(hooks))}")
        if record.history:
            print(f"  history")
            for event in record.history[-6:]:
                stamp = time.strftime("%H:%M:%S", time.localtime(event.at))
                print(f"    {style.dim(stamp)} {event.from_state.value} → {event.to_state.value}")
    return EXIT_OK


def cmd_plan(args: argparse.Namespace, style: Style) -> int:
    runtime = _make_runtime(args, style)
    runtime.restore(auto_enable=False)
    try:
        plan = runtime.plan(args.files, prune=args.prune)
    except BTPSError as exc:
        print(style.red(f"resolution failed: {exc}"), file=sys.stderr)
        return EXIT_DEPENDENCY

    if args.json:
        print(json.dumps(plan.to_dict(), indent=2, ensure_ascii=False))
        return EXIT_OK

    print(style.bold("install plan"))
    print(plan.render())
    if plan.order:
        print()
        print(f"{style.dim('install order')}  {' → '.join(plan.order)}")
    return EXIT_OK


def cmd_verify_deps(args: argparse.Namespace, style: Style) -> int:
    """Resolve a directory of packages without installing anything."""
    directory = Path(args.directory)
    files = sorted(directory.glob(f"*{EXTENSION}"))
    if not files:
        print(style.red(f"no {EXTENSION} files in {directory}"), file=sys.stderr)
        return EXIT_USAGE
    args.files = [str(f) for f in files]
    args.prune = False
    args.json = getattr(args, "json", False)
    return cmd_plan(args, style)


def cmd_doctor(args: argparse.Namespace, style: Style) -> int:
    runtime = _make_runtime(args, style)
    runtime.restore(auto_enable=False)
    report = runtime.doctor()

    if args.json:
        print(json.dumps(report, indent=2, ensure_ascii=False))
        return EXIT_OK

    summary = report["summary"]
    print(f"{style.bold('BTPS doctor')}")
    print(f"  install root  {summary['installRoot']}")
    print(f"  data root     {summary['dataRoot']}")
    print(f"  host          {summary['hostVersion']} (api {summary['hostApiVersion']})")
    print(f"  platform      {summary['platform']}")
    print(f"  plugins       {summary['count']}")
    for state, count in sorted(summary["byState"].items()):
        print(f"    {state:<12} {count}")
    print(f"  denied calls  {report['deniedCalls']}")
    print(f"  timeouts      {report['timeouts']}")

    if report["problems"]:
        print()
        print(style.yellow(f"{len(report['problems'])} problem(s):"))
        for problem in report["problems"]:
            print(f"  - [{problem['kind']}] {problem['pluginId']}: {problem['detail']}")
        return EXIT_RUNTIME

    print()
    print(style.green("no problems found"))
    return EXIT_OK


def cmd_registry(args: argparse.Namespace, style: Style) -> int:
    print(f"{style.bold('BTPS registration centre')}")
    print(f"  listening on http://{args.host}:{args.port}")
    print(f"  {style.dim('control plane only — plugin payloads never pass through here')}")
    print()
    print("  POST /register     allocate an injection port")
    print("  POST /heartbeat    extend the lease")
    print("  POST /unregister   release the slot")
    print("  GET  /hosts        list live hosts")
    print("  GET  /health       liveness probe")
    print()
    print(style.dim("  Ctrl-C to stop"))
    print()

    server = RegistryServer(host=args.host, port=args.port)

    def observe(kind: str, payload: Any) -> None:
        if kind == "registered":
            print(f"  {style.green('register')}   {payload}")
        elif kind == "unregistered":
            print(f"  {style.dim('unregister')} {payload}")

    server.on_event = observe
    try:
        server.start(background=False)
    except BTPSError as exc:
        print(style.red(str(exc)), file=sys.stderr)
        return EXIT_RUNTIME
    finally:
        server.stop()
    return EXIT_OK


def cmd_console(args: argparse.Namespace, style: Style) -> int:
    from .console import ConsoleConfig, ConsoleServer

    runtime = _make_runtime(args, style)
    runtime.restore(auto_enable=False)
    registry = None
    if args.with_registry:
        registry = RegistryServer(host="127.0.0.1", port=DEFAULT_REGISTRY_PORT).registry

    print(f"{style.bold('BTPS unified console')}")
    print(f"  listening on http://{args.host}:{args.port}")
    print(f"  plugins from {args.root}")
    print()
    print(style.dim("  Ctrl-C to stop"))
    print()

    config = ConsoleConfig(host=args.host, port=args.port)
    server = ConsoleServer(runtime, registry=registry, config=config)
    try:
        server.start(background=False)
    except BTPSError as exc:
        print(style.red(str(exc)), file=sys.stderr)
        return EXIT_RUNTIME
    finally:
        server.stop()
    return EXIT_OK


# --------------------------------------------------------------------------- #
# Parser
# --------------------------------------------------------------------------- #


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="btps",
        description="BrickTile Plugin System — package, verify, and manage .btp plugins.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=textwrap.dedent(
            """\
            exit codes:
              0  success
              1  usage error
              2  package or manifest failure
              3  dependency or version conflict
              4  runtime or lifecycle failure

            examples:
              btps init my-plugin --id com.example.myplugin
              btps pack my-plugin --output dist/my-plugin-0.1.0.btp
              btps verify dist/my-plugin-0.1.0.btp
              btps plan dist/*.btp --root ./plugins
              btps install dist/my-plugin-0.1.0.btp --root ./plugins --enable
              btps console --root ./plugins
            """
        ),
    )
    parser.add_argument("--version", action="version", version=f"btps {__version__}")
    parser.add_argument(
        "--no-color", action="store_true", help="disable ANSI colour output"
    )

    subparsers = parser.add_subparsers(dest="command", metavar="<command>")

    # init
    init = subparsers.add_parser("init", help="scaffold a plugin project")
    init.add_argument("directory", help="target directory")
    init.add_argument("--id", help="package id, e.g. com.example.myplugin")
    init.add_argument("--name", help="display name")
    init.add_argument("--author", help="author name")
    init.add_argument("--description", help="one-line description")
    init.add_argument(
        "--runtime",
        choices=("python", "javascript", "typescript"),
        default="python",
        help="entry language (default: python)",
    )
    init.add_argument("--force", action="store_true", help="overwrite existing files")
    init.set_defaults(handler=cmd_init)

    # pack
    pack_cmd = subparsers.add_parser("pack", help=f"build a {EXTENSION} archive")
    pack_cmd.add_argument("directory", help="source directory containing btps.json")
    pack_cmd.add_argument("-o", "--output", help="output path")
    pack_cmd.add_argument("--compress-level", type=int, default=9, choices=range(0, 10))
    pack_cmd.add_argument("--force", action="store_true", help="overwrite the output file")
    pack_cmd.add_argument(
        "--no-deterministic",
        action="store_true",
        help="use the current time instead of a fixed timestamp",
    )
    pack_cmd.set_defaults(handler=cmd_pack)

    # verify
    verify = subparsers.add_parser("verify", help="validate packages without extracting")
    verify.add_argument("files", nargs="+", help="one or more .btp files")
    verify.set_defaults(handler=cmd_verify)

    # inspect
    inspect_cmd = subparsers.add_parser("inspect", help="show full package detail")
    inspect_cmd.add_argument("file")
    inspect_cmd.add_argument("--members", action="store_true", help="list every member")
    inspect_cmd.add_argument("--json", action="store_true", help="machine-readable output")
    inspect_cmd.set_defaults(handler=cmd_inspect)

    # list
    list_cmd = subparsers.add_parser("list", help="discover packages in directories")
    list_cmd.add_argument("directories", nargs="*", help="directories to scan")
    list_cmd.add_argument("--json", action="store_true")
    list_cmd.set_defaults(handler=cmd_list)

    def add_root(parser: argparse.ArgumentParser) -> None:
        parser.add_argument(
            "--root", default="plugins", help="plugin install directory (default: ./plugins)"
        )
        parser.add_argument(
            "--host-version", default="1.0.0", help="host version for compatibility checks"
        )

    # install
    install = subparsers.add_parser("install", help="install a package")
    install.add_argument("file", help="path to a .btp file")
    add_root(install)
    install.add_argument("--enable", action="store_true", help="enable after installing")
    install.add_argument("--force", action="store_true", help="overwrite an existing install")
    install.set_defaults(handler=cmd_install)

    # uninstall
    uninstall = subparsers.add_parser("uninstall", help="remove an installed plugin")
    uninstall.add_argument("plugin_id")
    add_root(uninstall)
    uninstall.add_argument("--keep-data", action="store_true", help="preserve plugin data")
    uninstall.set_defaults(handler=cmd_uninstall)

    # enable / disable
    for name, help_text in (("enable", "enable an installed plugin"), ("disable", "disable an installed plugin")):
        command = subparsers.add_parser(name, help=help_text)
        command.add_argument("plugin_id")
        add_root(command)
        command.set_defaults(handler=cmd_enable if name == "enable" else cmd_disable)

    # info
    info = subparsers.add_parser("info", help="show installed plugin detail")
    info.add_argument("plugin_id", nargs="?")
    add_root(info)
    info.add_argument("--json", action="store_true")
    info.set_defaults(handler=cmd_info)

    # plan
    plan = subparsers.add_parser("plan", help="dry-run dependency resolution")
    plan.add_argument("files", nargs="+", help=".btp files to plan")
    add_root(plan)
    plan.add_argument("--prune", action="store_true", help="include removals of orphans")
    plan.add_argument("--json", action="store_true")
    plan.set_defaults(handler=cmd_plan)

    # verify-deps
    verify_deps = subparsers.add_parser(
        "verify-deps", help="resolve every package in a directory"
    )
    verify_deps.add_argument("directory")
    add_root(verify_deps)
    verify_deps.add_argument("--json", action="store_true")
    verify_deps.set_defaults(handler=cmd_verify_deps)

    # doctor
    doctor = subparsers.add_parser("doctor", help="check runtime health")
    add_root(doctor)
    doctor.add_argument("--json", action="store_true")
    doctor.set_defaults(handler=cmd_doctor)

    # registry
    registry = subparsers.add_parser(
        "registry", help=f"run the registration centre (default port {DEFAULT_REGISTRY_PORT})"
    )
    registry.add_argument("--host", default="127.0.0.1")
    registry.add_argument("--port", type=int, default=DEFAULT_REGISTRY_PORT)
    registry.set_defaults(handler=cmd_registry)

    # console
    console = subparsers.add_parser(
        "console", help="run the unified web console (default port 6818)"
    )
    console.add_argument("--host", default="127.0.0.1")
    console.add_argument("--port", type=int, default=6818)
    console.add_argument(
        "--with-registry",
        action="store_true",
        help="attach a registry handle so the hosts tab has data",
    )
    add_root(console)
    console.set_defaults(handler=cmd_console)

    return parser


def main(argv: Sequence[str] | None = None) -> int:
    """CLI entry point. Returns the process exit code."""
    parser = build_parser()
    args = parser.parse_args(argv)

    style = Style(enabled=False if getattr(args, "no_color", False) else None)

    handler = getattr(args, "handler", None)
    if handler is None:
        parser.print_help()
        return EXIT_USAGE

    try:
        return int(handler(args, style))
    except KeyboardInterrupt:
        print()
        print(style.dim("interrupted"))
        return EXIT_OK
    except BTPSError as exc:
        print(style.red(f"error: {exc}"), file=sys.stderr)
        return EXIT_RUNTIME
    except BrokenPipeError:
        # Writing to a closed pipe (e.g. `btps list | head`) is normal.
        try:
            sys.stdout.close()
        except Exception:  # noqa: BLE001
            pass
        return EXIT_OK


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
