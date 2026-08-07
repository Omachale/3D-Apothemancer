extends Node

## Autoload. Inert unless asked for.
##
## F12 saves a screenshot to user://screenshots.
##
## It also supports driving the game from the command line, so a change can be
## verified without sitting at the keyboard:
##
##     godot --path <project> -- --shot=out.png --shot-frames=120
##         run normally, wait N frames, write a PNG and quit
##     --drive=move_forward,move_right
##         hold those input actions for the whole run
##     --log=0.5
##         print the player's position/speed/grounded state every N seconds
##     --shot-at=1.4
##         take the screenshot at a wall-clock time instead of a frame count,
##         which is what you want when timing a shot against an animation
##     --cast-at=1.0
##         fire a single cast
##     --at=-26,0.5,-2
##         drop the player at a world position on the first frame, so a test
##         does not have to start with a thirty-second walk across the map at that time
##     --cam=45,-12,4
##         override the camera's yaw / pitch / distance, e.g. to get a close
##         side-on view of the character for judging a pose
##     --wind-log=0.5
##         print the live wind globals plus the shader's own gust math,
##         evaluated in GDScript at a fixed world point, every N seconds.
##         For verifying gust timing/position as numbers instead of guessing
##         from screenshots, which cannot tell a travelling band apart from
##         independent per-blade jitter.
##     --mouse=0.95,0.5
##         hold the mouse at that fraction of the viewport. The character turns
##         to face the mouse while casting, so without this the pose a
##         screenshot catches depends on wherever the cursor happened to be —
##         pin it to make cast shots repeatable
##
## Combined, those are enough to assert things like "walking north-west for
## four seconds ends up on top of the hill" from a single command.

const SCREENSHOT_DIR := "user://screenshots"

var _shot_path := ""
var _shot_frames := 90
var _shot_at := -1.0
var _frames_seen := 0
var _driven_actions: PackedStringArray = []
var _log_interval := 0.0
var _log_accum := 0.0
var _elapsed := 0.0
var _cast_at := -1.0
var _cast_done := false
var _cam_override := Vector3.ZERO
var _has_cam_override := false
var _cam_applied := false
var _mouse_fraction := Vector2.ZERO
var _has_mouse_override := false
var _spawn_at := Vector3.ZERO
var _has_spawn_at := false
var _spawn_applied := false
var _wind_log_interval := 0.0
var _wind_log_accum := 0.0
var _wind_log_at := Vector2(-40.0, -34.0) # HillsideMeadow centre, the usual test spot.


func _ready() -> void:
	_parse_args()
	set_process(_shot_path != "" or not _driven_actions.is_empty()
		or _log_interval > 0.0 or _cast_at >= 0.0 or _has_cam_override
		or _has_mouse_override or _has_spawn_at or _wind_log_interval > 0.0)
	for action in _driven_actions:
		if InputMap.has_action(action):
			Input.action_press(action)
		else:
			push_error("DevTools: unknown action '%s' passed to --drive." % action)


func _parse_args() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--shot="):
			_shot_path = arg.substr("--shot=".length())
		elif arg.begins_with("--shot-frames="):
			_shot_frames = int(arg.substr("--shot-frames=".length()))
		elif arg.begins_with("--drive="):
			_driven_actions = arg.substr("--drive=".length()).split(",", false)
		elif arg.begins_with("--log="):
			_log_interval = float(arg.substr("--log=".length()))
		elif arg.begins_with("--shot-at="):
			_shot_at = float(arg.substr("--shot-at=".length()))
		elif arg.begins_with("--cast-at="):
			_cast_at = float(arg.substr("--cast-at=".length()))
		elif arg.begins_with("--cam="):
			var parts := arg.substr("--cam=".length()).split(",", false)
			if parts.size() == 3:
				_cam_override = Vector3(float(parts[0]), float(parts[1]), float(parts[2]))
				_has_cam_override = true
			else:
				push_error("DevTools: --cam expects yaw,pitch,distance.")
		elif arg.begins_with("--at="):
			var a := arg.substr("--at=".length()).split(",", false)
			if a.size() == 3:
				_spawn_at = Vector3(float(a[0]), float(a[1]), float(a[2]))
				_has_spawn_at = true
			else:
				push_error("DevTools: --at expects x,y,z.")
		elif arg.begins_with("--wind-log="):
			_wind_log_interval = float(arg.substr("--wind-log=".length()))
		elif arg.begins_with("--wind-log-at="):
			var w := arg.substr("--wind-log-at=".length()).split(",", false)
			if w.size() == 2:
				_wind_log_at = Vector2(float(w[0]), float(w[1]))
			else:
				push_error("DevTools: --wind-log-at expects x,z.")
		elif arg.begins_with("--mouse="):
			var m := arg.substr("--mouse=".length()).split(",", false)
			if m.size() == 2:
				_mouse_fraction = Vector2(float(m[0]), float(m[1]))
				_has_mouse_override = true
			else:
				push_error("DevTools: --mouse expects x,y as viewport fractions.")


