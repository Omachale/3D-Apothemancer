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

## Emitted once, after placement finishes and blades are in the MultiMesh
## (even if zero blades were planted). grass_manager.gd waits on this so it
## can throttle how many chunks build at once instead of spawning them all in
## one frame.
signal built

@export_group("Extent")
## Ignored when [member square_size] is nonzero — see that var. Kept as the
## default mode because a single hand-placed meadow patch (no neighbours to
## tile with) wants a soft round edge, not a square one.
@export_range(1.0, 80.0, 0.5) var radius := 12.0
## When > 0, placement scatters across a [param square_size] x [param
## square_size] square instead of a circle of [member radius], and skips edge
## feathering. This is what grass_manager.gd's chunks use: a circle either
## leaves gaps at a grid cell's corners or, sized to cover them, overlaps and
## double-plants the band shared with the next chunk. A square tiles exactly.
@export_range(0.0, 200.0, 0.5) var square_size := 0.0
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
## Where the ground is, when it is known as maths rather than as geometry.
##
## WITH one, each blade's spot is worked out by asking the heightfield directly.
## WITHOUT one, placement falls back to firing a physics ray downward per blade,
## which is how this worked before terrain became a heightfield.
##
## The fallback is not just slower, it is WRONG NOW: terrain is streamed, so the
## collider a ray needs may not have been built yet, and a field planting itself
## a moment too early would come out bald with no way to tell that it had. The
## heightfield has no such problem — it can answer for ground nothing has ever
## looked at. Raycasting is kept only for grass on hand-placed objects that are
## not part of the heightfield at all.
var heightfield: Heightfield = null
## World-space rectangles, in XZ, where no grass is planted. Building
## footprints, mostly: the heightfield describes the ground UNDER a building, so
## without this, blades sprout through its floor. (The old raycast placement
## dodged this by accident — a ray hit the roof first — which is also why it
## used to grow grass on rooftops.)
var exclusions: Array = []
## Placement yields to the tree after this many blades, so a large field is
## spread over several frames instead of blocking one for its entire duration.
## A busy field otherwise reads as a stutter exactly when a streamed chunk
## starts building near the player — see grass_manager.gd.
## 0 disables batching (finishes in one frame, same as before this existed).
@export_range(0, 5000, 50) var samples_per_batch := 500

var _multimesh_instance: MultiMeshInstance3D = null
var _planted := 0
## Work actually done, with time spent waiting between frames excluded.
##
## Worth being pedantic about, because the obvious version is badly misleading:
## placement yields every samples_per_batch blades, so wall-clock time across
## the whole operation is dominated by how long the frames took, not by how much
## work this did. An earlier version reported that wall-clock figure and it read
## as ~60 ms per chunk when the real cost was a small fraction of it — which
## made a cheap chunk and an expensive one look identical, and sent tuning after
## the wrong things.
var _work_usec := 0
var _mark_usec := 0


func _ready() -> void:
	if heightfield == null:
		# One physics frame's grace: the terrain this field sits on was very
		# likely added to the tree in the same frame as this node, and a body is
		# not answerable to a raycast until the space has been stepped once.
		# Without this wait every ray misses and the field comes out empty.
		# Not needed when planting off a heightfield, which does not care
		# whether the ground has been built into the physics world yet.
		await get_tree().physics_frame
	_build()


## How many blades actually got planted. Lower than requested wherever rays
## found nothing, or found ground too steep to grass.
func get_blade_count() -> int:
	return _planted


## Hands the frame back, keeping [member _work_usec] counting only real work.
func _yield_now() -> void:
	_work_usec += Time.get_ticks_usec() - _mark_usec
	await get_tree().process_frame
	_mark_usec = Time.get_ticks_usec()


