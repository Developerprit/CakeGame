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

"""Unified web console — one page that manages plugins across every host.

Serves on port 6818. It is a thin backend over :class:`~btps.runtime.PluginRuntime`
and :class:`~btps.registry.HostRegistry`, exposing a small JSON API plus a
single-page UI.

The API is deliberately flat and boring: a handful of resource endpoints, JSON
in, JSON out. Hosts embed this console rather than each growing their own
plugin-management UI, which is where the "unified" claim is actually earned.

Endpoints
---------
``GET  /``                          the console UI
``GET  /api/status``                runtime + registry summary
``GET  /api/plugins``               installed plugins
``GET  /api/plugins/<id>``          one plugin, including manifest and history
``POST /api/plugins/<id>/enable``   enable
``POST /api/plugins/<id>/disable``  disable
``POST /api/plugins/<id>/reload``   reload
``DELETE /api/plugins/<id>``        uninstall (``?keepData=1`` preserves data)
``POST /api/plugins/<id>/permissions``  grant or revoke permissions
``POST /api/install``               install from a local ``.btp`` path
``GET  /api/packages``              discover ``.btp`` files
``GET  /api/plan?path=...``         dry-run an install plan
``GET  /api/hosts``                 registered hosts (proxied from 5663)
``GET  /api/hooks``                 hook subscriptions
``GET  /api/audit``                 audit log
``GET  /api/doctor``                health check
"""

from __future__ import annotations

import json
import threading
from dataclasses import dataclass
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Callable, Iterable, Mapping, Sequence
from urllib.parse import parse_qs, urlparse

from .errors import BTPSError, PermissionDenied
from .registry import DEFAULT_REGISTRY_PORT, HostRegistry

__all__ = [
    "DEFAULT_CONSOLE_PORT",
    "ConsoleServer",
    "serve_console",
]

DEFAULT_CONSOLE_PORT = 6818

#: The console talks only to loopback by default. Binding it to a routable
#: interface would expose plugin control to the network with no authentication,
#: which is not a decision a library should make on the user's behalf.
DEFAULT_CONSOLE_HOST = "127.0.0.1"


_CONSOLE_HTML = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>BTPS Console</title>
<style>
:root{
  color-scheme:light dark;
  --bg:#fbfbfc; --panel:#ffffff; --fg:#18181b; --muted:#6b7280;
  --line:#e4e4e7; --accent:#0f766e; --danger:#b91c1c; --warn:#b45309;
  --ok:#15803d; --mono:ui-monospace,SFMono-Regular,"SF Mono",Menlo,monospace;
}
@media (prefers-color-scheme:dark){
  :root{--bg:#0b0b0d;--panel:#141417;--fg:#e8e8ea;--muted:#9ca3af;
        --line:#26262b;--accent:#2dd4bf;--danger:#f87171;--warn:#fbbf24;--ok:#4ade80;}
}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);
  font:14px/1.55 var(--mono);-webkit-font-smoothing:antialiased}
header{display:flex;align-items:baseline;gap:1rem;padding:1.25rem 1.75rem;
  border-bottom:1px solid var(--line);position:sticky;top:0;background:var(--bg);z-index:5}
h1{font-size:.95rem;margin:0;letter-spacing:.08em;text-transform:uppercase}
.sub{color:var(--muted);font-size:.8rem}
nav{display:flex;gap:.25rem;margin-left:auto}
nav button{font:inherit;font-size:.8rem;background:none;border:1px solid transparent;
  color:var(--muted);padding:.3rem .7rem;border-radius:4px;cursor:pointer}
nav button:hover{color:var(--fg);border-color:var(--line)}
nav button[aria-selected=true]{color:var(--fg);border-color:var(--line);background:var(--panel)}
main{padding:1.5rem 1.75rem 4rem;max-width:1100px}
section{display:none} section.active{display:block}
.stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(130px,1fr));
  gap:1px;background:var(--line);border:1px solid var(--line);border-radius:6px;overflow:hidden;margin-bottom:1.5rem}
.stat{background:var(--panel);padding:.85rem 1rem}
.stat b{display:block;font-size:1.4rem;font-weight:600;line-height:1.2}
.stat span{color:var(--muted);font-size:.72rem;letter-spacing:.06em;text-transform:uppercase}
table{width:100%;border-collapse:collapse}
th,td{text-align:left;padding:.55rem .6rem;border-bottom:1px solid var(--line);vertical-align:top}
th{font-size:.72rem;letter-spacing:.07em;text-transform:uppercase;color:var(--muted);font-weight:600}
tbody tr:hover{background:var(--panel)}
.pill{display:inline-block;padding:.1rem .5rem;border-radius:99px;font-size:.7rem;
  border:1px solid currentColor;letter-spacing:.04em}
