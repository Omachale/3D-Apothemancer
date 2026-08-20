@tool
class_name Zone
extends Node3D

## Builds a zone's terrain from a declarative table.
##
## Everything below the "LAYOUT" heading READS a table rather than holding one:
## the actual data — every building, tower, NPC, prop and heightfield feature —
## lives in [member layout_path] (a JSON file; see [ZoneLayout] and
## `data/zones/starter.json`) so a terrain edit is a diff in a data file a tool
## can write, not a code change. Add or move something there and it appears.
##
## A SECOND ZONE NEEDS NO NEW CODE: point [member layout_path] at a different
## JSON file (a new .tscn with that one property overridden is enough). The
## older "subclass Zone and override the getters" path documented by
## [ZoneLayout]'s comments still works for anything genuinely code-shaped —
## the two procedural tree generators below are exactly that: their CODE stays
## here, only their dials (seed, counts, radii) come from the layout.
##
## CONVENTION: EVERY `pos` IS RELATIVE TO THE GROUND. The land undulates (see
## [method get_heightfield]), so a Y written as an absolute world height would
## mean "buried here, floating there" — every position below has its Y read as
## clearance ABOVE the heightfield and is dropped onto it at build time. Nearly
## all of them are therefore 0, meaning "standing on the land"; a plate's Y is
## how far its walking surface rises above the ground it stands on.
##
## This is the same rule [member spawn_position] already used, and it is why the
## numbers in the layout did not have to change when rolling was turned on.
##
## A staircase starts from the ground and ascends toward its own local +Z, so
## `yaw` aims it. Set a staircase's rise to exactly match the plate it feeds —
## and put both on the same levelling pad, or the ground under each end moves
## independently and the rise no longer matches.
##
## EVERY FLAT-BOTTOMED STRUCTURE NEEDS A PAD UNDER IT. The keep, the terrace and
## the staircase feeding it are rigid rectangles; on undulating ground they
## float at one corner and sink at the other. A "flatten" feature in the
## heightfield levels the ground beneath each one and eases back to the land
## around it. The rule when adding a structure is that its footprint goes in
## the layout's `buildings`, `towers` or `plates` list AND a pad covering it
## goes in `heightfield.features`, a little larger than the footprint so the
## blend starts clear of the walls.

const PLATE_SCRIPT := preload("res://scripts/terrain/ground_plate.gd")
const STAIRS_SCRIPT := preload("res://scripts/terrain/stairs.gd")
const BUILDING_SCRIPT := preload("res://scripts/terrain/building.gd")
const TOWER_SCRIPT := preload("res://scripts/terrain/tower.gd")
const MOUND_SCRIPT := preload("res://scripts/terrain/terrain_mound.gd")
const GRASS_MANAGER_SCRIPT := preload("res://scripts/world/grass_manager.gd")
const TERRAIN_MANAGER_SCRIPT := preload("res://scripts/world/terrain_manager.gd")
const TREE_SCATTER_MANAGER_SCRIPT := preload("res://scripts/world/tree_scatter_manager.gd")

## These three stay preloaded HERE (not just in [ZoneLayout]'s registries)
## because the `_make_*` builders below use them as the FALLBACK when a
## layout entry omits "material" entirely — e.g. TerraceStairs never
## specifies one, and must keep defaulting to stone. Duplicated on purpose:
## a builder's own default and a data file's registry answer different
## questions ("what if the key is absent" vs "what can the key resolve to").
const MAT_GRASS := preload("res://resources/materials/ground_grass.tres")
const MAT_HIGHLAND := preload("res://resources/materials/ground_highland.tres")
const MAT_STONE := preload("res://resources/materials/stone.tres")

## Where this zone's layout lives — see [ZoneLayout]. A second zone is a new
## JSON file and a .tscn overriding this one property; no new code needed.
@export var layout_path := "res://data/zones/starter.json"

