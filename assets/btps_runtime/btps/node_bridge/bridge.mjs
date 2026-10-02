// MIT License
//
// Copyright (c) 2026 kscm (Developerprit)
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

/**
 * BTPS Node bridge.
 *
 * Two responsibilities:
 *
 *   1. `describe` — import a plugin entry module, report its exported callables
 *      and its declared hook bindings as JSON on stdout.
 *   2. `invoke`  — run a single hook handler with a request payload and report
 *      the return value as JSON.
 *
 * Why a subprocess rather than `vm` in-process: the Python host and the Node
 * runtime cannot share a heap, so a subprocess is the only honest isolation
 * boundary available. It also means a JS plugin that hangs is killable, which
 * is not true of an in-process VM context.
 *
 * Protocol — newline-delimited JSON:
 *
 *   stdout  {"ok":true,"data":{...}}          on success
 *           {"ok":false,"error":"...","type":"..."}  on failure
 *
 *   stdin (invoke mode)  {"handler":"name","payload":{...}}
 *
 * The bridge writes exactly one JSON object to stdout per process, so callers
 * never need to parse interleaved output. Anything the plugin prints to stdout
 * is captured and forwarded inside the response, keeping the channel clean.
 */

import { pathToFileURL } from 'node:url';
import { createRequire } from 'node:module';
import path from 'node:path';
import fs from 'node:fs';
import process from 'node:process';

const require = createRequire(import.meta.url);

/* -------------------------------------------------------------------------- */
/* Output channel                                                              */
/* -------------------------------------------------------------------------- */

const captured = [];

/**
 * Redirect plugin writes into a buffer so they cannot corrupt the JSON channel.
 * The original writers are preserved and used for the final response.
 */
function captureStdio() {
  const original = {
    stdout: process.stdout.write.bind(process.stdout),
    stderr: process.stderr.write.bind(process.stderr),
  };

  const record = (stream) => (chunk, encoding, callback) => {
    try {
      const text = typeof chunk === 'string' ? chunk : Buffer.from(chunk).toString(
        typeof encoding === 'string' ? encoding : 'utf8',
      );
      captured.push({ stream, text });
    } catch {
      /* Never let logging break the protocol. */
    }
    if (typeof encoding === 'function') encoding();
    else if (typeof callback === 'function') callback();
    return true;
  };

  process.stdout.write = record('stdout');
  process.stderr.write = record('stderr');

  return () => {
    process.stdout.write = original.stdout;
    process.stderr.write = original.stderr;
  };
}

function respond(payload, restore) {
  restore?.();
  process.stdout.write(`${JSON.stringify(payload)}\n`);
}

function fail(error, restore) {
  respond(
    {
      ok: false,
      error: error instanceof Error ? error.message : String(error),
      type: error instanceof Error ? error.constructor.name : 'Error',
      stack: error instanceof Error ? error.stack : undefined,
      captured: captured.slice(0, 200),
    },
    restore,
  );
  process.exitCode = 1;
}

/* -------------------------------------------------------------------------- */
/* Context                                                                     */
/* -------------------------------------------------------------------------- */

/**
 * Build the JS face of the plugin context.
 *
 * Every privileged operation is delegated to the host over a request/response
 * file pair, because the sandbox lives on the Python side. This keeps one
 * implementation of the permission rules: the JS side cannot disagree with the
 * Python side about what is allowed, because the JS side does not decide.
 */
function buildContext(hostBridge) {
  const call = hostBridge.call;

  return {
    id: hostBridge.pluginId,
    pluginId: hostBridge.pluginId,
    version: hostBridge.version,
    name: hostBridge.name,
    packageDir: hostBridge.packageDir,
    dataDir: hostBridge.dataDir,

    log: {
      debug: (message, context = {}) => call('log', { level: 'debug', message, context }),
      info: (message, context = {}) => call('log', { level: 'info', message, context }),
      warn: (message, context = {}) => call('log', { level: 'warn', message, context }),
      error: (message, context = {}) => call('log', { level: 'error', message, context }),
    },

    storage: {
      get: (key, fallback = null) => call('storage.get', { key, default: fallback }),
      set: (key, value) => call('storage.set', { key, value }),
      delete: (key) => call('storage.delete', { key }),
      keys: (prefix = '') => call('storage.keys', { prefix }),
      clear: () => call('storage.clear', {}),
    },

    settings: {
      get: (key, fallback = null) => call('settings.get', { key, default: fallback }),
      all: () => call('settings.all', {}),
    },

    fs: {
      read: (target, options = {}) => call('fs.read', { path: target, binary: Boolean(options.binary) }),
      readAsset: (target, options = {}) => call('fs.readAsset', { path: target, binary: Boolean(options.binary) }),
      write: (target, data) => call('fs.write', { path: target, data }),
      exists: (target) => call('fs.exists', { path: target }),
      list: (target = '.') => call('fs.list', { path: target }),
    },

    net: {
      get: (url, options = {}) => call('net.request', { url, method: 'GET', ...options }),
      post: (url, body = '', options = {}) => call('net.request', { url, method: 'POST', body, ...options }),
    },

    host: {
      notify: (title, body = '') => call('host.notify', { title, body }),
      hasCapability: (name) => call('host.capability', { name }),
      version: () => call('host.version', {}),
      apiVersion: () => call('host.apiVersion', {}),
    },

    events: {
      emit: (hook, payload = {}) => call('events.emit', { hook, payload }),
      on: () => {
        throw new Error(
          'ctx.events.on() is not available from the Node bridge: '
          + 'declare the hook in btps.json instead, so the host can route it',
        );
      },
    },

    hasPermission: (permission) => call('permission.check', { permission }),
    permissions: () => call('permission.list', {}),
  };
}

