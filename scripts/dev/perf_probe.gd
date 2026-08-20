extends Node

## Frame-cost measurement and subsystem ablation. Spawned by dev_tools.gd when
## --perf is passed; costs nothing on a normal run.
##
## WHY THIS EXISTS: "the game feels slower" cannot be answered by reading the
## code and reasoning about which effect looks expensive — that is guessing, and
## rendering cost is routinely counter-intuitive (a cheap-looking shader on
## 50,000 grass blades beats an expensive one on 50). This measures two things
## that together give a real answer:
##
##   1. WHERE the time goes — CPU script time, CPU render-submit time, and
##      actual GPU time are reported separately. That split decides what kind of
##      fix is even worth attempting: optimising GDScript when the GPU is the
##      bottleneck changes nothing at all.
##   2. WHAT it belongs to — the ablation switches remove one subsystem at a
##      time and the run is repeated. The DIFFERENCE in frame time between the
##      baseline and the ablated run is that subsystem's true cost, including
##      every second-order effect (its shadow casting, its overdraw, its
##      streaming work). Attribution by profiler alone can mislead, because GPU
##      work overlaps and a profiler assigns it to whatever issued the call;
##      an A/B difference cannot mislead, because it is the answer to exactly
##      the question being asked — "what happens if this is not here".
##
## TWO THINGS THAT WOULD SILENTLY INVALIDATE EVERY NUMBER, both handled here:
##
##   - V-SYNC. With v-sync on, every frame that finishes early waits for the
##     display, so any scene running above the refresh rate reports exactly the
##     refresh rate and all differences vanish into the wait. Disabled in
##     _ready, along with Engine.max_fps.
##   - WARM-UP. The streaming managers build chunks over the first seconds of a
##     run, so frames during that window are dominated by one-off build cost and
##     are not representative of steady state. Samples before `warmup` are
##     discarded.
##
## A stationary probe also understates cost: with the player still, streaming
## settles and chunk building goes quiet. Drive the player (--drive=move_forward)
## so the measurement includes the continuous streaming that a moving player
## actually pays for. run_perf.ps1 does this by default.

## Ablations, by the name passed to --perf-disable. Each entry says what gets
## removed and how. Node paths are relative to the Zone.
const ABLATION_HELP := {
	"grass": "Zone/Grass — the streamed grass field (draw + shadow + streaming)",
	"trees": "Zone/TreeScatter — the streamed pine scatter",
	"terrain": "Zone/Terrain/TerrainManager — the streamed ground mesh",
	"structures": "Zone/Terrain/* except TerrainManager — plates, buildings, tower, stairs",
	"props": "Zone/Props — hand-placed and generator-placed props",
	"npcs": "Zone/NPCs",
	"rain": "forces Rain to OFF (particles, lightning, light dimming)",
	"shadows": "Sun.shadow_enabled = false — every shadow map, globally",
	"ssao": "Environment.ssao_enabled = false",
	"fog": "Environment.fog_enabled = false",
	"sky": "Environment background -> flat colour (no procedural sky shading)",
	"msaa": "viewport MSAA -> disabled",
}

var duration := 8.0
var warmup := 3.0
var label := "baseline"
var disabled: PackedStringArray = []

var _elapsed := 0.0
var _applied := false
var _reported := false

var _frame_ms: Array[float] = []
var _gpu_ms: Array[float] = []
var _render_cpu_ms: Array[float] = []
var _process_ms: Array[float] = []
var _physics_ms: Array[float] = []
var _draw_visible: Array[float] = []
var _draw_shadow: Array[float] = []
var _prim_visible: Array[float] = []
var _prim_shadow: Array[float] = []


func _ready() -> void:
	# See the class doc — without both of these, a scene running above the
	# refresh rate reports the refresh rate and every comparison reads as "no
	# difference".
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	RenderingServer.viewport_set_measure_render_time(
		get_viewport().get_viewport_rid(), true)
	print("PERF: label=%s warmup=%.1fs measure=%.1fs disable=[%s]" % [
		label, warmup, duration, ", ".join(disabled)])
	# Printed, not assumed: the request to disable v-sync can be overridden by
	# the driver or the desktop compositor, and if it is, every frame-time
	# reading quantises to the refresh rate and all comparisons collapse. Read
	# the mode BACK rather than trusting that setting it worked.
	print("PERF env: vsync_mode=%d (0=disabled) max_fps=%d refresh=%.1fHz" % [
		DisplayServer.window_get_vsync_mode(), Engine.max_fps,
		DisplayServer.screen_get_refresh_rate()])


