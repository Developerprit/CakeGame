#!/usr/bin/env python3
"""Smoke-test the CakeGame <-> BTPS bridge over loopback TCP.

Starts ``bridge.py --transport tcp``, reads the port off the ``ready`` line on
stdout, connects, and runs a fixed script of commands. Used to diagnose the
bridge without booting Godot.

Usage::

    python tools/btps_bridge_probe.py [path/to/plugin.btp]
"""

from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(HERE)
RUNTIME = os.path.join(PROJECT, "assets", "btps_runtime")
ROOT = os.path.join(PROJECT, "_check", "btps_root")


def main(argv: list[str]) -> int:
    plugin = argv[0] if argv else os.path.join(PROJECT, "_check", "btps", "example-bot-1.0.0.btp")
    python = sys.executable
    command = [
        python,
        os.path.join(RUNTIME, "bridge.py"),
        "--root",
        ROOT,
        "--transport",
        "tcp",
        "--log-file",
        os.path.join(PROJECT, "_check", "bridge.log"),
    ]
    proc = subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        bufsize=1,
    )

    hello = None
    deadline = time.time() + 15.0
    while time.time() < deadline:
        line = proc.stdout.readline()
        if not line:
            break
        payload = json.loads(line)
        if payload.get("event") == "ready":
            hello = payload
            break
        if payload.get("event") == "fatal":
            print("FATAL:", payload.get("msg"))
            return 1
    if hello is None:
        print("bridge never reported ready")
        proc.kill()
        return 1

    print("ready:", json.dumps({k: hello[k] for k in ("btps", "python", "port")}))
    sock = socket.create_connection((hello.get("host", "127.0.0.1"), hello["port"]), timeout=10)
    stream = sock.makefile("rw", encoding="utf-8", errors="replace")

    def send(ident: int, cmd: str, args=None) -> dict:
        stream.write(json.dumps({"id": ident, "cmd": cmd, "args": args or {}}) + "\n")
        stream.flush()
        while True:
            raw = stream.readline()
            if not raw:
                raise RuntimeError("bridge closed the connection")
            message = json.loads(raw)
            if "event" in message:
                print("  event:", json.dumps(message, ensure_ascii=False))
                continue
            return message

    print("ping:", send(1, "ping"))
    print("list:", [(p["id"], p["state"]) for p in send(2, "list")["result"]["plugins"]])
    if os.path.isfile(plugin):
        print("install:", send(3, "install", {"path": plugin, "auto_enable": True})["ok"])
    observation = {
        "self": {
            "pos": [100.0, 100.0], "vel": [0.0, 0.0], "hp": 100.0, "max_hp": 100.0,
            "state": "idle", "roll_cd": 0.0, "gun_cd": 0.0, "melee_cd": 0.0,
            "hook_cd": 0.0, "ammo": 7, "reloading": False,
        },
        "target": {
            "pos": [180.0, 140.0], "vel": [40.0, 0.0], "hp": 80.0, "state": "melee",
            "visible": True, "dist": 89.0,
        },
        "arena": {"w": 800.0, "h": 600.0},
        "tick": 5,
    }
    reply = send(
        4,
        "invoke",
        {
            "plugin": "com.kscm.cakegame.example-bot",
            "hook": "cakegame.bot.brain",
            "args": observation,
        },
    )
    print("invoke ok=%s result=%s" % (reply["ok"], json.dumps(reply.get("result"), ensure_ascii=False)))
    print("shutdown:", send(5, "shutdown")["ok"])
    try:
        sock.close()
    except OSError:
        pass
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:  # pragma: no cover
        proc.kill()
    print("probe done")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
