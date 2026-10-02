# CakeGame × BTPS — 插件宿主规划书 / Plugin Host Planning

> 版本 v1.0 · 目标：把 **BTPS 1.0**（BrickTile Plugin System）嵌进 CakeGame，让它能装 `.btp` 插件。
> 引擎 Godot 4.5.1-stable · 包格式 `.btp`（ZIP + `btps.json`）· 参考实现 `E:/PC/BrickTile`（MIT，同一作者）

---

## 0. 需求确认纪要（本轮三轮问答）

| 议题 | 最终决策 |
|---|---|
| 宿主实现方式 | **外挂 Python 进程桥** —— 100% 复用 `btps` 参考实现，插件入口是 `.py` |
| 插件能改什么 | **① 自定义 Bot 大脑 ② 自定义地图/种子生成 ③ 额外内容**（皮肤 / 音效） |
| 插件从哪来 | **`user://plugins` 扫描 + 设置面板管理**（启用 / 停用 / 卸载，状态持久化） |

未开放（本轮明确不做，说明理由见 §6.2）：
- **不开放 Balance 数值覆写** —— `Balance` 全是 `const`，改成运行时可变要触动全部调用点，风险远大于收益。
- **不开放 HUD 面板注入** —— 未选中；且面板重建走 `I18n.rebuild_panel`，外部节点混进来会破坏双语重建的假设。

---

## 1. 技术选型论证 / Trade-off

### 1.1 核心矛盾

BTPS 参考实现是**纯 Python**（`btps/` 约 472 KB，零第三方依赖），而 CakeGame 宿主是 **Godot / GDScript**，exe 里没有 Python 解释器。
所以"塞一个 BTPS"本质上是一道桥接题，不是移植题。

### 1.2 三方案对比

| 维度 | **A. 外挂 Python 桥（选用）** | B. GDScript 原生重写运行时 | C. 双栈（A+B） |
|---|---|---|---|
| 规范保真度 | **100%**（直接调 `btps.runtime.PluginRuntime`） | 有漂移风险：清单校验、semver、沙箱、依赖解析要全部重实现 | 100% |
| 插件语言 | Python（btps 生态既有插件直接可用） | 需新造 `godot` runtime，破坏跨宿主互通 | 两者 |
| 交付形态 | **exe 仍需本机有 Python**（便携 Python 可放旁边） | 纯单 exe，零依赖 | exe + 可选 Python |
| 实现工作量 | 中（一个桥 + 宿主状态机） | 大（≈3k 行 GDScript） | 最大 |
| 失败影响面 | Python 缺失 → **优雅降级，游戏照常** | 无外部失败面 | 同 A |
| 隔离性 | **进程级**（插件崩了只死桥进程） | 同进程（插件异常直接进 Godot 栈） | 视路径 |

**结论**：选 A，但必须把"Python 缺失"做成一等公民失败模式（§6.1），否则就违背了 CakeGame 目前"双击 exe 就能玩"的承诺。

### 1.3 桥的传输方式

| 方案 | 延迟 | 复杂度 | 结论 |
|---|---|---|---|
| 每次 `OS.execute` 调 CLI | ~80–200 ms/次（进程启动） | 低 | ❌ 60 Hz 决策下完全不可用 |
| 长驻子进程 + stdio 行式 JSON | ~1–5 ms/次 | 中 | ⚠️ 见下方「实现修订」 |
| **长驻子进程 + TCP 回环 + 端口文件握手（最终采用）** | ~1–3 ms/次 | 中 | ✅ |
| 共享内存 / mmap | 亚毫秒 | 高 | 过度设计 |

#### 实现修订：为什么最终不是 stdio

设计时选的是 stdio，落地时发现 **`OS.execute_with_pipe()` 只给 child's stdout / stderr，不给 stdin**。
单向管道承载不了「请求→响应」这种必须写回去的协议，而 0.06 s 一次的 Bot 大脑调用正是这种协议。
所以改成：`bridge.py` 在 127.0.0.1 上绑定一个临时端口，把端口号写进 `--port-file`，Godot 侧轮询该文件后连接。

| 坑 | 表现 | 结论 |
|---|---|---|
| `execute_with_pipe` 无 stdin | 桥收不到任何命令，永远不 publish 端口 | 改用 `OS.create_process`（不建管道）+ TCP |
| autoload `_ready` 里 spawn | 子进程存活但**一行都没跑**，主循环自旋时饿死 | 延迟 `BOOT_DELAY_FRAMES = 8` 帧再启动 |
| 探测命令与启动命令不一致 | `py` 单独用找不到解释器，必须 `py -3` | 探测与启动共用同一个 `python_cmd` |
| 桥顶层 `from btps import ...` 被改成延迟导入 | 类定义阶段 `DefaultHostAdapter` 为 None 直接崩 | 恢复顶层导入，另加 `bridge.crash.log` 兜底 |

