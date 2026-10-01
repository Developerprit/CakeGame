# CakeGame

> 2D top-down pixel brawling. 1–3 human players vs 1–2 high-skill AI bots. No dedicated server, no lobby server, no easy mode.

[中文说明](README-zh.md) · [落地页](index.html) · [许可证](LICENSE)

---

## What it is

CakeGame is a **top-down, pixel-art action brawler** built with Godot 4.5.1. One to three humans fight one to two AI bots in a team match you can run entirely on your own machine, or extend across a LAN / the open internet with a room code.

The design rule that shaped every system: **the bots are always the same difficulty.** There is no "easy" toggle, because a difficulty slider means shipping a bot that is deliberately worse, and that is not what a sparring partner is for. Bots predict your movement, dodge the shot you are about to take, use corners as cover, and switch between gun and melee depending on your state.

---

## Quick start

**Play the shipped build.** Drop `CakeGame.exe` anywhere and run it — the project is embedded in the binary, so there is no `project.pck` to keep next to it.

**Build it yourself.** You need the Godot 4.5.1 editor plus its export template, then:

```bash
godot --headless --path . --export-release "Windows Desktop" build/CakeGame.exe
```

The preset in `export_presets.cfg` embeds the pack, applies the icon and writes the Windows version resources. Use the **console** build of the editor (`Godot_v4.5.1-stable_win64_console.exe`) if you want the export log on stdout.

---

## Controls

The character **always faces your aim source**. With a mouse that is the pointer; with a pad it is the right stick. Movement and aim are fully independent, which is what makes the dodging read as skill rather than as clumsiness.

| Action | Keyboard / mouse | Gamepad |
| --- | --- | --- |
| Move | `W` `A` `S` `D` (arrows also work) | Left stick / D-pad |
| Aim | Mouse pointer | Right stick |
| Melee | **Right mouse** | `LB` |
| Draw / holster gun | `E` | `X` |
| Fire | **Left mouse** (gun must be drawn) | `RB` |
| Grapple hook | `Q` | `Y` |
| Roll (i-frames) | `Shift` | `B` |
| Reload | `R` | Left stick |
| Pause | `Esc` | `Start` |

Every binding except the mouse ones can be rebindable at runtime from Settings, and the game refuses a rebinding that would shadow a different action.

---

## Combat

All tuning lives in `src/core/balance.gd` — one file, no scattered magic numbers. Distances are authored at **1 tile = 16 px = 1 metre** and annotated with their m/s equivalent so a number can be sanity-checked without mental arithmetic.

| System | Numbers |
| --- | --- |
| Health | 100 HP, body radius 5 px |
| Movement | 57.6 px/s (3.6 m/s), 480 accel, 560 friction |
| Melee | 22 dmg, 24 px reach, ±0.95 rad arc, 0.38 s total, 0.55 s cooldown, 150 knockback |
| Gun | 12 dmg, 320 px/s bullet, 200 px range, 12-round mag, 1.4 s reload, 0.22 s cooldown, 3° bloom per shot |
| Grapple | 8 dmg, 520 px/s hook, 116 px range, 3.2 s cooldown, 1200 px/s² pull, keeps 62% of pull speed on release |
| Roll | 132 px/s for 0.42 s, 0.30 s of invulnerability, 0.90 s cooldown |
| Feel | hit-stop 0.075 s (melee) / 0.03 s (bullet) / 0.16 s (kill) |

The hook is the movement verb: it yanks you toward a wall **and** preserves momentum when you let go, so the same button is a gap-crosser, an escape, and a gap-closer.

---

## The bots

Two bots ship. To switch: Settings → **Bot version**.

`CakeGame AI Bot v1` (`cakegame_v1`) is the original, and is still the default. It re-plans every 0.06 s, but reacts on a 0.12 s delay — deliberately superhuman, never instant.

- **Predictive aim.** Leads the target using bullet speed and adds a second-order term for the target's acceleration, so it does not keep shooting where you stopped.
- **Predictive dodging.** Reads whether you are pointing at it (0.22 rad cone) and rolls on a 0.10 s reaction.
- **Range control.** Holds a preferred 58–92 px band, drops to melee inside 20 px, and disengages below 30 HP.
- **Cover and pathing.** Breaks a stalemate against a corner after 0.7 s, refreshes A* every 0.32 s, and unsticks itself after three failed 1.5 s windows.
- **Hunting.** Keeps extrapolating a target for 3.5 s after losing visual contact before sweeping for the enemy side, instead of orbiting a corpse.

`CakeGame AI Bot v1 pro` (`cakegame_v1_pro`) keeps v1's senses and changes what it does with them. The full argument is in `Planning/AI-Bot-v1-Pro.md`; the short version is one observation about the numbers:

> At the 58–92 px band v1 already holds, the target subtends 4.6° while the gun's cone is 3–6°. Even with bloom maxed the shot lands ~77% of the time on something that stays still — so **better aim is not where the headroom is**. What loses an exchange is that a target moving 57.6 px/s covers 16 px during the 0.28 s flight time, and that is 2.2× its own silhouette. `P(hit) = P(geometric) × P(he does not move out of the way)`, and the second factor dominates.

