@tool
class_name Heightfield
extends Resource

## The single source of truth for "how high is the ground at (x, z)?".
##
## Ground used to be built from hand-placed objects — a GroundPlate here, a
## TerrainMound there — each its own mesh with its own collider. That works
## while there are a dozen of them and stops working past a few hundred: there
## is no cheap way to simplify such a thing for the distance, no way to tile it
## for streaming, and no way to ask how high the ground is without firing a
## physics ray and waiting for an answer.
##
## This replaces all of that with a FUNCTION. Ground height is computed from a
## world position, as arithmetic, with no meshes and no physics involved.
## Everything else in the terrain stack reads from here:
##
##   terrain_chunk.gd  samples it on a grid to build a mesh and a collider
##   grass_field.gd    samples it to plant blades, instead of raycasting
##   distant tiles     sample it on a coarser grid, for a fraction of the cost
##
## Because it is arithmetic it costs almost nothing, is safe to call from any
## thread, and — the part that actually unlocks a large world — it can answer
## for ground that does not exist yet. A raycast can only report on terrain
## already built into the physics world; this can report on terrain a kilometre
## away that nothing has ever looked at.
##
## SHAPE COMES FROM LAYERS. A base elevation, optional gentle rolling noise
## across the whole world so open ground is not billiard-table flat, then a list
## of features (hills, plateaus) that each add their own contribution on top.
## Features SUM rather than replace, so two overlapping hills build into a ridge
## instead of one clipping through the other.
##
## EXCEPT PADS, WHICH BLEND. A "flatten" feature is the one thing here that does
## not add: it pulls the surface TOWARD a level over a footprint, easing back to
## whatever the land was doing across a falloff band. Summing cannot express
## that — the whole point is to erase variation, and to erase it you have to know
## what is already there. So the surface is built in two passes: every additive
## feature first, then every pad applied in list order over the result.
##
## Pads exist because buildings are rigid and land is not. A keep, a terrace and
## the staircase feeding it are all flat-bottomed rectangles that assume level
## ground; turn on rolling and they float at one corner and sink at the other.
## Levelling the ground under them is the cheaper half of that problem — the
## alternative is fitting the architecture to the land, which for hard-edged
## masonry means a foundation skirt around every base, and is a lot of geometry
## to solve a problem that a bulldozer solves.
##
## SLOPE IS THE CONSTRAINT THAT SHAPES EVERY NUMBER HERE, exactly as it is in
## terrain_mound.gd: the player is a CharacterBody3D with a 50 degree
## floor_max_angle, so anything steeper is a wall they slide off rather than
## ground they climb. A feature's `height` and `radius` are therefore not
## independent — use [method feature_max_slope_degrees] to check a set of
## numbers rather than guessing, and remember that summing two features sums
## their slopes too.
##
## WHAT THIS DELIBERATELY CANNOT DO: overhangs, arches, caves, anything with
## two floors above the same spot. There is exactly one height for any (x, z).
## That is the price of everything above, and it is the right trade for open
## landscape. Anything needing more — the stone keep, staircases, a cliff you
## can walk under — stays a hand-placed object standing on this surface, which
## is how buildings already work.
##
## Deterministic by construction: identical inputs always give an identical
## surface, with no state carried between calls. Nothing about the terrain ever
## needs saving, only the handful of numbers below that describe it.

@export_group("Base")
## Height of open ground with no feature over it and no rolling applied.
@export var base_elevation := 0.0: set = _set_base_elevation
## Amplitude of the gentle undulation applied across the entire world. Small
## values (well under a metre) are the point: this exists so that open ground
## reads as land rather than as a table top, not to make hills. Hills are
## features. Left at 0 the base surface is perfectly flat, matching the
## GroundPlate this replaces.
@export_range(0.0, 20.0, 0.05) var rolling_amplitude := 0.0: set = _set_rolling_amplitude
## How tightly the rolling undulation repeats. Lower is broader and gentler;
## this and [member rolling_amplitude] together decide its steepness, so raising
## one means watching the other — see the slope note at the top.
@export_range(0.0005, 0.2, 0.0005) var rolling_frequency := 0.008: set = _set_rolling_frequency

