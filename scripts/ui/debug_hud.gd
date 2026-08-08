extends CanvasLayer

## Throwaway diagnostics overlay. F3 toggles it.
## Worth keeping until movement feel is locked in — the speed and grounded
## readouts are what tell you whether a stair transition actually went wrong.

@onready var _label: Label = $Panel/Label

var _fps_accum := 0.0
var _fps_shown := 0.0


func _ready() -> void:
	layer = 100


func _process(delta: float) -> void:
	if Input.is_action_just_pressed("debug_toggle_hud"):
		visible = not visible
	if not visible:
		return

	# Smooth the framerate readout so it is legible rather than flickering.
	_fps_accum += delta
	if _fps_accum > 0.25:
		_fps_accum = 0.0
		_fps_shown = Engine.get_frames_per_second()

	var lines: Array[String] = []
	lines.append("FPS %d" % _fps_shown)

	var player := Game.player
	if player:
		var pos: Vector3 = player.global_position
		lines.append("pos   %6.1f %6.1f %6.1f" % [pos.x, pos.y, pos.z])
		lines.append("speed %5.2f  (%s)" % [player.get_planar_speed(), _state_name(player.state)])
		lines.append("floor %s" % ("yes" if player.is_on_floor() else "NO"))
	if Game.camera_rig:
		# Report the distance actually in use, not the exported gameplay value —
		# they differ while the inspect camera is engaged.
		var cam_dist: float = Game.camera_rig.get_active_distance()
		var mode := "  [inspect]" if Game.camera_rig.is_inspecting() else ""
		lines.append("cam   yaw %.0f  dist %.1f%s" % [Game.camera_rig.yaw, cam_dist, mode])

	lines.append("")
	lines.append("WASD move · Shift run · Q/E turn cam · scroll zoom · F3 hud · F5 rain · F12 shot")
	_label.text = "\n".join(lines)


func _state_name(state: int) -> String:
	match state:
		0: return "idle"
		1: return "walk"
		2: return "run"
	return "?"
