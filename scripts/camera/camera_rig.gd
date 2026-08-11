extends Node3D

## Isometric-style follow rig.
##
## The rig node sits at the point being looked at; the Camera3D child is pushed
## straight back along the rig's local +Z, so the whole framing is controlled by
## three numbers: [member yaw], [member pitch] and [member distance].
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

var target: Node3D = null

## 0 = gameplay framing, 1 = inspect framing.
var _inspect := 0.0
var _inspect_on := false

@onready var _camera: Camera3D = $Camera3D


func _ready() -> void:
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
	pitch = value
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