@export_group("Mountains")
## Large-scale procedural hills and valleys, summed on top of rolling. The
## wavelength is set by [member mountains_frequency]; with the default (0.002)
## peaks are ~500m apart, suitable for terrain features you'd walk between for
## a few minutes. Left at 0 amplitude, mountains are disabled and the world is
## just rolling undulation.
@export_range(0.0, 40.0, 0.5) var mountains_amplitude := 0.0: set = _set_mountains_amplitude
@export_range(0.0002, 0.04, 0.0002) var mountains_frequency := 0.002: set = _set_mountains_frequency
## Center of the protected zone where mountains fade out (the starting area).
## Peaks within this radius are suppressed so the player spawns on level ground.
@export var mountains_protected_center := Vector2(10.0, 22.0): set = _set_mountains_protected_center
@export_range(0.0, 200.0, 5.0) var mountains_protected_radius := 80.0: set = _set_mountains_protected_radius

@export_group("Features")
## Hills, plateaus, basins and levelling pads, each a Dictionary, applied onto
## the base surface. Kept as plain data (rather than as child nodes or hardcoded
## maths) so a future terrain-painting tool can write this list without touching
## any code.
##
## Recognised keys:
##   type    "hill" (default), "plateau" or "flatten"
##   pos     Vector2 world XZ of the centre
##   radius  world units out to where the feature fades to nothing
##   height  peak height above the base surface; NEGATIVE digs a basin
##   noise   local irregularity amplitude, faded out toward the rim
##   flat_ratio  "plateau" only: fraction of the radius that stays flat on top
##               before the edge begins falling away. Higher means a wider
##               table and a NARROWER, therefore steeper, edge band.
##
## "flatten" is the odd one out — it blends rather than sums, and takes its own
## keys (see the two-pass note at the top of this file):
##   size    Vector2 full XZ extent of the perfectly level core. RECTANGULAR
##           because everything that needs one is: a keep, a terrace, a
##           staircase landing. `radius` is accepted as a square shorthand.
##   falloff how far outside the core the surface takes to ease back to the land
##           it would otherwise have had. Corners are rounded, so a pad reads as
##           a graded shoulder rather than a cut block.
##   level   optional absolute height for the core. Left out — which is usually
##           right — the pad settles onto whatever height the rest of the
##           surface has at `pos`, so it follows the land instead of pinning the
##           world to an arbitrary number.
@export var features: Array = []: set = _set_features

@export_group("Wiring")
## Seeds both noise layers. Changing it reshapes every irregularity in the
## world while leaving the deliberate shapes above exactly where they are.
@export var seed := 20240: set = _set_seed

var _rolling := FastNoiseLite.new()
var _mountains := FastNoiseLite.new()
var _detail := FastNoiseLite.new()
## [member features] split into the two passes, and pads with their `level`
## already resolved. Rebuilt by [method _rebuild] whenever anything the surface
## depends on changes, so the per-sample path does no dictionary lookups it can
## avoid and no pad has to work out its own height a hundred thousand times.
var _shapes: Array = []
var _pads: Array = []
var _dirty := true


## Ground height at a world XZ position. The one function the rest of the
## terrain stack is built on.
func height_at(x: float, z: float) -> float:
	if _dirty:
		_rebuild()
	var h := _shaped_height_at(x, z)
	for pad in _pads:
		var weight := _pad_weight(pad, x, z)
		if weight > 0.0:
			h = lerpf(h, pad["level"] as float, weight)
	return h


## The surface BEFORE any pad levels it: base, rolling and every additive
## feature. Separate from [method height_at] because a pad that takes its level
## from the land has to ask what the land was doing, and asking [method
## height_at] would be circular.
##
## Assumes [method _rebuild] has already run — it is only reached from
## [method height_at], which guarantees that, and from [method _rebuild] itself,
## which is midway through doing it.
func _shaped_height_at(x: float, z: float) -> float:
	var h := base_elevation
	if rolling_amplitude > 0.0:
		h += _rolling.get_noise_2d(x, z) * rolling_amplitude
	if mountains_amplitude > 0.0:
		var dx := x - mountains_protected_center.x
		var dz := z - mountains_protected_center.y
		var dist := sqrt(dx * dx + dz * dz)
		# Fade out mountains toward zero at the protected center, full strength
		# beyond the protected radius. Smooth falloff over 100 units past the edge.
		var falloff := smoothstep(-50.0, 100.0, dist - mountains_protected_radius)
		h += _mountains.get_noise_2d(x, z) * mountains_amplitude * falloff
	for shape in _shapes:
		h += _feature_height(shape, x, z)
	return h


## Convenience wrapper taking a world position and returning it with Y set to
## the ground. Handy for placing things without caring about the components.
func drop_to_ground(pos: Vector3) -> Vector3:
	return Vector3(pos.x, height_at(pos.x, pos.z), pos.z)


