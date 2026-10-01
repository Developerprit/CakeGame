/**
 * CakeGame WebSocket relay.
 *
 * The third transport, used only when the UDP hole punch does not land:
 * symmetric NAT, carrier-grade NAT, a corporate proxy, or the two players
 * simply picked "relay" in Settings. It is a dumb pipe - it does not read the
 * payload, it only routes binary frames to the other members of a room.
 *
 * Rooms are addressed with ?room=CODE. The game appends &role=host|client,
 * which this script uses only to report who the host is; routing never
 * depends on it.
 *
 * Note about state: on platforms that give you a fresh process per request,
 * in-memory state does not outlive a request. `roomRegistry()` therefore
 * mirrors the room list into the platform KV under `room_NNNN` keys so a
 * later request can still answer "is anybody in there?". The relay itself is
 * a long-lived WebSocket, so the live sockets are held in memory for exactly
 * as long as they are open.
 *
 * Standalone use:
 *   npm install ws
 *   node server/relay.node.js 8080
 */

var PORT = Number(process.argv[2] || process.env.PORT || 8080);

var rooms = Object.create(null);   // code -> Set(socket)
var sockets = [];                  // every live socket, for shutdown sweeping

function kvSet(key, value) {
  if (typeof KV === "undefined" || !KV || typeof KV.set !== "function") return;
  try { KV.set(key, value); } catch (e) { /* a relay that cannot persist is still a relay */ }
}
function kvGet(key) {
  if (typeof KV === "undefined" || !KV || typeof KV.get !== "function") return null;
  try { return KV.get(key); } catch (e) { return null; }
}

/** Persist the room list so a fresh process can still answer "is the room up?".
 *  `room_<code>` holds the number of members; the actual sockets are in flight. */
function roomRegistry() {
  var list = [];
  for (var code in rooms) {
    if (rooms[code].size > 0) {
      list.push(code);
      kvSet("room_" + code, String(rooms[code].size));
    }
  }
  return list;
}

function joinRoom(code, sock) {
  if (!rooms[code]) rooms[code] = new Set();
  rooms[code].add(sock);
}

function leaveRoom(code, sock) {
  if (!rooms[code]) return;
  rooms[code].delete(sock);
  if (rooms[code].size === 0) {
    delete rooms[code];
    kvSet("room_" + code, "0");
  } else {
    roomRegistry();
  }
}

function broadcast(code, sock, data) {
  var peers = rooms[code];
  if (!peers) return;
  for (var s of peers) {
    if (s === sock || s.readyState !== 1) continue;
    try { s.send(data, { binary: true }); } catch (e) { /* peer vanished */ }
  }
}

function roomOf(sock) {
  return sock.room || null;
}

function handleOpen(sock, req, room, role) {
  sock.room = room;
  sock.role = role || "client";
  joinRoom(room, sock);
  roomRegistry();
  var text = JSON.stringify({
    type: "welcome",
    room: room,
    role: sock.role,
    peers: rooms[room] ? rooms[room].size : 1,
  });
  if (sock.readyState === 1) {
    try { sock.send(text, { binary: false }); } catch (e) { /* ignore */ }
  }
}

function handleMessage(sock, data) {
  var room = roomOf(sock);
  if (!room) return;
  // Godot's WebSocketMultiplayerPeer sends binary frames; anything textual is
  // control traffic the game itself never sends, so it is relayed verbatim too.
  broadcast(room, sock, data);
}

function handleClose(sock) {
  var room = roomOf(sock);
  if (!room) return;
  leaveRoom(room, sock);
  var text = JSON.stringify({ type: "left", room: room, peers: rooms[room] ? rooms[room].size : 0 });
  try { broadcast(room, sock, Buffer.from(text)); } catch (e) { /* ignore */ }
}

// ---------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------

function attach(httpServer, WebSocketServerCtor, log) {
  // Neither branch can be optional: `ws` demands exactly one of port / server /
  // noServer, and passing { server: null } throws.
  var wss = new WebSocketServerCtor(httpServer ? { server: httpServer } : { port: PORT });

  wss.on("connection", function (sock, req) {
    var url = new URL(req.url, "http://localhost");
    var room = (url.searchParams.get("room") || "").toLowerCase().replace(/[^a-z0-9]/g, "");
    var role = (url.searchParams.get("role") || "client").toLowerCase();
    if (room.length < 4) {
      try {
        sock.send(JSON.stringify({ type: "error", error: "room code too short" }), { binary: false });
        sock.close();
      } catch (e) { /* ignore */ }
      return;
    }
    sockets.push(sock);
    sock.on("message", function (data) { handleMessage(sock, data); });
    sock.on("close", function () { handleClose(sock); });
    sock.on("error", function () { handleClose(sock); });
    handleOpen(sock, req, room, role);
    if (log) log("join " + room + " as " + role + " (" + rooms[room].size + ")");
  });

  return {
    close: function () {
      for (var s of sockets) { try { s.close(); } catch (e) { /* ignore */ } }
      sockets = [];
      wss.close();
    },
    rooms: rooms,
  };
}

// ---------------------------------------------------------------------------
// Platform entry point
//
// On a platform that supplies getPeers()/updatePeers() (Node.js cloud function),
// it calls this module from inside its own request lifecycle. A normal `node
// server/relay.node.js` starts a plain HTTP+WS server instead - which is how
// the local test below runs.
// ---------------------------------------------------------------------------

if (typeof getPeers === "function" && typeof WebSocketServer !== "undefined") {
  var relay = attach(null, WebSocketServer, console.log);

  module.exports = {
    onOpen: function (sock, req) { relay.close(); },
    onMessage: function (sock, data) { handleMessage(sock, data); },
    onClose: function (sock) { handleClose(sock); },
  };
} else if (typeof require === "function" && typeof module !== "undefined") {
  module.exports = { attach: attach, rooms: rooms, handleMessage: handleMessage, handleClose: handleClose };

  // Only a real `node server/relay.node.js` starts a listener. Requiring the
  // module (a test, a platform shim) must not grab a port behind its caller's
  // back.
  if (typeof window === "undefined" && typeof process !== "undefined" && require && require.main === module) {
    var WS = (function () {
      try { return require("ws"); } catch (e) { return null; }
    })();
    if (WS && typeof WS.WebSocketServer === "function") {
      require("http").createServer().listen(PORT, function () {
        console.log("[cakegame] relay listening on ws://127.0.0.1:" + PORT);
      });
      attach(null, WS.WebSocketServer, console.log);
    }
  }
}
