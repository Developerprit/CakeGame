# CakeGame — 技术规划书 / Technical Planning

> 版本 v1.0 · 引擎 Godot **4.5.1-stable** · 目标平台 Windows（单文件 exe）
> 一句话：**1~3 名真人组队，对抗 1~2 个算法极强的 AI Bot 的 2D 俯视像素风动作对战游戏，支持局域网与跨网 P2P 联机。**

---

## 0. 需求确认纪要（来自陌老师的四轮问答）

| 议题 | 最终决策 |
|---|---|
| 视角与美术 | 2D 俯视（top-down）、简约像素风 |
| 多人方式 | **去中心化 P2P**（陌老师无独立服务器）/ 局域网 |
| 网络架构 | **Listen Server + 跨网房间码**（Host 兼任权威，Retinbox 免费 PHP + KV 做信令，WebSocket 中继兜底） |
| AI 算力 | **仅 Host 运算 AI**，Bot 状态同步给客户端 |
| 人数上限 | **可配置至 8 人**（默认 3 真人 + 2 Bot） |
| 地图 | **默认极简空竞技场**；设置中可开启「种子地图」→ 类似 MC 的种子系统纯随机生成 |
| 胜负规则 | **队伍式**：真人队 VS AI Bot 队 |
| 摄像机 | **自动框住所有玩家与 Bot**，动态缩放 |
| Bot 难度 | 参数**不可调**（固定高难度） |
| Bot 版本 | 设置中可选，当前内置 `CakeGame AI Bot v1` |

---

## 1. 技术选型论证 / Trade-off

### 1.1 引擎：Godot 4.5.1 vs 备选

| 维度 | **Godot 4.5.1（选用）** | Unity 6 | 自研（C# / Go + 自绘） |
|---|---|---|---|
| 单文件 exe | ✅ 原生 `embed_pck` + 单 exe | ❌ 需安装器/多文件 | ✅ 但需自写渲染与输入 |
| 2D 像素管线 | ✅ `nearest` 滤波 + `AtlasTexture` 切帧，零配置 | ⚠️ 需配置 Pixel Perfect Camera | ⚠️ 全手写 |
| 内置联机 | ✅ `ENetMultiplayerPeer` + 高层 `MultiplayerAPI`（RPC/Spawner/同步开箱即用） | ⚠️ Netcode for GameObjects 较重 | ❌ 从零写可靠 UDP |
| 无头验证 | ✅ `--headless --check-only / --fixed-fps` 可做 CI 级自动化 | ❌ 无等价能力 | ⚠️ 需自建 |
| 产出体积 | ~95 MB（引擎占大头） | ~200 MB+ | ~15 MB |
| 本机已装 | ✅ `/e/godot_toolchain/godot/` + 导出模板齐全 | 未装 | — |

**结论**：Godot 胜在「单 exe + 内置高层联机 + 无头可验证」三点同时成立，且本机工具链已就绪，无需额外下载。

### 1.2 网络拓扑：为什么是 Listen Server 而不是全互联 Mesh

| 方案 | NAT 穿透 | 状态一致性 | Godot 支持 | 结论 |
|---|---|---|---|---|
| **Listen Server（选用）** | 打洞一次即可，中继兜底 | 单点权威，无分歧 | 原生一等公民 | ✅ |
| 真·全互联 Mesh | 需 N×(N-1)/2 条连接，对称 NAT 下单条失败即断链 | 每端各算，帧级分叉 | 无原生支持，需自写 | ❌ |
| 独立专用服务器 | — | 最好 | — | ❌ 陌老师无服务器 |

**「去中心化」的落地含义**：不依赖任何**常驻游戏服务器**。第一个创建房间的玩家**同时就是服务器**，退出即散房。Retinbox 侧只做**无状态信令**（交换公网端点，不转发游戏流量），因此零成本、零运维。

### 1.3 跨网三档策略（逐级降级，UI 显式提示当前档位）

```
① LAN 直连        UDP 广播自动发现 → ENetMultiplayerPeer.create_client(内网IP, 端口)     延迟 <5ms
② P2P 打洞        Retinbox 信令交换公网端点 → 双方 UDP 互打 → ENet 复用该映射           延迟 20~80ms
③ WebSocket 中继  均失败时，两端连 wss://<站点>/relay.node.js?room=CODE，字节转发        延迟 60~200ms
```

