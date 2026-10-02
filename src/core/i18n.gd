class_name I18n
extends RefCounted
## Minimal source-string localisation.
##
## The UI used to hardcode its strings. Settings had a Language row that wrote
## `GameConfig.language` and then nothing - `EventBus.language_changed` was
## declared, never emitted and never connected - so picking 中文 silently
## changed a saved value and redrew exactly the same English screen. That is
## the bug this class exists to fix.
##
## Keys are the English source strings themselves rather than invented keys like
## `menu.play`. The payoff is large: the code reads the same as before, the
## English text stays where a designer would expect to find it, and a missing
## translation degrades to English instead of to a blank or an `undefined_key`.
## The cost is that the same sentence cannot be reused with different wording in
## two places, which this UI does not do.
##
## `EventBus.language_changed` is emitted after the value lands, so a UI panel
## can rebuild itself from scratch - trying to mutate individual labels in place
## means every panel needs to know which of its labels changed.

## Simplified Chinese. Anything absent falls back to the source string.
const ZH: Dictionary = {
	# ---- main menu ---------------------------------------------------------
	"CAKEGAME": "蛋糕对战",
	"1-3 PLAYERS   VS   1-2 AI BOTS": "1~3 名玩家  VS  1~2 个 AI Bot",
	"Top-down pixel brawling. Melee, a handgun and a grapple\nyou can aim at a wall or at somebody's back. Every bot is\nthe same difficulty - there is no easy mode.": "俯视像素乱斗：近战、手枪与钩索。\n你可以对着墙壁开枪，也可以对着别人的后背开枪。\n每个 Bot 的难度完全一致 —— 没有简单模式。",
	"PLAY  VS  BOTS": "单人对战 Bot",
	"one human on this machine, against the configured bots": "本机一名玩家，对手是设定好的 Bot",
	"HOST / JOIN ROOM": "开房 / 加入房间",
	"LAN discovery and cross-network room codes": "局域网发现与跨网房间码",
	"SETTINGS": "设置",
	"bot version, arena, controls, audio": "Bot 版本、场地、操作、音频",
	"QUIT": "退出游戏",
	"close the game": "关闭游戏",
	"MATCH SETUP": "对局设定",
	"Edit these in SETTINGS.": "这些都在「设置」里可以改。",

	# ---- HUD / match states -----------------------------------------------
	"GET READY": "准备开始",
	"LIVE": "开打",
	"ELIMINATION  ·  first to %d rounds": "淘汰赛  ·  先拿 %d 分者胜",
	"DEATHMATCH  ·  first to %d kills": "死斗  ·  先拿 %d 杀者胜",
	"ELIMINATED  ·  watch the round play out": "已淘汰  ·  等待本回合结束",
	"DOWN  ·  back in %.1fs": "倒地  ·  %.1f 秒后重生",
	"DEFEAT": "战败",
	"WIN": "胜利",
	"%s WIN   %d — %d": "%s 获胜   %d — %d",
	"%d / %d": "%d / %d",
	"%d kills": "%d 杀",
	"%d rounds": "%d 回合",
	"%d fps": "%d 帧",
	"HUMANS": "人类",
	"BOTS": "Bot",
	"MINIMAP": "小地图",
	"KILL FEED": "击杀播报",
	"HINT": "操作提示",
	"CROSSHAIR": "准星",
	"FPS": "帧率",

	# ---- ability names -----------------------------------------------------
	"MELEE": "近战",
	"GUN": "枪械",
	"HOOK": "钩索",
	"ROLL": "翻滚",
	"SETTINGS_TITLE": "设置",
	"AIM": "瞄准",
	"MOVE": "移动",

	# ---- lobby -------------------------------------------------------------
	"HOST": "开房",
	"HOST P2P": "开房（跨网）",
	"JOIN": "加入",
	"LEAVE": "离开",
	"READY": "准备",
	"CODE": "房间码",
	"SCAN LAN": "扫描局域网",
	"local only": "仅本机",
	"open the room over the internet and print the code": "跨网开房，并把房间码发给别人",
	"no such room": "房间不存在",
	"room codes are at least 4 characters": "房间码至少 4 个字符",
	"open a room first - HOST P2P next to SCAN LAN": "请先开房 —— SCAN LAN 旁边那个就是 HOST P2P",
	"ready": "已准备",
	"transport: %s   ·   %s": "传输方式：%s   ·   %s",
	"tries UDP punch, then the relay": "先试 UDP 打洞，不行就走中继",
	"v%s   ·   Available License": "v%s   ·   Available License",
	"where is everybody": "人到哪儿了",
	"1 human + %d bot": "1 名玩家 + %d 个 Bot",
	"seed %d  ·  %d human vs %d bot": "种子 %d  ·  %d 名玩家 vs %d 个 Bot",
	"the AI got a free round": "AI 白捡一分",
	"PLAYERS": "玩家",

	# ---- pause menu --------------------------------------------------------
	"MATCH PAUSED": "对局已暂停",
	"ESC to resume": "ESC 继续游戏",
	"ESC  ·  rematch or main menu": "ESC  ·  再来一局或回主菜单",
	"MAIN MENU": "主菜单",
	"RESTART": "重新开始",
	"CLOSE  [ESC]": "关闭  [ESC]",
	"CANCEL": "取消",
	# "OK" here is the cooldown read-out, not a confirmation - a button would say
	# 确定, this label says 就绪.
	"OK": "就绪",
	"CONTROLS": "操作",
	"Seed": "种子",
	"REROLL": "换一个",
	"PRESENTATION": "呈现",
	"GAMEPLAY": "对局",
	"NETWORK": "网络",
	"ROOM": "房间",
	"SLOT": "槽位",
	"PLAYER": "玩家",
	"SIDE": "阵营",
	"ROOM CODE": "房间码",
	"START MATCH": "开始对战",
	"Only one human can play on this machine: the InputMap binds WASD and one set of pad buttons globally, so a second local player would share player one's keys. Extra humans join over LAN / room code, which is what 'Human slots' describes. Offline you get one human plus the bots, and the bot count is floored at one so a match always has an enemy.": "这台机器上只有一名本地玩家：InputMap 全局绑定 WASD 和一组手柄按键，
所以第二名本地玩家会跟第一名共用按键。额外的人类成员靠局域网 / 房间码加入，
也就是「人类位置」这项描述的东西。离线时你是一名人类加若干 Bot，
Bot 数量下限是 1，保证每局都有对手。",
	"Off: elimination rounds, wipe the other team, first to the score wins. On: no rounds - a downed fighter returns, kills score, and the target becomes 'score to win' times the enemy team size.": "关：淘汰回合制，打光对方队伍，先拿到目标分者胜。
开：没有回合 —— 倒下的角色会回来，击杀计分，
目标分变为「胜利分数」乘以敌方队伍人数。",
	"Off by default. One light per fighter is five shadow casters: they project a fan of dark wedges across the whole floor, which at five actors buries the tile art and reads as a rendering fault rather than as lighting. The team-coloured glow stays either way - it is how you track a 1v3.": "默认关闭。每个角色一盏灯，五名角色就是五个投影体：
它们会在整个地面上投出一扇形深色阴影，五个人时就把地砖美术盖掉了，
看起来像渲染故障而不是光照。阵营色的光晕一直都在 —— 那是你辨认 1v3 的依据。",

	# ---- settings ----------------------------------------------------------
	"BOT": "Bot",
	"ARENA": "场地",
	"ROSTER": "阵容",
	"SCORE": "比分",
	"RESPAWN": "重生",
	"LIGHTS": "灯光",
	"SEED": "种子",
	"Bot slots": "Bot 数量",
	"Bot version": "Bot 版本",
	"Human slots": "玩家数量",
	"Max players": "最大人数",
	"Round target score": "回合目标分",
	"Respawn delay": "重生延迟",
	"Mouse sensitivity": "鼠标灵敏度",
	"Master volume": "主音量",
	"Music volume": "音乐音量",
	"SFX volume": "音效音量",
	"Dark theme": "深色主题",
	"Light shadows": "投影",
	"Screen shake": "屏幕震动",
	"Damage numbers": "伤害数字",
	"Show FPS": "显示帧率",
	"Fullscreen": "全屏",
	"Language": "语言",
	"English": "English",
	"中文": "中文",
	"Friendly fire": "友伤",
	"Seeded map": "种子地图",
	"Player name": "玩家名",
	"Server port": "服务器端口",
	"Transport": "传输方式",
	"Signaling URL": "信令地址",
	"Relay URL": "中继地址",
	"auto": "自动",
	"lan": "局域网",
	"p2p": "跨网",
	"relay": "中继",
	"on": "开",
	"off": "关",
	"yes": "是",
	"no": "否",
	"random arena from a seed": "按种子生成随机场地",
	"WASD move  ·  mouse aim  ·  RMB melee  ·  E gun  ·  Q hook  ·  Shift roll": "WASD 移动  ·  鼠标瞄准  ·  右键近战  ·  E 开枪  ·  Q 钩索  ·  Shift 翻滚",
	"WASD move  ·  mouse aim  ·  RMB melee\nE gun  ·  LMB fire  ·  Q hook  ·  Shift roll": "WASD 移动  ·  鼠标瞄准  ·  右键近战\nE 开枪  ·  左键开火  ·  Q 钩索  ·  Shift 翻滚",
	"Released under the Available License - license.kscm.top/available.md": "基于 Available License 发布 —— license.kscm.top/available.md",
	"Score to win": "胜利分数",
	"deathmatch (back after the delay)": "死斗（延迟后回归）",
	"Pad aim assist": "手柄瞄准辅助",
	"Window scale": "窗口缩放",
	"blank = invent one": "留空则随机生成一个",
	"Click a key to rebind it, then press the new key. Escape cancels.": "点击按键重新绑定，然后按下新键。ESC 取消。",
	"read this out, or paste it below": "可以照着念，或者直接粘贴到下面",
	"UDP broadcast discovery on the local network": "局域网 UDP 广播发现",
	"empty slots fill with bots": "空位自动补 Bot",
	"START uses everyone in the room; empty human slots are filled with bots.": "开始会带上房间里的所有人；空出来的人类位置由 Bot 补齐。",
	"go back to the menu and open the room first": "先回主菜单把房间开起来",
	"seeded, random each match": "开启种子则每局随机",
	"reseed each match": "每局重新掷种子",
	# Short set-up column labels (70 px), so they translate short.
	"WIN AT": "胜利分",
	"SHADOWS": "投影",
	"built-in (34x34)": "内置（34x34）",
	"off (elimination)": "关（淘汰制）",
	# Settings panel: a check-button caption and the reset action.
	"fighter lights cast shadows": "角色灯光会投射阴影",
	"RESET ALL SETTINGS TO DEFAULTS": "恢复所有设置为默认值",
	# The lobby transports the preferred one when the room was opened with one.
	"forced to %s": "已强制为 %s",
	# HUD state words that were never wrapped; all-caps arcade text, but they
	# read as sentences to a player who does not know the vocabulary.
	"RELOADING": "换弹中",
	"ROUND OVER": "本回合结束",
	"VICTORY": "胜利",

	# ---- BTPS plugin host ---------------------------------------------------
	# The trust line is deliberately blunt rather than reassuring: a btps sandbox
	# is a boundary constraint, not a malware container, so the player is told
	# what is actually true instead of what would sell the feature.
	"Plugins run as your own user account. Only install plugins you trust.": "插件以你的用户权限运行，只装你信任的插件。",
	"Plugins": "插件",
	"Plugin host": "插件宿主",
	"Enable plugins": "启用插件",
	"Loading the plugin host...": "正在加载插件宿主……",
	"not started": "未启动",
	"starting...": "启动中……",
	"host ready": "就绪",
	"no Python interpreter found": "未找到 Python 解释器",
	"plugin host error": "插件宿主出错",
	"Python path": "Python 路径",
	"Restart the plugin host": "重启插件宿主",
	"No plugins installed.": "尚未安装插件。",
	"Drop a .btp file into the plugins folder to install one.": "把 .btp 文件放进插件目录即可安装。",
	"ENABLE": "启用",
	"DISABLE": "停用",
	"UNINSTALL": "卸载",
	"UNINSTALL %s?": "确定卸载 %s？",
	"Cannot be undone from inside the game.": "此操作无法在游戏内撤销。",
	"Bot brain": "Bot 大脑",
	"Waiting for the plugin host...": "等待插件宿主……",
	"Plugins stay on this machine and are not sent to other players.": "插件仅在本机生效，不会同步给其他玩家。",
}