## Where the player is dropped when this zone loads. Read from the layout on
## first use ([method _ensure_layout]) rather than exported directly, so a
## subclass or an override .tscn can still set it the old way if it ever
## needs to — but nothing in this project does that today.
@export var spawn_position := Vector3(10.0, 0.5, 22.0)
## Which way they face on arrival, in degrees.
@export var spawn_yaw := 180.0

## Built once by [method _ensure_heightfield] and shared by everything that
## needs to know where the ground is.
var _heightfield: Heightfield = null
## Parsed once by [method _ensure_layout] and shared by every getter below.
var _layout: ZoneLayout = null


# ---------------------------------------------------------------------------
# LAYOUT
# ---------------------------------------------------------------------------

## THE SHAPE OF THE LAND ITSELF — see [Heightfield]. Ground is a function of
## position rather than an object, so terrain_manager.gd can build only the
## part near the player, at whatever detail that distance deserves, and the map
## has no edge to fall off.
##
## The scalars and the feature list both come from the layout
## (`heightfield.*` in [member layout_path]'s JSON) — see [ZoneLayout] and
## that file's per-feature `note` fields for the reasoning behind each one
## (SouthValley's falloff derivation, why EastMountain's summit pad is a
## plateau rather than a hill, and so on).
func get_heightfield() -> Heightfield:
	var hf: Dictionary = _ensure_layout().heightfield_scalars
	var field := Heightfield.new()
	field.seed = hf.get("seed", 20240)
	field.base_elevation = hf.get("base_elevation", 0.0)
	field.rolling_amplitude = hf.get("rolling_amplitude", 0.0)
	field.rolling_frequency = hf.get("rolling_frequency", 0.0)
	field.mountains_amplitude = hf.get("mountains_amplitude", 0.0)
	field.mountains_frequency = hf.get("mountains_frequency", 0.0)
	field.mountains_protected_center = hf.get("mountains_protected_center", Vector2.ZERO)
	field.mountains_protected_radius = hf.get("mountains_protected_radius", 0.0)
	# Already fully converted (Vector2 pos, typed floats, only the keys each
	# feature's JSON entry actually had) by ZoneLayout — see its file header
	# on why an absent key must stay absent rather than gaining a default
	# here (heightfield.gd's pad "level" default is COMPUTED from the
	# terrain when missing, not a fixed fallback).
	field.features = _layout.heightfield_features
	return field


## Flat walkable slabs standing ON the heightfield. `y` is how far the walking
## surface rises above the ground under `pos`; `thickness` should be deep enough
## that a raised plate sinks into whatever is beneath it, with no gap.
##
## A plate is rigid, so the ground under it must be level — give every plate a
## "flatten" pad in the layout's `heightfield.features` covering its footprint.
## Without one the plate stays flat while the land does not, and its edges
## float.
##
## The ground plane is no longer one of these — see [method get_heightfield].
## What belongs here now is anything architectural: a level platform, a
## foundation, anything with a hard edge the land itself should not have.
func get_plates() -> Array:
	return _ensure_layout().plates


## Staircases. `steps` x `step_height` must equal the rise to the target plate.
## `yaw` rotates the flight; 0 climbs toward +Z, 180 toward -Z, 90 toward +X.
func get_staircases() -> Array:
	return _ensure_layout().staircases


## Standalone sculpted hills, built as their own mesh with their own collider.
##
## Empty in the shipped layout: the one hill this zone had is a heightfield
## feature instead, which streams and takes detail levels, neither of which a
## TerrainMound can do. Kept available for the case a heightfield cannot
## express — a hill with an overhang, or one that has to sit on top of a plate
## rather than on the land.
func get_mounds() -> Array:
	return _ensure_layout().mounds


