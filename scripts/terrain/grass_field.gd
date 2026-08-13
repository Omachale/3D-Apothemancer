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
## Beyond [member max_slope_degrees], ground does not go straight to bare —
## it steps down to one of three reduced densities (80%, 60%, 40%) over this
## many further degrees, THEN goes bare. Slopes this project actually has
## (a hillside, a pad's shoulder, the mountain's flank) are not the sheer
## drops a hard cutoff was written for; a band of thinning grass reads as
## ground that is merely steep, where a hard edge read as a mistake. 0
## restores the old hard cutoff exactly.
@export_range(0.0, 60.0, 1.0) var reduced_density_band_degrees := 15.0
## World size of one density-tier patch within the reduced band — see
## [member reduced_density_band_degrees]. Coarser than the height/slope grid
## on purpose: the tier is chosen per PATCH so a hillside reads as a few
## distinct, plausible thinning bands, not a speckle that changes at every
## grid point.
@export_range(1.0, 40.0, 1.0) var density_region_size := 12.0
## Seed for the density-tier hash — see [member density_region_size].
## Deliberately separate from [member seed] (which grass_manager.gd varies
## per chunk so neighbouring patches don't repeat the same scatter): a
## density-tier region can straddle two chunks, and if the hash used the
## per-chunk seed the two halves would disagree on the tier, showing a hard
## density edge exactly on the chunk boundary. This one is the SAME across
## every chunk in a field, so the tier a region gets does not depend on which
## chunk happens to be sampling it.
@export var density_seed := 20240
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
## Spacing of the coarse height/slope grid [method _find_placements] samples
## the heightfield on, when one is set. Every candidate blade then reads that
## grid (a few array lookups and a lerp) instead of calling into the
## heightfield itself — see the note there for why that distinction is the
## whole point. 1 unit matches ring 0's own vertex spacing (terrain_manager.gd),
## which is already the finest the ground mesh itself resolves to, so this
## costs no visible accuracy.
@export var height_sample_spacing := 1.0
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
##
## Sized for the grid-sampling path (see [method _sample_grid]): a batch this
## size costs under 1 ms of real work now that a candidate is a few array
## lookups instead of a heightfield call, so the frame count a large field
## needs to fill — the thing that actually decides wall-clock load time, since
## each batch still waits a full frame regardless of how little of it the
## batch used — is set by this number, not by per-blade cost. Raising it
## trades a faster fill for a bigger (but still sub-frame) lump of work
## whenever a batch boundary lands. 0 disables batching (finishes in one
## frame, same as before this existed).
@export_range(0, 8000, 50) var samples_per_batch := 3000

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
	# VERTICAL RANGE COMES FROM THE PLACEMENTS, NOT A FIXED BAND AROUND 0. This
	# node sits at (x, 0, z) — see grass_manager.gd's _spawn — but a blade's
	# local Y is the actual ground height at its spot (Heightfield.height_at,
	# offset by nothing, since this node's own Y is always 0). On flat ground
	# that is a couple of units and `reach` alone would cover it, which is
	# almost certainly why this went unnoticed for as long as it did — but on
	# rolling terrain, a hill, or the mountain, a single chunk can span tens of
	# metres of real elevation. custom_aabb REPLACES Godot's automatic bounds
	# entirely (it does not look at the real instance transforms once set), so
	# a box sized for flat ground silently mis-culls every chunk whose ground
	# is not near world Y=0 — which, once anything has relief, is most of
	# them. The failure reads as exactly this: the chunk is fully built and
	# correct, but whether it draws flips with camera angle, because the wrong
	# box crosses the frustum edge at a different spot than the true geometry
	# does — a threshold tied to where the camera (and so the player) is
	# standing, not to loading.
	var min_y := INF
	var max_y := -INF
	for p in placements:
		min_y = minf(min_y, p.y)
		max_y = maxf(max_y, p.y)
	_multimesh_instance.custom_aabb = AABB(
		Vector3(-half_extent - reach, min_y - reach, -half_extent - reach),
		Vector3((half_extent + reach) * 2.0, (max_y - min_y) + reach * 3.0, (half_extent + reach) * 2.0))
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
##
## WITH a heightfield, ground is read from a coarse grid built once up front
## (see [method _sample_grid]), not from a fresh [method Heightfield.height_at]
## per blade. A single lookup already costs several microseconds — three
## octaves of noise plus a walk over every feature in the zone — and at tens
## of thousands of candidates per chunk that is seconds of CPU per chunk, not
## microseconds. The grid is exactly the same information at a resolution no
## coarser than the ground mesh itself already uses (see
## [member height_sample_spacing]), so nothing about the result looks
## different; only how many times the heightfield gets asked does.
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
	var half := square_size * 0.5 if square else radius
	# Hoisted out of the loop. to_local() rebuilds this inverse on every call,
	# and it was the single largest cost in placing a chunk of grass — far
	# larger than working out where the ground is.
	var to_local_xform := global_transform.affine_inverse()

	var grid: Dictionary = {}
	if heightfield != null:
		grid = _sample_grid(origin, half)

	for _i in count:
		var x: float
		var z: float
		if square:
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
			spot = _sample_from_grid(grid, origin, half, x, z, rng)
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