> ①②③ 共用**同一套 RPC 代码**：Godot 的 `MultiplayerAPI` 对 `ENetMultiplayerPeer` 与 `WebSocketMultiplayerPeer` 是同一抽象，切换只需替换 `multiplayer.multiplayer_peer`。这是选择 Godot 的决定性理由之一。

---

## 2. 数值尺度约定

**`1 tile = 16 世界像素 = 1 米`**，代码里写 `Utils.m(4.0)` 而不是 `256.0`，与真实 m/s 数值可直接对照调参。

| 项目 | 数值 | 说明 |
|---|---|---|
| 视口 | 640 × 360 | `canvas_items` 拉伸，整数倍缩放，`nearest` 滤波 |
| 角色碰撞半径 | 5 px | 圆形，内缩保证能挤过 1 格走廊 |
| 移动速度 | 3.6 m/s | 翻滚时 8.0 m/s |
| 生命值 | 100 | — |
| 近战伤害 | 22 | 扇形 90°，射程 22 px，前摇 0.12 s，冷却 0.55 s |
| 子弹伤害 | 12 | 速度 320 px/s，散布 3°，冷却 0.22 s，弹匣 12，换弹 1.4 s |
| 抓钩伤害 | 8 | 射程 110 px，冷却 3.5 s，命中后施加加速度 |
| 翻滚 | 0.42 s | **无敌帧 0.30 s**，结束后冷却 0.90 s |
| 抓钩惯性 | 加速度 62 m/s²，初速 12 m/s | 松钩后保留 78% 速度 → 有滑行感 |

---

## 3. 操作方案（1 台机器 1 名玩家，天然适配联机）

| 输入 | 动作 | 备注 |
|---|---|---|
| `WASD` | 八向移动 | — |
| **鼠标位置** | **朝向** | 角色**始终**朝向鼠标指针；双方（含 Bot）都能读到对方朝向 |
| **鼠标右键** | 近战攻击 | 立即收枪，扇形判定 |
| `E` | 掏枪 / 收枪 | 切远程姿态 |
| **鼠标左键** | 射击 | 仅在枪已掏出时生效 |
| `Q` | 发射抓钩 | 命中墙 → 拉自己（带惯性）；命中敌人 → 把对方拉过来 |
| `Shift` | 翻滚 | 无敌帧闪避 |
| `ESC` | 菜单 | 暂停 / 退出 |

> **设计要点**：由「朝向 = 鼠标」这一条推出 **Bot 可以读到玩家朝向**，于是「预判性翻滚」成立 —— Bot 看到你枪口指着它，就能在你扣扳机前先滚。这是本作 AI 强度的核心来源。

---

## 4. 目录结构

```
E:/PC/CakeGame/
├─ Planning/Planning.md          本文件
├─ project.godot                 autoload + 输入映射 + 像素渲染配置
├─ export_presets.cfg            单文件 exe（embed_pck、icon.ico、四段版本号）
├─ icon.ico                      多尺寸图标
├─ index.html                    商业风格落地页（中英双语 / 浅深双主题）
├─ README.md · README-zh.md · LICENSE
├─ tools/                        Python 零依赖生成器（素材/音效/字体/图标）
├─ assets/{sprites,sfx,fonts}/   运行时资源
├─ src/
│  ├─ core/      enums, utils, event_bus, game_config, scene_router
│  ├─ actors/    character_base, player, bot_actor, bullet, hook, fx
│  ├─ states/    state_machine + 各状态
│  ├─ ai/        bot_registry, bot_brain_base, bot_v1
│  ├─ world/     arena, map_generator, tileset_builder, camera_rig
│  ├─ net/       net_manager, signaling, lan_discovery
│  └─ ui/        main_menu, lobby, settings, hud, pixel_theme
├─ scenes/       main_menu.tscn, lobby.tscn, game.tscn
└─ server/       api.php（信令）· relay.node.js（中继）· rth-host.json
```

---

## 5. Bot 决策模型 —— `CakeGame AI Bot v1`

三层结构：**感知 → 决策 → 执行**，每层独立可测。

### 5.1 感知层（每帧刷新）

- 敌对目标列表（队伍过滤、可见性 = 射线未被墙阻挡）
- 每个目标的：位置、**朝向**（由鼠标方向推出）、当前状态（换弹/近战前摇/翻滚/残血）、朝向与自己的夹角
- **潜在弹道**：目标枪口方向 ± 散布角内的射线 → 判断「他正在瞄我」
- 地形：`AStarGrid2D` 网格、掩体格、自身到目标的路径

### 5.2 决策层（有限状态 + 效用打分）

