extends Node

## Prints every Zone getter's fully-expanded output, in a stable order and at
## fixed float precision, for byte-for-byte comparison across a refactor.
##
## THIS IS THE SAFETY NET for moving zone.gd's layout from hardcoded arrays
## into data/zones/starter.json (task #4 — see DEVLOG.md). Run it, save the
## output, make the change, run it again, diff. Identical output is the proof
## that nothing was dropped, transposed, or given a default value it should
## not have had (several call sites in zone.gd/heightfield.gd branch on a key
## being ABSENT, not on its value — see heightfield.gd's pad "level" default
## and zone.gd's _make_tower "size" check — so an accidental default is a
## silent behaviour change a build failure would never catch).
##
## Run as a SCENE, not with --script: [method Zone.get_props] calls
## _generate_forest(), which reads Wind.direction_degrees live outside the
## editor — that autoload does not exist under --script, so a dump taken that
## way would disagree with the real game for a reason that has nothing to do
## with the refactor being checked.
##
##   Godot --headless --quit-after 20000 res://scenes/dev/DumpZoneLayout.tscn
##
## Deliberately no assertions here — this is a diffing tool, not a verify
## suite. See verify_zone_data.gd for the permanent, pass/fail guard that
## replaces it once the JSON exists.

const FLOAT_FMT := "%.6f"


func _ready() -> void:
	var zone := Zone.new()

	_section("spawn_position", zone.spawn_position)
	_section("spawn_yaw", zone.spawn_yaw)
	_section("spawn_transform", zone.get_spawn_transform())
	_section("heightfield", _dump_heightfield(zone.get_heightfield()))
	_section("plates", zone.get_plates())
	_section("staircases", zone.get_staircases())
	_section("mounds", zone.get_mounds())
	_section("terrain_manager", zone.get_terrain_manager())
	_section("atmosphere", zone.get_atmosphere())
	_section("grass_manager", zone.get_grass_manager())
	_section("tree_scatter", zone.get_tree_scatter())
	_section("grass_exclusions", zone.get_grass_exclusions())
	_section("buildings", zone.get_buildings())
	_section("towers", zone.get_towers())
	_section("npcs", zone.get_npcs())
	_section("props", zone.get_props())

	zone.free()
	print("")
	print("DUMP COMPLETE")
	get_tree().quit(0)


func _section(label: String, value: Variant) -> void:
	print("=== %s ===" % label)
	print(_format(value, 0))
	print("")


func _dump_heightfield(field: Heightfield) -> Dictionary:
	# Heightfield is a Resource with scalar properties plus a `features`
	# array — pull the scalars out into a plain Dictionary so it goes through
	# the same formatter as everything else instead of relying on Resource's
	# own (unstable, engine-version-dependent) string conversion.
	return {
		"seed": field.seed,
		"base_elevation": field.base_elevation,
		"rolling_amplitude": field.rolling_amplitude,
		"rolling_frequency": field.rolling_frequency,
		"mountains_amplitude": field.mountains_amplitude,
		"mountains_frequency": field.mountains_frequency,
		"mountains_protected_center": field.mountains_protected_center,
		"mountains_protected_radius": field.mountains_protected_radius,
		"features": field.features,
	}


## Recursively renders any Variant this file's data ever contains, in a
## stable and diff-friendly shape:
##   - Dictionary: keys SORTED (insertion order in GDScript literals is not
##     semantically meaningful here, and sorting makes a reordered-but-equal
##     dict diff as identical instead of as a false positive).
##   - Array: order PRESERVED (array order IS meaningful — it's build order).
##   - float: fixed precision, so float-repr noise cannot masquerade as or
##     hide a real difference.
##   - Object (PackedScene, Material, ...): resolved to its resource_path,
##     not Godot's default `<PackedScene#123>` (the instance ID is different
##     every run and would make every dump look like a diff).
func _format(value: Variant, indent: int) -> String:
	var pad := "  ".repeat(indent)
	match typeof(value):
		TYPE_DICTIONARY:
			var d: Dictionary = value
			if d.is_empty():
				return pad + "{}"
			var keys := d.keys()
			keys.sort()
			var lines: Array[String] = []
			for k in keys:
				lines.append("%s%s: %s" % [pad, k, _format(d[k], indent + 1).strip_edges()])
			return "\n".join(lines)
		TYPE_ARRAY:
			var a: Array = value
			if a.is_empty():
				return pad + "[]"
			var lines: Array[String] = []
			for i in a.size():
				lines.append("%s[%d]\n%s" % [pad, i, _format(a[i], indent + 1)])
			return "\n".join(lines)
		TYPE_VECTOR2:
			var v: Vector2 = value
			return pad + "(%s, %s)" % [FLOAT_FMT % v.x, FLOAT_FMT % v.y]
		TYPE_VECTOR3:
			var v3: Vector3 = value
			return pad + "(%s, %s, %s)" % [FLOAT_FMT % v3.x, FLOAT_FMT % v3.y, FLOAT_FMT % v3.z]
		TYPE_RECT2:
			var r: Rect2 = value
			return pad + "[pos (%s, %s) size (%s, %s)]" % [
				FLOAT_FMT % r.position.x, FLOAT_FMT % r.position.y,
				FLOAT_FMT % r.size.x, FLOAT_FMT % r.size.y]
		TYPE_COLOR:
			var c: Color = value
			return pad + "rgba(%s, %s, %s, %s)" % [
				FLOAT_FMT % c.r, FLOAT_FMT % c.g, FLOAT_FMT % c.b, FLOAT_FMT % c.a]
		TYPE_TRANSFORM3D:
			var t: Transform3D = value
			return pad + "origin %s basis_z %s" % [
				_format(t.origin, 0), _format(t.basis.z, 0)]
		TYPE_FLOAT:
			return pad + (FLOAT_FMT % value)
		TYPE_OBJECT:
			if value == null:
				return pad + "null"
			if value.has_method("get") and "resource_path" in value and value.resource_path != "":
				return pad + value.resource_path
			return pad + str(value)
		_:
			return pad + str(value)