static func current() -> String:
	return GameConfig.language


## Translate a source string into the active language.
##
## Deliberately named `t` and not `tr`: `Object.tr()` is an engine method, and a
## static member of that name is shadowed by it, so every `I18n.tr(...)` call
## site failed with "Could not resolve external class member tr" while the file
## itself parsed. Renaming it was cheaper than re-learning the engine.
static func t(source: String) -> String:
	if GameConfig.language != "zh":
		return source
	return str(ZH.get(source, source))


## Switch language and announce it. Every open UI panel listens for this and
## rebuilds; this is the only place the change is published, so a panel cannot
## miss it by being wired to the settings widget instead of to the event.
static func set_lang(code: String) -> void:
	if GameConfig.language == code:
		return
	GameConfig.language = code
	EventBus.language_changed.emit(code)


## Drop every connection `node` holds on the EventBus autoload.
##
## A panel that rebuilds itself has to detach first: the handlers are methods on
## the panel, so the old connection survives `queue_free()`-ing the widgets and a
## second build would stack a second handler, which means every event then runs
## twice - the classic "the counter jumps by two" bug. Listing the signals by
## hand is the alternative and it rots the moment a signal is added.
static func unbind_bus(node: Node) -> void:
	if node == null or not is_instance_valid(node):
		return
	for sig in EventBus.get_signal_list():
		var sname: StringName = sig["name"]
		for conn in EventBus.get_signal_connection_list(sname):
			var cb: Callable = conn["callable"]
			# `is_connected` is not redundant: the list is being mutated on every
			# disconnect, and asking for a connection that is already gone is an
			# error rather than a no-op.
			if cb.get_object() == node and EventBus.is_connected(sname, cb):
				EventBus.disconnect(sname, cb)


## Throw away a panel's widgets and build them again.
##
## Strings are baked into widget text at build time, so a panel cannot relabel
## itself in place without knowing which of its labels hold which string. `build`
## therefore re-runs against the new `GameConfig.language` and `after` restores
## whatever the old widgets were showing (selection, open/closed, scores).
static func rebuild_panel(node: Control, build: Callable, bind: Callable,
		after: Callable) -> void:
	unbind_bus(node)
	for c in node.get_children():
		c.queue_free()
	build.call()
	# Binding is a separate step for a reason: it is the only way a rebuild can
	# guarantee the panel is wired again. Moving the connects inside `build`
	# hides them next to the widget construction that uses them, and the first
	# version of this helper did exactly that - it rebuilt the screen and then
	# left it deaf to the next language change, which is a bug that no panel
	# would notice until it switched language twice.
	bind.call()
	after.call()