## How the ground is streamed and how its detail falls away with distance — see
## terrain_manager.gd.
##
## Tiles GROW with distance rather than getting coarser at a fixed size:
## `chunk_size` is the innermost tile size and each of the `ring_count` rings
## outward doubles it, so tiles here are 32, 64, 128, 256 and 512 units across.
## Every tile builds at `tile_resolution`, which makes the vertex spacing 1, 2,
## 4, 8 and 16 units — the same range of detail as before, but reached with a
## few hundred tiles instead of nine hundred, and extendable.
##
## Which ring a tile lands in is chosen from projected screen size, not a
## fixed-distance ladder: it falls out of `max_screen_error_px` and wherever the
## camera happens to be, including its altitude once flying exists. THAT is the
## detail dial — `tile_resolution` is a ratio, not a quality setting. Only ring
## 0 gets collision (`collision_level_maximum`), because it is the only one the
## player can reach; anchored NPCs are the exception, handled by
## terrain_manager.gd itself.
##
## `horizon_distance` is the hard edge past which nothing is built at all —
## the screen-space test alone never reaches exactly zero, so this is what
## keeps the world finite. There is no MAP edge short of it, only unbuilt
## ground — walking, or flying, toward it simply builds more. Pushing it out is
## now roughly one extra ring rather than quadratically more tiles, but wants
## distance fog first or the edge is plainly visible.
##
## `skirt_depth` is the hidden apron on a LEVEL 0 tile; coarser rings double it,
## because the crack it hides is set by vertex spacing and spacing doubles every
## ring. verify_zone_layout.gd measures the real gaps against this land — check
## it after changing the terrain, since a hill or a raised amplitude widens them.
func get_terrain_manager() -> Dictionary:
	return _ensure_layout().terrain_manager


## Distance haze, and the view ranges derived from it — see atmosphere.gd for
## why the fog end, the camera far plane and the shadow range have to be solved
## together rather than authored separately.
##
## The two fog distances are FRACTIONS of `horizon_distance` above, not metres,
## so pushing the horizon out moves the haze with it and the world edge stays
## hidden without retuning anything here. `fog_opacity` is the dial to reach
## for first if the look is wrong: 1.0 is total haze at the far end, lower
## leaves the horizon translucent.
##
## `shadow_distance` is the one number that is NOT derived. It is a fixed texel
## budget spread over a distance, so stretching it to the horizon just blurs
## every shadow near the player to buy shadows the fog already hides.
func get_atmosphere() -> Dictionary:
	return _ensure_layout().atmosphere


## Wall-to-wall grass, streamed in square chunks around the player rather
## than a fixed set of hand-placed patches — see grass_manager.gd. Blades now
## find the ground by asking the heightfield instead of raycasting, which is
## both faster and, more importantly, works before the terrain tile beneath a
## chunk has been built. `density` is blades per square metre, same dial as
## before. `load_radius` is sized to clear everything the isometric camera can
## show at a bit past the default zoom in any direction the player rotates to,
## so a chunk should never visibly pop in or out.
func get_grass_manager() -> Dictionary:
	return _ensure_layout().grass_manager


## Ambient tree cover, streamed in square chunks the same way as
## [method get_grass_manager] — see tree_scatter_manager.gd. NOT the same
## thing as [method _generate_mountain_trees]/[method _generate_forest]:
## those are finite, hand-placed landmark stands; this has no edge and is
## what keeps trees from running out however far the player walks.
func get_tree_scatter() -> Dictionary:
	return _ensure_layout().tree_scatter


## Footprints, in world XZ, where grass must not grow. Despite the name, ALSO
## used for [method _make_tree_scatter_manager]'s exclusions — a building
## footprint is exactly as invalid a spot for a tree's roots as it is for a
## blade of grass, so the one list serves both.
##
## The heightfield describes the ground UNDER a building, not its floor, so
## without these, blades sprout through it. The old raycast placement dodged
## this by accident — a downward ray struck the roof first — which is also why
## it used to plant grass on rooftops.
##
## Each entry must cover the object's footprint; check a new building's `pos`
## and `size` in [method get_buildings] against this list.
##
## Most entries in the layout are a literal `rect`; a `derive: tower_footprint`
## entry instead names a point and gets resolved here, at read time, via
## [method _tower_exclusion_rect] — see [ZoneLayout]'s header on why that stays
## symbolic in the data rather than freezing Tower.suggest_size()'s current
## answer into a number that could go stale the moment the tower's own stair
## geometry changes.
func get_grass_exclusions() -> Array:
	var out: Array = []
	for entry in _ensure_layout().grass_exclusion_entries:
		match entry["kind"]:
			"rect":
				out.append(entry["rect"])
			"derive_tower":
				out.append(_tower_exclusion_rect(entry["pos"]))
	return out


