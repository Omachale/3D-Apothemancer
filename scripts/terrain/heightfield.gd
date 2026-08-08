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
@export var base_elevation := 0.0
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

@export_group("Features")
## Hills, plateaus and basins, each a Dictionary, summed onto the base surface.
## Kept as plain data (rather than as child nodes or hardcoded maths) so a
## future terrain-painting tool can write this list without touching any code.
##
## Recognised keys:
##   type    "hill" (default) or "plateau"
##   pos     Vector2 world XZ of the centre
##   radius  world units out to where the feature fades to nothing
##   height  peak height above the base surface; NEGATIVE digs a basin
##   noise   local irregularity amplitude, faded out toward the rim
##   flat_ratio  "plateau" only: fraction of the radius that stays flat on top
##               before the edge begins falling away. Higher means a wider
##               table and a NARROWER, therefore steeper, edge band.
@export var features: Array = []: set = _set_features

@export_group("Wiring")
## Seeds both noise layers. Changing it reshapes every irregularity in the
## world while leaving the deliberate shapes above exactly where they are.
@export var seed := 20240: set = _set_seed

var _rolling := FastNoiseLite.new()
var _detail := FastNoiseLite.new()
var _noise_dirty := true


## Ground height at a world XZ position. The one function the rest of the
## terrain stack is built on.
func height_at(x: float, z: float) -> float:
	if _noise_dirty:
		_rebuild_noise()
	var h := base_elevation
	if rolling_amplitude > 0.0:
		h += _rolling.get_noise_2d(x, z) * rolling_amplitude
	for feature in features:
		h += _feature_height(feature, x, z)
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
## than either reports.
func feature_max_slope_degrees(feature: Dictionary) -> float:
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


## One feature's contribution at a world XZ position, or 0 outside its radius.
func _feature_height(feature: Dictionary, x: float, z: float) -> float:
	var centre: Vector2 = feature.get("pos", Vector2.ZERO)
	var radius: float = maxf(feature.get("radius", 1.0), 0.001)
	var dx := x - centre.x
	var dz := z - centre.y
	# Normalised distance from the centre: 0 at the middle, 1 at the rim.
	var d := sqrt(dx * dx + dz * dz) / radius
	if d >= 1.0:
		return 0.0

	var falloff: float
	if feature.get("type", "hill") == "plateau":
		# Flat across the middle, falling away only over the outer band.
		var flat: float = clampf(feature.get("flat_ratio", 0.5), 0.0, 0.99)
		falloff = smoothstep(1.0, flat, d)
	else:
		# smoothstep is flat-tangent at both ends, which gives a rounded summit
		# and a rim that meets open ground without a visible crease.
		falloff = smoothstep(0.0, 1.0, 1.0 - d)

	var h: float = feature.get("height", 0.0) * falloff

	var detail: float = feature.get("noise", 0.0)
	if not is_zero_approx(detail):
		# Faded out toward the rim as well, so the join with open ground stays
		# clean instead of ending on a ring of visible bumps.
		h += _detail.get_noise_2d(x, z) * detail * smoothstep(0.0, 0.4, 1.0 - d)
	return h


func _rebuild_noise() -> void:
	_rolling.seed = seed
	_rolling.frequency = rolling_frequency
	_rolling.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_rolling.fractal_octaves = 3
	# Offset seed, so feature detail is not a scaled copy of the same pattern
	# the whole world already undulates by.
	_detail.seed = seed ^ 0x51ed
	_detail.frequency = rolling_frequency * 3.0
	_detail.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_detail.fractal_octaves = 3
	_noise_dirty = false


func _set_rolling_amplitude(value: float) -> void:
	rolling_amplitude = maxf(value, 0.0)
	emit_changed()


func _set_rolling_frequency(value: float) -> void:
	rolling_frequency = maxf(value, 0.0001)
	_noise_dirty = true
	emit_changed()


func _set_features(value: Array) -> void:
	features = value
	emit_changed()


func _set_seed(value: int) -> void:
	seed = value
	_noise_dirty = true
	emit_changed()
