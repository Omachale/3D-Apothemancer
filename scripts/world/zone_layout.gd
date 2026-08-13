class_name ZoneLayout
extends RefCounted

## Loads and validates a zone's layout from a JSON file — see
## `data/zones/starter.json` for the shape, and [Zone]'s header for why this
## exists (task #4: layout used to be GDScript literals in zone.gd; it is
## now data a tool, or a person who doesn't read GDScript, can edit).
##
## ALL THE JSON KNOWLEDGE LIVES HERE AND NOWHERE ELSE. zone.gd's getters are
## thin reads over this class's already-typed fields; nothing outside this
## file knows JSON exists.
##
## THE ONE RULE THAT MATTERS: A KEY ABSENT FROM THE JSON ENTRY MUST BE ABSENT
## FROM THE CONVERTED DICTIONARY. Several callers branch on presence, not
## value — [Heightfield]'s flatten pads compute `level` from the terrain when
## it is missing (heightfield.gd:463), a pad sizes from `size` OR falls back
## to `radius` (heightfield.gd:498), [Zone]'s `_make_tower` only sets `size`
## when `data.has("size")` (a tower without one solves its own footprint),
## and `_make_terrain_manager` defaults five fields to the NODE's own
## declared defaults rather than a literal. So conversion below is a pure
## shape-and-type translation that never injects a default of its own — it
## either carries a key through, converted, or leaves it out entirely and
## records why if that absence wasn't allowed.
##
## Validation runs on every load (not just in tests) and collects every
## error before reporting, rather than stopping at the first one — a typo'd
## key should not hide the three other typos in the same file. See [member
## errors]; [Zone] pushes each one through push_error() and falls back to an
## empty layout rather than crashing mid-build.
##
## `.json` IS NOT AN IMPORTED RESOURCE TYPE. That's harmless today — this
## project has no export_presets.cfg at all, so nothing is filtered — but if
## one is ever added, `*.json` needs to go in its include_filter or zone data
## silently fails to ship in an exported build. Worth checking first if a
## shipped build ever has an empty world.

const CURRENT_FORMAT_VERSION := 1

## String keys a JSON entry can use for `"scene"` / `"material"`, resolved to
## the SAME preloaded resources zone.gd used to hold as consts — preload,
## not a runtime load() of an arbitrary path, stays the default for exactly
## the reasons the rest of the project already preloads everything (static,
## export-safe, no first-use hitch). A value beginning with "res://" is the
## escape hatch for tooling that wants to point at something not yet in
## these tables — see [method _resolve_registry].
const SCENES := {
	"witch": preload("res://scenes/npc/Witch.tscn"),
	"medieval": preload("res://scenes/npc/Medieval.tscn"),
	"rock": preload("res://scenes/props/RockProp.tscn"),
	"wall": preload("res://scenes/props/WallProp.tscn"),
	"pine_tree": preload("res://scenes/props/PineTreeProp.tscn"),
}
const MATERIALS := {
	"grass": preload("res://resources/materials/ground_grass.tres"),
	"highland": preload("res://resources/materials/ground_highland.tres"),
	"stone": preload("res://resources/materials/stone.tres"),
}

## Section name -> {key -> type tag}, for the flat tuning dictionaries.
## Nothing here is required: every field has a real fallback already living
## in the class that consumes it ([TerrainManager]'s own declared defaults,
## [GrassManager]'s exported defaults), and duplicating those numbers here
## as "required" would just be a second place for them to go stale.
const SECTION_FIELD_TYPES := {
	"terrain_manager": {
		"chunk_size": "float", "unload_margin": "float", "skirt_depth": "float",
		"material": "material", "tile_resolution": "int", "ring_count": "int",
		"max_screen_error_px": "float", "collision_level_maximum": "int",
		"horizon_distance": "float",
	},
	"atmosphere": {
		"fog_begin_fraction": "float", "fog_end_fraction": "float", "fog_curve": "float",
		"fog_opacity": "float", "fog_color": "color", "fog_sun_scatter": "float",
		"fog_sky_affect": "float", "far_margin": "float", "shadow_distance": "float",
	},
	"grass_manager": {
		"chunk_size": "float", "load_radius": "float", "unload_radius": "float",
		"density": "float", "max_slope": "float", "seed": "int",
	},
}