So v1 pro **banks its rounds**: it fires into windows where dodging is physically impossible and walks instead of spraying when it is not. Every one of those windows is readable off the opponent's animation — nothing hidden is consulted.

- **Commitment windows.** Locked targets (mid roll, the 0.90 s after a roll ends, mid swing, under hook stun) get focused fire; everything else gets positioning.
- **Scored dodging.** A roll covers ~45 px, so the landing is chosen, not random — v1 could spend its own 1.32 s roll lockout to end up in another part of the same corridor.
- **Fire discipline.** A geometric hit gate turns victory-range sprays into repositioning, which is why it deals more damage on FEWER shots.
- **Melee answers.** Melee is 22 damage, the biggest number in the game, and v1 never stepped out of a windup. It also stops swinging into targets that can simply roll away.
- **Multi-threat movement.** v1's steering only ever saw one target; v1 pro scores where it stands against everyone aiming at it.
- **Hook combos.** Guaranteed connect on a locked target → 8 damage + 0.22 s stun → close → swing. And a wall hook to disengage, which covers ~90 px versus a roll's 45.

### Measured, not asserted

`tests/bot_duel.tscn` runs a headless 1v1 between them — 24 seeds × 2 sides so neither brain owns a spawn side — with deaths respawned back into rifle range:

```
godot --headless --path . --fixed-fps 60 res://tests/bot_duel.tscn

48 duels  (17 decided, 31 draws)
cakegame_v1         5-12-31   win 10.4 pct (all)  win 29.4 pct (decided)
                    K/D 0.61   out-damaged opponent in 14.6 pct of duels
                    damage 3184   shots 797   damage per shot 33.3 of 12
cakegame_v1_pro    12-5-31   win 25.0 pct (all)  win 70.6 pct (decided)
                    K/D 1.64   out-damaged opponent in 37.5 pct of duels
                    damage 3604   shots 756   damage per shot 39.7 of 12
```

Three things to read off that:

