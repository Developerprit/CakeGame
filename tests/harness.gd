class_name TestHarness
extends Node
## Shared assertion harness for the headless test scenes.
##
## Both `tests/selfcheck.gd` and `tests/match_sim.gd` extend this. They used to
## each carry a copy, which is the classic two-sources-of-truth trap in miniature:
## the `run()` wrapper below exists to catch a specific silent failure, and the
## day one copy got that fix and the other did not, half the suite would go back
## to reporting a cheerful green for work that never ran.

var _fail: Array[String] = []
var _pass: int = 0
var _section: String = ""
var _notes: Array[String] = []


## Every check is wrapped in this.
##
## GDScript has no exceptions, so a runtime error part way through a check just
## abandons that function and the caller carries on to the summary - which then
## prints a cheerful "OK" for work that never ran. Counting assertions before and
## after turns that into a failure. This is not hypothetical: the first version of
## the self-check reported 64 passed / 0 failed while the entire camera section had
## errored out on its first line.
##
## Note the limit: a check whose assertions all come BEFORE a mid-function `await`
## still trips the counter, so its remaining assertions are silently dropped. Test
## checks must therefore not await half way through.
func run(label: String, fn: Callable) -> void:
	_section = label
	print("")
	print("== %s ==" % label)
	var before := _pass + _fail.size()
	fn.call()
	if _pass + _fail.size() == before:
		ok(false, "check aborted before asserting anything - look for a SCRIPT ERROR above")


## Coroutine variant of `run()`. `fn` must await at least once, otherwise use
## `run()`. Needed because a match simulation has to actually let frames elapse,
## and `run()` cannot await its callee.
func run_async(label: String, fn: Callable) -> void:
	_section = label
	print("")
	print("== %s ==" % label)
	var before := _pass + _fail.size()
	await fn.call()
	if _pass + _fail.size() == before:
		ok(false, "check aborted before asserting anything - look for a SCRIPT ERROR above")