## Section name -> {"types": {...}, "required": [...]}, for arrays of
## placed-object entries. Unlike the flat dicts above, these DO have
## required keys — an entry with no `pos` isn't a valid anything.
const ENTRY_SCHEMAS := {
	"plate": {
		"types": {"name": "string", "pos": "vec3", "size": "vec2",
			"thickness": "float", "material": "material"},
		"required": ["pos"],
	},
	"staircase": {
		"types": {"name": "string", "pos": "vec3", "yaw": "float", "steps": "int",
			"step_height": "float", "step_depth": "float", "width": "float",
			"material": "material"},
		"required": ["pos"],
	},
	"mound": {
		"types": {"name": "string", "pos": "vec3", "radius": "float", "height": "float",
			"resolution": "int", "noise_amplitude": "float", "seed": "int"},
		"required": ["pos"],
	},
	"building": {
		"types": {"name": "string", "pos": "vec3", "yaw": "float", "size": "vec2",
			"levels": "int", "level_height": "float"},
		"required": ["pos"],
	},
	# "size" deliberately excluded from required — see the file header:
	# Tower solves its own footprint when it is absent, and that must stay
	# reachable from data the same way it is reachable from code today.
	"tower": {
		"types": {"name": "string", "pos": "vec3", "yaw": "float", "height": "float",
			"size": "vec2"},
		"required": ["pos"],
	},
	"npc": {
		"types": {"scene": "scene", "pos": "vec3", "wander_radius": "float"},
		"required": ["scene", "pos"],
	},
	"prop": {
		"types": {"scene": "scene", "pos": "vec3", "yaw": "float",
			"scale": "float", "sink": "float"},
		"required": ["scene", "pos"],
	},
}

## Heightfield features are polymorphic by `"type"` — a plateau's flat_ratio
## means nothing on a hill, and a flatten pad's falloff/level/shape/noise mean
## nothing on either. `"pos"` is the one field every feature shares.
const FEATURE_SCHEMAS := {
	"hill": {"radius": "float", "height": "float", "noise": "float"},
	"plateau": {"radius": "float", "height": "float", "noise": "float", "flat_ratio": "float"},
	"flatten": {"size": "vec2", "radius": "float", "falloff": "float",
		"level": "float", "noise": "float", "shape": "string"},
}
## hill/plateau need radius+height; flatten needs EITHER size or radius,
## checked separately in [method _load_features] because "one of two keys"
## isn't expressible as a flat required-list.
const FEATURE_REQUIRED := {
	"hill": ["radius", "height"],
	"plateau": ["radius", "height"],
	"flatten": [],
}

const HEIGHTFIELD_SCALAR_TYPES := {
	"seed": "int", "base_elevation": "float",
	"rolling_amplitude": "float", "rolling_frequency": "float",
	"mountains_amplitude": "float", "mountains_frequency": "float",
	"mountains_protected_center": "vec2", "mountains_protected_radius": "float",
}

## Every generator field is required, on purpose: a generator's constants
## have no independently-meaningful "default" the way a builder's do (there
## is no sensible fallback for "how many trees"), so leaving one out would
## either silently reuse whatever GDScript's own initial value happens to be
## or crash — required makes the missing value a loud validation error
## instead of either of those.
const GENERATOR_SCHEMAS := {
	"mountain_trees": {
		"types": {"seed": "int", "centre": "vec2", "clear_radius": "float",
			"outer_radius": "float", "target_count": "int", "clump_count": "int",
			"clump_size_min": "int", "clump_size_max": "int",
			"clump_radius_margin": "float", "clump_jitter": "float",
			"clump_scale_min": "float", "clump_scale_max": "float",
			"fill_scale_min": "float", "fill_scale_max": "float", "scene": "scene"},
		"required": ["seed", "centre", "clear_radius", "outer_radius", "target_count",
			"clump_count", "clump_size_min", "clump_size_max", "clump_radius_margin",
			"clump_jitter", "clump_scale_min", "clump_scale_max",
			"fill_scale_min", "fill_scale_max", "scene"],
	},
	"forest": {
		"types": {"seed": "int", "anchor": "vec2", "rows": "int", "row_spacing": "float",
			"trees_per_row": "int", "tree_spacing": "float", "jitter": "float",
			"scale_min": "float", "scale_max": "float", "scene": "scene",
			"align_to_wind": "bool"},
		"required": ["seed", "anchor", "rows", "row_spacing", "trees_per_row",
			"tree_spacing", "jitter", "scale_min", "scale_max", "scene", "align_to_wind"],
	},
}

