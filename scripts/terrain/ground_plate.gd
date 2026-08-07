@tool
class_name GroundPlate
extends StaticBody3D

## A flat slab of walkable ground.
##
## The node's own origin sits on the *top* surface, so placing a plate at
## Y = 3 means you walk on Y = 3. The slab body hangs below that. This is the
## building block for both the main plane and the raised areas — one large
## plate at Y=0, smaller ones stacked wherever the ground needs to rise.

@export var size := Vector2(100.0, 100.0): set = set_size
## How far the slab extends below the walking surface. Purely cosmetic depth,
## except that it needs to be thick enough not to be fallen through.
@export var thickness := 1.0: set = set_thickness
@export var material: Material: set = set_material

var _mesh: MeshInstance3D
var _collider: CollisionShape3D


func _ready() -> void:
	collision_layer = Layers.WORLD
	collision_mask = 0
	_rebuild()


func set_size(value: Vector2) -> void:
	size = value
	_rebuild()


func set_thickness(value: float) -> void:
	thickness = maxf(value, 0.05)
	_rebuild()


func set_material(value: Material) -> void:
	material = value
	if _mesh:
		_mesh.material_override = material


func _rebuild() -> void:
	if not is_inside_tree():
		return

	if _mesh == null:
		_mesh = MeshInstance3D.new()
		_mesh.name = "Mesh"
		_mesh.mesh = BoxMesh.new()
		add_child(_mesh)
	if _collider == null:
		_collider = CollisionShape3D.new()
		_collider.name = "Collider"
		_collider.shape = BoxShape3D.new()
		add_child(_collider)

	var extents := Vector3(size.x, thickness, size.y)
	(_mesh.mesh as BoxMesh).size = extents
	(_collider.shape as BoxShape3D).size = extents

	# Push both down so the top face lands exactly on the node origin.
	var offset := Vector3(0.0, -thickness * 0.5, 0.0)
	_mesh.position = offset
	_collider.position = offset
	_mesh.material_override = material