1. **Fewer shots, more damage.** 756 vs 797 rounds fired for +13% damage. That is the fire gate working exactly as designed — the rounds that used to miss are now spent walking instead.
2. **19% better damage-per-shot** (39.7% of a bullet's nominal 12 vs 33.3%). Since duels include plenty of geometry-corner misses on both sides, this is the cleanest single measure of "did it stop wasting rounds".
3. **Decisive duels 12-5**, K/D 1.64 vs 0.61. Most duels end 0-0 because two competent bots rarely kill each other in 40 s, so wins alone are a noisy signal — which is why damage is tracked alongside.

Two methodological notes, because a benchmark that quietly lies is worse than no benchmark:

- The harness **pins the global RNG** (`seed(20261001)`). `ActorBody.fire_bullet()` spreads with the global `randf_range`, not the per-brain RNG, so unseeded runs of *identical code* produced 12-2 and 6-6. It now reproduces byte-for-byte.
- It samples **engagement every frame** from outside both brains (mutual line of sight, mean distance). An early configuration returned a run of 0-0 duels with zero shots fired, and without that column "they never met" and "they fought to a standstill" look identical.

The bot list is data, not code. Adding `CakeGame AI Bot v2` means dropping a script under `src/ai/` and adding one dictionary to `BotRegistry.ENTRIES` — the Settings dropdown reads that table, so no UI change is needed.

---

## Match flow

Three-scene router with a fade transition: **Main Menu → Lobby → Game**.

A match is a **team score race to 5** (configurable, 1–30). Rounds start with a 3 s countdown, end after 3.4 s of slow-motion, and award a point to the surviving team. Spawning is off by default: **last team standing wins the round**. Turn respawn on in Settings if you would rather play a single continuous brawl.

The camera is a `CameraRig` that frames **every** actor and dynamically zooms to fit them, clamped to a minimum extent of 200×112.5 px so one lone survivor does not get a absurdly wide view.

---

## Maps

- **Built-in arena** (default): hand-made, 34×34 tiles, predictable sightlines.
- **Seeded map**: a 56×56 procedural arena from a seed you type, or RANDOM if you leave the box empty. The seed is **latched for the session** — edit the box and it invalidates itself, so a rematch never silently rebuilds the previous arena while you thought you had asked for a new one.

---

## Playing together

**Listen Server.** Whoever creates the room is the host and the authority. Bots are simulated **only** on the host — that is what makes a 3-human-vs-2-bot match deterministic without shipping every bot brain to every client.

Three transports are tried in order, and gameplay RPC code never learns which one is live:

1. **LAN** — a UDP broadcast on `server_port - 1` finds a host, then a direct ENet connect on `server_port`. Say **SCAN LAN** in the lobby; a host answers with its room code.
2. **P2P** — the signalling server swaps public endpoints, then both sides bind the *same* UDP port and dial each other, so ENet's own outbound packets open the NAT.
3. **RELAY** — WebSocket fallback, used when the punch does not go through (symmetric or carrier-grade NAT, a corporate proxy).

Pick a preference in Settings (`auto` / `lan` / `p2p` / `relay`). `auto` punches first and relays on failure. **HOST P2P** in the lobby publishes the room; JOIN then reads the host's endpoint out of the code.

Both peers being forced onto `server_port` is deliberate — `ENetMultiplayerPeer.create_client()` defaults to an ephemeral local port, and a punch only lands when the NAT mapping ENet talks from is the one the other side punches at.

The signalling and relay endpoints are configurable:

```
signaling_url = https://cakegame.rth1.xyz/api.php
relay_url     = wss://cakegame.rth1.xyz/relay.node.js
```

### Self-hosting

[`server/`](server/) is a complete, small deployment:

| File | Role |
| --- | --- |
| `api.php` | Signalling. Answers `ping`, `whereami`, `announce`, `peers`, `leave`. Rooms are `room:<code>:<addr>` keys in the platform KV, swept after an hour idle. |
| `relay.node.js` | The WebSocket fallback. Routes binary frames to the other members of a room, mirrors the room list into the KV, and runs standalone with `node relay.node.js 8080`. |

Drop both on a PHP host plus a Node endpoint (Retinbox serves these as `api.php` and `relay.node.js`), then paste the URLs into Settings — or edit the defaults in `src/core/game_config.gd`. Nothing else has to change: the client probes both endpoints and degrades on its own.

`api.php` falls back to a flock'd JSON file next to itself when no KV class is present, which is what makes the protocol test below possible on any host.

---

## Settings

Everything persists to `user://settings.cfg`.

| Group | Options |
| --- | --- |
| Match | Bot version, seeded map + seed, max players (2–8), human slots, bot slots, round target score, friendly fire, respawn + delay |
| Feel | Mouse sensitivity, gamepad aim assist |
| Presentation | Dark / light theme, fullscreen, window scale 1–4×, master / SFX / music volume, light shadows, screen shake, damage numbers, FPS counter |
| Network | Player name, port, last host IP, last room code, signalling URL, relay URL, preferred transport |

Every setting is clamped on load, so a hand-edited config cannot produce an unplayable match.

---

## Project layout

```
project.godot            640x360 design resolution, expand stretch, GL Compatibility
export_presets.cfg       Windows Desktop preset (embedded pack, icon, version resources)
build/                   exported CakeGame.exe (gitignored)
assets/                  icon, fonts, procedural sprites, SFX
scenes/                  main_menu.tscn · lobby.tscn · game.tscn
src/
  core/         enums, balance, event bus, config, runtime InputMap, scene router, audio
  actors/       actor body + state machine, player, bot, combat, bullets, hook, FX
  states/       shared actor states
  ai/           bot brain base, registry, cakegame_v1, cakegame_v1_pro
  world/        arena, tile set builder, seeded map generator, camera rig
  ui/           pixel theme, main menu, settings, lobby, HUD, pause menu, game root
server/         deployable signalling (api.php) and relay (relay.node.js)
tests/          headless suites: selfcheck, match_sim, ui_smoke
promo/          screenshots used by index.html
```

**Art and audio are generated at build time, not shipped as hand-drawn files.** Sprites, tiles and SFX come from `src/data/atlas_library.gd` and `AudioDirector`, which is why the whole game is a single 97 MB binary and not a folder of texture atlases.

---

## Verification

Three headless suites run in the Godot engine itself — no external test runner:

```bash
godot --headless --path . res://tests/selfcheck.tscn     #  107 assertions
godot --headless --path . res://tests/match_sim.tscn     #  92 assertions
godot --headless --path . res://tests/ui_smoke.tscn      #  93 assertions
```

Note the invocation: the suites are **scenes**, not scripts, because `--script` does not bring the autoload singletons up and every one of them fails to compile.

The two servers have headless checks of their own: `api.php` answers a full ping → whereami → announce × 2 → peers → leave cycle under `php -S` (including the two rejections: a code under 4 characters, and an `addr` that is not `ip:port`), and `relay.node.js` is exercised by a two-socket test that asserts a binary frame reaches the other member byte-for-byte, that the sender gets no echo, and that a room on another code hears nothing.

`tests/harness.gd` counts assertions before and after each check. A check that errors out halfway through still trips the counter, so a silent "0 failed" means work actually ran. The UI smoke suite measures every panel inside the 640×360 design space in **both** themes, asserting controls stay on-screen, do not overlap, and keep a 0.5 contrast ratio against their own background.

---

## Building the Windows executable

`tools/build_exe.bat` does the full loop on Windows: it locates the Godot binary (several candidate paths, since a bare `godot` is often not on `PATH`), exports the release binary into `build/`, and reports the result.

To sanity-check a shipped binary instead of the editor:

```bash
./build/CakeGame.exe --write-movie frame.png --fixed-fps 30 --quit-after 40
```

That records 40 real rendered frames and exits — a black screen or a missing scene shows up immediately as a missing frame file rather than as a game that "looks like it launched".

---

## License

**Available License** — see [LICENSE](LICENSE). Use it, redistribute it, ship it; derivative closed-source works stay closed. Attribute the original project, development team and the source version you used.
