@tool
class_name Zone
extends Node3D

## Builds a zone's terrain from a declarative table.
##
## Everything below the "LAYOUT" heading is data: add a dictionary to a list and
## the piece appears. Nothing is stored in the .tscn, so terrain edits are diffs
## in one readable file rather than thousands of lines of scene text — and the
## same script serves every future zone by subclassing and overriding the
## layout functions.
##
## Convention: a plate's Y is the surface you walk on. A staircase's Y is the
## ground it starts from, and it ascends toward its own local +Z, so `yaw` aims
## it. Set a staircase's rise to exactly match the plate it feeds.

const PLATE_SCRIPT := preload("res://scripts/terrain/ground_plate.gd")
const STAIRS_SCRIPT := preload("res://scripts/terrain/stairs.gd")
const BUILDING_SCRIPT := preload("res://scripts/terrain/building.gd")
const MOUND_SCRIPT := preload("res://scripts/terrain/terrain_mound.gd")
const GRASS_SCRIPT := preload("res://scripts/terrain/grass_field.gd")

const WITCH_SCENE := preload("res://scenes/npc/Witch.tscn")
const MEDIEVAL_SCENE := preload("res://scenes/npc/Medieval.tscn")

const MAT_GRASS := preload("res://resources/materials/ground_grass.tres")
const MAT_HIGHLAND := preload("res://resources/materials/ground_highland.tres")
const MAT_STONE := preload("res://resources/materials/stone.tres")

const TREE_SCENE := preload("res://scenes/props/TreeProp.tscn")
const ROCK_SCENE := preload("res://scenes/props/RockProp.tscn")
const WALL_SCENE := preload("res://scenes/props/WallProp.tscn")

## Where the player is dropped when this zone loads.
@export var spawn_position := Vector3(10.0, 0.5, 22.0)
## Which way they face on arrival, in degrees.
@export var spawn_yaw := 180.0


# ---------------------------------------------------------------------------
# LAYOUT
# ---------------------------------------------------------------------------

## Flat walkable slabs. `y` is the walking surface; `thickness` should be deep
## enough that a raised plate sinks into whatever is beneath it, with no gap.
func get_plates() -> Array:
	return [
		# The main ground plane. Widened from 100 to 140 so the mound in the
		# south-west corner sits on it rather than hanging off the edge.
		{"name": "MainPlane", "pos": Vector3(0, 0, 0), "size": Vector2(140, 140),
			"thickness": 1.0, "material": MAT_GRASS},

		# The big hill: 40x40 at Y=3, reached by three separate staircases.
		{"name": "Hill", "pos": Vector3(18, 3, -12), "size": Vector2(40, 40),
			"thickness": 3.4, "material": MAT_HIGHLAND},

		# A lower terrace on the far side of the map, to prove the system
		# handles more than one elevation.
		{"name": "Terrace", "pos": Vector3(-25, 1.5, 20), "size": Vector2(20, 20),
			"thickness": 1.9, "material": MAT_HIGHLAND},
	]


## Staircases. `steps` x `step_height` must equal the rise to the target plate.
## `yaw` rotates the flight; 0 climbs toward +Z, 180 toward -Z, 90 toward +X.
func get_staircases() -> Array:
	return [
		# --- Hill, rise 3.0 (10 x 0.3) ---
		# South approach: starts on open ground, climbs north onto the hill.
		{"name": "HillStairsSouth", "pos": Vector3(10, 0, 12), "yaw": 180.0,
			"steps": 10, "width": 5.0},
		# East approach.
		{"name": "HillStairsEast", "pos": Vector3(42, 0, -12), "yaw": -90.0,
			"steps": 10, "width": 4.0},
		# West approach.
		{"name": "HillStairsWest", "pos": Vector3(-6, 0, -20), "yaw": 90.0,
			"steps": 10, "width": 4.0},

		# --- Terrace, rise 1.5 (5 x 0.3) ---
		{"name": "TerraceStairs", "pos": Vector3(-25, 0, 32), "yaw": 180.0,
			"steps": 5, "width": 6.0},
	]


## Procedural hills — real sloped landscape, as opposed to the stepped boxes
## `get_plates()` produces. `radius` and `height` together set the steepness,
## and the player cannot climb past 50 degrees; `terrain_mound.gd` documents
## the relationship and offers `max_slope_degrees()` to check a change.
func get_mounds() -> Array:
	return [
		# South-west corner, clear of the keep (which ends at z = -20).
		{"name": "SouthHill", "pos": Vector3(-46, 0, -46),
			"radius": 24.0, "height": 11.0, "noise_amplitude": 1.9},
	]