func _process(delta: float) -> void:
	_elapsed += delta
	_tick_log(delta)
	_tick_spawn()
	_tick_camera()
	_tick_mouse()
	_tick_cast()
	_tick_wind_log(delta)

	# Driven actions have to be re-pressed: anything that consumes them with
	# is_action_just_pressed would otherwise only ever see a single frame.
	for action in _driven_actions:
		if InputMap.has_action(action):
			Input.action_press(action)

	if _shot_path == "":
		return
	_frames_seen += 1
	if _shot_at >= 0.0:
		if _elapsed < _shot_at:
			return
	elif _frames_seen < _shot_frames:
		return
	set_process(false)
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	var err := image.save_png(_shot_path)
	if err != OK:
		push_error("DevTools: could not write %s (error %d)" % [_shot_path, err])
	else:
		print("DevTools: wrote screenshot to ", _shot_path)
	get_tree().quit()


func _tick_camera() -> void:
	if not _has_cam_override or _cam_applied or Game.camera_rig == null:
		return
	Game.camera_rig.set_yaw(_cam_override.x)
	Game.camera_rig.set_pitch(_cam_override.y)
	Game.camera_rig.set_distance(_cam_override.z)
	Game.camera_rig.target_offset = Vector3(0.0, 1.5, 0.0)
	_cam_applied = true


func _tick_spawn() -> void:
	if not _has_spawn_at or _spawn_applied or Game.player == null:
		return
	_spawn_applied = true
	Game.player.global_position = _spawn_at
	if Game.camera_rig:
		Game.camera_rig.snap_to_target()


func _tick_mouse() -> void:
	if not _has_mouse_override:
		return
	var size := Vector2(get_viewport().get_visible_rect().size)
	Input.warp_mouse(size * _mouse_fraction)


func _tick_cast() -> void:
	if _cast_done or _cast_at < 0.0 or _elapsed < _cast_at:
		return
	_cast_done = true
	if Game.player == null:
		return
	var caster: Node = Game.player.get_node_or_null("SpellCaster")
	if caster:
		caster.try_cast()
	else:
		push_error("DevTools: --cast-at but the player has no SpellCaster.")


func _tick_log(delta: float) -> void:
	if _log_interval <= 0.0:
		return
	_log_accum += delta
	if _log_accum < _log_interval:
		return
	_log_accum = 0.0
	var player := Game.player
	if player == null:
		return
	var pos: Vector3 = player.global_position
	var line := "t=%5.2f  pos=(%6.2f, %5.2f, %6.2f)  speed=%5.2f  floor=%s" % [
		_elapsed, pos.x, pos.y, pos.z, player.get_planar_speed(),
		"yes" if player.is_on_floor() else "no",
	]
	# Cast state, plus where the casting hand actually is relative to the feet.
	# Judging an arm pose from a screenshot is guesswork; this is not.
	var caster: Node = player.get_node_or_null("SpellCaster")
	if caster:
		var hand: Vector3 = caster.get_cast_origin() - pos
		# The Mage rig faces +Z (its toe bones point that way) and _face aligns
		# local +Z with the direction of travel, so forward is +basis.z here.
		var forward: Vector3 = player.model.global_transform.basis.z
		line += "  cast=%s w=%.2f e=%.2f  hand(up=%.2f fwd=%.2f)" % [
			caster.Phase.keys()[caster.phase], caster.weight, caster.extend,
			hand.y, hand.dot(forward),
		]
	print(line)
	_log_npcs()


## One line per NPC: where it is, how fast it is going and which clip is
## playing. Eyeballing two screenshots cannot tell you whether a wander state
## machine is actually cycling or just sitting still in a convincing pose.
func _log_npcs() -> void:
	var zone: Node = Game.current_zone
	if zone == null:
		return
	var holder := zone.get_node_or_null("NPCs")
	if holder == null:
		return
	for npc in holder.get_children():
		var anim: AnimationPlayer = npc.get_node_or_null("CharacterArmature/AnimationPlayer")
		var clip: String = anim.current_animation if anim else "<none>"
		print("        %-10s pos=(%6.2f, %5.2f, %6.2f)  speed=%5.2f  state=%s  clip=%s" % [
			npc.name, npc.global_position.x, npc.global_position.y,
			npc.global_position.z, Vector2(npc.velocity.x, npc.velocity.z).length(),
			npc.State.keys()[npc.state], clip,
		])