.s-enabled{color:var(--ok)} .s-disabled{color:var(--muted)}
.s-failed{color:var(--danger)} .s-installed{color:var(--warn)}
.s-loaded{color:var(--accent)} .s-other{color:var(--muted)}
button.act{font:inherit;font-size:.75rem;background:none;border:1px solid var(--line);
  color:var(--fg);padding:.22rem .6rem;border-radius:4px;cursor:pointer;margin-right:.3rem}
button.act:hover{border-color:var(--accent);color:var(--accent)}
button.act.danger:hover{border-color:var(--danger);color:var(--danger)}
pre{background:var(--panel);border:1px solid var(--line);border-radius:6px;
  padding:.9rem;overflow:auto;max-height:60vh;font-size:.78rem;margin:0}
.empty{color:var(--muted);font-style:italic;padding:1.5rem 0}
.err{color:var(--danger)}
.muted{color:var(--muted)}
input[type=text]{font:inherit;background:var(--panel);border:1px solid var(--line);
  color:var(--fg);padding:.4rem .6rem;border-radius:4px;min-width:22rem}
.row{display:flex;gap:.6rem;align-items:center;margin-bottom:1rem;flex-wrap:wrap}
.foot{color:var(--muted);font-size:.75rem;margin-top:2rem;padding-top:1rem;border-top:1px solid var(--line)}
</style>
</head>
<body>
<header>
  <h1>BTPS Console</h1>
  <span class="sub" id="endpoint"></span>
  <nav id="tabs">
    <button data-tab="plugins" aria-selected="true">plugins</button>
    <button data-tab="hosts">hosts</button>
    <button data-tab="hooks">hooks</button>
    <button data-tab="audit">audit</button>
    <button data-tab="raw">raw</button>
  </nav>
</header>
<main>
  <div class="stats" id="stats"></div>

  <section id="tab-plugins" class="active">
    <div class="row">
      <input type="text" id="installPath" placeholder="/path/to/plugin-1.0.0.btp">
      <button class="act" id="installBtn">install</button>
      <button class="act" id="refreshBtn">refresh</button>
    </div>
    <div id="plugins"></div>
  </section>

  <section id="tab-hosts"><div id="hosts"></div></section>
  <section id="tab-hooks"><div id="hooks"></div></section>
  <section id="tab-audit"><div id="audit"></div></section>
  <section id="tab-raw"><pre id="raw">–</pre></section>
</main>
<div class="foot" style="padding:0 1.75rem">
  BrickTile Plugin System · unified console · control plane on 127.0.0.1 only
</div>

<script>
const $ = (id) => document.getElementById(id);
const esc = (value) => String(value ?? '').replace(/[&<>"]/g,
  (ch) => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[ch]));

async function api(path, options){
  const response = await fetch(path, options);
  const text = await response.text();
  let data;
  try { data = text ? JSON.parse(text) : {}; }
  catch { data = { ok:false, error:'non-JSON response', body:text.slice(0,400) }; }
  if(!response.ok || data.ok === false){
    throw new Error(data.error || `HTTP ${response.status}`);
  }
  return data;
}

function stateClass(state){
  const known = ['enabled','disabled','failed','installed','loaded','resolved','discovered'];
  return known.includes(state) ? `s-${state}` : 's-other';
}

/* -- tabs ---------------------------------------------------------------- */
$('tabs').addEventListener('click', (event) => {
  const button = event.target.closest('button[data-tab]');
  if(!button) return;
  for(const other of $('tabs').querySelectorAll('button')){
    other.setAttribute('aria-selected', String(other === button));
  }
  for(const section of document.querySelectorAll('main section')){
    section.classList.toggle('active', section.id === `tab-${button.dataset.tab}`);
  }
  refresh();
});