const TOP_LEVEL_KEYS := ["format_version", "name", "spawn", "heightfield",
	"terrain_manager", "atmosphere", "grass_manager", "grass_exclusions",
	"plates", "staircases", "mounds", "buildings", "towers", "npcs", "props",
	"generators"]

## Every problem found while loading, in the order encountered. Empty means
## the file is fully valid. [Zone] pushes each through push_error(); this
## class never prints on its own so a caller in a test context can inspect
## the list instead of scraping the console.
var errors: Array[String] = []

var spawn_pos := Vector3(10.0, 0.5, 22.0)
var spawn_yaw := 180.0
var heightfield_scalars: Dictionary = {}
var heightfield_features: Array = []
var terrain_manager: Dictionary = {}
var atmosphere: Dictionary = {}
var grass_manager: Dictionary = {}
## {"kind": "rect", "rect": Rect2} or {"kind": "derive_tower", "pos": Vector2}
## — see the file header on why "derive" entries stay symbolic rather than
## freezing Tower.suggest_size()'s current answer into a literal. Resolving
## "derive_tower" needs Tower itself, which stays a zone.gd concern (the
## generator-code-stays-code rule), so this class hands back the request,
## not the resolved Rect2.
var grass_exclusion_entries: Array = []
var plates: Array = []
var staircases: Array = []
var mounds: Array = []
var buildings: Array = []
var towers: Array = []
var npcs: Array = []
var props: Array = []
var generator_mountain_trees: Dictionary = {}
var generator_forest: Dictionary = {}


func is_ok() -> bool:
	return errors.is_empty()


func _init(path: String) -> void:
	var text := _read_file(path)
	if text.is_empty():
		return # _read_file already recorded why.
	var json := JSON.new()
	var parse_err := json.parse(text)
	if parse_err != OK:
		errors.append("%s:%d: %s" % [path, json.get_error_line(), json.get_error_message()])
		return
	var parsed: Variant = json.get_data()
	if typeof(parsed) != TYPE_DICTIONARY:
		errors.append("%s: root of the file must be a JSON object" % path)
		return
	_load(parsed)


func _read_file(path: String) -> String:
	if not FileAccess.file_exists(path):
		errors.append("zone layout not found: %s" % path)
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		errors.append("could not open zone layout %s (%s)" % [
			path, error_string(FileAccess.get_open_error())])
		return ""
	return f.get_as_text()