## Which way the surface faces at a world XZ position, as a unit vector.
##
## Derived by measuring the height a short way either side and comparing —
## the surface has no vertices to read a normal from, so it is worked out from
## the shape of the function itself. [param epsilon] is that sampling distance;
## it should be a fraction of the smallest feature worth noticing, and larger
## values quietly smooth the answer.
func normal_at(x: float, z: float, epsilon := 0.25) -> Vector3:
	var e := maxf(epsilon, 0.0001)
	var slope_x := height_at(x + e, z) - height_at(x - e, z)
	var slope_z := height_at(x, z + e) - height_at(x, z - e)
	return Vector3(-slope_x, 2.0 * e, -slope_z).normalized()


## Cosine of the ground's slope at a point: 1 on the level, falling toward 0 as
## it steepens. Exactly the quantity a "is this flat enough to plant on?" test
## wants, compared against cos(the limit).
##
## Exists separately from [method normal_at] purely for cost. Grass asks this
## once per candidate blade — tens of thousands of times per chunk — so the two
## differences matter: it takes the height at (x, z) rather than looking it up
## again, because every caller already has it, and it measures FORWARD only
## rather than to either side. Three height lookups per blade instead of five,
## and no vector to normalise.
##
## Marginally less accurate than normal_at's centred measurement, which does not
## matter for a threshold test. Use [method normal_at] where the direction
## itself is wanted, such as for lighting.
func slope_cosine_at(x: float, z: float, height_here: float, epsilon := 0.25) -> float:
	var e := maxf(epsilon, 0.0001)
	var dx := height_at(x + e, z) - height_here
	var dz := height_at(x, z + e) - height_here
	return e / sqrt(dx * dx + dz * dz + e * e)


## How steep the ground is at a world XZ position, in degrees from flat. What
## to check a spot against the player's 50 degree floor_max_angle.
func slope_degrees_at(x: float, z: float, epsilon := 0.25) -> float:
	return rad_to_deg(acos(clampf(normal_at(x, z, epsilon).y, -1.0, 1.0)))


## The steepest slope a single feature dictionary can produce, in degrees,
## counting both its falloff and the worst case its own noise can add.
##
## Same purpose and same derivation as terrain_mound.gd's method of the same
## name: the falloff is a smoothstep, whose steepest point is 1.5 x height over
## the distance it falls across. Compare the result against the player's
## floor_max_angle (50) before trusting new numbers.
##
## NOTE this judges one feature alone. Two features overlapping sum their
## heights, and therefore their slopes — a spot covered by both can be steeper
## than either reports. Pads are the exception: theirs is measured against the
## finished surface, so it already accounts for everything under them.
func feature_max_slope_degrees(feature: Dictionary) -> float:
	if feature.get("type", "hill") == "flatten":
		return _pad_max_slope_degrees(feature)
	var radius: float = maxf(feature.get("radius", 1.0), 0.001)
	var height: float = absf(feature.get("height", 0.0))
	var fall_distance := radius
	if feature.get("type", "hill") == "plateau":
		# A plateau drops its whole height across the outer band only, so the
		# flatter the top, the steeper the edge.
		var flat: float = clampf(feature.get("flat_ratio", 0.5), 0.0, 0.99)
		fall_distance = radius * (1.0 - flat)
	var falloff := 1.5 * height / maxf(fall_distance, 0.001)
	var detail: float = absf(feature.get("noise", 0.0)) * TAU * rolling_frequency
	return rad_to_deg(atan(falloff + detail))


## Every feature whose numbers exceed [param limit] degrees, as readable
## strings. Empty means the whole layout is climbable. Cheap enough to call
## from a test or a startup assertion rather than eyeballing a map.
func find_unclimbable_features(limit := 50.0) -> Array:
	var offenders: Array = []
	for feature in features:
		var steepest := feature_max_slope_degrees(feature)
		if steepest > limit:
			offenders.append("%s at %s: up to %.1f degrees" % [
				feature.get("type", "hill"), feature.get("pos", Vector2.ZERO), steepest])
	return offenders