## Builds a throwaway Tower just to ask its derived footprint — see
## get_grass_exclusions' note on why this isn't a hardcoded literal like the
## other entries.
func _tower_exclusion_rect(centre: Vector2) -> Rect2:
	var tower: Tower = TOWER_SCRIPT.new()
	var s := tower.suggest_size()
	tower.free()
	return Rect2(centre.x - s * 0.5, centre.y - s * 0.5, s, s)


## Multi-storey buildings. Each is generated from its own numbers by
## `building.gd`; `pos` is the ground its ground floor sits on, and `yaw` turns
## it (the front door is on the -Z side before rotation).
func get_buildings() -> Array:
	return _ensure_layout().buildings


## Tall, narrow towers with a spiral interior stair — see tower.gd. pos is
## the ground the base slab sits on; yaw turns it (the door is on the -Z
## side before rotation, same convention as get_buildings).
func get_towers() -> Array:
	return _ensure_layout().towers


## NPCs. Visual only for now — no health, no aggro, no attacks — see
## [[DESIGN_GOALS.md]]. Check a new position against the layout's other
## footprints (Terrace, StoneKeep, ...) before adding one, so it doesn't spawn
## inside solid ground.
func get_npcs() -> Array:
	return _ensure_layout().npcs


## Static scenery with collision, plus the two procedurally-generated tree
## stands appended after it (EastMountain's cover and the south forest — see
## [method _generate_mountain_trees] and [method _generate_forest]).
##
## `pos.y` is clearance above the land, like everything else here, so 0 means
## "standing on the ground wherever that turns out to be". An optional `sink`
## buries the base — see [method _ground] for when that is wanted.
func get_props() -> Array:
	var layout := _ensure_layout()
	return layout.props \
		+ _generate_mountain_trees(layout.generator_mountain_trees) \
		+ _generate_forest(layout.generator_forest)


## EastMountain's tree cover: a mix of tight clumps and a sparse scatter
## between them, so the slope reads as a real treeline rather than a grid or a
## uniform sprinkle. Confined to an annulus around the peak — inside
## `clear_radius` is left bare for the tower on that summit's flatten pad, and
## outside `outer_radius` stays clear of the steepest ground near the rim. All
## the numbers below (including the seed) come from the layout's
## `generators.mountain_trees` — see `starter.json`'s note on that section for
## the annulus reasoning; this function is the CODE that walks those numbers,
## not the numbers themselves.
##
## Deterministic: seeded RNG only, same rule as [method _generate_forest].
func _generate_mountain_trees(cfg: Dictionary) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = cfg.get("seed", 21140)

	var center: Vector2 = cfg.get("centre", Vector2(130.0, 22.0))
	var clear_radius: float = cfg.get("clear_radius", 26.0)
	var outer_radius: float = cfg.get("outer_radius", 92.0)
	var target_count: int = cfg.get("target_count", 100)
	var clump_count: int = cfg.get("clump_count", 9)
	var clump_size_min: int = cfg.get("clump_size_min", 6)
	var clump_size_max: int = cfg.get("clump_size_max", 13)
	var clump_radius_margin: float = cfg.get("clump_radius_margin", 8.0)
	var clump_jitter: float = cfg.get("clump_jitter", 4.0)
	var clump_scale_min: float = cfg.get("clump_scale_min", 0.85)
	var clump_scale_max: float = cfg.get("clump_scale_max", 1.25)
	var fill_scale_min: float = cfg.get("fill_scale_min", 0.8)
	var fill_scale_max: float = cfg.get("fill_scale_max", 1.3)
	var scene: PackedScene = cfg.get("scene", ZoneLayout.SCENES["pine_tree"])

	var trees: Array = []

	# Clumps first: a handful of tight stands scattered around the slope.
	# Placed before the sparse fill so the fill can simply top up whatever
	# count the clumps didn't reach, rather than the two fighting over a
	# shared budget.
	for _c in clump_count:
		var clump_r := rng.randf_range(clear_radius, outer_radius - clump_radius_margin)
		var clump_angle := rng.randf() * TAU
		var clump_center := center + Vector2(cos(clump_angle), sin(clump_angle)) * clump_r
		var clump_size := rng.randi_range(clump_size_min, clump_size_max)
		for _i in clump_size:
			var jitter := Vector2(
				rng.randf_range(-clump_jitter, clump_jitter),
				rng.randf_range(-clump_jitter, clump_jitter))
			var pos := clump_center + jitter
			# A clump anchored just outside clear_radius can still jitter a
			# tree or two across it; drop those rather than let the tower's
			# clearing grow a tree.
			if pos.distance_to(center) < clear_radius:
				continue
			trees.append({
				"scene": scene, "pos": Vector3(pos.x, 0.0, pos.y),
				"yaw": rng.randf_range(0.0, 360.0),
				"scale": rng.randf_range(clump_scale_min, clump_scale_max),
			})

	# Sparse fill: uniform across the whole annulus, closing the gaps between
	# clumps so the slope between stands doesn't read as bare.
	while trees.size() < target_count:
		var angle := rng.randf() * TAU
		var r := rng.randf_range(clear_radius, outer_radius)
		var pos := center + Vector2(cos(angle), sin(angle)) * r
		trees.append({
			"scene": scene, "pos": Vector3(pos.x, 0.0, pos.y),
			"yaw": rng.randf_range(0.0, 360.0),
			"scale": rng.randf_range(fill_scale_min, fill_scale_max),
		})

	return trees