func _process(delta: float) -> void:
	_elapsed += delta

	# Ablations wait for the zone: it is built by World's _ready, one frame in
	# at the earliest, so applying them from this node's _ready would silently
	# find nothing and produce a "no difference" result that looks like a
	# measurement but is really a missed hookup.
	if not _applied and Game.current_zone != null:
		_applied = true
		_apply_ablations()

	if _reported or _elapsed < warmup:
		return

	var rid := get_viewport().get_viewport_rid()
	_frame_ms.append(delta * 1000.0)
	_gpu_ms.append(RenderingServer.viewport_get_measured_render_time_gpu(rid))
	_render_cpu_ms.append(RenderingServer.viewport_get_measured_render_time_cpu(rid))
	# Performance's time monitors are in SECONDS; everything else here is ms.
	_process_ms.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	_physics_ms.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
	_draw_visible.append(_info(rid, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE,
		RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME))
	_draw_shadow.append(_info(rid, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_SHADOW,
		RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME))
	_prim_visible.append(_info(rid, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE,
		RenderingServer.VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME))
	_prim_shadow.append(_info(rid, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_SHADOW,
		RenderingServer.VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME))

	if _elapsed >= warmup + duration:
		_reported = true
		_report()
		get_tree().quit(0)


func _info(rid: RID, type: int, what: int) -> float:
	return float(RenderingServer.viewport_get_render_info(rid, type, what))


func _apply_ablations() -> void:
	var zone: Node = Game.current_zone
	for raw in disabled:
		var key := raw.strip_edges()
		if key == "" or key == "none":
			continue
		if not ABLATION_HELP.has(key):
			# Loud, because the failure mode is silent otherwise: an unknown
			# switch removes nothing, the run matches baseline, and the result
			# reads as "this subsystem is free" when it was never turned off.
			push_error("PERF: unknown ablation '%s'. Known: %s" % [
				key, ", ".join(ABLATION_HELP.keys())])
			print("PERF ABLATION FAILED: unknown '%s'" % key)
			continue
		var ok := _apply_one(key, zone)
		print("PERF ablated %-11s %s -> %s" % [
			key, ABLATION_HELP[key], "ok" if ok else "TARGET NOT FOUND"])
		if not ok:
			push_error("PERF: ablation '%s' found nothing to disable." % key)


func _apply_one(key: String, zone: Node) -> bool:
	match key:
		"grass":
			return _silence(zone.get_node_or_null("Grass"))
		"trees":
			return _silence(zone.get_node_or_null("TreeScatter"))
		"props":
			return _silence(zone.get_node_or_null("Props"))
		"npcs":
			return _silence(zone.get_node_or_null("NPCs"))
		"terrain":
			var t: Node = zone.get_node_or_null("Terrain")
			return _silence(t.get_node_or_null("TerrainManager") if t else null)
		"structures":
			var holder: Node = zone.get_node_or_null("Terrain")
			if holder == null:
				return false
			var any := false
			for child in holder.get_children():
				if child.name != "TerrainManager":
					any = _silence(child) or any
			return any
		"rain":
			Rain.set_intensity(Rain.Intensity.OFF)
			return true
		"shadows":
			var sun := get_tree().get_first_node_in_group("sun") as DirectionalLight3D
			if sun == null:
				return false
			sun.shadow_enabled = false
			return true
		"ssao", "fog", "sky":
			return _apply_environment(key)
		"msaa":
			get_viewport().msaa_3d = Viewport.MSAA_DISABLED
			return true
	return false


func _apply_environment(key: String) -> bool:
	var we := get_tree().get_first_node_in_group("world_environment") as WorldEnvironment
	if we == null or we.environment == null:
		return false
	var env := we.environment
	match key:
		"ssao":
			env.ssao_enabled = false
		"fog":
			env.fog_enabled = false
		"sky":
			env.background_mode = Environment.BG_COLOR
	return true