**结论**：选 TCP + 端口文件，但保留 §2 的整体架构。stdio 版本作为历史方案记录在案。


---

## 2. 架构 / Architecture

```
┌──────────────────────── Godot (CakeGame.exe) ────────────────────────┐
│                                                                      │
│  BtpsHost (autoload)  ── 生命周期 / 权限 / 扩展点注册表 / tick 派发     │
│        │                                                             │
│        ├── BtpsBridge ── 长驻 python 子进程 + 轮询握手 + 请求队列      │
│        │        │                                                    │
│        │        └── 行式 JSON-RPC over TCP 回环（端口文件握手）        │
│        │                                                             │
│        ├── BtpsBotBrain (BotBrain 子类) ── 异步影子大脑                │
│        ├── MapGenerator 钩子 ── cakegame.map.generate（开局一次性）    │
│        └── SettingsPanel PLUGINS 区块 ── 双语管理 UI                  │
└──────────────────────────────┬───────────────────────────────────────┘
                               │ TCP 127.0.0.1:<ephemeral>
┌──────────────────────────────┴───────────────────────────────────────┐
│  bridge.py (user://btps_runtime/bridge.py)                            │
│        └── import btps → PluginRuntime(install_root=user://plugins)   │
│              install / load / enable / disable / uninstall / emit      │
└──────────────────────────────────────────────────────────────────────┘
```

### 2.1 文件清单

| 路径 | 作用 |
|---|---|
| `assets/btps_runtime/btps/*.py` | vendored 参考实现（MIT，随包释放） |
| `assets/btps_runtime/bridge.py` | Python 侧桥：stdin 行式命令 → `PluginRuntime` |
| `assets/btps_runtime/VERSION` | 运行时版本戳，用于"释放是否要更新" |
| `src/btps/btps_manifest.gd` | 清单轻量校验（UI 展示 / 准入预判），真校验仍由 Python 侧做 |
| `src/btps/btps_bridge.gd` | 子进程 + 读线程 + 请求/响应配对 |
| `src/btps/btps_host.gd` | autoload：状态机、扫描、权限、扩展点、tick |
| `src/ai/btps_bot_brain.gd` | 异步影子大脑（超时降级到 `BotV1`） |
| `plugins-src/cakegame-example-bot/` | 示例插件源码（bot 大脑） |
| `plugins-src/cakegame-example-map/` | 示例插件源码（地图） |
| `tests/btps_smoke.gd/.tscn` | 无头全链路验收 |

### 2.2 为什么运行时要"释放到 user://"

单文件 exe 里 `res://` 是 pck 内的虚拟路径，**Python 拿不到真实文件路径**。
所以启动时把 `res://assets/btps_runtime/` 整个拷到 `user://btps_runtime/`（用 `VERSION` 戳做幂等，避免每次启动都拷 472 KB）。

---

## 3. 桥协议 / Wire Protocol

**一行为一个 JSON**（`\n` 结尾），UTF-8，无换行内嵌（JSON 字符串自带转义）：

请求：

```json
{"id": 17, "cmd": "invoke", "plugin": "com.example.bot", "fn": "bot_decide", "args": {...}}
```

响应：

```json
{"id": 17, "ok": true,  "result": {...}}
{"id": 17, "ok": false, "error": "PermissionDenied: cakegame.bot.brain"}
```

事件（无 id，宿主单向推）：

```json
{"event": "ready", "btps": "1.0.0", "python": "3.13.5"}
{"event": "log",   "level": "warn", "plugin": "...", "msg": "..."}
```

| 命令 | 参数 | 说明 |
|---|---|---|
| `ping` | — | 探活，回 `{"pong":true}` |
| `scan` | — | 扫 `user://plugins` 下 `*.btp`，返回候选（未安装 / 已安装） |
| `list` | — | 已安装插件 + 状态 + manifest 摘要 + 权限 |
| `install` | `path` | 装一个 `.btp`（走 `PluginRuntime.install`） |
| `enable` / `disable` / `uninstall` | `id` | 生命周期 |
| `emit` | `hook`, `data` | 派发核心钩子（`host.startup` / `tick` / …） |
| `invoke` | `plugin`, `fn`, `args` | 调插件导出的能力函数 |
| `shutdown` | — | 优雅退出（派发 `host.shutdown`） |

