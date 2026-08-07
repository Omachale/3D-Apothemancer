class_name GrassField
extends Node3D

## A patch of wind-swayed grass, drawn as one MultiMesh.
##
## Every blade in a field is a single draw call no matter how many there are,
## so the cost here is instance count and the fill they cover — not the number
## of nodes. That is why this is a MultiMesh and not thousands of MeshInstances.
##
## Blades are planted by raycasting down onto whatever is actually below, so a
## field follows the terrain it is laid over, including the procedural mound.
## Slopes past [member max_slope_degrees] are skipped, which keeps grass off
## stair ramps without needing to know they are there.
##
## NOT a @tool script, deliberately: placement needs the physics world, which
## does not exist in the editor the way it does at runtime. Fields simply do
## not appear in the editor viewport.

const DEFAULT_MATERIAL := preload("res://resources/materials/grass_blades.tres")

@export_group("Extent")
@export_range(1.0, 80.0, 0.5) var radius := 12.0
## Blades per square metre. The single number that decides both how good this
## looks and what it costs — see [member max_blades].
@export_range(1.0, 400.0, 1.0) var density := 90.0
## Hard ceiling, applied after density x area. Exists so that widening a patch
## cannot accidentally ask for millions of blades.
@export_range(100, 400000, 100) var max_blades := 60000
## Ground steeper than this gets no grass, which keeps it off stair ramps and
## the steepest flanks of hills.
@export_range(0.0, 89.0, 1.0) var max_slope_degrees := 30.0
## Fraction of the radius over which density falls away to nothing at the rim.
## Without this a patch ends on a hard circular line that reads as a bald spot
## in the world rather than as a meadow.
@export_range(0.0, 1.0, 0.05) var edge_feather := 0.4

@export_group("Blade")
@export_range(0.05, 4.0, 0.05) var blade_height := 0.32
@export_range(0.005, 0.5, 0.005) var blade_width := 0.05
## Vertical segments per blade. This is what the bend curve has to work with:
## 1 segment cannot bend at all, 2 looks like a hinge. 4 is smooth enough that
## more is hard to see.
@export_range(1, 8, 1) var blade_segments := 4
## Forward lean built into the mesh, so a blade at rest is not a rigid spike.
@export_range(0.0, 1.0, 0.01) var blade_droop := 0.16
@export_range(0.0, 1.0, 0.05) var height_variation := 0.4

@export_group("Wiring")
@export var seed := 20240
@export var material: Material = null

var _multimesh_instance: MultiMeshInstance3D = null
var _planted := 0


func _ready() -> void:
	# One physics frame's grace: the terrain this field sits on was very
	# likely added to the tree in the same frame as this node, and a body is
	# not answerable to a raycast until the space has been stepped once.
	# Without this wait every ray misses and the field comes out empty.
	await get_tree().physics_frame
	_build()


## How many blades actually got planted. Lower than requested wherever rays
## found nothing, or found ground too steep to grass.
func get_blade_count() -> int:
	return _planted