## A dense pine forest, well clear of spawn — see [method get_props] for the
## header comment on the small hand-placed cluster this extends. Laid out as a
## band ROTATED 90 DEGREES FROM that cluster: rows run along [member Wind]'s
## direction axis (so a gust sweeps down a row, tree after tree) and the band
## itself is long in the perpendicular axis, so the forest reads as a mass
## from any angle rather than a single-file line. All the numbers below come
## from the layout's `generators.forest`; this function is the code that
## walks them.
##
## Deterministic: seeded RNG only, per [[DESIGN_GOALS.md]]'s "keep generated
## content seeded" rule — rerunning build() must place the same trees.
func _generate_forest(cfg: Dictionary) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = cfg.get("seed", 20940)

	# Read live from Wind rather than hardcoding the angle a second time, so
	# the forest can't quietly drift out of alignment with it the way the
	# hand-placed pines in the layout's props list did (see their `note`).
	#
	# ...except in the EDITOR, where build() also runs and non-@tool autoloads
	# like Wind exist as bare Nodes carrying none of their script's properties —
	# reading direction_degrees there fails exactly the way Game access does,
	# which is why every Game access in this file is already guarded the same
	# way. The fallback duplicates wind.gd's own declared default, so the editor
	# preview matches the running game; if that default changes, change this too.
	var wind_degrees := 90.0
	if cfg.get("align_to_wind", true) and not Engine.is_editor_hint():
		wind_degrees = Wind.direction_degrees
	var along_wind := Vector2(sin(deg_to_rad(wind_degrees)), cos(deg_to_rad(wind_degrees)))
	var across_wind := Vector2(-along_wind.y, along_wind.x)

	var anchor: Vector2 = cfg.get("anchor", Vector2(-40.0, 90.0))
	var row_count: int = cfg.get("rows", 4)
	var row_spacing: float = cfg.get("row_spacing", 4.0)
	var trees_per_row: int = cfg.get("trees_per_row", 40)
	var tree_spacing: float = cfg.get("tree_spacing", 4.0)
	var jitter_amount: float = cfg.get("jitter", 1.2)
	var scale_min: float = cfg.get("scale_min", 0.85)
	var scale_max: float = cfg.get("scale_max", 1.2)
	var scene: PackedScene = cfg.get("scene", ZoneLayout.SCENES["pine_tree"])

	var trees: Array = []
	for row in row_count:
		var row_offset := (row - (row_count - 1) / 2.0) * row_spacing
		for i in trees_per_row:
			var along_offset := (i - (trees_per_row - 1) / 2.0) * tree_spacing
			# Small jitter so the stand doesn't read as a rank-and-file grid.
			var jitter := Vector2(
				rng.randf_range(-jitter_amount, jitter_amount),
				rng.randf_range(-jitter_amount, jitter_amount))
			var xz := anchor + across_wind * along_offset + along_wind * row_offset + jitter
			trees.append({
				"scene": scene,
				"pos": Vector3(xz.x, 0, xz.y),
				"yaw": rng.randf_range(0.0, 360.0),
				"scale": rng.randf_range(scale_min, scale_max),
			})
	return trees