func ok(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail.append("[%s] %s" % [_section, msg])
		print("   FAIL  " + msg)


func info(msg: String) -> void:
	_notes.append("[%s] %s" % [_section, msg])
	print("   note  " + msg)


func report(suite: String) -> int:
	print("")
	print("-------------------")
	print("passed: %d" % _pass)
	print("failed: %d" % _fail.size())
	for f in _fail:
		print("  FAIL " + f)
	print("%s %s" % [suite, "OK" if _fail.is_empty() else "FAILED"])
	return 0 if _fail.is_empty() else 1


## Frames to await for `seconds` of game time. Only correct under `--fixed-fps`,
## which is how both test scenes are run.
func frames_for(seconds: float, fps: int = 60) -> int:
	return maxi(1, ceili(seconds * float(fps)))


# ---------------------------------------------------------------------------
# layout
# ---------------------------------------------------------------------------

## Names of every visible Control under `root` whose rect leaves `space`, plus how
## many Controls the walk actually reached. See `assert_fits` for why both.
##
## Returns `{"examined": int, "outside": Array[String]}`.
func measure_controls(root: Node, space: Vector2) -> Dictionary:
	var bad: Array[String] = []
	var count := [0]
	_walk_outside(root, root, false, space, bad, count)
	return {"examined": count[0], "outside": bad}


## Assert that every visible Control fits inside the design space.
##
## This is the regression guard for a bug that shipped in three screens at once:
## `set_anchors_and_offsets_preset(..., PRESET_MODE_MINSIZE, ...)` bakes offsets
## from the control's minimum size at call time, and that minimum is zero both for
## a container whose children arrive later and for anything sized by
## `custom_minimum_size` (which MINSIZE ignores outright). The result is a control
## whose anchored edge is on the screen edge and whose body grows *away* from it.
##
## What it cost when nobody measured: the lobby's READY / START MATCH / LEAVE row
## rendered at y = 360..382 in a 360 px space, so a match could not be started from
## the lobby; the pause menu panel landed at (312,175)..(782,491), so pausing dimmed
## the screen and showed no menu; the HUD's kill feed measured (634,6)..(824,6) with
## a height of 0 and never displayed a kill; and the minimap was a 6x6 sliver.
## None of that is visible in a code review and none of it fails a build.
##
## Descendants of a clipping container are skipped - a ScrollContainer's body is
## *supposed* to be taller than its window.
func assert_fits(root: Node, space: Vector2, label: String) -> void:
	var m := measure_controls(root, space)
	var examined: int = m["examined"]
	var bad: Array = m["outside"]
	# A walker that reached nothing passes every "nothing escaped" test ever
	# written. Measured inside a SubViewport it is worth confirming, because a
	# CanvasItem that reports itself invisible would silently skip the whole tree.
	ok(examined > 0, "%s: the walker reached Controls (%d examined)" % [label, examined])
	if bad.is_empty():
		ok(true, "%s: all %d visible Controls fit inside %dx%d"
			% [label, examined, int(space.x), int(space.y)])
		return
	ok(false, "%s: %d of %d controls escape the %dx%d design space: %s"
		% [label, bad.size(), examined, int(space.x), int(space.y),
			", ".join(PackedStringArray(bad))])


func _walk_outside(n: Node, root: Node, clipped: bool, space: Vector2,
		bad: Array[String], count: Array) -> void:
	for c in n.get_children():
		var ctl := c as Control
		var ctl_clipped := clipped
		if ctl != null and (ctl.clip_contents or c is ScrollContainer):
			ctl_clipped = true
		if ctl != null and ctl != root and ctl.is_visible_in_tree() and not ctl_clipped:
			count[0] += 1
			var r := ctl.get_global_rect()
			if r.position.x < -0.5 or r.position.y < -0.5 \
					or r.end.x > space.x + 0.5 or r.end.y > space.y + 0.5:
				bad.append("%s@(%.0f,%.0f %.0fx%.0f)" % [
					c.name, r.position.x, r.position.y, r.size.x, r.size.y])
		_walk_outside(c, root, ctl_clipped, space, bad, count)


func find_control(root: Node, name: String) -> Control:
	if root.name == name:
		return root as Control
	for c in root.get_children():
		var hit := find_control(c, name)
		if hit != null:
			return hit
	return null


## Assert none of the named pairs overlap, and that every name resolves.
##
## `assert_fits` only checks that each Control is inside the design space, which
## says nothing about two Controls occupying the same pixels. These pairs are laid
## out from opposite ends of a shared strip and nothing in the engine keeps them
## apart: the HUD's centred header and its right-anchored kill feed measured 52 px
## of overprint ("ELIMINATION - first to 5 rounds" ending at x=496 while the feed's
## column began at 444).
func assert_no_overlap(root: Node, pairs: Array, label: String) -> void:
	var hits: Array[String] = []
	for pair in pairs:
		var a := find_control(root, str(pair[0]))
		var b := find_control(root, str(pair[1]))
		if a == null or b == null:
			ok(false, "%s: %s x %s - node missing (%s, %s)" % [
				label, pair[0], pair[1], str(a != null), str(b != null)])
			continue
		var ra := a.get_global_rect()
		var rb := b.get_global_rect()
		if ra.intersects(rb):
			hits.append("%s x %s (overlap %.0fx%.0f)" % [pair[0], pair[1],
				ra.intersection(rb).size.x, ra.intersection(rb).size.y])
	ok(hits.is_empty(), "%s: %d of %d watched pairs overlap: %s"
		% [label, hits.size(), pairs.size(), ", ".join(PackedStringArray(hits))])


## Assert each named Control is horizontally centred in `space`.
##
## The specific failure this exists for: a Label built with empty text (`body("")`
## and filled in later by `_update_top()`) has a minimum size of zero, so a
## `PRESET_MODE_MINSIZE` centre anchor parks its LEFT edge on the centre line and
## the text then grows rightward. It looks centred in the code and is off by half
## its own width on screen.
func assert_centred_h(root: Node, names: Array, space: Vector2, label: String) -> void:
	var mid := space.x * 0.5
	for n in names:
		var c := find_control(root, str(n))
		if c == null:
			ok(false, "%s: %s not found" % [label, n])
			continue
		var off := c.get_global_rect().get_center().x - mid
		ok(absf(off) <= 1.0, "%s: %s is centred (off by %.0f px)" % [label, n, off])


## Assert each named Label's resolved `font_color` is light enough to read over the
## arena, and that a panel-backed widget is actually themed.
##
## The arena art is the same in both themes - it never reads the palette - and it
## is dark. So overlay text has to stay light in BOTH themes. In light mode the
## theme's `text` colour is `#1b1d22`, and the header lines, the countdown banner
## and the kill feed all went near-black on a dark floor: invisible, but invisible
## in only one of the two themes, which is exactly why a dark-mode screenshot
## review passed it.
##
## The second half of the check is the related bug that hid behind it: the HUD
## never assigned `theme` at all, so its `PanelContainer` painted the engine's
## stock grey box in both themes instead of the project palette.
##
## The threshold is 0.5, not "not black". The light theme's `dim` is `#6b7180`,
## luminance 0.44: dark enough to look switched off against a dark floor, light
## enough to pass a 0.35 threshold. Two header lines sat there for a whole match
## because nothing re-coloured them and the check was written too kindly.
func assert_overlay_legible(root: Node, names: Array, label: String) -> void:
	for n in names:
		var c := find_control(root, str(n)) as Label
		if c == null:
			ok(false, "%s: %s not found" % [label, n])
			continue
		var col := c.get_theme_color("font_color")
		var lum := PixelTheme.luminance(col)
		ok(lum >= 0.5, "%s: %s stays readable on the arena (luminance %.2f)"
			% [label, n, lum])


func assert_panel_themed(root: Node, name: String, label: String) -> void:
	var c := find_control(root, name) as PanelContainer
	if c == null:
		ok(false, "%s: %s not found" % [label, name])
		return
	var sb := c.get_theme_stylebox("panel")
	ok(sb is StyleBoxFlat and (sb as StyleBoxFlat).bg_color.is_equal_approx(
		PixelTheme.c("panel")),
		"%s: %s uses the project theme's panel colour, not the engine default"
			% [label, name])
