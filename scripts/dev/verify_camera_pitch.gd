extends Node

## Checks camera_rig.gd's always-on middle-mouse drag control and ground
## collision.
##
## Drag has two axes now (see camera_rig.gd's class doc): vertical drag tilts
## pitch, horizontal drag orbits yaw, and there is no lock/unlock step — both
## must work from the first frame. The other thing worth checking on its own
## is ground collision: a heightfield with a wall under where the camera would
## sit must push the camera up rather than let it clip through.
##
##   Godot --headless res://scenes/dev/VerifyCameraPitch.tscn
## Exits non-zero if any check fails.

const RIG := preload("res://scenes/camera/CameraRig.tscn")
const HEIGHTFIELD_SCRIPT := preload("res://scripts/terrain/heightfield.gd")

var _failures := 0
var _rig: Node3D = null


func _ready() -> void:
	_rig = RIG.instantiate()
	add_child(_rig)
	await get_tree().process_frame

	_check_vertical_drag_moves_pitch()
	_check_horizontal_drag_moves_yaw()
	_check_pitch_clamped_to_range()
	await _check_ground_collision()

	if _failures == 0:
		print("VERIFY CAMERA PITCH: PASS")
	else:
		print("VERIFY CAMERA PITCH: FAIL (%d)" % _failures)
	get_tree().quit(1 if _failures > 0 else 0)


func _fail(message: String) -> void:
	print("  FAIL: %s" % message)
	_failures += 1


## Feeds a mouse-motion event straight to the rig's handler, with the middle
## button held. Bypasses the input queue so the test stays synchronous.
func _drag(pixels: Vector2) -> void:
	Input.action_press("camera_pitch_drag")
	var event := InputEventMouseMotion.new()
	event.relative = pixels
	_rig.call("_unhandled_input", event)
	Input.action_release("camera_pitch_drag")


func _check_vertical_drag_moves_pitch() -> void:
	var before: float = _rig.pitch
	_drag(Vector2(0.0, 20.0))
	if is_equal_approx(_rig.pitch, before):
		_fail("vertical drag did not move pitch")
	# Opposite drag must come back to where it started, or the control drifts.
	_drag(Vector2(0.0, -20.0))
	if not is_equal_approx(_rig.pitch, before):
		_fail("drag and drag-back left pitch at %.3f, expected %.3f" % [_rig.pitch, before])
	else:
		print("  vertical drag: tilts the camera and is exactly reversible")


func _check_horizontal_drag_moves_yaw() -> void:
	var before: float = _rig.yaw
	_drag(Vector2(20.0, 0.0))
	if is_equal_approx(_rig.yaw, before):
		_fail("horizontal drag did not move yaw")
	_drag(Vector2(-20.0, 0.0))
	if not is_equal_approx(_rig.yaw, before):
		_fail("drag and drag-back left yaw at %.3f, expected %.3f" % [_rig.yaw, before])
	else:
		print("  horizontal drag: orbits the camera and is exactly reversible")


## A drag must not reach a pitch the @export_range forbids — the annotation only
## binds the inspector, so nothing but the clamp stops it.
func _check_pitch_clamped_to_range() -> void:
	_drag(Vector2(0.0, 100000.0))
	var low: float = _rig.pitch
	if low > _rig.MAX_PITCH + 0.001 or low < _rig.MIN_PITCH - 0.001:
		_fail("a huge drag reached pitch %.2f, outside [%.0f, %.0f]"
			% [low, _rig.MIN_PITCH, _rig.MAX_PITCH])
	_drag(Vector2(0.0, -100000.0))
	var high: float = _rig.pitch
	if high > _rig.MAX_PITCH + 0.001 or high < _rig.MIN_PITCH - 0.001:
		_fail("a huge reverse drag reached pitch %.2f, outside [%.0f, %.0f]"
			% [high, _rig.MIN_PITCH, _rig.MAX_PITCH])
	if is_equal_approx(low, high):
		_fail("both drag directions clamped to the same end, %.2f" % low)
	else:
		print("  pitch clamped: extreme drags stop at %.0f and %.0f" % [low, high])


## A heightfield with a tall wall right under the camera must push the camera
## above it, rather than let it end up beneath the surface. Restores
## Game.heightfield afterward — this autoload is shared, and leaving a stub
## heightfield behind would make every check after this one lie.
func _check_ground_collision() -> void:
	var previous: Heightfield = Game.heightfield
	var wall := HEIGHTFIELD_SCRIPT.new()
	wall.base_elevation = 500.0
	Game.heightfield = wall

	# The scene this runs in has no Player, so the rig has no follow target and
	# _process's ground-collision step (gated on one existing) never runs.
	# Give it a stationary stand-in purely so that gate opens.
	if _rig.target == null:
		var stand_in := Node3D.new()
		add_child(stand_in)
		_rig.target = stand_in

	# Reset to a known framing so the camera's prospective position is
	# predictable, then let one frame run the collision check in _process.
	_rig.set_pitch(-20.0)
	_rig.set_distance(20.0)
	_rig.global_position = _rig.target.global_position + _rig.target_offset
	await get_tree().process_frame

	var cam_y: float = _rig.get_camera().global_position.y
	var expected_min: float = wall.base_elevation + _rig.ground_clearance
	if cam_y < expected_min - 0.01:
		_fail("camera at y=%.2f sits below the ground it should have been pushed above (%.2f)"
			% [cam_y, expected_min])
	else:
		print("  ground collision: camera pushed to y=%.2f, at/above %.2f" % [cam_y, expected_min])

	# The real bug this caught: the clamp writes the camera's LOCAL transform
	# (it's a child of the rig), and without a reset each frame that offset is
	# permanent — the camera stays pushed up forever, even once the ground
	# that caused it is gone. Swap back to flat ground and confirm one more
	# frame brings the camera back down rather than leaving it parked at the
	# wall's height.
	var flat := HEIGHTFIELD_SCRIPT.new()
	Game.heightfield = flat
	await get_tree().process_frame
	var recovered_y: float = _rig.get_camera().global_position.y
	if recovered_y > wall.base_elevation - 1.0:
		_fail("camera stuck at y=%.2f after the ground that raised it was gone (wall was at %.2f)"
			% [recovered_y, wall.base_elevation])
	else:
		print("  spring-back: camera returned to y=%.2f once flat ground allowed it" % recovered_y)

	Game.heightfield = previous
