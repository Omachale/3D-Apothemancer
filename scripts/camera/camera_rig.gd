extends Node3D

## Isometric-style follow rig.
##
## The rig node sits at the point being looked at; the Camera3D child is pushed
## straight back along the rig's local +Z, so the whole framing is controlled by
## three numbers: [member yaw], [member pitch] and [member distance].
##
## Pitch is fixed at the game's framing by default. F12 unlocks it for
## middle-mouse dragging and F12 again re-locks it, snapping back to the
## startup value — so experimenting with the angle can always be undone with
## one key rather than by nudging it back by eye.
##
## Framing note: a narrow FOV pushed further back reads as "isometric" while
## keeping a little perspective depth. At the defaults below the mage (~2.6
## units tall including the hat) fills roughly 18% of the viewport height,
## which is the Fallout / Diablo sort of scale asked for.

@export_group("Framing")
## Rotation around the world Y axis. 0 faces due North (-Z) — see
## [[DESIGN_GOALS.md]]'s compass note. 45 gives the classic diagonal view;
## the default is 0 so the game opens facing North, at the cost of the
## diagonal look for that first frame until the player rotates or moves.
@export_range(-180.0, 180.0, 1.0) var yaw := 0.0: set = set_yaw
## Downward tilt. -90 would be straight down; -50 keeps some sense of height.
@export_range(-89.0, -5.0, 1.0) var pitch := -45.0: set = set_pitch
## How far the camera sits back along the view ray.
@export_range(4.0, 60.0, 0.5) var distance := 20.0: set = set_distance
@export_range(10.0, 90.0, 1.0) var fov := 45.0: set = set_fov
## World units [member distance] moves per scroll-wheel notch. Zooming out
## (larger distance) reads as "smaller on screen, more of the map visible" —
## the same three numbers (yaw/pitch/distance) already drive the whole
## framing, so this is just scroll wired to one of them, clamped to the
## @export_range above like every other path that touches distance.
@export_range(0.5, 10.0, 0.5) var zoom_step := 2.5

@export_group("Follow")
## Point on the player the camera centres on, relative to their feet.
@export var target_offset := Vector3(0.0, 1.1, 0.0)
## Higher = snappier horizontal follow.
@export_range(0.5, 30.0, 0.5) var follow_speed := 9.0
## Deliberately slower than horizontal follow so stairs and hills glide
## rather than jolting the whole view up a step at a time.
@export_range(0.5, 30.0, 0.5) var vertical_follow_speed := 4.0

@export_group("Rotation")
@export var allow_rotation := true
@export_range(0.0, 360.0, 5.0) var rotation_speed := 90.0

@export_group("Pitch control")
## Degrees of tilt per pixel of middle-mouse drag, once F12 has unlocked pitch.
@export_range(0.02, 1.0, 0.01) var pitch_drag_speed := 0.25
## Which way a drag tilts. The default is the orbit convention: drag UP and the
## camera rises, giving a more top-down view. Exported because this is pure
## preference and the opposite convention is just as common — one checkbox
## beats asking anyone to edit code over it.
@export var invert_pitch_drag := false

@export_group("Inspect mode")
## F1 swings the camera in close at near eye level. The gameplay framing is
## deliberately far enough out that the character is only ~100px tall, which is
## useless for judging an animation — this is the view to tune poses in.
@export_range(-89.0, 30.0, 1.0) var inspect_pitch := -8.0
@export_range(1.0, 20.0, 0.25) var inspect_distance := 4.0
@export_range(10.0, 90.0, 1.0) var inspect_fov := 50.0
## Chest height, so the character sits centred rather than at the bottom edge.
@export var inspect_offset := Vector3(0.0, 1.5, 0.0)
## Seconds to swing between the two framings.
@export_range(0.0, 2.0, 0.05) var inspect_blend_time := 0.35

## Ends of the pitch range, matching [member pitch]'s @export_range. Held as
## constants because that annotation only constrains the INSPECTOR — nothing
## stopped code from setting a pitch the editor would refuse, and dragging is
## code. Clamping in [method set_pitch] makes the two agree.
const MIN_PITCH := -89.0
const MAX_PITCH := -5.0

var target: Node3D = null

## 0 = gameplay framing, 1 = inspect framing.
var _inspect := 0.0
var _inspect_on := false
## Whether middle-drag may tilt the camera. Off by default: the fixed pitch is
## the game's look, and a camera that drifts off it by accident is worse than
## one that cannot move at all.
var _pitch_unlocked := false
## The framing to restore when pitch is locked again. Captured once at startup
## rather than read from the export at restore time, because dragging writes
## straight to `pitch` — by the time the player toggles off, the export no
## longer remembers what it started as.
var _default_pitch := -45.0

@onready var _camera: Camera3D = $Camera3D


func _ready() -> void:
	_default_pitch = pitch
	_apply_rig_rotation()
	_apply_camera_transform()
	Game.register_camera(self)
	if target == null and Game.player:
		target = Game.player
	Game.player_registered.connect(func(p: Node3D) -> void: target = p)
	# Start already framed on the target instead of flying in from the origin.
	if target:
		global_position = target.global_position + target_offset