**关键约束**：`emit` 必须**不等待返回就继续**（fire-and-forget 语义对大多数事件成立），只有 `invoke` 需要配对响应。
因为钩子单条默认超时 5 s，而 Godot 主循环不能等。

---

## 4. 扩展点与权限 / Extension Points

主机名 `cakegame`，宿主版本沿用游戏版本，API 版本 `1.0.0`。

| 扩展点（钩子 / 能力） | 权限 | 调用频率 | 语义 |
|---|---|---|---|
| `cakegame.startup` | — | 1 次 | 宿主就绪 |
| `cakegame.shutdown` | — | 1 次 | 退出前 |
| `cakegame.tick` | `cakegame.match.read` | 每 0.5 s（**不是每帧**） | 低频心跳 |
| `cakegame.match.begin` / `.end` | `cakegame.match.read` | 每回合 | 只读广播 |
| `cakegame.actor.damaged` / `.died` | `cakegame.match.read` | 每次事件 | 只读广播 |
| **`cakegame.bot.brain`** | `cakegame.bot.brain` | 每 0.06 s（影子模式） | 插件返回意图，见 §5 |
| **`cakegame.map.generate`** | `cakegame.map.generate` | 每回合 1 次 | 返回修改后的 tile 数组 |
| **`cakegame.content.register`** | `cakegame.content.skin` / `.sfx` | 1 次 | 皮肤 / 音效注册 |
| `host.ui.notify` | `host.ui.notify` | 按需 | 弹一条原生通知 |

权限串全部满足 BTPS 正则 `^[a-z][a-z0-9]*(\.[a-z0-9_-]*)+(:[^\s]+)?$`（至少两级）。
**敏感前缀**（`fs.write` / `net.` / `host.process` / `host.env`）安装时弹同意，不静默授予。

---

## 5. 延迟权衡：Bot 大脑走"异步影子"

这是整个设计里唯一有真实时间压力的地方。

- `BotBrain.decide()` 每 **0.06 s** 跑一次，`update_aim()` 每帧跑。
- 跨进程往返约 1–5 ms —— 听起来够快，但**不能同步等待**：一次 GC、一次杀软扫描、一次插件自己的重活都可能把它拖到几十 ms，而 Godot 主循环是同步阻塞的，一帧卡住就是掉帧。

所以采用 **影子大脑（shadow brain）**：

```
think 时刻 t：把观测 O(t) 异步发出，不等待
             ↓
决策沿用上一轮的意图 I(t-1)（延迟 1~2 帧，人眼不可见，且 v1 本身也有 0.12 s 反应延迟的设定）
             ↓
I(t) 回来 → 覆盖；超时 0.5 s 未回 → 标记 stale，降级为 BotV1 行为并计数
```

| 方案 | 一帧最坏耗时 | 决策新鲜度 | 结论 |
|---|---|---|---|
| 同步等桥 | 受插件支配（可能 >100 ms） | 总是最新 | ❌ 会掉帧 |
| **异步影子** | **≈0**（只做一次入队） | 滞后 1–2 帧（≈16–33 ms） | ✅ |
| Godot 侧跑 Python 决策的缓存副本 | 低 | 高 | 过度设计 |

观测载荷（JSON，约 20 个字段）：自身 `pos/vel/hp/state/cooldowns`、目标 `pos/vel/hp/state/visible`、队友摘要、arena 尺寸、tick 序号。
响应：`move_dir`、`aim`、`want_gun/want_melee/want_hook/want_roll`（布尔）。**数值全部由 Godot 侧 clamp**，插件不能凭返回值把移速改到天上。

---

## 6. 失败模式与降级 / Failure Modes

### 6.1 Python 缺失（一等公民）

| 状态 | UI 呈现 | 游戏行为 |
|---|---|---|
| `DISABLED`（玩家关掉） | 灰色提示 | 不加载插件 |
| `NO_PYTHON` | 提示 + 手动指定路径入口 | **游戏完全正常**，仅插件不可用 |
| `RUNTIME_ERROR` | 显示最后一行 stderr | 游戏正常 |
| `READY` | 列出插件 | 全功能 |

Python 探测顺序：玩家配置 → `py -3` → managed Python → 系统 Python → PATH `python`。
**探测必须验证输出**：Windows 上 `WindowsApps/python.exe` 是符号链接，会**静默失败（零输出、非 0 退出）**，所以必须真的 `-c "print(1)"` 拿到 `1` 才算有效。

### 6.2 插件崩溃 / 恶意插件