/* -------------------------------------------------------------------------- */
/* Host bridge (file-based request/response)                                   */
/* -------------------------------------------------------------------------- */

/**
 * File-based RPC back to the Python host.
 *
 * Chosen over sockets so the bridge works identically on every platform without
 * port allocation, firewall prompts, or nested-sandbox issues — and so the
 * request/response exchange is inspectable on disk when debugging.
 */
function createHostBridge(options) {
  const { requestDir, pluginId, version, name, packageDir, dataDir } = options;
  let sequence = 0;

  return {
    pluginId,
    version,
    name,
    packageDir,
    dataDir,
    call(method, params) {
      sequence += 1;
      const token = `${process.pid}-${sequence}`;
      const requestPath = path.join(requestDir, `req-${token}.json`);
      const responsePath = path.join(requestDir, `res-${token}.json`);

      fs.writeFileSync(
        requestPath,
        JSON.stringify({ method, params, pluginId, token }),
        'utf8',
      );

      const deadline = Date.now() + 30_000;
      while (!fs.existsSync(responsePath)) {
        if (Date.now() > deadline) {
          throw new Error(`host bridge timed out for method ${method}`);
        }
        // Busy-wait: this process exists only to service one call, so a sleep
        // loop is simpler than bringing in async plumbing.
        Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 5);
      }

      const raw = fs.readFileSync(responsePath, 'utf8');
      fs.rmSync(responsePath, { force: true });
      const parsed = JSON.parse(raw);
      if (!parsed.ok) {
        const error = new Error(parsed.error || `host refused ${method}`);
        error.name = parsed.type || 'HostError';
        throw error;
      }
      return parsed.data;
    },
  };
}

/* -------------------------------------------------------------------------- */
/* Commands                                                                    */
/* -------------------------------------------------------------------------- */

async function loadModule(entry) {
  const url = pathToFileURL(path.resolve(entry)).href;
  return import(url);
}

/**
 * Describe a plugin module: exported symbol names, their arity, and any
 * `btps` export block declaring metadata the manifest did not carry.
 */
async function describe(entry, options) {
  const module = await loadModule(entry);
  const exports = {};

  for (const [name, value] of Object.entries(module)) {
    if (typeof value !== 'function') continue;
    exports[name] = {
      type: 'function',
      arity: value.length,
      async: value.constructor?.name === 'AsyncFunction',
    };
  }

  // `export const btps = { hooks: {...} }` lets a JS plugin declare its hook
  // bindings alongside the code, mirroring the Python `btps_setup` contract.
  let declared = null;
  if (module.btps && typeof module.btps === 'object') {
    declared = {
      hooks: module.btps.hooks ?? null,
      setup: typeof module.btps.setup === 'function' ? 'btps.setup' : null,
    };
  }

  const context = buildContext(createHostBridge(options));
  let setupResult = null;
  if (typeof module.btps?.setup === 'function') {
    setupResult = await module.btps.setup(context);
  } else if (typeof module.setup === 'function') {
    setupResult = await module.setup(context);
  }

  return {
    runtime: process.version,
    exports,
    declared,
    setupResult: setupResult ?? null,
    modulePath: path.resolve(entry),
    symbolCount: Object.keys(exports).length,
  };
}

/** Invoke one handler by name and return its result. */
async function invoke(entry, options, request) {
  const module = await loadModule(entry);
  const handler = module[request.handler];

  if (typeof handler !== 'function') {
    throw Object.assign(
      new Error(`handler ${JSON.stringify(request.handler)} is not exported by the module`),
      { name: 'MissingHandler' },
    );
  }

  const context = buildContext(createHostBridge(options));
  const payload = request.payload ?? {};
  const value = await handler(context, payload);
  return { returned: value ?? null };
}

/* -------------------------------------------------------------------------- */
/* Entry point                                                                 */
/* -------------------------------------------------------------------------- */

async function main() {
  const argv = process.argv.slice(2);
  const command = argv[0];
  const restore = captureStdio();

  let options = {};
  try {
    options = JSON.parse(argv[1] ?? '{}');
  } catch (error) {
    fail(new Error(`invalid options JSON: ${error.message}`), restore);
    return;
  }

  const { entry } = options;
  if (!entry) {
    fail(new Error('the "entry" option is required'), restore);
    return;
  }

  try {
    if (command === 'describe') {
      respond({ ok: true, data: await describe(entry, options) }, restore);
      return;
    }

    if (command === 'invoke') {
      const raw = await readStdin();
      const request = JSON.parse(raw || '{}');
      respond({ ok: true, data: await invoke(entry, options, request) }, restore);
      return;
    }

    fail(new Error(`unknown command ${JSON.stringify(command)}; expected "describe" or "invoke"`), restore);
  } catch (error) {
    fail(error, restore);
  }
}

function readStdin() {
  return new Promise((resolve, reject) => {
    let buffer = '';
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', (chunk) => {
      buffer += chunk;
    });
    process.stdin.on('end', () => resolve(buffer));
    process.stdin.on('error', reject);
  });
}

main();