func _process(delta: float) -> void:
	if allow_rotation:
		var turn := Input.get_axis("camera_rotate_right", "camera_rotate_left")
		if not is_zero_approx(turn):
			set_yaw(yaw + turn * rotation_speed * delta)

	if Input.is_action_just_pressed("camera_inspect"):
		_inspect_on = not _inspect_on

	if Input.is_action_just_pressed("camera_pitch_toggle"):
		_pitch_unlocked = not _pitch_unlocked
		# Locking SNAPS back to the default rather than easing there. An eased
		# return would be prettier, but it would also fight the inspect blend
		# for ownership of the same value; snapping is unambiguous, and F12 is
		# a deliberate press rather than something brushed by accident.
		if not _pitch_unlocked:
			set_pitch(_default_pitch)

	# Only zooms the gameplay framing — inspect mode has its own fixed
	# distance for judging poses up close, and scrolling shouldn't disturb it.
	if not _inspect_on:
		if Input.is_action_just_pressed("camera_zoom_in"):
			set_distance(clampf(distance - zoom_step, 4.0, 60.0))
		elif Input.is_action_just_pressed("camera_zoom_out"):
			set_distance(clampf(distance + zoom_step, 4.0, 60.0))
	var blend_weight := 1.0 - exp(-delta / maxf(inspect_blend_time, 0.001))
	var inspect_goal := 1.0 if _inspect_on else 0.0
	if not is_equal_approx(_inspect, inspect_goal):
		_inspect = lerpf(_inspect, inspect_goal, blend_weight)
		_apply_rig_rotation()
		_apply_camera_transform()

	if target == null:
		return

	var goal := target.global_position + target_offset.lerp(inspect_offset, _inspect)
	var pos := global_position
	# Exponential smoothing: framerate independent, unlike a raw lerp factor.
	var h_weight := 1.0 - exp(-follow_speed * delta)
	var v_weight := 1.0 - exp(-vertical_follow_speed * delta)
	pos.x = lerp(pos.x, goal.x, h_weight)
	pos.z = lerp(pos.z, goal.z, h_weight)
	pos.y = lerp(pos.y, goal.y, v_weight)
	global_position = pos


## Middle-drag tilts the camera while pitch is unlocked.
##
## Handled here as an event rather than polled in _process because only the
## event carries `relative` — the per-frame mouse DELTA. Polling would give the
## cursor position, from which a delta would have to be reconstructed by
## remembering last frame's, and that reconstruction breaks the moment the
## window loses and regains focus.
func _unhandled_input(event: InputEvent) -> void:
	if not _pitch_unlocked or not (event is InputEventMouseMotion):
		return
	if not Input.is_action_pressed("camera_pitch_drag"):
		return
	# Inspect mode drives pitch from inspect_pitch, so a drag now would write a
	# value nothing displays and then surprise the player when they leave
	# inspect. Refusing outright is clearer than a silent partial effect.
	if _inspect_on:
		return
	var amount: float = event.relative.y * pitch_drag_speed
	set_pitch(pitch + (-amount if invert_pitch_drag else amount))


## True while middle-drag may tilt the camera.
func is_pitch_unlocked() -> bool:
	return _pitch_unlocked


## Jump straight to the target with no smoothing. Call after teleporting the
## player (spawn, zone change) so the camera does not sweep across the map.
func snap_to_target() -> void:
	if target:
		global_position = target.global_position + target_offset


## Direction the camera faces, flattened onto the ground plane. Movement input
## is resolved against this so W always means "away from the camera".
func get_ground_basis() -> Basis:
	return Basis(Vector3.UP, deg_to_rad(yaw))


## Projects a viewport point onto a horizontal plane at [param plane_y].
## Used for mouse aiming. Returns null if the ray runs parallel to the plane.
func screen_point_to_ground(screen_pos: Vector2, plane_y: float) -> Variant:
	if _camera == null:
		return null
	var origin := _camera.project_ray_origin(screen_pos)
	var dir := _camera.project_ray_normal(screen_pos)
	if is_zero_approx(dir.y):
		return null
	var t := (plane_y - origin.y) / dir.y
	if t < 0.0:
		return null
	return origin + dir * t


func set_yaw(value: float) -> void:
	yaw = wrapf(value, -180.0, 180.0)
	_apply_rig_rotation()


func set_pitch(value: float) -> void:
	pitch = clampf(value, MIN_PITCH, MAX_PITCH)
	_apply_rig_rotation()


func set_distance(value: float) -> void:
	distance = value
	_apply_camera_transform()


func set_fov(value: float) -> void:
	fov = value
	_apply_camera_transform()


## True while the close-up inspect framing is active. Handy for anything that
## wants to behave differently when the player is studying the character.
func is_inspecting() -> bool:
	return _inspect_on


func set_inspect(enabled: bool) -> void:
	_inspect_on = enabled


## The distance actually in use, which differs from [member distance] while the
## inspect camera is engaged or blending.
func get_active_distance() -> float:
	return lerpf(distance, inspect_distance, _inspect)


## The actual Camera3D, for anything that needs its real position or FOV
## rather than the rig's — terrain_manager.gd's screen-space LOD test, chiefly,
## since the rig's own origin is the point being looked AT, not looked FROM.
func get_camera() -> Camera3D:
	return _camera


func _apply_rig_rotation() -> void:
	if not is_inside_tree():
		return
	var p := lerpf(pitch, inspect_pitch, _inspect)
	rotation = Vector3(deg_to_rad(p), deg_to_rad(yaw), 0.0)


func _apply_camera_transform() -> void:
	if _camera == null:
		return
	_camera.position = Vector3(0.0, 0.0, lerpf(distance, inspect_distance, _inspect))
	_camera.rotation = Vector3.ZERO
	_camera.fov = lerpf(fov, inspect_fov, _inspect)