- 插件在**独立进程**里跑 → 崩溃只死桥进程，Godot 侧检测到 EOF 后**自动重启桥一次**，再失败就转 `RUNTIME_ERROR`。
- 如实告知：btps 的沙箱是**边界约束**（权限闸门 + PathGuard + 超时），**不是恶意代码容器**。同进程 Python 无法对抗刻意逃逸。
  → 设置面板里明确写一行：`插件以你的用户权限运行，只装你信任的插件。`（中英双语）
- 卸载是破坏性操作 → **二次确认弹窗**（这属于用户无法在软件内撤销的行为，必须拦一道）。

### 6.3 联机一致性（重要，别踩）

CakeGame 是 Listen Server：Host 权威。插件**只在本地生效**，不同步给客户端。
→ 因此插件**不得影响权威模拟**（不改伤害、不改命中判定），只影响：Bot 决策（Host 侧本来就独占 AI）、地图生成（种子同步，插件若改地图会让客户端地形不一致！）

**处理**：`cakegame.map.generate` 只在**离线/单机**生效；联机时若检测到有插件订阅该钩子，Host 侧提示并**跳过**插件，保证地形与客户端一致。这一条必须在文档和 UI 里写清楚。

---

## 7. 验收标准 / Acceptance

| # | 标准 | 手段 | 结果 |
|---|---|---|---|
| 1 | `.btp` 能被发现、安装、启用、停用、卸载 | `tests/btps_smoke`（无头，真 Python） | ✅ 15/0 |
| 2 | 插件大脑能真的驱动一个 Bot | 同上，8 s 对局统计回复数与开火帧 | ✅ 473 次回复 / 148 开火帧 / 位移 156 px |
| 3 | 插件能改地图 | 同上，比对 tile 数组确实被改 | ⏳ 未实现（钩子已注册，未接 MapGenerator） |
| 4 | 无 Python / 桥崩溃时游戏不受影响 | `tests/btps_degrade`：指向不存在的解释器 + 运行中杀桥 | ✅ 18/0 |
| 5 | 三套既有回归不掉 | `selfcheck` / `match_sim` / `ui_smoke` | ✅ 107/0、92/0、106/0 |
| 6 | 管理 UI 中英双语 | 设置面板 PLUGINS 区块 + `ui_smoke` 断言区块已构建 | ✅ 106/0（未做 zh/en 截图） |
| 7 | 单 exe 仍可导出且运行时能释放 | 重导出后跑 `--headless` 冒烟 | ✅ 见 §9 |

### 7.1 测试装置上的一个教训（值得单列）

第一次跑 `btps_smoke` 时，「Bot 会移动」绿了、「Bot 从不开枪」红了。看起来像桥坏了。

实际诊断数据是：`replies: 471`（8 s 480 帧几乎每帧都有回复）、`visible: 0`、`ammo: 12`、`gun_out: 476`。
**桥、Python、插件全链路完全正常** —— 真正的原因是 rig 把两个 Bot 生成在了互相看不见的位置。
`pick_target()` 只在**可见**敌人里选，无视线时 `target` 为 null，插件收到的就是
`{visible: false, dist: 0}`，于是它正确地拒绝了开枪。

修法不是放宽断言，而是把前置条件变成被断言的事实：新增 `_place_duel()` 扫描地图找一对互相有视线的落点，
并加一条 `ok(placed, "the rig gives both bots a line of sight")`。
**教训**：当"AI 不做某事"时，先证明它*能*看到，再证明它*没有做**。
中间还踩了两个自己的 bug，都写进了注释：视线校验在传送 Bot **之前**算（起点错了），
以及把 `Combat.has_line` 当成 `ActorBody` 的方法调用（它其实在 `BotBrain` 与 `Combat` 上）。


---

## 8. 被否决的方案 / Rejected

| 方案 | 否决理由 |
|---|---|
| GDScript 重写 BTPS 运行时 | 规范漂移 + 3000 行重复实现；用户已选外挂桥 |
| 每次调用 `OS.execute` 跑 CLI | 进程启动 80–200 ms，60 Hz 决策场景不可用 |
| 开放 Balance 数值覆写 | `Balance` 是 `const`，改运行时可变要动全部调用点，风险 >> 收益 |
| 开放 HUD 面板注入 | 与 `I18n.rebuild_panel` 的重建假设冲突（重建后外部节点无法重新接线） |
| 插件影响联机地形 | 会破坏 Host/客户端地形一致性（见 §6.3） |
| 把 Python 一起打进 exe | 体积 +30 MB 起，且违背"纯单文件"；外挂更诚实 |
