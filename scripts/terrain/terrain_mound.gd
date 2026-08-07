@tool
class_name TerrainMound
extends StaticBody3D

## A procedurally generated hill: a heightmap surface with trimesh collision.
##
## Everything else in this project's terrain is boxes, which cannot make a
## slope that reads as landscape. This builds a real mesh instead — a grid of
## vertices whose height comes from a radial falloff plus noise — and hands the
## same triangles to a ConcavePolygonShape3D so the player walks on exactly
## what they see. No sculpting, no imported heightmap image, no external tools.
##
## SLOPE IS THE CONSTRAINT THAT SHAPES EVERY DEFAULT HERE. The player is a
## CharacterBody3D with a 50 degree floor_max_angle; anything steeper is a
## wall they slide off rather than ground they climb. The falloff below is a
## smoothstep, whose steepest point is 1.5 x [member height] / [member radius],
## so those two numbers are not free — at the defaults that is about 35
## degrees, leaving room for the noise to add its own local steepness without
## crossing the limit. Raising `height` without raising `radius` to match will
## produce a hill that cannot be climbed.
##
## Use [method max_slope_degrees] to check a configuration rather than guessing.

const DEFAULT_MATERIAL := preload("res://resources/materials/mound.tres")

@export_group("Shape")
@export_range(4.0, 200.0, 0.5) var radius := 24.0: set = _set_radius
@export_range(0.5, 80.0, 0.5) var height := 11.0: set = _set_height
## Grid cells across the whole mound. Cost is this squared, and it is the only
## real dial on how smooth the silhouette looks.
@export_range(8, 160, 1) var resolution := 56: set = _set_resolution

@export_group("Detail")
## Irregularity on top of the smooth cone. Adds local slope, so it eats into
## the headroom under floor_max_angle — see the note above.
@export_range(0.0, 10.0, 0.1) var noise_amplitude := 1.2: set = _set_noise_amplitude
@export_range(0.001, 0.5, 0.001) var noise_frequency := 0.025: set = _set_noise_frequency
@export var noise_seed := 1337: set = _set_noise_seed

@export_group("Fit")
## Sinks the rim below the surrounding ground. The mound's edge height is
## exactly zero, which is the same plane as the ground slab it sits on, and
## coplanar surfaces z-fight. Dropping the rim a little puts the join safely
## underground: the ground wins where they overlap, the mound emerges cleanly
## a short way in, and there is no lip to catch on.
@export_range(0.0, 1.0, 0.01) var rim_sink := 0.08: set = _set_rim_sink
@export var material: Material = null: set = _set_material

var _mesh_instance: MeshInstance3D = null
var _collider: CollisionShape3D = null
var _noise := FastNoiseLite.new()


func _ready() -> void:
	collision_layer = Layers.WORLD
	collision_mask = 0
	_rebuild()


## The steepest slope this configuration can produce, in degrees, counting both
## the falloff and the worst case the noise can add. Compare against the
## player's floor_max_angle (50) before trusting a new set of numbers.
func max_slope_degrees() -> float:
	var falloff := 1.5 * height / maxf(radius, 0.001)
	var detail := noise_amplitude * TAU * noise_frequency
	return rad_to_deg(atan(falloff + detail))


## Surface height at a point in the mound's local XZ, relative to its origin.
func height_at(x: float, z: float) -> float:
	var d := sqrt(x * x + z * z) / maxf(radius, 0.001)
	if d >= 1.0:
		return -rim_sink
	var t := 1.0 - d
	# smoothstep is flat-tangent at both ends, which gives a rounded summit and
	# a rim that meets the surrounding ground without a visible crease.
	var base := height * smoothstep(0.0, 1.0, t)
	# Fade the noise out near the rim too, so the join stays clean.
	var detail := _noise.get_noise_2d(x, z) * noise_amplitude * smoothstep(0.0, 0.4, t)
	return base + detail - rim_sink


func _rebuild() -> void:
	if not is_inside_tree():
		return

	_noise.seed = noise_seed
	_noise.frequency = noise_frequency
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.fractal_octaves = 3

	if _mesh_instance == null:
		_mesh_instance = MeshInstance3D.new()
		_mesh_instance.name = "Surface"
		add_child(_mesh_instance)
	if _collider == null:
		_collider = CollisionShape3D.new()
		_collider.name = "Collider"
		add_child(_collider)

	var mesh := _build_mesh()
	_mesh_instance.mesh = mesh
	_mesh_instance.material_override = material if material else DEFAULT_MATERIAL
	_collider.shape = mesh.create_trimesh_shape()


func _build_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var step := radius * 2.0 / float(resolution)
	var stride := resolution + 1

	for i in stride:
		for j in stride:
			var x := -radius + i * step
			var z := -radius + j * step
			st.set_uv(Vector2(float(i) / resolution, float(j) / resolution))
			st.add_vertex(Vector3(x, height_at(x, z), z))

	# Godot treats CLOCKWISE-wound triangles as front-facing, so the indices
	# below run a-c-b rather than the a-b-c a right-hand-rule derivation
	# suggests. Getting this backwards is quietly expensive: the surface
	# renders near-black (normals face down, so it takes no light) *and* the
	# player cannot stand on it (`is_on_floor()` stays false, because the
	# collision normal points down too). One cause, two unrelated-looking
	# symptoms.
	for i in resolution:
		for j in resolution:
			var a := i * stride + j
			var b := a + 1
			var c := a + stride
			var d := c + 1
			st.add_index(a)
			st.add_index(c)
			st.add_index(b)
			st.add_index(b)
			st.add_index(c)
			st.add_index(d)

	# Averaged across shared vertices, so the surface shades smoothly instead
	# of showing every triangle.
	st.generate_normals()
	return st.commit()


func _set_radius(value: float) -> void:
	radius = maxf(value, 1.0)
	_rebuild()


func _set_height(value: float) -> void:
	height = maxf(value, 0.1)
	_rebuild()


func _set_resolution(value: int) -> void:
	resolution = maxi(value, 4)
	_rebuild()


func _set_noise_amplitude(value: float) -> void:
	noise_amplitude = maxf(value, 0.0)
	_rebuild()


func _set_noise_frequency(value: float) -> void:
	noise_frequency = maxf(value, 0.0001)
	_rebuild()


func _set_noise_seed(value: int) -> void:
	noise_seed = value
	_rebuild()


func _set_rim_sink(value: float) -> void:
	rim_sink = maxf(value, 0.0)
	_rebuild()


func _set_material(value: Material) -> void:
	material = value
	if _mesh_instance:
		_mesh_instance.material_override = material if material else DEFAULT_MATERIAL
