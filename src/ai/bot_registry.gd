class_name BotRegistry
extends RefCounted
## The list of AI bots a player can pick from in Settings.
##
## Registration is data, not code: adding "CakeGame AI Bot v2" means dropping a
## script under `src/ai/` and adding one dictionary here. The settings dropdown
## reads this table, so the UI needs no change either.
##
## Difficulty is deliberately NOT exposed. The spec fixes the bots at a single
## hard difficulty, and every number that would soften them lives in `Balance`
## under the AI section where a player cannot reach it. A difficulty slider would
## also mean shipping a bot that is deliberately bad, which is not what "算法极强"
## is asking for.

const DEFAULT_ID: String = "cakegame_v1"

const ENTRIES: Array[Dictionary] = [
	{
		"id": "cakegame_v1",
		"name": "CakeGame AI Bot v1",
		"script": "res://src/ai/bot_v1.gd",
		"tag": "DEFAULT",
		"desc_en": "Predictive aim and predictive dodging: reads your facing, "
			+ "controls range, uses cover and the grapple, and switches between "
			+ "gun and melee based on your state.",
		"desc_zh": "预判射击 + 预判翻滚：读取你的朝向、控制交战距离、利用掩体与抓钩，"
			+ "并根据你的状态在近战与枪械之间切换。",
	},
]


static func ids() -> PackedStringArray:
	var out := PackedStringArray()
	for e in ENTRIES:
		out.append(str(e["id"]))
	return out


static func display_names() -> PackedStringArray:
	var out := PackedStringArray()
	for e in ENTRIES:
		out.append(str(e["name"]))
	return out


static func index_of(id: String) -> int:
	for i in ENTRIES.size():
		if str(ENTRIES[i]["id"]) == id:
			return i
	return -1


static func entry(id: String) -> Dictionary:
	var i := index_of(id)
	if i < 0:
		return ENTRIES[0]
	return ENTRIES[i]


static func id_at(index: int) -> String:
	if index < 0 or index >= ENTRIES.size():
		return DEFAULT_ID
	return str(ENTRIES[index]["id"])


static func display_name(id: String) -> String:
	return str(entry(id).get("name", id))


static func description(id: String, zh: bool = false) -> String:
	var e := entry(id)
	return str(e.get("desc_zh" if zh else "desc_en", ""))


## Instantiate a brain. Returns null when the script is missing or does not
## produce a BotBrain, so a broken registration degrades to "no bot" rather than
## taking the whole match down.
static func create(id: String) -> BotBrain:
	var e := entry(id)
	var path := str(e.get("script", ""))
	if path.is_empty() or not ResourceLoader.exists(path):
		push_error("[BotRegistry] missing brain script: %s" % path)
		return null
	var script := load(path) as GDScript
	if script == null:
		push_error("[BotRegistry] cannot load %s" % path)
		return null
	var obj: Variant = script.new()
	var brain := obj as BotBrain
	if brain == null:
		push_error("[BotRegistry] %s does not extend BotBrain" % path)
		return null
	return brain