## Mirrors grass.gdshader's gust math in GDScript so gust timing/position can
## be read as printed numbers instead of inferred from screenshots — two
## frames a moment apart always differ because of the idle layer, so a
## screenshot diff cannot prove a gust happened, only that *something* moved.
## Keep this in sync with gust_lane() in grass.gdshader if that changes.
func _tick_wind_log(delta: float) -> void:
	if _wind_log_interval <= 0.0:
		return
	_wind_log_accum += delta
	if _wind_log_accum < _wind_log_interval:
		return
	_wind_log_accum = 0.0

	var t: float = _elapsed
	# RenderingServer.global_shader_parameter_get() returns Nil at runtime —
	# it only reliably works from the editor — so read the canonical values
	# straight off the Wind autoload instead, which is what actually pushed
	# them to the shader in the first place.
	var radians := deg_to_rad(Wind.direction_degrees)
	var direction := Vector2(sin(radians), cos(radians))
	var strength: float = Wind.strength
	var speed: float = Wind.speed
	var gust_width: float = Wind.gust_width
	var gust_period: float = Wind.gust_period

	var mat: ShaderMaterial = load("res://resources/materials/grass_blades.tres")
	var travel_range: float = mat.get_shader_parameter("wind_travel_range")
	var lifetime: float = mat.get_shader_parameter("gust_lifetime")

	var dir := direction.normalized()
	var perp := Vector2(-dir.y, dir.x)
	var seeds := [0.11, 0.53, 0.79, 0.97]
	var total := 0.0
	var active: Array = []
	for seed in seeds:
		var v := _gust_lane_value(_wind_log_at, dir, perp, seed, t,
			speed, gust_width, gust_period, travel_range, lifetime)
		total += v
		if v > 0.001:
			active.append("%.2f" % v)
	total = minf(total, 1.4)
	print("wind t=%6.2f  at=(%.0f,%.0f)  dir=(%.2f,%.2f) strength=%.2f speed=%.2f  gust=%.3f  active_lanes=%s" % [
		t, _wind_log_at.x, _wind_log_at.y, dir.x, dir.y, strength, speed, total,
		"[" + ", ".join(active) + "]" if not active.is_empty() else "none",
	])


func _hash2(a: float, b: float) -> float:
	return fmod(sin(a * 12.9898 + b * 78.233) * 43758.5453, 1.0)


func _gust_lane_value(xz: Vector2, dir: Vector2, perp: Vector2, lane_seed: float,
		t: float, speed: float, gust_width: float, gust_period: float,
		travel_range: float, lifetime: float) -> float:
	lifetime = maxf(lifetime, 0.5)
	var wait_min: float = maxf(gust_period * 0.6, 0.1)
	var wait_max: float = maxf(gust_period * 1.4, wait_min + 0.1)
	var cycle_length: float = lifetime + wait_max
	var local_time: float = t + lane_seed * 4096.0
	var cycle_time: float = fmod(local_time, cycle_length)
	var cycle_index: float = floor(local_time / cycle_length)

	var wait: float = lerp(wait_min, wait_max, absf(_hash2(cycle_index, lane_seed)))
	if cycle_time < wait or cycle_time > wait + lifetime:
		return 0.0
	var since_spawn: float = cycle_time - wait

	var travel_dist: float = speed * lifetime
	var spawn_along: float = lerp(-travel_range, travel_range,
		absf(_hash2(cycle_index + 0.37, lane_seed))) - travel_dist * 0.5
	var spawn_lateral: float = lerp(-travel_range, travel_range,
		absf(_hash2(cycle_index + 0.71, lane_seed)))

	var center: Vector2 = dir * (spawn_along + speed * since_spawn) + perp * spawn_lateral
	var radius: float = maxf(gust_width, 0.5)
	var dist: float = xz.distance_to(center)
	var spatial: float = exp(-(dist * dist) / (radius * radius))

	var fade_time: float = lifetime * 0.2
	var temporal: float = clampf(minf(since_spawn, lifetime - since_spawn) / maxf(fade_time, 0.01), 0.0, 1.0)
	return spatial * temporal


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("debug_screenshot"):
		return
	DirAccess.make_dir_recursive_absolute(SCREENSHOT_DIR)
	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	var path := "%s/shot_%s.png" % [SCREENSHOT_DIR, stamp]
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	if image.save_png(path) == OK:
		print("Screenshot saved: ", ProjectSettings.globalize_path(path))