## The steepest ground a levelling pad produces, in degrees, MEASURED rather
## than predicted.
##
## Every other feature can be bounded from its own numbers because it knows its
## own height. A pad does not have one: how steep its shoulder gets depends
## entirely on how far the land it is levelling had strayed from the level it
## settles on, and that is the rolling noise, every hill nearby, and any other
## pad overlapping it. There is nothing to derive it from, so this walks the
## finished surface instead — outward from the centre in every direction, from
## the core out past the far edge of the band.
##
## SCOPED TO GROUND THE PAD IS ACTUALLY RESPONSIBLE FOR — every sample where it
## has any influence at all, and none where it has none. The obvious
## implementation, sweeping a disc big enough to contain the pad, quietly
## reports whatever else is nearby: the keep's pad sits within reach of the
## SouthHill, and a disc drawn around it swept up 34 degrees of hillside the pad
## has nothing to do with. That is not a conservative over-estimate to be shrugged
## at, it is a check that fails for a reason its own message does not name.
##
## Only relevant when the answer matters, which is at build time: a pad steeper
## than the player's floor_max_angle is a terrace they cannot walk up to. See
## [method find_unclimbable_features], which is what actually calls this.
func _pad_max_slope_degrees(feature: Dictionary) -> float:
	# The resolved shape _pad_weight expects. Its `level` is not needed: this
	# asks the finished surface how steep it is, not what the pad aimed for.
	var probe := {
		"pos": feature.get("pos", Vector2.ZERO) as Vector2,
		"half": _pad_half_extent(feature),
		"falloff": maxf(feature.get("falloff", 8.0), 0.001),
	}
	var centre: Vector2 = probe["pos"]
	var extent: Vector2 = (probe["half"] as Vector2) + Vector2.ONE * (probe["falloff"] as float)
	const STEPS := 64
	var worst := 0.0
	for i in STEPS + 1:
		for j in STEPS + 1:
			var p := centre - extent + Vector2(
				2.0 * extent.x * float(i) / float(STEPS),
				2.0 * extent.y * float(j) / float(STEPS))
			if _pad_weight(probe, p.x, p.y) <= 0.0:
				continue
			worst = maxf(worst, slope_degrees_at(p.x, p.y))
	return worst


## One RESOLVED shape's contribution at a world XZ position, or 0 outside its
## radius. Takes a _shapes entry (see [method _resolve_shape]), not a raw
## [member features] dictionary — every field here is already the right type
## with its default applied, and `is_plateau`/`has_noise` are precomputed
## bools rather than a string compare or an is_zero_approx redone per sample.
## This is the single hottest function in the class (every terrain vertex,
## every grass blade, every slope probe reaches it), so the split from raw
## dictionary lookups to a resolved struct is worth the indirection of having
## two representations of one feature.
func _feature_height(shape: Dictionary, x: float, z: float) -> float:
	var dx := x - (shape["pos"] as Vector2).x
	var dz := z - (shape["pos"] as Vector2).y
	# Normalised distance from the centre: 0 at the middle, 1 at the rim.
	var d := sqrt(dx * dx + dz * dz) * (shape["inv_radius"] as float)
	if d >= 1.0:
		return 0.0

	var falloff: float
	if shape["is_plateau"]:
		# Flat across the middle, falling away only over the outer band.
		falloff = smoothstep(1.0, shape["flat_ratio"] as float, d)
	else:
		# smoothstep is flat-tangent at both ends, which gives a rounded summit
		# and a rim that meets open ground without a visible crease.
		falloff = smoothstep(0.0, 1.0, 1.0 - d)

	var h: float = (shape["height"] as float) * falloff

	if shape["has_noise"]:
		# Faded out toward the rim as well, so the join with open ground stays
		# clean instead of ending on a ring of visible bumps.
		h += _detail.get_noise_2d(x, z) * (shape["noise"] as float) * smoothstep(0.0, 0.4, 1.0 - d)
	return h


## How strongly a pad levels the ground at a world XZ position: 1 across its
## core, easing to 0 at the far edge of its falloff band.
##
## The distance used is the distance OUTSIDE the core rectangle, which is zero
## anywhere within it — so a pad is genuinely level everywhere under the thing
## standing on it, not merely level at its middle. Taking that as the length of
## the per-axis overhangs (rather than the larger of them) rounds the corners,
## which matters: square corners would put a crease running diagonally out of
## each one, and creases are exactly what a pad exists to remove.
func _pad_weight(pad: Dictionary, x: float, z: float) -> float:
	var centre: Vector2 = pad["pos"]
	var half: Vector2 = pad["half"]
	var over_x := absf(x - centre.x) - half.x
	var over_z := absf(z - centre.y) - half.y
	if over_x <= 0.0 and over_z <= 0.0:
		return 1.0
	var outside := Vector2(maxf(over_x, 0.0), maxf(over_z, 0.0)).length()
	var falloff: float = pad["falloff"]
	if outside >= falloff:
		return 0.0
	return smoothstep(1.0, 0.0, outside / falloff)


