extends Node

## Checks that THIS ZONE's layout actually sits on the land it declares.
##
## verify_heightfield.gd proves the heightfield maths works — that a levelling
## pad levels, that a hill is the right height. This proves zone.gd used it:
## that rolling is really on, that every flat-bottomed structure has a pad under
## its whole footprint, that the staircase and the terrace it feeds stand on the
## same level, and that nothing ended up too steep to walk on.
##
## Reads zone.gd's own layout rather than a copy of it, so it cannot drift out
## of step with the world. Add a building without a pad and this fails.
##
## Run as a SCENE rather than with --script, because zone.gd reaches the Wind and
## Game autoloads and autoloads are not set up for --script:
##   Godot --headless res://scenes/dev/VerifyZoneLayout.tscn
## Exits non-zero if any check fails.

## The player's floor_max_angle (see player_controller.gd). Ground steeper than
## this is a wall they slide off, not ground they walk on.
const FLOOR_MAX_ANGLE := 50.0
## How far a structure's footprint may vary in height before it counts as
## unlevel. Generous enough to survive float arithmetic, far tighter than
## anything visible — a millimetre of tilt under a keep is not a floating corner.
const LEVEL_TOLERANCE := 0.001

## Every rigid, flat-bottomed thing in the zone, as centre and full XZ extent.
## Stated here rather than read from get_plates()/get_buildings() ON PURPOSE:
## the claim being tested is that the pads cover the real footprints, and a pad
## checked against its own numbers would only ever confirm itself. These are
## transcribed from the layout, so a structure that moves without its pad moving
## shows up as a failure here rather than as a floating corner in-game.
const FOOTPRINTS := {
	"StoneKeep": [Vector2(-26, -14), Vector2(16, 12)],
	"Terrace": [Vector2(-25, 20), Vector2(20, 20)],
	# Starts at z=32 and climbs 2 units of run toward -Z, 6 wide.
	"TerraceStairs": [Vector2(-25, 31), Vector2(6, 2)],
}


func _ready() -> void:
	var fails := 0
	var zone := Zone.new()
	var field: Heightfield = zone.get_heightfield()

	fails += _check_rolling_is_on(field)
	fails += _check_structures_are_level(field)
	fails += _check_stairs_meet_terrace(field)
	fails += _check_nothing_unclimbable(field)
	fails += _check_spawn(zone, field)
	fails += _check_skirt_covers_seams(zone, field)

	zone.free()
	print("")
	if fails == 0:
		print("ALL ZONE LAYOUT CHECKS PASSED")
	else:
		print("%d CHECK(S) FAILED" % fails)
	get_tree().quit(1 if fails > 0 else 0)


## Rolling being on is the point of the whole exercise, and it is one line in
## zone.gd away from being silently off again. Measured on the surface rather
## than read off the property, so a pad accidentally covering the sample line
## would be caught too.
func _check_rolling_is_on(field: Heightfield) -> int:
	var fails := 0
	if is_zero_approx(field.rolling_amplitude):
		print("FAIL rolling_amplitude is 0 — the land is still a table top")
		fails += 1

	var lo := INF
	var hi := -INF
	var steepest := 0.0
	for i in 400:
		# A line across open ground, well clear of every feature — the hill,
		# keep and terrace to the west, and EastMountain (centre 130,22,
		# radius 100) to the east. Run at z=-150, far enough south that even
		# EastMountain's radius does not reach it.
		var x := -150.0 + float(i) * 0.75
		var z := -150.0
		var h := field.height_at(x, z)
		lo = minf(lo, h)
		hi = maxf(hi, h)
		steepest = maxf(steepest, field.slope_degrees_at(x, z))
	if hi - lo < 0.5:
		print("FAIL open ground varies only %.3f m — rolling is not visible" % (hi - lo))
		fails += 1
	if steepest > FLOOR_MAX_ANGLE:
		print("FAIL open ground reaches %.1f deg, past the player's %.0f deg limit" % [
			steepest, FLOOR_MAX_ANGLE])
		fails += 1
	print("open ground: %.2f .. %.2f m over 400 samples, steepest %.1f deg (limit %.0f)" % [
		lo, hi, steepest, FLOOR_MAX_ANGLE])
	return fails


## The actual claim of this task: a rigid structure needs level ground under its
## WHOLE footprint, not just under its centre. Sampled on a grid across each
## one, because a pad a unit too small is level everywhere except exactly where
## it matters — under the walls.
func _check_structures_are_level(field: Heightfield) -> int:
	var fails := 0
	for label in FOOTPRINTS:
		var centre: Vector2 = FOOTPRINTS[label][0]
		var half: Vector2 = (FOOTPRINTS[label][1] as Vector2) * 0.5
		var level := field.height_at(centre.x, centre.y)
		var spread := 0.0
		for i in 13:
			for j in 13:
				var px := centre.x - half.x + half.x * 2.0 * float(i) / 12.0
				var pz := centre.y - half.y + half.y * 2.0 * float(j) / 12.0
				spread = maxf(spread, absf(field.height_at(px, pz) - level))
		if spread > LEVEL_TOLERANCE:
			print("FAIL ground under %s varies by %.4f m — missing pad, or one too small" % [
				label, spread])
			fails += 1
		print("%-14s stands at %.3f m, footprint level to %.5f m" % [label, level, spread])
	return fails


