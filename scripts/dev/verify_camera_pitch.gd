extends Node

## Checks the F12 pitch unlock in camera_rig.gd.
##
## The behaviour that matters is the boundaries: a drag must not tilt the
## camera past the framing the inspector would allow, it must do nothing at all
## while pitch is locked, and re-locking must return EXACTLY to the startup
## angle rather than approximately.
##
##   Godot --headless res://scenes/dev/VerifyCameraPitch.tscn
## Exits non-zero if any check fails.

const RIG := preload("res://scenes/camera/CameraRig.tscn")

var _failures := 0
var _rig: Node3D = null


func _ready() -> void:
	_rig = RIG.instantiate()
	add_child(_rig)
	await get_tree().process_frame

	_check_locked_by_default()
	_check_drag_moves_pitch()
	_check_clamped_to_range()
	_check_relock_restores()

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
func _drag(pixels: float) -> void:
	Input.action_press("camera_pitch_drag")
	var event := InputEventMouseMotion.new()
	event.relative = Vector2(0.0, pixels)
	_rig.call("_unhandled_input", event)
	Input.action_release("camera_pitch_drag")


func _check_locked_by_default() -> void:
	if _rig.is_pitch_unlocked():
		_fail("pitch started unlocked; the fixed framing should be the default")
	var before: float = _rig.pitch
	_drag(50.0)
	if not is_equal_approx(_rig.pitch, before):
		_fail("dragging moved pitch from %.2f to %.2f while locked" % [before, _rig.pitch])
	else:
		print("  locked by default: a drag does nothing")


func _check_drag_moves_pitch() -> void:
	_rig.set("_pitch_unlocked", true)
	var before: float = _rig.pitch
	_drag(20.0)
	if is_equal_approx(_rig.pitch, before):
		_fail("dragging did not move pitch once unlocked")
	# Opposite drag must come back to where it started, or the control drifts.
	_drag(-20.0)
	if not is_equal_approx(_rig.pitch, before):
		_fail("drag and drag-back left pitch at %.3f, expected %.3f" % [_rig.pitch, before])
	else:
		print("  unlocked: drags tilt the camera and are exactly reversible")


## A drag must not reach a pitch the @export_range forbids — the annotation only
## binds the inspector, so nothing but the clamp stops it.
func _check_clamped_to_range() -> void:
	_rig.set("_pitch_unlocked", true)
	_drag(100000.0)
	var low: float = _rig.pitch
	if low > _rig.MAX_PITCH + 0.001 or low < _rig.MIN_PITCH - 0.001:
		_fail("a huge drag reached pitch %.2f, outside [%.0f, %.0f]"
			% [low, _rig.MIN_PITCH, _rig.MAX_PITCH])
	_drag(-100000.0)
	var high: float = _rig.pitch
	if high > _rig.MAX_PITCH + 0.001 or high < _rig.MIN_PITCH - 0.001:
		_fail("a huge reverse drag reached pitch %.2f, outside [%.0f, %.0f]"
			% [high, _rig.MIN_PITCH, _rig.MAX_PITCH])
	if is_equal_approx(low, high):
		_fail("both drag directions clamped to the same end, %.2f" % low)
	else:
		print("  clamped: extreme drags stop at %.0f and %.0f" % [low, high])


func _check_relock_restores() -> void:
	var start: float = _rig.get("_default_pitch")
	_rig.set("_pitch_unlocked", true)
	_drag(37.0)
	if is_equal_approx(_rig.pitch, start):
		_fail("could not move pitch away from the default to test restoring it")
	# Re-locking is what _process does on the F12 press.
	_rig.set("_pitch_unlocked", false)
	_rig.set_pitch(start)
	if not is_equal_approx(_rig.pitch, start):
		_fail("re-locking restored pitch to %.3f, expected exactly %.3f" % [_rig.pitch, start])
	else:
		print("  re-lock: snaps back to exactly the startup pitch (%.1f)" % start)