## Hides a subtree AND stops its processing, so the reported difference covers
## the whole cost of the subsystem — its drawing, the shadow maps it feeds, and
## the CPU streaming work behind it. Which SIDE that cost came from is then read
## off the gpu/render/process columns rather than needing a separate run.
func _silence(node: Node) -> bool:
	if node == null:
		return false
	if node is Node3D:
		(node as Node3D).visible = false
	_stop_processing(node)
	return true


func _stop_processing(node: Node) -> void:
	node.set_process(false)
	node.set_physics_process(false)
	for child in node.get_children():
		_stop_processing(child)


## Everything is reported as a MEDIAN, not a mean. The streaming managers build
## chunks in bursts costing tens of milliseconds each, and a mean over a window
## containing a few of those describes neither the typical frame nor the stall —
## the first run of this probe reported a mean script time of 41 ms alongside a
## median frame time of 18 ms, which is not a possible steady state, only an
## average of two very different populations. Median answers "what does a normal
## frame cost"; the p95 columns answer "how bad are the stalls". Both matter and
## they are different questions, so both are printed.
func _report() -> void:
	var frame_med := _percentile(_frame_ms, 0.5)
	var frame_p95 := _percentile(_frame_ms, 0.95)
	var gpu_med := _percentile(_gpu_ms, 0.5)
	var render_med := _percentile(_render_cpu_ms, 0.5)
	var script_med := _percentile(_process_ms, 0.5)
	var script_p95 := _percentile(_process_ms, 0.95)
	print("")
	print("=== PERF %s ===" % label)
	print("samples          %d over %.1fs (after %.1fs warm-up)" % [
		_frame_ms.size(), duration, warmup])
	print("frame  median    %7.3f ms  (%.1f fps)" % [
		frame_med, 1000.0 / maxf(frame_med, 0.001)])
	print("frame  p95       %7.3f ms  (%.1f fps)   <- worst frames / stalls" % [
		frame_p95, 1000.0 / maxf(frame_p95, 0.001)])
	print("gpu    median    %7.3f ms   <- rendering, on the GPU" % gpu_med)
	print("render cpu med   %7.3f ms   <- building the draw list, on the CPU" % render_med)
	print("script median    %7.3f ms   <- all GDScript _process, typical frame" % script_med)
	print("script p95       %7.3f ms   <- all GDScript _process, worst frames" % script_p95)
	# Sanity check, printed rather than assumed: script time is a COMPONENT of
	# frame time, so a median above the frame median is arithmetically
	# impossible and means this monitor is not reporting per-frame script cost.
	# Saying so in the output beats quietly publishing a number that cannot be
	# true.
	if script_med > frame_med:
		print("script SUSPECT   median %.3f ms exceeds frame median %.3f ms" % [
			script_med, frame_med])
		print("                 -> TIME_PROCESS is not a per-frame script cost here;")
		print("                    ignore the script column, trust gpu + frame + p95.")
	print("script raw range %7.3f .. %.3f ms" % [
		_percentile(_process_ms, 0.0), _percentile(_process_ms, 1.0)])
	print("physics median   %7.3f ms" % _percentile(_physics_ms, 0.5))
	print("draw calls       %7.0f visible + %.0f shadow" % [
		_percentile(_draw_visible, 0.5), _percentile(_draw_shadow, 0.5)])
	print("primitives       %7.0f visible + %.0f shadow" % [
		_percentile(_prim_visible, 0.5), _percentile(_prim_shadow, 0.5)])
	print("video memory     %7.1f MB" % [
		Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0])
	# One machine-readable line, so run_perf.ps1 can build the comparison table
	# without parsing the human-facing block above.
	print("PERF|%s|%.4f|%.4f|%.4f|%.4f|%.4f|%.4f|%.0f|%.0f|%.0f|%.0f" % [
		label, frame_med, frame_p95, gpu_med, render_med, script_med, script_p95,
		_percentile(_draw_visible, 0.5), _percentile(_draw_shadow, 0.5),
		_percentile(_prim_visible, 0.5), _percentile(_prim_shadow, 0.5)])
	print("PERF DONE")


func _percentile(values: Array[float], p: float) -> float:
	if values.is_empty():
		return 0.0
	var sorted := values.duplicate()
	sorted.sort()
	var index := int(round((sorted.size() - 1) * p))
	return sorted[index]