## A staircase rises by a fixed amount, so it only meets the plate above if the
## ground at BOTH ends is the same height. That is why they share one pad, and
## it is the thing most easily broken by nudging either of them later — the
## failure is a step through the terrace or a lip in front of it, which is
## exactly the sort of thing that gets lived with rather than noticed.
func _check_stairs_meet_terrace(field: Heightfield) -> int:
	var stair_ground := field.height_at(-25.0, 32.0)
	var terrace_ground := field.height_at(-25.0, 20.0)
	if absf(stair_ground - terrace_ground) > LEVEL_TOLERANCE:
		print("FAIL stairs start at %.3f but the terrace stands on %.3f — the 1.5 m rise misses by %.3f" % [
			stair_ground, terrace_ground, absf(stair_ground - terrace_ground)])
		return 1
	print("stairs and terrace share ground at %.3f m; a 5 x 0.3 rise meets a 1.5 m plate"
		% stair_ground)
	return 0


## A pad that is level but walled in by its own shoulder is worse than no pad —
## the terrace becomes unreachable. Pad steepness is measured against the
## finished surface (see heightfield.gd), so this covers the hill and the
## rolling underneath them as well as the pads themselves.
func _check_nothing_unclimbable(field: Heightfield) -> int:
	var fails := 0
	var offenders := field.find_unclimbable_features(FLOOR_MAX_ANGLE)
	if not offenders.is_empty():
		print("FAIL layout has features the player cannot climb: %s" % offenders)
		fails += 1
	for feature in field.features:
		var kind: String = feature.get("type", "hill")
		print("%-8s at %-16s reaches %.1f deg" % [
			kind, feature.get("pos", Vector2.ZERO),
			field.feature_max_slope_degrees(feature)])
	return fails


## Spawn's Y is clearance above the land (see zone.gd's header), so this both
## confirms the drop happened and that the player is not put down on a slope
## they immediately slide off.
func _check_spawn(zone: Zone, field: Heightfield) -> int:
	var fails := 0
	var spawn := zone.get_spawn_transform().origin
	var ground := field.height_at(spawn.x, spawn.z)
	var slope := field.slope_degrees_at(spawn.x, spawn.z)
	if absf(spawn.y - (ground + zone.spawn_position.y)) > LEVEL_TOLERANCE:
		print("FAIL spawn Y %.3f is not %.3f above the ground at %.3f" % [
			spawn.y, zone.spawn_position.y, ground])
		fails += 1
	if slope > FLOOR_MAX_ANGLE:
		print("FAIL spawn slope %.1f deg" % slope)
		fails += 1
	print("spawn at (%.1f, %.2f, %.1f): %.2f m above ground, slope %.1f deg" % [
		spawn.x, spawn.y, spawn.z, spawn.y - ground, slope])
	return fails


## Raising the rolling amplitude widens the cracks between detail levels, and
## `skirt_depth` is what hides them — so it has to be rechecked whenever the land
## gets more dramatic. This is the half of that verify_terrain_chunk.gd cannot
## do: it builds real meshes but on a synthetic heightfield of its own, which
## says nothing about how deep the skirt needs to be for THIS zone's land.
##
## Measured from the heightfield directly rather than by building tiles, because
## the gap has an exact definition that needs no geometry. A coarse tile draws a
## straight line between two vertices `spacing` apart; the fine tile beside it
## has a vertex on that line's midpoint, at the surface's true height there. The
## crack between them is the difference — the heightfield's deviation from linear
## over one coarse step. Sampling that over the whole zone at every ring's
## spacing is both faster and stricter than meshing two tiles and comparing an
## edge, which only ever tests the one line the two tiles happen to share.
func _check_skirt_covers_seams(zone: Zone, field: Heightfield) -> int:
	var config := zone.get_terrain_manager()
	var chunk_size: float = config.get("chunk_size", 32.0)
	var resolution: float = float(config.get("tile_resolution", 32))
	var rings: int = config.get("ring_count", 5)
	var skirt: float = config.get("skirt_depth", 2.0)

	var fails := 0
	for level in rings:
		var spacing := chunk_size * pow(2.0, level) / resolution
		# The apron this ring actually gets, which grows with the tile — see
		# terrain_manager.gd's skirt_depth_for(). Checking every ring against
		# one number was how the outer rings stayed cracked open unnoticed.
		var covers := skirt * pow(2.0, level)
		var gap := 0.0
		# Across the built-up part of the zone and out past the hill, on a grid
		# offset off the round numbers so samples do not all land on the same
		# phase of the noise.
		for i in 90:
			for j in 90:
				var x := -120.0 + 2.9 * float(i)
				var z := -120.0 + 2.9 * float(j)
				# Both axes: a seam can run either way, and the surface is not
				# symmetric about them.
				for axis in [Vector2(spacing, 0.0), Vector2(0.0, spacing)]:
					var lo := field.height_at(x - axis.x, z - axis.y)
					var hi := field.height_at(x + axis.x, z + axis.y)
					gap = maxf(gap, absf(field.height_at(x, z) - (lo + hi) * 0.5))
		if gap >= covers:
			print("FAIL ring %d seam gap %.3f m reaches its %.1f m skirt — cracks would show" % [
				level, gap, covers])
			fails += 1
		print("ring %d (spacing %5.2f m): worst seam gap %.3f m, skirt %5.1f m, %3.0f%% headroom" % [
			level, spacing, gap, covers, (1.0 - gap / covers) * 100.0])
	return fails