## Rebuilds everything cached from the exported numbers: the two noise layers,
## the split of [member features] into additive shapes and levelling pads, and
## each pad's resolved level.
##
## Pad levels are resolved HERE, once, rather than per sample. A pad without an
## explicit `level` takes the height the rest of the surface has at its centre,
## and that is several noise lookups plus every feature — affordable once,
## ruinous at the hundred thousand samples a single terrain tile asks for.
func _rebuild() -> void:
	_rolling.seed = seed
	_rolling.frequency = rolling_frequency
	_rolling.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_rolling.fractal_octaves = 3
	# Mountains are a separate layer with lower frequency (broader features) and
	# its own seed offset so they don't follow the rolling pattern.
	_mountains.seed = seed ^ 0xbeef
	_mountains.frequency = mountains_frequency
	_mountains.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_mountains.fractal_octaves = 3
	# Offset seed, so feature detail is not a scaled copy of the same pattern
	# the whole world already undulates by.
	_detail.seed = seed ^ 0x51ed
	_detail.frequency = rolling_frequency * 3.0
	_detail.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_detail.fractal_octaves = 3

	_shapes = []
	_pads = []
	var raw_pads: Array = []
	for feature in features:
		if feature.get("type", "hill") == "flatten":
			raw_pads.append(feature)
		else:
			_shapes.append(_resolve_shape(feature))
	# Lowered before the levels are worked out, not after: resolving them calls
	# _shaped_height_at, and leaving the flag raised would have that re-enter
	# this function. Safe to do early because _shapes is already complete and
	# _pads is empty, so the surface is simply the unlevelled one — which is
	# exactly what a pad's default level is asking for.
	_dirty = false

	var resolved: Array = []
	for pad in raw_pads:
		var centre: Vector2 = pad.get("pos", Vector2.ZERO)
		var level: float = pad.get("level", _shaped_height_at(centre.x, centre.y))
		resolved.append({
			"pos": centre,
			"half": _pad_half_extent(pad),
			"falloff": maxf(pad.get("falloff", 8.0), 0.001),
			"level": level,
		})
	_pads = resolved


## Turns one raw [member features] dictionary (type "hill" or "plateau") into
## the resolved form [method _feature_height] actually samples: every default
## applied once, `type` reduced to a bool, and radius pre-inverted so the hot
## path divides never. See [method _feature_height]'s note on why this split
## exists.
func _resolve_shape(feature: Dictionary) -> Dictionary:
	var radius: float = maxf(feature.get("radius", 1.0), 0.001)
	var noise: float = feature.get("noise", 0.0)
	return {
		"pos": feature.get("pos", Vector2.ZERO) as Vector2,
		"inv_radius": 1.0 / radius,
		"is_plateau": feature.get("type", "hill") == "plateau",
		"flat_ratio": clampf(feature.get("flat_ratio", 0.5), 0.0, 0.99),
		"height": feature.get("height", 0.0) as float,
		"noise": noise,
		"has_noise": not is_zero_approx(noise),
	}


## Half the pad's level core, per axis. `size` is the full extent, so a 16x12
## keep asks for `size: Vector2(16, 12)` and gets exactly its own footprint
## levelled. `radius` is accepted as shorthand for a square one.
func _pad_half_extent(pad: Dictionary) -> Vector2:
	if pad.has("size"):
		return (pad["size"] as Vector2).abs() * 0.5
	var r: float = absf(pad.get("radius", 1.0))
	return Vector2(r, r)


func _set_base_elevation(value: float) -> void:
	base_elevation = value
	# Every pad that takes its level from the land is now holding a stale one.
	_dirty = true
	emit_changed()


func _set_rolling_amplitude(value: float) -> void:
	rolling_amplitude = maxf(value, 0.0)
	_dirty = true
	emit_changed()


func _set_rolling_frequency(value: float) -> void:
	rolling_frequency = maxf(value, 0.0001)
	_dirty = true
	emit_changed()


func _set_mountains_amplitude(value: float) -> void:
	mountains_amplitude = maxf(value, 0.0)
	_dirty = true
	emit_changed()


func _set_mountains_frequency(value: float) -> void:
	mountains_frequency = maxf(value, 0.0001)
	_dirty = true
	emit_changed()


func _set_mountains_protected_center(value: Vector2) -> void:
	mountains_protected_center = value
	_dirty = true
	emit_changed()


func _set_mountains_protected_radius(value: float) -> void:
	mountains_protected_radius = maxf(value, 0.0)
	_dirty = true
	emit_changed()


func _set_features(value: Array) -> void:
	features = value
	_dirty = true
	emit_changed()


func _set_seed(value: int) -> void:
	seed = value
	_dirty = true
	emit_changed()