func _build() -> void:
	var started_msec := Time.get_ticks_msec()
	var wanted := mini(int(density * PI * radius * radius), max_blades)
	var placements := _find_placements(wanted)
	_planted = placements.size()
	if _planted == 0:
		push_warning("GrassField '%s': nothing to plant on." % name)
		return
	# Worth seeing at a glance: this is the number that costs, and it is always
	# lower than density x area once the rim feathering and the slope and ray
	# rejections have had their say. The elapsed time is the number that
	# actually limits how large a field can get — one raycast per candidate
	# blade, done once at load, not a per-frame render cost.
	var placed_msec := Time.get_ticks_msec() - started_msec

	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	# Per-blade phase, stiffness and tint travel to the shader this way.
	multimesh.use_custom_data = true
	multimesh.mesh = _build_blade_mesh()
	multimesh.instance_count = _planted

	var rng := RandomNumberGenerator.new()
	rng.seed = seed ^ 0x5f3a
	for i in _planted:
		var spot: Dictionary = placements[i]
		var scale_y := 1.0 + rng.randf_range(-height_variation, height_variation)
		var basis := Basis(Vector3.UP, rng.randf() * TAU)
		basis = basis.scaled(Vector3(1.0, scale_y, 1.0))
		multimesh.set_instance_transform(i, Transform3D(basis, spot["pos"]))
		multimesh.set_instance_custom_data(i, Color(
			rng.randf(),   # phase
			rng.randf(),   # stiffness
			rng.randf(),   # tint
			0.0))

	_multimesh_instance = MultiMeshInstance3D.new()
	_multimesh_instance.name = "Blades"
	_multimesh_instance.multimesh = multimesh
	_multimesh_instance.material_override = material if material else DEFAULT_MATERIAL
	# Grass casting shadows on itself is expensive and, at this blade size,
	# invisible. The ground already receives the shadows that matter.
	_multimesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# The shader bends blades outside the bounds Godot computes from the
	# instance transforms, so widen the box or patches flicker out at the edge
	# of view.
	var reach := blade_height * (1.0 + height_variation) + 1.0
	_multimesh_instance.custom_aabb = AABB(
		Vector3(-radius - reach, -reach, -radius - reach),
		Vector3((radius + reach) * 2.0, reach * 3.0, (radius + reach) * 2.0))
	add_child(_multimesh_instance)

	var total_msec := Time.get_ticks_msec() - started_msec
	print("GrassField '%s': %d blades (asked for %d) — %d ms placement, %d ms total" % [
		name, _planted, wanted, placed_msec, total_msec])


## Rays straight down over the patch, keeping the ones that land on ground
## flat enough to grow on. Returns dictionaries with a local-space position.
func _find_placements(count: int) -> Array:
	var space := get_world_3d().direct_space_state
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var min_up := cos(deg_to_rad(max_slope_degrees))
	var results: Array = []
	var origin := global_position

	for _i in count:
		# sqrt keeps the scatter even; without it everything crowds the middle.
		var angle := rng.randf() * TAU
		var unit := sqrt(rng.randf())
		# Thin the planting out toward the rim so the patch has no hard edge.
		if edge_feather > 0.0:
			var keep := 1.0 - smoothstep(1.0 - edge_feather, 1.0, unit)
			if rng.randf() > keep:
				continue
		var r := unit * radius
		var x := origin.x + cos(angle) * r
		var z := origin.z + sin(angle) * r

		var query := PhysicsRayQueryParameters3D.create(
			Vector3(x, origin.y + 60.0, z),
			Vector3(x, origin.y - 60.0, z),
			Layers.WORLD)
		var hit := space.intersect_ray(query)
		if hit.is_empty():
			continue
		if hit["normal"].y < min_up:
			continue
		results.append({"pos": to_local(hit["position"])})

	return results


## One blade: a tapered strip standing on the origin, leaning slightly forward.
##
## UV.y carries the normalised height, 0 at root and 1 at tip, which is what
## the shader bends by. Keeping it in the mesh rather than in a uniform means
## changing the blade dimensions here cannot desynchronise the two.
func _build_blade_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	for i in blade_segments + 1:
		var t := float(i) / float(blade_segments)
		# Taper toward the tip, fastest near the top, so the blade keeps some
		# body low down instead of being a plain triangle.
		var half_width := blade_width * 0.5 * pow(1.0 - t, 0.65)
		var y := blade_height * t
		var z := blade_droop * blade_height * t * t

		st.set_uv(Vector2(0.0, t))
		st.add_vertex(Vector3(-half_width, y, z))
		st.set_uv(Vector2(1.0, t))
		st.add_vertex(Vector3(half_width, y, z))

	# Clockwise winding is front-facing in Godot. The blade is drawn
	# double-sided so this does not decide visibility, but it does decide which
	# way generate_normals() points.
	for i in blade_segments:
		var a := i * 2
		var b := a + 1
		var c := a + 2
		var d := a + 3
		st.add_index(a)
		st.add_index(c)
		st.add_index(b)
		st.add_index(b)
		st.add_index(c)
		st.add_index(d)

	st.generate_normals()
	return st.commit()