func _build() -> void:
	_work_usec = 0
	_mark_usec = Time.get_ticks_usec()
	var area := square_size * square_size if square_size > 0.0 else PI * radius * radius
	var wanted := mini(int(density * area), max_blades)
	var placements: PackedVector3Array = await _find_placements(wanted)
	_planted = placements.size()
	if _planted == 0:
		push_warning("GrassField '%s': nothing to plant on." % name)
		built.emit()
		return
	# Worth seeing at a glance: this is the number that costs, and it is always
	# lower than density x area once the rim feathering, the slope rejections
	# and any exclusion rectangles have had their say.
	var placed_usec := _work_usec + (Time.get_ticks_usec() - _mark_usec)

	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	# Per-blade phase, stiffness and tint travel to the shader this way.
	multimesh.use_custom_data = true
	multimesh.mesh = _build_blade_mesh()
	multimesh.instance_count = _planted

	var rng := RandomNumberGenerator.new()
	rng.seed = seed ^ 0x5f3a
	for i in _planted:
		var scale_y := 1.0 + rng.randf_range(-height_variation, height_variation)
		var basis := Basis(Vector3.UP, rng.randf() * TAU)
		basis = basis.scaled(Vector3(1.0, scale_y, 1.0))
		multimesh.set_instance_transform(i, Transform3D(basis, placements[i]))
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
	var half_extent := square_size * 0.5 if square_size > 0.0 else radius
	_multimesh_instance.custom_aabb = AABB(
		Vector3(-half_extent - reach, -reach, -half_extent - reach),
		Vector3((half_extent + reach) * 2.0, reach * 3.0, (half_extent + reach) * 2.0))
	add_child(_multimesh_instance)

	var total_usec := _work_usec + (Time.get_ticks_usec() - _mark_usec)
	print("GrassField '%s': %d blades (asked for %d) — %.1f ms placing, %.1f ms total work" % [
		name, _planted, wanted, placed_usec / 1000.0, total_usec / 1000.0])
	built.emit()


## Scatters candidate spots across the patch and keeps the ones standing on
## ground flat enough to grow on. Returns dictionaries with a local-space
## position.
##
## Where the ground IS comes either from the heightfield (arithmetic, instant,
## and answerable for terrain that has not been built yet) or, without one, from
## a downward physics ray per blade. See [member heightfield].
func _find_placements(count: int) -> PackedVector3Array:
	var space := get_world_3d().direct_space_state if heightfield == null else null
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var min_up := cos(deg_to_rad(max_slope_degrees))
	# Packed, not an Array of dictionaries: at tens of thousands of blades per
	# chunk the per-entry allocation was costing more than finding the spots.
	var results := PackedVector3Array()
	var origin := global_position
	var square := square_size > 0.0
	# Hoisted out of the loop. to_local() rebuilds this inverse on every call,
	# and it was the single largest cost in placing a chunk of grass — far
	# larger than working out where the ground is.
	var to_local_xform := global_transform.affine_inverse()

	for _i in count:
		var x: float
		var z: float
		if square:
			var half := square_size * 0.5
			x = origin.x + rng.randf_range(-half, half)
			z = origin.z + rng.randf_range(-half, half)
		else:
			# sqrt keeps the scatter even; without it everything crowds the middle.
			var angle := rng.randf() * TAU
			var unit := sqrt(rng.randf())
			# Thin the planting out toward the rim so the patch has no hard edge.
			if edge_feather > 0.0:
				var keep := 1.0 - smoothstep(1.0 - edge_feather, 1.0, unit)
				if rng.randf() > keep:
					continue
			var r := unit * radius
			x = origin.x + cos(angle) * r
			z = origin.z + sin(angle) * r

		if _is_excluded(x, z):
			continue

		var spot: Variant = null
		if heightfield != null:
			# Height first, then the flatness test reusing it — see
			# Heightfield.slope_cosine_at for why that is worth doing.
			var h := heightfield.height_at(x, z)
			if heightfield.slope_cosine_at(x, z, h) >= min_up:
				spot = Vector3(x, h, z)
		else:
			var query := PhysicsRayQueryParameters3D.create(
				Vector3(x, origin.y + 60.0, z),
				Vector3(x, origin.y - 60.0, z),
				Layers.WORLD)
			var hit := space.intersect_ray(query)
			if not hit.is_empty() and hit["normal"].y >= min_up:
				spot = hit["position"]

		# Yielded AFTER sampling, not before, so a batch boundary cannot fall
		# between choosing a spot and deciding whether to keep it.
		if samples_per_batch > 0 and (_i + 1) % samples_per_batch == 0:
			await _yield_now()

		if spot == null:
			continue
		results.append(to_local_xform * (spot as Vector3))

	return results


## Whether a spot falls inside any of the no-grass rectangles — see
## [member exclusions].
func _is_excluded(x: float, z: float) -> bool:
	if exclusions.is_empty():
		return false
	var p := Vector2(x, z)
	for rect: Rect2 in exclusions:
		if rect.has_point(p):
			return true
	return false


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