# ---------------------------------------------------------------------------
# BUILD
# ---------------------------------------------------------------------------

func _ready() -> void:
	build()
	if not Engine.is_editor_hint():
		Game.spawn_transform = get_spawn_transform()
		Game.register_zone(self)


## Where the player starts, with [member spawn_position]'s Y read as clearance
## ABOVE the ground rather than as an absolute height. Terrain is streamed now,
## so the tile under the spawn point may not exist yet and a raycast could not
## answer this — the heightfield can, before anything is built.
func get_spawn_transform() -> Transform3D:
	var field := _ensure_heightfield()
	var pos := spawn_position
	pos.y = field.height_at(pos.x, pos.z) + spawn_position.y
	return Transform3D(Basis(Vector3.UP, deg_to_rad(spawn_yaw)), pos)


## The one heightfield this zone is using. Built on first ask and reused, so
## every consumer — terrain, grass, spawning — is reading the same land.
func _ensure_heightfield() -> Heightfield:
	if _heightfield == null:
		_heightfield = get_heightfield()
	return _heightfield


## Loads and validates [member layout_path] on first ask and reuses it, so
## every getter reads the same parse rather than re-reading the file. Any
## problem found goes through push_error() here — once, at the point of
## discovery — rather than at every getter that happens to touch the bad
## section, and [member spawn_position]/[member spawn_yaw] are synced from
## the layout on a clean load so external readers of those two exports (see
## verify_zone_layout.gd) see the same numbers the layout declares. On a
## failed load the exported defaults stand untouched and every getter below
## falls back to its own `.get(key, default)` — a broken zone comes up mostly
## empty and loud in the console, not crashed.
func _ensure_layout() -> ZoneLayout:
	if _layout == null:
		_layout = ZoneLayout.new(layout_path)
		for err in _layout.errors:
			push_error("Zone '%s' layout (%s): %s" % [name, layout_path, err])
		if _layout.is_ok():
			spawn_position = _layout.spawn_pos
			spawn_yaw = _layout.spawn_yaw
	return _layout


func build() -> void:
	for child in get_children():
		child.free()
	# Dropped so an edited layout takes effect on rebuild rather than the old
	# land (or the old parse of layout_path) quietly persisting.
	_heightfield = null
	_layout = null
	var field := _ensure_heightfield()
	# Guarded like every other Game access in this script: build() also runs in
	# the editor, where the autoload is not fully set up and touching it fails.
	if not Engine.is_editor_hint():
		Game.heightfield = field

	var unclimbable := field.find_unclimbable_features(50.0)
	if not unclimbable.is_empty():
		push_warning("Zone '%s': terrain too steep for the player to climb: %s" % [
			name, unclimbable])

	var terrain := Node3D.new()
	terrain.name = "Terrain"
	add_child(terrain)
	# The streamed ground itself, before anything that stands on it.
	terrain.add_child(_make_terrain_manager(get_terrain_manager(), field))

	var props := Node3D.new()
	props.name = "Props"
	add_child(props)

	for data in get_plates():
		terrain.add_child(_make_plate(data))
	for data in get_staircases():
		terrain.add_child(_make_stairs(data))
	for data in get_mounds():
		terrain.add_child(_make_mound(data))
	for data in get_buildings():
		terrain.add_child(_make_building(data))
	for data in get_towers():
		terrain.add_child(_make_tower(data))

	var flora := Node3D.new()
	flora.name = "Grass"
	add_child(flora)
	flora.add_child(_make_grass_manager(get_grass_manager(), field))

	var tree_scatter := Node3D.new()
	tree_scatter.name = "TreeScatter"
	add_child(tree_scatter)
	tree_scatter.add_child(_make_tree_scatter_manager(get_tree_scatter(), field))

	var npcs := Node3D.new()
	npcs.name = "NPCs"
	add_child(npcs)
	for data in get_npcs():
		npcs.add_child(_make_npc(data))

	for data in get_props():
		props.add_child(_make_prop(data))