| 行为 | 触发条件 |
|---|---|
| `DODGE` | ① 有子弹在 0.25 s 内将命中自身轨迹；② 目标朝向夹角 < 12° 且枪已掏出且有视线；③ 目标近战前摇中且距离 < 30 px |
| `MELEE_RUSH` | 目标正在换弹 / 弹匣空 / 血量 < 25% / 目标背对我 → 贴近至 18 px 内挥砍 |
| `KITE` | 自身血量 < 45% 或换弹中 → 后撤到掩体后，换弹完成再出 |
| `GUNFIGHT` | 默认交战：维持 **55~90 px** 射程带，横向绕圈走位 |
| `HOOK_OPEN` | 目标拉开到 > 100 px 或目标在掩体后 → 用抓钩强制拉近 |
| `REPOSITION` | 弹道被墙挡 > 0.6 s 或连续 3 次射击无命中 → A* 换点位 |
| `PEEK` | 在掩体后且我方弹药满 → 定时出掩体点射，命中或受击立即缩回 |

### 5.3 三个「显得聪明」的关键实现

1. **预判射击**：`aim_point = target.pos + target.velocity * (dist / bullet_speed)`，再对目标速度向量做一次一阶导修正（二阶预判），命中率显著高于朴素提前量。
2. **预判性翻滚**：不是「看到子弹才滚」，而是**读朝向**。玩家朝向 = 鼠标方向是公开信息，Bot 在「夹角 < 12° 且对方枪已掏出且无遮挡」时**提前**翻滚 —— 人类玩家看到的观感是「它躲开了我还没打出去的枪」。
3. **地形利用**：掩体格记录 + `PEEK` 状态机 + 视线射线校验。**禁止隔墙开火**（`blocked_by_wall()` 校验），这条不做的话 Bot 会永远对着墙挥刀。

### 5.4 扩展性

`BotRegistry` 以 `{id, display_name, script, description}` 注册。设置面板下拉读取注册表，因此新增 `CakeGame AI Bot v2` 只需加一个脚本 + 一行注册。**难度参数写死在 v1 内部，不对玩家暴露。**

---

## 6. 验收标准（Definition of Done）

| # | 验收项 | 方式 |
|---|---|---|
| 1 | 全部 `.gd` 脚本 `Parse Error` = 0 | `--headless --check-only` 全量扫描 |
| 2 | 三个场景均可启动无 `SCRIPT ERROR` | `--headless --quit-after` 逐个冒烟 |
| 3 | Bot 在 90 秒压测中击杀数 > 0 且自身死亡数 < 3 | `--fixed-fps 60 --quit-after 5400 -- --debug-ai`，连跑 6 次防抖 |
| 4 | 近战/射击/抓钩/翻滚四条链路均有可观测命中日志 | 调试日志断言 |
| 5 | 单文件 exe 可双击启动并进入主菜单 | 导出后实际运行 |
| 6 | 局域网双实例可互相发现并进入同一局 | 双进程实测 |
| 7 | 设置面板能切换 Bot 版本、开关种子地图并生效 | 手动 + 日志 |
| 8 | 浅色/深色主题均可读，中英双语完整 | 落地页 + 游戏内 UI |

---

## 7. 风险登记

| 风险 | 等级 | 对策 |
|---|---|---|
| 对称型 NAT 下 UDP 打洞失败 | 中 | 已设计 WebSocket 中继兜底，UI 显式显示「中继模式」 |
| 抓钩惯性导致角色穿墙 | 中 | 拉拽全程用 `move_and_slide`；松钩速度上限钳制 |
| 动态缩放在玩家分散时画面过小 | 低 | 缩放钳制 `[0.75, 1.6]`，超出范围改用边缘指示器 |
| Godot 导出 exe 被占用 | 低 | 先导出到新文件名再 `mv` 覆盖（技能已验证方案） |
| 程序化地图出现不可达区域 | 中 | 生成后做多源 BFS 连通性校验，保留最大连通域并填封其余 |

---

## 8. 交付物清单

1. `build/CakeGame.exe` —— 单文件自包含可执行程序
2. `Planning/Planning.md` —— 本规划书
3. `README.md` / `README-zh.md` —— 中英双语说明
4. `index.html` —— 商业风格项目落地页
5. `server/` —— Retinbox 信令 + 中继云函数与部署配置
6. `LICENSE` —— Available License
7. GitHub 仓库 `Developerprit/CakeGame`

---

*规划批准后即进入实现。若中途需要调整数值或行为，会在本文件中同步更新并标注修订记录。*