## Builds the coarse height/slope grid [method _find_placements] samples
## candidates from, covering the square (2*half) centred on [param origin].
## Runs [member Heightfield.height_at]/[method Heightfield.slope_cosine_at]
## once per grid point rather than once per blade — for a 20-unit chunk at the
## default 1-unit spacing that is 441 calls instead of tens of thousands.
##
## Returns a Dictionary rather than a class purely to keep this file free of
## an extra type: `res` (grid points per axis), `step` (world units between
## them), `h` (heights, row-major), `up` (slope cosines, same layout) and
## `density` (keep-probability per point, 1.0 on walkable ground, tiered down
## through the reduced band, 0.0 past it — see [method _density_factor]).
func _sample_grid(origin: Vector3, half: float) -> Dictionary:
	var spacing := maxf(height_sample_spacing, 0.05)
	var res := maxi(2, int(ceil(2.0 * half / spacing)) + 1)
	var step := (2.0 * half) / float(res - 1)
	var h := PackedFloat32Array()
	var up := PackedFloat32Array()
	var density := PackedFloat32Array()
	h.resize(res * res)
	up.resize(res * res)
	density.resize(res * res)
	for gz in res:
		var wz := origin.z - half + float(gz) * step
		for gx in res:
			var wx := origin.x - half + float(gx) * step
			var height := heightfield.height_at(wx, wz)
			var idx := gz * res + gx
			var u := heightfield.slope_cosine_at(wx, wz, height)
			h[idx] = height
			up[idx] = u
			density[idx] = _density_factor(wx, wz, u)
	return {"res": res, "step": step, "h": h, "up": up, "density": density}


## Keep-probability at one world point, given its slope cosine [param up]
## (from [method Heightfield.slope_cosine_at]): 1.0 within
## [member max_slope_degrees], one of {0.8, 0.6, 0.4} across
## [member reduced_density_band_degrees] beyond it, then 0.0.
##
## The tier is chosen by hashing a [member density_region_size] world-space
## cell, not the point itself, so a whole patch of hillside commits to one
## tier instead of flickering between three at grid resolution — a real slope
## reads as having a few plausible thinning bands, not static.
func _density_factor(x: float, z: float, up: float) -> float:
	var min_up := cos(deg_to_rad(max_slope_degrees))
	if up >= min_up:
		return 1.0
	if reduced_density_band_degrees <= 0.0:
		return 0.0
	var hard_min_up := cos(deg_to_rad(max_slope_degrees + reduced_density_band_degrees))
	if up < hard_min_up:
		return 0.0
	var rx := int(floor(x / density_region_size))
	var rz := int(floor(z / density_region_size))
	var h := (rx * 92821) ^ (rz * 68917) ^ density_seed
	match absi(h) % 3:
		0: return 0.8
		1: return 0.6
		_: return 0.4


## One candidate's ground spot, read from the grid [method _sample_grid]
## built: height bilinearly interpolated for a smooth surface, density taken
## from the nearest grid point (see [method _density_factor]) since it only
## ever feeds a keep/reject roll — no visible loss at grid points a metre
## apart, and one lookup instead of four plus a lerp. Returns null where the
## roll rejects the spot, whether from a hard cutoff (density 0) or from
## losing the reduced-density roll.
func _sample_from_grid(
	grid: Dictionary, origin: Vector3, half: float, x: float, z: float, rng: RandomNumberGenerator
) -> Variant:
	var res: int = grid["res"]
	var step: float = grid["step"]
	var fx: float = clampf((x - (origin.x - half)) / step, 0.0, float(res - 1))
	var fz: float = clampf((z - (origin.z - half)) / step, 0.0, float(res - 1))
	var gx0 := mini(int(fx), res - 2)
	var gz0 := mini(int(fz), res - 2)
	var tx := fx - gx0
	var tz := fz - gz0

	var density: PackedFloat32Array = grid["density"]
	# Nearest grid point, not bilinear — a fractional density is realised by
	# rolling against it, not by blending two neighbours' tiers together.
	var nx := gx0 + (1 if tx >= 0.5 else 0)
	var nz := gz0 + (1 if tz >= 0.5 else 0)
	var keep_chance: float = density[nz * res + nx]
	if keep_chance <= 0.0:
		return null
	if keep_chance < 1.0 and rng.randf() >= keep_chance:
		return null

	var h: PackedFloat32Array = grid["h"]
	var h00: float = h[gz0 * res + gx0]
	var h10: float = h[gz0 * res + gx0 + 1]
	var h01: float = h[(gz0 + 1) * res + gx0]
	var h11: float = h[(gz0 + 1) * res + gx0 + 1]
	var height := lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), tz)
	return Vector3(x, height, z)


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