## Patches of swaying grass. Each is one MultiMesh draw call, and blades are
## raycast onto whatever terrain is underneath, so a patch can safely straddle
## a slope. `density` is blades per square metre and is the dial that decides
## both how good it looks and what it costs.
##
## Grass is placed in patches rather than carpeting the map on purpose: the
## camera only ever sees ~40 units of ground, so blanket coverage would spend
## most of its instances on grass nobody is looking at.
func get_grass() -> Array:
	return [
		# In front of spawn, around the NPCs, clear of the hill plate to the
		# south (z >= 8) and of the staircase at its foot. Placement time (see
		# the print each field logs on load) is the actual ceiling on size —
		# this was pushed until the load-time cost became worth noticing, not
		# until the frame rate did.
		{"name": "SpawnMeadow", "pos": Vector3(0, 0, 24), "radius": 20.0,
			"density": 90.0},

		# Up the north flank of the mound, to show grass following real
		# terrain rather than sitting on a flat slab. Its slope limit is
		# raised because the flank is steeper than the default allows, and a
		# hillside with a bald ring around it looks worse than one that is
		# grassed to the point the ground gets genuinely steep.
		{"name": "HillsideMeadow", "pos": Vector3(-40, 0, -34), "radius": 18.0,
			"density": 90.0, "max_slope": 40.0, "seed": 7781},

		# East of spawn, clear of the boxed Hill plate (x in [-2,38],
		# z in [-32,8]) by z alone — a third patch so the grassed area is not
		# two isolated circles either side of the player's usual path. (An
		# earlier choice here clipped the Terrace's corner on paper; verify
		# radius against every footprint in get_plates(), not just the
		# nearest one, before trusting a placement.)
		{"name": "EastMeadow", "pos": Vector3(24, 0, 22), "radius": 10.0,
			"density": 90.0, "seed": 4102},
	]


## Multi-storey buildings. Each is generated from its own numbers by
## `building.gd`; `pos` is the ground its ground floor sits on, and `yaw` turns
## it (the front door is on the -Z side before rotation).
func get_buildings() -> Array:
	return [
		# Turned to put the front door on the north face. The default camera
		# looks toward -X/-Z, so a door on the -Z face would never be seen.
		{"name": "StoneKeep", "pos": Vector3(-26, 0, -14), "yaw": 180.0,
			"size": Vector2(16, 12), "levels": 3, "level_height": 3.2},
	]


## NPCs. Visual only for now — no health, no aggro, no attacks — see
## [[DESIGN_GOALS.md]]. Placed south of spawn on the open plane: clear of the
## Hill (x in [-2,38], z in [-32,8]), the Terrace (x in [-35,-15], z in
## [10,30]) and the keep (x in [-34,-18], z in [-20,-8]) footprints, so they
## don't spawn inside solid ground. Check new footprints against those three
## before adding an NPC position — that check is exactly what caught the
## Medieval knight spawning inside the Hill during testing.
func get_npcs() -> Array:
	return [
		{"scene": WITCH_SCENE, "pos": Vector3(-18, 0, 50), "wander_radius": 5.0},
		{"scene": MEDIEVAL_SCENE, "pos": Vector3(14, 0, 16), "wander_radius": 5.0},
	]


## Static scenery with collision. Scattered by hand so there is something to
## bump into and something to judge distance against.
func get_props() -> Array:
	return [
		{"scene": TREE_SCENE, "pos": Vector3(-8, 0, 8), "yaw": 20.0, "scale": 1.0},
		{"scene": TREE_SCENE, "pos": Vector3(-14, 0, 2), "yaw": 140.0, "scale": 1.2},
		{"scene": TREE_SCENE, "pos": Vector3(-19, 0, -6), "yaw": 75.0, "scale": 0.9},
		{"scene": TREE_SCENE, "pos": Vector3(2, 0, 26), "yaw": 200.0, "scale": 1.1},
		# Directly behind the spawn point, so there is something to walk into
		# within a second of starting.
		{"scene": TREE_SCENE, "pos": Vector3(10, 0, 27), "yaw": 15.0, "scale": 1.0},
		{"scene": TREE_SCENE, "pos": Vector3(22, 0, 24), "yaw": 310.0, "scale": 1.0},
		{"scene": TREE_SCENE, "pos": Vector3(30, 0, 16), "yaw": 45.0, "scale": 1.3},
		# On top of the hill, to sell the height.
		{"scene": TREE_SCENE, "pos": Vector3(14, 3, -18), "yaw": 90.0, "scale": 1.1},
		{"scene": TREE_SCENE, "pos": Vector3(26, 3, -22), "yaw": 250.0, "scale": 1.0},

		{"scene": ROCK_SCENE, "pos": Vector3(6, 0, 14), "yaw": 0.0, "scale": 1.0},
		{"scene": ROCK_SCENE, "pos": Vector3(-4, 0, 18), "yaw": 60.0, "scale": 1.4},
		{"scene": ROCK_SCENE, "pos": Vector3(20, 3, -6), "yaw": 120.0, "scale": 1.2},

		{"scene": WALL_SCENE, "pos": Vector3(-14, 0, 24), "yaw": 0.0, "scale": 1.0},
		{"scene": WALL_SCENE, "pos": Vector3(-35, 0, 6), "yaw": 90.0, "scale": 1.0},
	]