## Resolves a layout `pos` — whose Y is clearance above the land, per this
## file's header — into an actual world position.
##
## [param sink] buries the result, for anything wide enough that standing it on
## a single ground sample leaves daylight under one end. A tree trunk is narrow
## and needs none; a six-metre wall across a slope needs a little. The honest
## alternative is sampling each object's whole footprint and taking the lowest
## point, which needs every layout entry to declare a footprint it does not
## currently have — for two walls, one number is the better trade.
func _ground(pos: Vector3, sink := 0.0) -> Vector3:
	var field := _ensure_heightfield()
	return Vector3(pos.x, field.height_at(pos.x, pos.z) + pos.y - sink, pos.z)


func _make_plate(data: Dictionary) -> GroundPlate:
	var plate: GroundPlate = PLATE_SCRIPT.new()
	plate.name = data.get("name", "Plate")
	plate.size = data.get("size", Vector2(10, 10))
	plate.thickness = data.get("thickness", 1.0)
	plate.material = data.get("material", MAT_GRASS)
	plate.position = _ground(data.get("pos", Vector3.ZERO))
	return plate


func _make_stairs(data: Dictionary) -> Stairs:
	var flight: Stairs = STAIRS_SCRIPT.new()
	flight.name = data.get("name", "Stairs")
	flight.step_count = data.get("steps", 10)
	flight.step_height = data.get("step_height", 0.3)
	flight.step_depth = data.get("step_depth", 0.4)
	flight.width = data.get("width", 4.0)
	flight.material = data.get("material", MAT_STONE)
	flight.position = _ground(data.get("pos", Vector3.ZERO))
	flight.rotation = Vector3(0.0, deg_to_rad(data.get("yaw", 0.0)), 0.0)
	return flight


func _make_mound(data: Dictionary) -> TerrainMound:
	var mound: TerrainMound = MOUND_SCRIPT.new()
	mound.name = data.get("name", "Mound")
	mound.radius = data.get("radius", 24.0)
	mound.height = data.get("height", 11.0)
	mound.resolution = data.get("resolution", 56)
	mound.noise_amplitude = data.get("noise_amplitude", 1.2)
	mound.noise_seed = data.get("seed", 1337)
	mound.position = _ground(data.get("pos", Vector3.ZERO))
	return mound


func _make_terrain_manager(data: Dictionary, field: Heightfield) -> TerrainManager:
	var manager: TerrainManager = TERRAIN_MANAGER_SCRIPT.new()
	manager.name = "TerrainManager"
	manager.heightfield = field
	manager.chunk_size = data.get("chunk_size", 32.0)
	manager.unload_margin = data.get("unload_margin", 48.0)
	manager.skirt_depth = data.get("skirt_depth", 2.0)
	manager.material = data.get("material", MAT_GRASS)
	manager.tile_resolution = data.get("tile_resolution", manager.tile_resolution)
	manager.ring_count = data.get("ring_count", manager.ring_count)
	manager.max_screen_error_px = data.get("max_screen_error_px", manager.max_screen_error_px)
	manager.collision_level_maximum = data.get(
		"collision_level_maximum", manager.collision_level_maximum)
	manager.horizon_distance = data.get("horizon_distance", manager.horizon_distance)
	return manager


