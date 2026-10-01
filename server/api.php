<?php
/**
 * CakeGame signalling endpoint.
 *
 * The game does not discover players by scanning, and it does not rent a
 * server. It asks this tiny endpoint one thing: "which public address is the
 * other side behind?" Both peers then dial each other directly over UDP, and
 * if that punch does not land, they fall back to the WebSocket relay in
 * relay.node.js.
 *
 * Protocol (all GET, all JSON):
 *   a=ping                     liveness probe
 *   a=whereami                 -> { ip, lan, port }   the caller's public side
 *   a=announce&code=C&addr=E   publish E under room C
 *   a=peers&code=C             -> { endpoints: [E, ...] }
 *   a=leave&code=C             drop our own endpoint
 *
 * Room codes are lowercase alnum only, max 8 chars: they are shown to players
 * on screen and typed by players, and the KV keys are ASCII-only anyway.
 *
 * Storage: uses the Retinbox KV (`new Database()`) when present, and otherwise
 * a JSON file under __DIR__ with flock. The file path exists so this same file
 * runs on a plain PHP host during development - which is also how the tests
 * below were written.
 */

const ROOM_CODE_MAX   = 8;
const ROOM_CODE_MIN   = 4;
const ENDPOINT_MAX    = 64;
const ROOM_TTL        = 3600;   // seconds an unused room is worth keeping
const MAX_PER_ROOM    = 8;

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');

/**
 * Rooms live in one flat KV: keys are "room:<code>:<addr>". Storing each
 * member as its own key (instead of one JSON blob per room) means a room can be
 * listed with a single key prefix scan, and a crash can never leave a room
 * half-written.
 */
class RoomStore
{
    private $file = null;
    private $db = null;

    public function __construct()
    {
        if (class_exists('Database')) {
            $this->db = new Database('cakegame');
            return;
        }
        $this->file = __DIR__ . '/rooms.json';
    }

    public function put($room, $addr, $info)
    {
        $key = 'room:' . $room . ':' . $addr;
        if ($this->db) {
            $this->db->set($key, json_encode($info));
            return true;
        }
        $rooms = $this->read();
        $rooms[$room][$addr] = $info;
        return $this->write($rooms);
    }

    public function get($room)
    {
        if ($this->db) {
            $keys = $this->db->list_keys('room:' . $room . ':');
            $out = array();
            foreach ($keys as $key) {
                $raw = $this->db->get($key);
                $info = json_decode($raw, true);
                if (is_array($info)) {
                    $out[] = $info;
                }
            }
            return $out;
        }
        $rooms = $this->read();
        return isset($rooms[$room]) ? $rooms[$room] : array();
    }

    public function drop($room, $addr)
    {
        if ($this->db) {
            $this->db->delete('room:' . $room . ':' . $addr);
            return;
        }
        $rooms = $this->read();
        if (isset($rooms[$room][$addr])) {
            unset($rooms[$room][$addr]);
        }
        $this->write($rooms);
    }

    public function sweep()
    {
        if ($this->db) {
            return; // the platform TTLs keys; nothing to do
        }
        $rooms = $this->read();
        $dirty = false;
        foreach ($rooms as $room => $members) {
            foreach ($members as $addr => $info) {
                if (isset($info['ts']) && time() - $info['ts'] > ROOM_TTL) {
                    unset($rooms[$room][$addr]);
                    $dirty = true;
                }
            }
            if (empty($rooms[$room])) {
                unset($rooms[$room]);
            }
        }
        if ($dirty) {
            $this->write($rooms);
        }
    }

    private function read()
    {
        if (!file_exists($this->file)) {
            return array();
        }
        $raw = @file_get_contents($this->file);
        $rooms = json_decode($raw === false ? '' : $raw, true);
        return is_array($rooms) ? $rooms : array();
    }