func _load(root: Dictionary) -> void:
	for key in root.keys():
		if not TOP_LEVEL_KEYS.has(key):
			errors.append("root: unknown section '%s'" % key)

	if not root.has("format_version"):
		errors.append("root: missing 'format_version'")
	elif root["format_version"] != CURRENT_FORMAT_VERSION:
		errors.append("root: format_version %s is not supported (this loader understands %d)" % [
			str(root["format_version"]), CURRENT_FORMAT_VERSION])
	if root.has("name") and typeof(root["name"]) != TYPE_STRING:
		errors.append("root.name: expected a string")

	_load_spawn(root.get("spawn", {}))
	_load_heightfield(root.get("heightfield", {}))
	terrain_manager = _convert_flat_dict(
		root.get("terrain_manager", {}), SECTION_FIELD_TYPES["terrain_manager"], "terrain_manager")
	atmosphere = _convert_flat_dict(
		root.get("atmosphere", {}), SECTION_FIELD_TYPES["atmosphere"], "atmosphere")
	grass_manager = _convert_flat_dict(
		root.get("grass_manager", {}), SECTION_FIELD_TYPES["grass_manager"], "grass_manager")
	_load_grass_exclusions(root.get("grass_exclusions", []))
	plates = _convert_entries(root.get("plates", []), ENTRY_SCHEMAS["plate"], "plates")
	staircases = _convert_entries(root.get("staircases", []), ENTRY_SCHEMAS["staircase"], "staircases")
	mounds = _convert_entries(root.get("mounds", []), ENTRY_SCHEMAS["mound"], "mounds")
	buildings = _convert_entries(root.get("buildings", []), ENTRY_SCHEMAS["building"], "buildings")
	towers = _convert_entries(root.get("towers", []), ENTRY_SCHEMAS["tower"], "towers")
	npcs = _convert_entries(root.get("npcs", []), ENTRY_SCHEMAS["npc"], "npcs")
	props = _convert_entries(root.get("props", []), ENTRY_SCHEMAS["prop"], "props")
	_load_generators(root.get("generators", {}))


func _load_spawn(raw: Variant) -> void:
	if typeof(raw) != TYPE_DICTIONARY:
		errors.append("spawn: expected an object")
		return
	var converted := _convert_entry(raw, {"pos": "vec3", "yaw": "float"}, ["pos", "yaw"], "spawn")
	if converted.has("pos"):
		spawn_pos = converted["pos"]
	if converted.has("yaw"):
		spawn_yaw = converted["yaw"]


func _load_heightfield(raw: Variant) -> void:
	if typeof(raw) != TYPE_DICTIONARY:
		errors.append("heightfield: expected an object")
		return
	var scalars_raw: Dictionary = (raw as Dictionary).duplicate()
	var features_raw: Variant = scalars_raw.get("features", [])
	scalars_raw.erase("features")
	heightfield_scalars = _convert_entry(
		scalars_raw, HEIGHTFIELD_SCALAR_TYPES, HEIGHTFIELD_SCALAR_TYPES.keys(), "heightfield")
	heightfield_features = _load_features(features_raw)


func _load_features(raw: Variant) -> Array:
	if typeof(raw) != TYPE_ARRAY:
		errors.append("heightfield.features: expected an array")
		return []
	var out: Array = []
	for i in raw.size():
		var entry: Variant = raw[i]
		var context := "heightfield.features[%d]" % i
		if typeof(entry) != TYPE_DICTIONARY:
			errors.append("%s: expected an object" % context)
			continue
		var entry_dict: Dictionary = entry
		if not entry_dict.has("type"):
			errors.append("%s: missing required key 'type'" % context)
			continue
		var ftype: Variant = entry_dict["type"]
		if typeof(ftype) != TYPE_STRING or not FEATURE_SCHEMAS.has(ftype):
			errors.append("%s: unknown feature type '%s' (known: %s)" % [
				context, str(ftype), ", ".join(FEATURE_SCHEMAS.keys())])
			continue
		var types: Dictionary = {"pos": "vec2"}
		types.merge(FEATURE_SCHEMAS[ftype])
		var required: Array = ["pos"] + FEATURE_REQUIRED[ftype]
		var without_type: Dictionary = entry_dict.duplicate()
		without_type.erase("type")
		var converted := _convert_entry(without_type, types, required, context)
		if ftype == "flatten" and not converted.has("size") and not converted.has("radius"):
			errors.append("%s: a flatten pad needs 'size' or 'radius'" % context)
		converted["type"] = ftype
		out.append(converted)
	return out


