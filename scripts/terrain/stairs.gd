@tool
class_name Stairs
extends Node3D

## A parametric flight of steps.
##
## IMPORTANT — how these are collided with:
## Godot 4's CharacterBody3D has no step-up handling, so a body walked into a
## stack of real step colliders simply stops dead against the first riser.
## The standard fix, and what this does, is to make the *visuals* stepped but
## the *collision* a single smooth ramp laid across the step noses. The player
## glides up it with move_and_slide and no raycasting or Y-lerping is needed.
##
## Keep the ramp angle under the player's floor_max_angle (currently 50 deg).
## The default 0.3 rise / 0.4 going works out at ~37 deg.
##
## The flight starts at the node origin and ascends toward local +Z, so rotating
## the node aims the staircase.

@export var step_count := 10: set = set_step_count
@export var step_height := 0.3: set = set_step_height
@export var step_depth := 0.4: set = set_step_depth
@export var width := 4.0: set = set_width
@export var material: Material: set = set_material
## Thickness of the invisible collision ramp.
@export var ramp_thickness := 0.5

var _steps_root: Node3D
var _body: StaticBody3D
var _ramp: CollisionShape3D


## Total height gained across the flight. Match this to the plate it feeds.
func get_rise() -> float:
	return step_count * step_height


## Horizontal distance covered, along local +Z.
func get_run() -> float:
	return step_count * step_depth


func _ready() -> void:
	_rebuild()


func set_step_count(value: int) -> void:
	step_count = maxi(value, 1)
	_rebuild()


func set_step_height(value: float) -> void:
	step_height = maxf(value, 0.02)
	_rebuild()


func set_step_depth(value: float) -> void:
	step_depth = maxf(value, 0.02)
	_rebuild()


func set_width(value: float) -> void:
	width = maxf(value, 0.1)
	_rebuild()


func set_material(value: Material) -> void:
	material = value
	_rebuild()


func _rebuild() -> void:
	if not is_inside_tree():
		return

	if _steps_root == null:
		_steps_root = Node3D.new()
		_steps_root.name = "Steps"
		add_child(_steps_root)
	if _body == null:
		_body = StaticBody3D.new()
		_body.name = "RampBody"
		_body.collision_layer = Layers.WORLD
		_body.collision_mask = 0
		add_child(_body)
	if _ramp == null:
		_ramp = CollisionShape3D.new()
		_ramp.name = "RampCollider"
		_ramp.shape = BoxShape3D.new()
		_body.add_child(_ramp)

	_build_visual_steps()
	_build_ramp()


func _build_visual_steps() -> void:
	for child in _steps_root.get_children():
		child.queue_free()

	for i in step_count:
		var height := (i + 1) * step_height
		var step := MeshInstance3D.new()
		step.name = "Step%02d" % i
		var box := BoxMesh.new()
		# Each step is a solid block from the ground up to its own tread, so
		# the flight reads as masonry rather than floating slabs.
		box.size = Vector3(width, height, step_depth)
		step.mesh = box
		step.position = Vector3(0.0, height * 0.5, i * step_depth + step_depth * 0.5)
		step.material_override = material
		_steps_root.add_child(step)


func _build_ramp() -> void:
	var rise := get_rise()
	var run := get_run()
	var angle := atan2(rise, run)
	var length := sqrt(rise * rise + run * run)

	(_ramp.shape as BoxShape3D).size = Vector3(width, ramp_thickness, length)

	# Rotating +Z down by -angle lays the box's long axis along the flight.
	_ramp.rotation = Vector3(-angle, 0.0, 0.0)

	# Surface runs from (y=0, z=0) to (y=rise, z=run); sink the box by half its
	# thickness along its own up-normal so its top face is that surface.
	var up_normal := Vector3(0.0, cos(angle), -sin(angle))
	_ramp.position = Vector3(0.0, rise * 0.5, run * 0.5) - up_normal * (ramp_thickness * 0.5)