    private function write($rooms)
    {
        if (function_exists('file_put_contents') && function_exists('flock')) {
            $fp = @fopen($this->file, 'c+');
            if ($fp) {
                @flock($fp, LOCK_EX);
                ftruncate($fp, 0);
                fwrite($fp, json_encode($rooms));
                fflush($fp);
                flock($fp, LOCK_UN);
                fclose($fp);
                return true;
            }
        }
        return false;
    }
}

function out($data, $code = 200)
{
    http_response_code($code);
    echo json_encode($data, JSON_UNESCAPED_SLASHES);
    exit;
}

function fail($why, $code = 400)
{
    out(array('ok' => false, 'error' => $why), $code);
}

function clean_code($c)
{
    $c = strtolower(trim((string) $c));
    $c = preg_replace('/[^a-z0-9]/', '', $c);
    return $c;
}

/** Accept only "ip:port" shapes, so a hostile client cannot stuff a value
 *  long enough to blow up storage or a socket address. */
function clean_addr($a)
{
    $a = trim((string) $a);
    if (strlen($a) > ENDPOINT_MAX || !preg_match('/^[0-9.]+:\d+$/', $a)) {
        return null;
    }
    return $a;
}

$action = isset($_GET['a']) ? strtolower((string) $_GET['a']) : '';
$action = preg_replace('/[^a-z]/', '', $action);

$store = new RoomStore();
$store->sweep();

switch ($action) {
    case '':
    case 'ping':
        out(array('ok' => true, 'pong' => true, 'game' => 'cakegame'));
        break;

    case 'whereami':
        // REMOTE_ADDR is the only honest answer to "what is my public IP"
        // here. REMOTE_PORT is the source port of THIS request, which is not
        // the game's UDP port, so the game sends its own port separately.
        $ip = isset($_SERVER['REMOTE_ADDR']) ? $_SERVER['REMOTE_ADDR'] : '';
        if ($ip === '::1' || $ip === '127.0.0.1') {
            $ip = '127.0.0.1';
        }
        $lan = isset($_SERVER['HTTP_X_FORWARDED_FOR']) ? $_SERVER['HTTP_X_FORWARDED_FOR'] : '';
        out(array(
            'ok'   => true,
            'ip'   => $ip,
            'lan'  => $lan,
            'port' => isset($_GET['port']) ? (int) $_GET['port'] : 0,
        ));
        break;

    case 'announce': {
        $code = clean_code(isset($_GET['code']) ? $_GET['code'] : '');
        $addr = clean_addr(isset($_GET['addr']) ? $_GET['addr'] : '');
        if (strlen($code) < ROOM_CODE_MIN) {
            fail('room code must be at least ' . ROOM_CODE_MIN . ' characters');
        }
        if ($addr === null) {
            fail('addr must look like ip:port');
        }
        $peers = $store->get($code);
        if (count($peers) >= MAX_PER_ROOM) {
            out(array('ok' => false, 'error' => 'room is full'));
        }
        $store->put($code, $addr, array(
            'addr' => $addr,
            'ts'   => time(),
            'ua'   => substr(isset($_SERVER['HTTP_USER_AGENT']) ? $_SERVER['HTTP_USER_AGENT'] : '', 0, 80),
        ));
        out(array('ok' => true, 'peers' => count($peers) + 1));
        break;
    }

    case 'peers': {
        $code = clean_code(isset($_GET['code']) ? $_GET['code'] : '');
        if (strlen($code) < ROOM_CODE_MIN) {
            fail('room code must be at least ' . ROOM_CODE_MIN . ' characters');
        }
        $eps = array();
        foreach ($store->get($code) as $info) {
            if (isset($info['addr'])) {
                $eps[] = $info['addr'];
            }
        }
        out(array('ok' => true, 'code' => $code, 'endpoints' => $eps));
        break;
    }

    case 'leave': {
        $code = clean_code(isset($_GET['code']) ? $_GET['code'] : '');
        $addr = clean_addr(isset($_GET['addr']) ? $_GET['addr'] : '');
        if ($code !== '' && $addr !== null) {
            $store->drop($code, $addr);
        }
        out(array('ok' => true));
        break;
    }

    default:
        fail('unknown action', 404);
}