/* -- global refresh ------------------------------------------------------ */
async function refresh(){
  try{
    const status = await api('/api/status');
    $('endpoint').textContent = `${status.runtime.hostVersion} · api ${status.runtime.hostApiVersion}`;
    const byState = status.runtime.byState || {};
    $('stats').innerHTML = [
      ['plugins', status.runtime.count],
      ['enabled', byState.enabled || 0],
      ['failed', byState.failed || 0],
      ['hosts', (status.registry?.hosts || []).length],
      ['hooks', (status.runtime.hooks || []).length],
      ['denied calls', status.doctor?.deniedCalls ?? 0],
    ].map(([label, value]) =>
      `<div class="stat"><b>${esc(value)}</b><span>${esc(label)}</span></div>`).join('');
  }catch(error){
    $('stats').innerHTML = `<div class="stat err">status error: ${esc(error.message)}</div>`;
  }

  const active = document.querySelector('#tabs button[aria-selected=true]')?.dataset.tab;
  try{
    if(active === 'plugins') await renderPlugins();
    else if(active === 'hosts') await renderHosts();
    else if(active === 'hooks') await renderHooks();
    else if(active === 'audit') await renderAudit();
    else await renderRaw();
  }catch(error){
    const target = {plugins:'plugins',hosts:'hosts',hooks:'hooks',audit:'audit',raw:'raw'}[active];
    $(target).innerHTML = `<div class="err">${esc(error.message)}</div>`;
  }
}

async function renderPlugins(){
  const { plugins } = await api('/api/plugins');
  if(!plugins.length){ $('plugins').innerHTML = '<div class="empty">no plugins installed</div>'; return; }

  $('plugins').innerHTML = `<table><thead><tr>
    <th>plugin</th><th>version</th><th>state</th><th>permissions</th><th>actions</th>
  </tr></thead><tbody>` + plugins.map((plugin) => `
    <tr>
      <td><b>${esc(plugin.name || plugin.id)}</b><br><span class="muted">${esc(plugin.id)}</span></td>
      <td>${esc(plugin.version)}</td>
      <td><span class="pill ${stateClass(plugin.state)}">${esc(plugin.state)}</span>
          ${plugin.error ? `<br><span class="err">${esc(plugin.error.slice(0,120))}</span>` : ''}</td>
      <td class="muted">${(plugin.permissions || []).map(esc).join('<br>') || '–'}
          ${(plugin.pendingConsent||[]).length
            ? `<br><span class="err">needs consent: ${plugin.pendingConsent.map(esc).join(', ')}</span>` : ''}</td>
      <td>
        <button class="act" data-action="enable" data-id="${esc(plugin.id)}">enable</button>
        <button class="act" data-action="disable" data-id="${esc(plugin.id)}">disable</button>
        <button class="act" data-action="reload" data-id="${esc(plugin.id)}">reload</button>
        <button class="act danger" data-action="uninstall" data-id="${esc(plugin.id)}">uninstall</button>
      </td>
    </tr>`).join('') + '</tbody></table>';
}

async function renderHosts(){
  const data = await api('/api/hosts');
  const hosts = data.registry?.hosts || [];
  $('hosts').innerHTML = hosts.length
    ? `<table><thead><tr><th>name</th><th>version</th><th>pid</th><th>inject port</th><th>age</th></tr></thead><tbody>`
      + hosts.map((h) => `<tr><td>${esc(h.name)}</td><td>${esc(h.hostVersion)}</td>
          <td>${esc(h.pid)}</td><td>${esc(h.injectPort)}</td><td>${esc(h.ageSeconds)}s</td></tr>`).join('')
      + '</tbody></table>'
    : '<div class="empty">no hosts registered on the registration centre</div>';
}

async function renderHooks(){
  const data = await api('/api/hooks');
  const hooks = Object.entries(data.hooks || {});
  $('hooks').innerHTML = hooks.length
    ? '<table><thead><tr><th>hook</th><th>subscriber</th><th>priority</th><th>on error</th></tr></thead><tbody>'
      + hooks.flatMap(([hook, subscribers]) => subscribers.map((s) => `
          <tr><td>${esc(hook)}</td><td>${esc(s.pluginId)}</td>
              <td>${esc(s.priority)}</td>
              <td>${s.continueOnError ? 'continue' : 'stop chain'}</td></tr>`)).join('')
      + '</tbody></table>'
    : '<div class="empty">no hook subscriptions</div>';
}

async function renderAudit(){
  const data = await api('/api/audit?limit=200');
  const entries = data.audit?.entries || [];
  $('audit').innerHTML = entries.length
    ? '<table><thead><tr><th>time</th><th>kind</th><th>plugin</th><th>detail</th></tr></thead><tbody>'
      + entries.slice().reverse().map((e) => `<tr><td class="muted">${esc(e.time)}</td>
          <td>${esc(e.kind)}</td><td>${esc(e.pluginId)}</td><td>${esc(e.detail)}</td></tr>`).join('')
      + '</tbody></table>'
    : '<div class="empty">audit log is empty</div>';
}