func _load_grass_exclusions(raw: Variant) -> void:
	if typeof(raw) != TYPE_ARRAY:
		errors.append("grass_exclusions: expected an array")
		return
	var out: Array = []
	for i in raw.size():
		var entry: Variant = raw[i]
		var context := "grass_exclusions[%d]" % i
		if typeof(entry) != TYPE_DICTIONARY:
			errors.append("%s: expected an object" % context)
			continue
		var entry_dict: Dictionary = entry
		if entry_dict.has("rect"):
			for k in entry_dict.keys():
				if k != "rect" and k != "note":
					errors.append("%s: unknown key '%s'" % [context, k])
			var rect: Variant = _convert_value(entry_dict["rect"], "rect2", "%s.rect" % context)
			if rect != null:
				out.append({"kind": "rect", "rect": rect})
		elif entry_dict.has("derive"):
			var derive_kind: Variant = entry_dict["derive"]
			for k in entry_dict.keys():
				if k != "derive" and k != "pos" and k != "note":
					errors.append("%s: unknown key '%s'" % [context, k])
			if derive_kind != "tower_footprint":
				errors.append("%s: unknown derive kind '%s' (known: tower_footprint)" % [
					context, str(derive_kind)])
			elif not entry_dict.has("pos"):
				errors.append("%s: 'derive' entry needs 'pos'" % context)
			else:
				var pos: Variant = _convert_value(entry_dict["pos"], "vec2", "%s.pos" % context)
				if pos != null:
					out.append({"kind": "derive_tower", "pos": pos})
		else:
			errors.append("%s: exclusion entry needs 'rect' or 'derive'" % context)
	grass_exclusion_entries = out


func _load_generators(raw: Variant) -> void:
	if typeof(raw) != TYPE_DICTIONARY:
		errors.append("generators: expected an object")
		return
	var raw_dict: Dictionary = raw
	for key in raw_dict.keys():
		if not GENERATOR_SCHEMAS.has(key):
			errors.append("generators: unknown key '%s'" % key)
	if raw_dict.has("mountain_trees"):
		var schema: Dictionary = GENERATOR_SCHEMAS["mountain_trees"]
		generator_mountain_trees = _convert_entry(
			raw_dict["mountain_trees"], schema["types"], schema["required"],
			"generators.mountain_trees")
	else:
		errors.append("generators: missing 'mountain_trees'")
	if raw_dict.has("forest"):
		var schema2: Dictionary = GENERATOR_SCHEMAS["forest"]
		generator_forest = _convert_entry(
			raw_dict["forest"], schema2["types"], schema2["required"], "generators.forest")
	else:
		errors.append("generators: missing 'forest'")


## Converts a whole array of entries against one entry schema, e.g. every
## item in `"buildings"`. Non-object entries are reported and skipped rather
## than aborting the whole array, so one bad entry doesn't hide the rest.
func _convert_entries(raw: Variant, schema: Dictionary, context: String) -> Array:
	if typeof(raw) != TYPE_ARRAY:
		errors.append("%s: expected an array" % context)
		return []
	var raw_array: Array = raw
	var out: Array = []
	for i in raw_array.size():
		var entry: Variant = raw_array[i]
		if typeof(entry) != TYPE_DICTIONARY:
			errors.append("%s[%d]: expected an object" % [context, i])
			continue
		out.append(_convert_entry(entry, schema["types"], schema["required"], "%s[%d]" % [context, i]))
	return out


func _convert_flat_dict(raw: Variant, types: Dictionary, context: String) -> Dictionary:
	if typeof(raw) != TYPE_DICTIONARY:
		errors.append("%s: expected an object" % context)
		return {}
	return _convert_entry(raw, types, [], context)


## The core conversion step, shared by every section: walks the keys actually
## present in `raw`, converts each against `types`, and returns a Dictionary
## containing ONLY the keys that were present and valid — see the file
## header on why nothing here may invent a default. `"note"` is always
## accepted and always dropped; that is what lets rationale live next to the
## numbers it explains without becoming a stray "unknown key" error.
func _convert_entry(raw: Dictionary, types: Dictionary, required: Array, context: String) -> Dictionary:
	var out: Dictionary = {}
	for key in raw.keys():
		if key == "note":
			continue
		if not types.has(key):
			errors.append("%s: unknown key '%s' (valid: %s)" % [
				context, key, ", ".join(types.keys())])
			continue
		var converted: Variant = _convert_value(raw[key], types[key], "%s.%s" % [context, key])
		if converted != null:
			out[key] = converted
	for req in required:
		if not raw.has(req):
			errors.append("%s: missing required key '%s'" % [context, req])
	return out


