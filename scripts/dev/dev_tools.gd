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
##     --click-npc-at=2.0
##         aim the cursor at the nearest targetable NPC and click it, which is
##         how you exercise selection: unlike --cast-at (which calls the caster
##         directly and never touches the input system) this drives the real
##         button, so it covers mouse -> raycast -> selection. Prints what ended
##         up selected, so a failure says whether the pick or the UI was at
##         fault. Do NOT combine with --drive=cast_primary or --mouse: --drive
##         holds the button from frame one, so the press edge this needs happens
##         before the cursor is aimed and never comes again, and --mouse re-warps
##         the cursor every frame, dragging it off whatever this aimed at.
##     --at=-26,0.5,-2
##         drop the player at a world position on the first frame, so a test
##         does not have to start with a thirty-second walk across the map at that time
##     --cam=45,-12,4
##         override the camera's yaw / pitch / distance, e.g. to get a close
##         side-on view of the character for judging a pose
##     --wind-log=0.5
##         every N seconds, print the live wind settings and one line per
##         gust currently alive — position, radius, strength, age — plus the
##         combined intensity at --wind-log-at. These are the same numbers
##         wind.gd hands the shaders, so this is authoritative rather than a
##         reconstruction. For verifying gust timing/position without
##         guessing from screenshots, which cannot tell a travelling patch
##         apart from independent per-blade jitter.
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
var _click_npc_at := -1.0
## 0 aim, 1 press, 2 release, 3 report, 4 done.
var _click_npc_stage := 0
var _click_npc_screen := Vector2.ZERO
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
## Where combined gust intensity is sampled. Defaults to the player's spawn
## point, since gusts now spawn around wherever the player is rather than
## around the world origin — a fixed far-off probe would usually read zero.
var _wind_log_at := Vector2(10.0, 22.0)


func _ready() -> void:
	_parse_args()
	set_process(_shot_path != "" or not _driven_actions.is_empty()
		or _log_interval > 0.0 or _cast_at >= 0.0 or _has_cam_override
		or _has_mouse_override or _has_spawn_at or _wind_log_interval > 0.0
		or _click_npc_at >= 0.0)
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
		elif arg.begins_with("--click-npc-at="):
			_click_npc_at = float(arg.substr("--click-npc-at=".length()))
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
	_tick_click_npc()
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


## Prints the live gusts so gust timing/position can be read as numbers rather
## than inferred from screenshots — two frames a moment apart always differ
## because of the idle layer, so a screenshot diff cannot prove a gust
## happened, only that *something* moved.
##
## This used to be a hand-written GDScript MIRROR of grass.gdshader's gust
## math, which had to be kept in step by hand and twice silently didn't be.
## There is nothing to mirror now: wind.gd computes the gusts and hands the
## same numbers to both this log and the shaders, so the readout cannot
## disagree with the screen.
## Clicks the nearest targetable NPC, for exercising selection end to end.
##
## Aims by UNPROJECTING the NPC's own world position to screen coordinates
## rather than taking a hand-guessed viewport fraction, so this keeps hitting
## what it means to hit at any camera angle, zoom or window size — a guessed
## fraction is right for exactly one framing and silently misses in every other.
##
## Distinct from --cast-at, which calls SpellCaster.try_cast() directly and so
## never touches the input system at all. This drives the real button, which is
## the only way to cover the mouse -> raycast -> selection path.
##
## The click is injected with Input.parse_input_event rather than
## Input.action_press, and the difference is not cosmetic. action_press sets the
## action pressed on the spot, and is_action_just_pressed is then only true for
## the remainder of THAT frame — but this autoload is registered after
## Targeting, so it processes after it, and Targeting would never once see the
## press. A parsed event goes through the normal input pipeline instead and is
## visible to every poller on the following frame regardless of node order.
func _tick_click_npc() -> void:
	if _click_npc_at < 0.0 or _elapsed < _click_npc_at or _click_npc_stage > 3:
		return
	match _click_npc_stage:
		0:
			var npc := _nearest_targetable_npc()
			if npc == null:
				push_error("DevTools: --click-npc-at but no targetable NPC was found.")
				_click_npc_stage = 4
				return
			var camera: Camera3D = Game.camera_rig.get_camera()
			# Aimed at the body rather than the feet, so the ray meets the
			# collider instead of passing under it.
			_click_npc_screen = camera.unproject_position(npc.global_position + Vector3.UP)
			Input.warp_mouse(_click_npc_screen)
			print("DevTools: aiming at %s, screen %s" % [npc.name, _click_npc_screen])
			_click_npc_stage = 1
		1:
			_send_click(true)
			_click_npc_stage = 2
		2:
			_send_click(false)
			_click_npc_stage = 3
		3:
			# Reported rather than left for a screenshot to imply: a missing
			# panel could equally be a failed pick or a broken panel, and those
			# want different fixes.
			var selected: Node3D = Targeting.current
			print("DevTools: after click, target = %s" % (
				selected.name if selected else "<none>"))
			_click_npc_stage = 4


func _send_click(pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = _click_npc_screen
	event.global_position = _click_npc_screen
	Input.parse_input_event(event)


func _nearest_targetable_npc() -> Node3D:
	var player: Node3D = Game.player
	if player == null or Game.current_zone == null or Game.camera_rig == null:
		return null
	var best: Node3D = null
	var best_distance := INF
	for node in Game.current_zone.find_children("*", "CharacterBody3D", true, false):
		if node == player or not (node.get("targetable") as bool):
			continue
		var distance: float = player.global_position.distance_to(node.global_position)
		if distance < best_distance:
			best_distance = distance
			best = node
	return best


func _tick_wind_log(delta: float) -> void:
	if _wind_log_interval <= 0.0:
		return
	_wind_log_accum += delta
	if _wind_log_accum < _wind_log_interval:
		return
	_wind_log_accum = 0.0

	var gusts := Wind.get_gusts()
	print("wind t=%6.2f  dir=%.0f deg  strength=%.2f speed=%.2f  live=%d/%d  gust_at(%.0f,%.0f)=%.3f" % [
		_elapsed, Wind.direction_degrees, Wind.strength, Wind.speed,
		gusts.size(), Wind.MAX_GUSTS,
		_wind_log_at.x, _wind_log_at.y, Wind.gust_value_at(_wind_log_at),
	])
	for i in gusts.size():
		var g: Dictionary = gusts[i]
		var pos: Vector2 = g["pos"]
		print("        gust %d  at=(%7.1f,%7.1f)  r=%.1f  strength=%.3f  age=%5.1f/%5.1f" % [
			i, pos.x, pos.y, g["radius"], g["strength"], g["age"], g["lifetime"],
		])


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