async function renderRaw(){
  const [status, plugins, doctor] = await Promise.all([
    api('/api/status'), api('/api/plugins'), api('/api/doctor'),
  ]);
  $('raw').textContent = JSON.stringify({ status, plugins, doctor }, null, 2);
}

/* -- actions ------------------------------------------------------------- */
document.addEventListener('click', async (event) => {
  const button = event.target.closest('button[data-action]');
  if(!button) return;
  const { action, id } = button.dataset;
  button.disabled = true;
  try{
    if(action === 'uninstall'){
      if(!confirm(`Uninstall ${id}? Plugin data will also be removed.`)) return;
      await api(`/api/plugins/${encodeURIComponent(id)}`, { method:'DELETE' });
    }else{
      await api(`/api/plugins/${encodeURIComponent(id)}/${action}`, { method:'POST' });
    }
  }catch(error){
    alert(`${action} failed: ${error.message}`);
  }finally{
    button.disabled = false;
    refresh();
  }
});

$('installBtn').addEventListener('click', async () => {
  const path = $('installPath').value.trim();
  if(!path) return;
  try{
    const result = await api('/api/install', {
      method:'POST',
      headers:{'Content-Type':'application/json'},
      body: JSON.stringify({ path, autoEnable: true }),
    });
    $('installPath').value = '';
    alert(`installed ${result.plugin.id}@${result.plugin.version}`);
  }catch(error){
    alert(`install failed: ${error.message}`);
  }finally{
    refresh();
  }
});