## Converts one value against one type tag. Returns null (and appends to
## [member errors]) on any mismatch — none of these types can legitimately
## BE null on success, so null doubles safely as the "conversion failed"
## sentinel for [method _convert_entry] to skip.
func _convert_value(raw: Variant, type_tag: String, context: String) -> Variant:
	match type_tag:
		"float":
			if typeof(raw) == TYPE_FLOAT or typeof(raw) == TYPE_INT:
				return float(raw)
			errors.append("%s: expected a number" % context)
			return null
		"int":
			if typeof(raw) == TYPE_INT:
				return raw
			if typeof(raw) == TYPE_FLOAT and is_equal_approx(raw, round(raw)):
				return int(raw)
			errors.append("%s: expected an integer" % context)
			return null
		"string":
			if typeof(raw) == TYPE_STRING:
				return raw
			errors.append("%s: expected a string" % context)
			return null
		"bool":
			if typeof(raw) == TYPE_BOOL:
				return raw
			errors.append("%s: expected a boolean" % context)
			return null
		"vec2":
			return _convert_numeric_array(raw, 2, context, func(n): return Vector2(n[0], n[1]))
		"vec3":
			return _convert_numeric_array(raw, 3, context, func(n): return Vector3(n[0], n[1], n[2]))
		"rect2":
			return _convert_numeric_array(raw, 4, context, func(n): return Rect2(n[0], n[1], n[2], n[3]))
		"color":
			if typeof(raw) != TYPE_ARRAY or not ((raw as Array).size() == 3 or (raw as Array).size() == 4):
				errors.append("%s: expected an array of 3 or 4 numbers" % context)
				return null
			var nums := _numbers_from_array(raw, context)
			if nums.size() == 3:
				return Color(nums[0], nums[1], nums[2])
			elif nums.size() == 4:
				return Color(nums[0], nums[1], nums[2], nums[3])
			return null # _numbers_from_array already recorded why.
		"scene":
			return _resolve_registry(raw, SCENES, "scene", context)
		"material":
			return _resolve_registry(raw, MATERIALS, "material", context)
		_:
			errors.append("%s: internal error, unknown type tag '%s'" % [context, type_tag])
			return null


func _convert_numeric_array(raw: Variant, count: int, context: String, ctor: Callable) -> Variant:
	if typeof(raw) != TYPE_ARRAY or (raw as Array).size() != count:
		errors.append("%s: expected an array of %d numbers" % [context, count])
		return null
	var nums := _numbers_from_array(raw, context)
	if nums.size() != count:
		return null # _numbers_from_array already recorded why.
	return ctor.call(nums)


func _numbers_from_array(raw: Variant, context: String) -> Array:
	if typeof(raw) != TYPE_ARRAY:
		errors.append("%s: expected an array" % context)
		return []
	var nums: Array = []
	for v in (raw as Array):
		if typeof(v) != TYPE_FLOAT and typeof(v) != TYPE_INT:
			errors.append("%s: array elements must all be numbers" % context)
			return []
		nums.append(float(v))
	return nums


## `raw` is either a key into `registry` (the normal case — a name from the
## project's own preloaded consts) or a `res://` path (the escape hatch for
## anything a future tool wants to reference before it has earned a name in
## SCENES/MATERIALS). The registry form is preferred: it stays a static
## preload rather than a runtime load(), matching every other resource
## reference in this project.
func _resolve_registry(raw: Variant, registry: Dictionary, kind: String, context: String) -> Variant:
	if typeof(raw) != TYPE_STRING:
		errors.append("%s: expected a string %s key" % [context, kind])
		return null
	var key: String = raw
	if key.begins_with("res://"):
		if not ResourceLoader.exists(key):
			errors.append("%s: %s path does not exist: %s" % [context, kind, key])
			return null
		return load(key)
	if registry.has(key):
		return registry[key]
	errors.append("%s: unknown %s '%s' (known: %s)" % [
		context, kind, key, ", ".join(registry.keys())])
	return null