# ---------------------------------------------------------------------------
# BUILD
# ---------------------------------------------------------------------------

func _ready() -> void:
	build()
	if not Engine.is_editor_hint():
		Game.spawn_transform = get_spawn_transform()
		Game.register_zone(self)


func get_spawn_transform() -> Transform3D:
	return Transform3D(Basis(Vector3.UP, deg_to_rad(spawn_yaw)), spawn_position)


func build() -> void:
	for child in get_children():
		child.free()

	var terrain := Node3D.new()
	terrain.name = "Terrain"
	add_child(terrain)

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

	# Grass plants itself by raycasting onto the terrain above, so it has to be
	# added after everything it might land on.
	var flora := Node3D.new()
	flora.name = "Grass"
	add_child(flora)
	for data in get_grass():
		flora.add_child(_make_grass(data))

	var npcs := Node3D.new()
	npcs.name = "NPCs"
	add_child(npcs)
	for data in get_npcs():
		npcs.add_child(_make_npc(data))

	for data in get_props():
		props.add_child(_make_prop(data))


func _make_plate(data: Dictionary) -> GroundPlate:
	var plate: GroundPlate = PLATE_SCRIPT.new()
	plate.name = data.get("name", "Plate")
	plate.size = data.get("size", Vector2(10, 10))
	plate.thickness = data.get("thickness", 1.0)
	plate.material = data.get("material", MAT_GRASS)
	plate.position = data.get("pos", Vector3.ZERO)
	return plate


func _make_stairs(data: Dictionary) -> Stairs:
	var flight: Stairs = STAIRS_SCRIPT.new()
	flight.name = data.get("name", "Stairs")
	flight.step_count = data.get("steps", 10)
	flight.step_height = data.get("step_height", 0.3)
	flight.step_depth = data.get("step_depth", 0.4)
	flight.width = data.get("width", 4.0)
	flight.material = data.get("material", MAT_STONE)
	flight.position = data.get("pos", Vector3.ZERO)
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
	mound.position = data.get("pos", Vector3.ZERO)
	return mound


func _make_grass(data: Dictionary) -> GrassField:
	var field: GrassField = GRASS_SCRIPT.new()
	field.name = data.get("name", "Grass")
	field.radius = data.get("radius", 12.0)
	field.density = data.get("density", 55.0)
	field.blade_height = data.get("blade_height", 0.5)
	field.max_slope_degrees = data.get("max_slope", 30.0)
	field.seed = data.get("seed", 20240)
	field.position = data.get("pos", Vector3.ZERO)
	return field


func _make_building(data: Dictionary) -> Building:
	var building: Building = BUILDING_SCRIPT.new()
	building.name = data.get("name", "Building")
	building.size = data.get("size", Vector2(16, 12))
	building.levels = data.get("levels", 3)
	building.level_height = data.get("level_height", 3.2)
	building.position = data.get("pos", Vector3.ZERO)
	building.rotation = Vector3(0.0, deg_to_rad(data.get("yaw", 0.0)), 0.0)
	return building


func _make_npc(data: Dictionary) -> Node3D:
	var scene: PackedScene = data["scene"]
	var npc: Node3D = scene.instantiate()
	npc.position = data.get("pos", Vector3.ZERO)
	if data.has("wander_radius"):
		npc.wander_radius = data["wander_radius"]
	return npc


func _make_prop(data: Dictionary) -> Node3D:
	var scene: PackedScene = data["scene"]
	var node: Node3D = scene.instantiate()
	node.position = data.get("pos", Vector3.ZERO)
	node.rotation = Vector3(0.0, deg_to_rad(data.get("yaw", 0.0)), 0.0)
	var s: float = data.get("scale", 1.0)
	node.scale = Vector3(s, s, s)
	return node