$('refreshBtn').addEventListener('click', refresh);
refresh();
setInterval(refresh, 5000);
</script>
</body>
</html>
"""


@dataclass
class ConsoleConfig:
    """Console server options."""

    host: str = DEFAULT_CONSOLE_HOST
    port: int = DEFAULT_CONSOLE_PORT
    registry_url: str = f"http://127.0.0.1:{DEFAULT_REGISTRY_PORT}"
    allow_install: bool = True


class ConsoleServer:
    """HTTP server backing the unified console."""

    def __init__(
        self,
        runtime: Any,
        *,
        registry: HostRegistry | None = None,
        config: ConsoleConfig | None = None,
        on_event: Callable[[str, Any], None] | None = None,
    ) -> None:
        self.runtime = runtime
        self.registry = registry
        self.config = config or ConsoleConfig()
        self.on_event = on_event
        self._server: ThreadingHTTPServer | None = None
        self._thread: threading.Thread | None = None

    @property
    def address(self) -> str:
        actual = self._server.server_address[1] if self._server else self.config.port
        return f"http://{self.config.host}:{actual}"

    def start(self, *, background: bool = True) -> "ConsoleServer":
        handler = self._make_handler()

        class _Server(ThreadingHTTPServer):
            daemon_threads = True
            allow_reuse_address = True

        try:
            self._server = _Server((self.config.host, self.config.port), handler)
        except OSError as exc:
            from .errors import TransportError

            raise TransportError(
                f"cannot bind the BTPS console to {self.config.host}:{self.config.port}: {exc}",
                port=self.config.port,
                hint="another process may already own port 6818",
            ) from exc

        self.config.port = self._server.server_address[1]
        if background:
            self._thread = threading.Thread(
                target=self._server.serve_forever, name="btps-console", daemon=True
            )
            self._thread.start()
        return self

    def serve_forever(self) -> None:
        if self._server is None:
            self.start(background=False)
        assert self._server is not None
        self._server.serve_forever()

    def stop(self) -> None:
        if self._server is not None:
            self._server.shutdown()
            self._server.server_close()
            self._server = None
        if self._thread is not None:
            self._thread.join(timeout=2.0)
            self._thread = None

    def __enter__(self) -> "ConsoleServer":
        return self.start()

    def __exit__(self, *exc_info: object) -> None:
        self.stop()

    # -- routing ------------------------------------------------------------ #

    def _make_handler(console_self) -> type[BaseHTTPRequestHandler]:  # noqa: N805
        runtime = console_self.runtime
        registry = console_self.registry
        config = console_self.config
        on_event = console_self.on_event

        class Handler(BaseHTTPRequestHandler):
            server_version = "BTPS-Console/1.0"
            protocol_version = "HTTP/1.1"

            # -- plumbing ------------------------------------------------ #

            def _send_json(self, payload: Any, status: int = HTTPStatus.OK) -> None:
                body = json.dumps(payload, ensure_ascii=False, default=str).encode("utf-8")
                self.send_response(status)
                self.send_header("Content-Type", "application/json; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                try:
                    self.wfile.write(body)
                except OSError:
                    pass

            def _send_html(self, text: str, status: int = HTTPStatus.OK) -> None:
                body = text.encode("utf-8")
                self.send_response(status)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                try:
                    self.wfile.write(body)
                except OSError:
                    pass

            def _read_json(self) -> dict[str, Any]:
                length = int(self.headers.get("Content-Length") or 0)
                if length <= 0:
                    return {}
                if length > 512_000:
                    raise BTPSError("request body too large", size=length)
                raw = self.rfile.read(length)
                parsed = json.loads(raw.decode("utf-8") or "{}")
                if not isinstance(parsed, dict):
                    raise BTPSError("request body must be a JSON object")
                return parsed

            def _fail(self, exc: Exception) -> None:
                status = HTTPStatus.BAD_REQUEST
                if isinstance(exc, PermissionDenied):
                    status = HTTPStatus.FORBIDDEN
                elif isinstance(exc, KeyError):
                    status = HTTPStatus.NOT_FOUND
                self._send_json(
                    {"ok": False, "error": str(exc), "type": type(exc).__name__},
                    status,
                )

            def log_message(self, fmt: str, *args: Any) -> None:  # noqa: A003
                if on_event is not None:
                    on_event("http", {"format": fmt, "args": args})

            # -- GET ----------------------------------------------------- #

            def do_GET(self) -> None:  # noqa: N802
                parsed = urlparse(self.path)
                route = parsed.path.rstrip("/") or "/"
                query = parse_qs(parsed.query)

                if route == "/":
                    self._send_html(_CONSOLE_HTML)
                    return

                try:
                    if route == "/api/status":
                        self._send_json(
                            {
                                "ok": True,
                                "runtime": runtime.summary(),
                                "registry": registry.describe() if registry else None,
                                "doctor": runtime.doctor(),
                                "console": {
                                    "address": f"http://{config.host}:{config.port}"
                                },
                            }
                        )
                        return

                    if route == "/api/doctor":
                        self._send_json({"ok": True, "doctor": runtime.doctor()})
                        return

                    if route == "/api/plugins":
                        self._send_json(
                            {
                                "ok": True,
                                "plugins": [r.to_dict() for r in runtime.list()],
                            }
                        )
                        return

                    if route.startswith("/api/plugins/"):
                        plugin_id = route.split("/", 3)[3]
                        record = runtime.get(plugin_id)
                        if record is None:
                            self._fail(KeyError(plugin_id))
                            return
                        payload = record.to_dict()
                        payload["sandbox"] = (
                            record.sandbox.envelope() if record.sandbox else None
                        )
                        self._send_json({"ok": True, "plugin": payload})
                        return

                    if route == "/api/packages":
                        roots = query.get("root") or None
                        found = runtime.discover(roots)
                        self._send_json(
                            {"ok": True, "packages": [p.to_dict() for p in found]}
                        )
                        return

                    if route == "/api/plan":
                        paths = query.get("path") or []
                        if not paths:
                            self._fail(BTPSError("the 'path' query parameter is required"))
                            return
                        plan = runtime.plan(paths, prune=bool(query.get("prune")))
                        self._send_json({"ok": True, "plan": plan.to_dict()})
                        return

                    if route == "/api/hosts":
                        if registry is not None:
                            self._send_json({"ok": True, "registry": registry.describe()})
                        else:
                            self._send_json(
                                {
                                    "ok": True,
                                    "registry": {
                                        "hosts": [],
                                        "note": "no registry handle was provided to the console",
                                    },
                                }
                            )
                        return

                    if route == "/api/hooks":
                        self._send_json({"ok": True, "hooks": runtime.hooks.describe()})
                        return

                    if route == "/api/audit":
                        limit = int((query.get("limit") or ["200"])[0])
                        entries = runtime.audit.entries()[-limit:]
                        self._send_json(
                            {
                                "ok": True,
                                "audit": {
                                    "count": len(entries),
                                    "entries": [e.to_dict() for e in entries],
                                },
                            }
                        )
                        return
                except BTPSError as exc:
                    self._fail(exc)
                    return
                except Exception as exc:  # noqa: BLE001 - surfaced as a JSON error
                    self._fail(exc)
                    return

                self._fail(KeyError(f"no route for GET {route}"))

            # -- POST ---------------------------------------------------- #

            def do_POST(self) -> None:  # noqa: N802
                route = urlparse(self.path).path.rstrip("/") or "/"
                try:
                    body = self._read_json()
                except Exception as exc:  # noqa: BLE001
                    self._fail(exc)
                    return

                try:
                    if route == "/api/install":
                        if not config.allow_install:
                            self._fail(
                                BTPSError("installation is disabled in this console configuration")
                            )
                            return
                        path = str(body.get("path", "")).strip()
                        if not path:
                            self._fail(BTPSError("the 'path' field is required"))
                            return
                        record = runtime.install(
                            path,
                            granted_permissions=body.get("grantedPermissions"),
                            auto_enable=bool(body.get("autoEnable", False)),
                            overwrite=bool(body.get("overwrite", False)),
                        )
                        self._send_json(
                            {"ok": True, "plugin": record.to_dict()},
                            HTTPStatus.CREATED,
                        )
                        return

                    parts = route.split("/")
                    # /api/plugins/<id>/<action>
                    if len(parts) >= 5 and parts[1] == "api" and parts[2] == "plugins":
                        plugin_id = parts[3]
                        action = parts[4]

                        if action == "enable":
                            record = runtime.enable(plugin_id)
                            self._send_json({"ok": True, "plugin": record.to_dict()})
                            return
                        if action == "disable":
                            record = runtime.disable(plugin_id)
                            self._send_json({"ok": True, "plugin": record.to_dict()})
                            return
                        if action == "reload":
                            record = runtime.reload(plugin_id)
                            self._send_json({"ok": True, "plugin": record.to_dict()})
                            return
                        if action == "permissions":
                            record = runtime.require(plugin_id)
                            if record.sandbox is None:
                                self._fail(BTPSError("plugin has no sandbox"))
                                return
                            for permission in body.get("grant", []):
                                record.sandbox.permissions.grant(str(permission))
                            for permission in body.get("revoke", []):
                                record.sandbox.permissions.revoke(str(permission))
                            runtime._save_state()
                            self._send_json(
                                {
                                    "ok": True,
                                    "permissions": record.sandbox.permissions.to_dict(),
                                }
                            )
                            return
                        if action == "dispatch":
                            hook = str(body.get("hook", ""))
                            if not hook:
                                self._fail(BTPSError("the 'hook' field is required"))
                                return
                            report = runtime.dispatch(hook, body.get("data") or {})
                            self._send_json({"ok": True, "report": report.to_dict()})
                            return
                except BTPSError as exc:
                    self._fail(exc)
                    return
                except Exception as exc:  # noqa: BLE001
                    self._fail(exc)
                    return

                self._fail(KeyError(f"no route for POST {route}"))

            # -- DELETE -------------------------------------------------- #

            def do_DELETE(self) -> None:  # noqa: N802
                parsed = urlparse(self.path)
                route = parsed.path.rstrip("/")
                query = parse_qs(parsed.query)

                if route.startswith("/api/plugins/"):
                    plugin_id = route.split("/", 3)[3]
                    keep_data = str((query.get("keepData") or ["0"])[0]).lower() in (
                        "1",
                        "true",
                        "yes",
                    )
                    try:
                        runtime.uninstall(plugin_id, keep_data=keep_data)
                    except BTPSError as exc:
                        self._fail(exc)
                        return
                    self._send_json(
                        {"ok": True, "uninstalled": plugin_id, "keptData": keep_data}
                    )
                    return

                self._fail(KeyError(f"no route for DELETE {route}"))

            def do_OPTIONS(self) -> None:  # noqa: N802
                self.send_response(HTTPStatus.NO_CONTENT)
                self.send_header("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
                self.send_header("Access-Control-Allow-Headers", "Content-Type")
                self.send_header("Content-Length", "0")
                self.end_headers()

        return Handler


def serve_console(
    runtime: Any,
    *,
    host: str = DEFAULT_CONSOLE_HOST,
    port: int = DEFAULT_CONSOLE_PORT,
    registry: HostRegistry | None = None,
) -> ConsoleServer:
    """Bind and start the console in a background thread."""
    config = ConsoleConfig(host=host, port=port)
    return ConsoleServer(runtime, registry=registry, config=config).start()
