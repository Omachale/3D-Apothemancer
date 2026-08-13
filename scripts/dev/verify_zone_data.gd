extends Node

## Checks that data/zones/starter.json — the actual shipped layout — parses
## and validates cleanly, and that a handful of values known to matter
## survived transcription from the old GDScript literals intact.
##
## This is the PERMANENT guard replacing what GDScript's own type system used
## to give for free: a typo'd key, a wrong-shaped value, or an accidentally
## injected default in the JSON now fails a build here instead of silently
## changing the world. See [ZoneLayout] for the loader this exercises and
## dump_zone_layout.gd for the one-time equivalence proof used while writing
## the JSON (a diff tool, not a standing check — this suite is the standing
## check).
##
## Run as a SCENE, because it touches `Zone`, which touches the `Game`
## autoload in `_ready()` when not in the editor — see the other verify
## suites' identical note.
##   Godot --headless res://scenes/dev/VerifyZoneData.tscn
## Exits non-zero if any check fails.


func _ready() -> void:
	var fails := 0
	var zone := Zone.new()
	var layout := ZoneLayout.new(zone.layout_path)

	fails += _check_loads_clean(layout)
	fails += _check_canaries(layout)
	fails += _check_absence_preserved(layout)
	fails += _check_generators_present(layout)

	zone.free()
	print("")
	if fails == 0:
		print("ALL ZONE DATA CHECKS PASSED")
	else:
		print("%d CHECK(S) FAILED" % fails)
	get_tree().quit(1 if fails > 0 else 0)


## The actual claim of this suite: the file that ships parses and validates
## with ZERO errors. Every error ZoneLayout finds is printed, not just
## counted, so a failure here tells you exactly what to fix rather than just
## that something is wrong.
func _check_loads_clean(layout: ZoneLayout) -> int:
	if layout.is_ok():
		print("starter.json: loaded with 0 errors")
		return 0
	print("FAIL starter.json failed to load cleanly:")
	for err in layout.errors:
		print("  - %s" % err)
	return 1


## Cheap insurance against a truncated or garbled file: a handful of values
## that came from the original GDScript literals and are known-important
## (they were the subject of real design decisions, not filler) must still
## read back exactly. This does not replace the golden-dump equivalence check
## used during the migration itself — it is a much smaller, permanent version
## of the same idea, cheap enough to run on every CI pass.
func _check_canaries(layout: ZoneLayout) -> int:
	var fails := 0

	if not layout.spawn_pos.is_equal_approx(Vector3(10.0, 0.5, 22.0)):
		print("FAIL spawn.pos is %s, expected (10, 0.5, 22)" % layout.spawn_pos)
		fails += 1

	var south_valley: Dictionary = {}
	var east_mountain: Dictionary = {}
	for feature in layout.heightfield_features:
		if feature.get("type") == "flatten" and feature.get("shape") == "ellipse":
			south_valley = feature
		if feature.get("type") == "plateau":
			east_mountain = feature

	if south_valley.is_empty():
		print("FAIL SouthValley (the ellipse flatten pad) is missing from heightfield.features")
		fails += 1
	else:
		if not is_equal_approx(south_valley.get("falloff", -1.0), 60.0):
			print("FAIL SouthValley falloff is %s, expected 60 — this number is DERIVED from the player's floor_max_angle, not decorative" % south_valley.get("falloff"))
			fails += 1
		if not is_equal_approx(south_valley.get("level", 999.0), -30.0):
			print("FAIL SouthValley level is %s, expected -30" % south_valley.get("level"))
			fails += 1

	if east_mountain.is_empty():
		print("FAIL EastMountain (the plateau feature) is missing from heightfield.features")
		fails += 1
	elif not is_equal_approx(east_mountain.get("radius", -1.0), 100.0):
		print("FAIL EastMountain radius is %s, expected 100" % east_mountain.get("radius"))
		fails += 1

	if fails == 0:
		print("canary values intact: spawn, SouthValley falloff/level, EastMountain radius")
	return fails


## THE thing this whole file structure exists to protect: several builders
## branch on a key being ABSENT, not on its value (see zone_layout.gd's file
## header). If the converter ever regresses to injecting a default, the world
## still builds — just subtly wrong, with no error anywhere. Assert the
## absence directly rather than trusting that nothing changed.
func _check_absence_preserved(layout: ZoneLayout) -> int:
	var fails := 0

	if layout.towers.is_empty():
		print("FAIL no towers in the layout to check")
		fails += 1
	elif layout.towers[0].has("size"):
		print("FAIL towers[0] has an explicit 'size' — EastMountainTower is meant to solve its own footprint (Tower.suggest_size), which only happens when 'size' is ABSENT")
		fails += 1

	var flatten_without_level := false
	for feature in layout.heightfield_features:
		if feature.get("type") == "flatten" and not feature.has("level"):
			flatten_without_level = true
			break
	if not flatten_without_level:
		print("FAIL every flatten pad has an explicit 'level' — expected at least one (e.g. the StoneKeep/Terrace/EastMountain pads) to omit it, letting Heightfield compute the level from the terrain itself")
		fails += 1

	if fails == 0:
		print("optional keys stayed optional: tower size, flatten pad level")
	return fails


## generators.mountain_trees / generators.forest are REQUIRED sections (see
## GENERATOR_SCHEMAS) — a layout that loads "clean" but is silently missing
## one would build a world with no mountain trees or no forest, which
## _check_loads_clean's error count alone would already have caught, but this
## spells out the two things a broken generators section actually costs.
func _check_generators_present(layout: ZoneLayout) -> int:
	var fails := 0
	if layout.generator_mountain_trees.is_empty():
		print("FAIL generators.mountain_trees is empty — EastMountain would come up bare")
		fails += 1
	if layout.generator_forest.is_empty():
		print("FAIL generators.forest is empty — the south forest would come up bare")
		fails += 1
	if fails == 0:
		print("both procedural generators have their dials")
	return fails