func _make_grass_manager(data: Dictionary, field: Heightfield) -> GrassManager:
	var manager: GrassManager = GRASS_MANAGER_SCRIPT.new()
	manager.name = "GrassManager"
	manager.heightfield = field
	manager.exclusions = get_grass_exclusions()
	manager.chunk_size = data.get("chunk_size", 20.0)
	manager.load_radius = data.get("load_radius", 45.0)
	manager.unload_radius = data.get("unload_radius", 65.0)
	manager.density = data.get("density", 90.0)
	manager.max_slope_degrees = data.get("max_slope", 30.0)
	manager.seed = data.get("seed", 20240)
	manager.blade_height = data.get("blade_height", manager.blade_height)
	manager.blade_width = data.get("blade_width", manager.blade_width)
	return manager


func _make_tree_scatter_manager(data: Dictionary, field: Heightfield) -> TreeScatterManager:
	var manager: TreeScatterManager = TREE_SCATTER_MANAGER_SCRIPT.new()
	manager.name = "TreeScatterManager"
	manager.heightfield = field
	manager.exclusions = get_grass_exclusions()
	manager.clear_center = Vector2(spawn_position.x, spawn_position.z)
	manager.chunk_size = data.get("chunk_size", manager.chunk_size)
	manager.load_radius = data.get("load_radius", manager.load_radius)
	manager.unload_radius = data.get("unload_radius", manager.unload_radius)
	manager.radius_per_distance = data.get("radius_per_distance", manager.radius_per_distance)
	manager.max_radius = data.get("max_radius", manager.max_radius)
	manager.check_interval = data.get("check_interval", manager.check_interval)
	manager.seed = data.get("seed", manager.seed)
	manager.noise_frequency = data.get("noise_frequency", manager.noise_frequency)
	manager.trees_per_chunk_floor = data.get("trees_per_chunk_floor", manager.trees_per_chunk_floor)
	manager.trees_per_chunk_max = data.get("trees_per_chunk_max", manager.trees_per_chunk_max)
	manager.bare_threshold = data.get("bare_threshold", manager.bare_threshold)
	manager.max_slope_degrees = data.get("max_slope_degrees", manager.max_slope_degrees)
	manager.clear_radius = data.get("clear_radius", manager.clear_radius)
	manager.scale_min = data.get("scale_min", manager.scale_min)
	manager.scale_max = data.get("scale_max", manager.scale_max)
	if data.has("scene"):
		manager.scene = data["scene"]
	return manager


func _make_building(data: Dictionary) -> Building:
	var building: Building = BUILDING_SCRIPT.new()
	building.name = data.get("name", "Building")
	building.size = data.get("size", Vector2(16, 12))
	building.levels = data.get("levels", 3)
	building.level_height = data.get("level_height", 3.2)
	building.position = _ground(data.get("pos", Vector3.ZERO))
	building.rotation = Vector3(0.0, deg_to_rad(data.get("yaw", 0.0)), 0.0)
	return building


func _make_tower(data: Dictionary) -> Tower:
	var tower: Tower = TOWER_SCRIPT.new()
	tower.name = data.get("name", "Tower")
	tower.height = data.get("height", 30.0)
	if data.has("size"):
		tower.size = data["size"]
	tower.position = _ground(data.get("pos", Vector3.ZERO))
	tower.rotation = Vector3(0.0, deg_to_rad(data.get("yaw", 0.0)), 0.0)
	return tower


func _make_npc(data: Dictionary) -> Node3D:
	var scene: PackedScene = data["scene"]
	var npc: Node3D = scene.instantiate()
	npc.position = _ground(data.get("pos", Vector3.ZERO))
	if data.has("wander_radius"):
		npc.wander_radius = data["wander_radius"]
	return npc


func _make_prop(data: Dictionary) -> Node3D:
	var scene: PackedScene = data["scene"]
	var node: Node3D = scene.instantiate()
	node.position = _ground(data.get("pos", Vector3.ZERO), data.get("sink", 0.0))
	node.rotation = Vector3(0.0, deg_to_rad(data.get("yaw", 0.0)), 0.0)
	var s: float = data.get("scale", 1.0)
	node.scale = Vector3(s, s, s)
	return node
