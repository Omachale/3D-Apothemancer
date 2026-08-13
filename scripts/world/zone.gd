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
## CONVENTION: EVERY `pos` IS RELATIVE TO THE GROUND. The land undulates (see
## [method get_heightfield]), so a Y written as an absolute world height would
## mean "buried here, floating there" — every position below has its Y read as
## clearance ABOVE the heightfield and is dropped onto it at build time. Nearly
## all of them are therefore 0, meaning "standing on the land"; a plate's Y is
## how far its walking surface rises above the ground it stands on.
##
## This is the same rule [member spawn_position] already used, and it is why the
## numbers in this file did not have to change when rolling was turned on.
##
## A staircase starts from the ground and ascends toward its own local +Z, so
## `yaw` aims it. Set a staircase's rise to exactly match the plate it feeds —
## and put both on the same levelling pad, or the ground under each end moves
## independently and the rise no longer matches.

const PLATE_SCRIPT := preload("res://scripts/terrain/ground_plate.gd")
const STAIRS_SCRIPT := preload("res://scripts/terrain/stairs.gd")
const BUILDING_SCRIPT := preload("res://scripts/terrain/building.gd")
const TOWER_SCRIPT := preload("res://scripts/terrain/tower.gd")
const MOUND_SCRIPT := preload("res://scripts/terrain/terrain_mound.gd")
const GRASS_MANAGER_SCRIPT := preload("res://scripts/world/grass_manager.gd")
const TERRAIN_MANAGER_SCRIPT := preload("res://scripts/world/terrain_manager.gd")

const WITCH_SCENE := preload("res://scenes/npc/Witch.tscn")
const MEDIEVAL_SCENE := preload("res://scenes/npc/Medieval.tscn")

const MAT_GRASS := preload("res://resources/materials/ground_grass.tres")
const MAT_HIGHLAND := preload("res://resources/materials/ground_highland.tres")
const MAT_STONE := preload("res://resources/materials/stone.tres")

const ROCK_SCENE := preload("res://scenes/props/RockProp.tscn")
const WALL_SCENE := preload("res://scenes/props/WallProp.tscn")
const PINE_TREE_SCENE := preload("res://scenes/props/PineTreeProp.tscn")

## Where the player is dropped when this zone loads.
@export var spawn_position := Vector3(10.0, 0.5, 22.0)
## Which way they face on arrival, in degrees.
@export var spawn_yaw := 180.0

## Built once by [method _ensure_heightfield] and shared by everything that
## needs to know where the ground is.
var _heightfield: Heightfield = null


# ---------------------------------------------------------------------------
# LAYOUT
# ---------------------------------------------------------------------------

## THE SHAPE OF THE LAND ITSELF — see [Heightfield]. This replaced the fixed
## 140x140 "MainPlane" slab that used to be the world: ground is now a function
## of position rather than an object, so terrain_manager.gd can build only the
## part near the player, at whatever detail that distance deserves, and the map
## has no edge to fall off.
##
## Everything here is data. A future terrain-painting tool would write this list
## rather than anyone typing coordinates.
##
## ROLLING IS ON NOW. It was held at 0 through the migration so the streamed
## world could be compared against the flat slab it replaced and any difference
## blamed on the streaming rather than on the land — that comparison is done.
## 1.5 metres over a ~125-unit wavelength is swells, not hills: enough that open
## ground reads as land from a low camera, gentle enough to walk over without
## noticing. Hills are still features.
##
## EVERY FLAT-BOTTOMED STRUCTURE NEEDS A PAD UNDER IT. The keep, the terrace and
## the staircase feeding it are rigid rectangles; on undulating ground they
## float at one corner and sink at the other. A "flatten" feature levels the
## ground beneath each one and eases back to the land around it — see
## [Heightfield]'s note on the two passes. The rule when adding a structure is
## that its footprint goes in [method get_buildings], [method get_towers] or
## [method get_plates] AND a pad covering it goes here, a little larger than
## the footprint so the blend starts clear of the walls.
##
## The terrace pad deliberately covers its staircase too. Stairs rise by a fixed
## amount to meet the plate above, so the ground they start from and the ground
## the plate stands on have to be the SAME level — two pads at their own
## separate levels would leave the top step short of the terrace or through it.
func get_heightfield() -> Heightfield:
	var field := Heightfield.new()
	field.seed = 20240
	field.base_elevation = 0.0
	field.rolling_amplitude = 3.0
	field.rolling_frequency = 0.008
	field.mountains_amplitude = 45.0
	field.mountains_frequency = 0.002
	field.mountains_protected_center = Vector2(10.0, 22.0)
	field.mountains_protected_radius = 80.0
	field.features = [
		# Was the "SouthHill" TerrainMound. Same centre, radius and height, so
		# the same hill stands in the same place — it is simply described now
		# rather than built.
		{"type": "hill", "pos": Vector2(-46, -46),
			"radius": 24.0, "height": 11.0, "noise": 1.9},

		# EastMountain — a scale test for rolling/features, and a proving ground
		# for a large landmark. 200m across, its nearest foot 20m east of spawn
		# (spawn.x=10, so the foot sits at x=30; centre is the foot plus the
		# 100m radius). height=47 with noise=1.5 measures a peak slope of ~38
		# degrees (see feature_max_slope_degrees) — matching the SouthHill's own
		# proven-climbable steepness, safely under the player's 50 degree limit
		# even before accounting for the smoothing a real mesh adds. Rounded
		# summit by construction (smoothstep is flat-tangent at d=0), so the
		# flatten pad below settles onto the true peak height with nothing to
		# override.
		{"type": "plateau", "pos": Vector2(130, 22),
			"radius": 100.0, "height": 47.0, "noise": 1.5, "flat_ratio": 0.15},

		# Pads. Listed after the hill because pads apply to the finished additive
		# surface, and a pad's default level is read from it — order within this
		# list only matters between pads that overlap, and these two do not.
		#
		# StoneKeep, footprint 16x12 centred (-26,-14): one unit of margin all
		# round so the blend never starts under a wall.
		{"type": "flatten", "pos": Vector2(-26, -14),
			"size": Vector2(18, 14), "falloff": 10.0},
		# Terrace (20x20 centred (-25,20)) AND TerraceStairs (which start at
		# z=32 and climb to z=30): one pad spanning z 8..34 so both sit on the
		# same level, plus a unit of margin on x.
		{"type": "flatten", "pos": Vector2(-25, 21),
			"size": Vector2(22, 26), "falloff": 10.0},
		# EastMountain summit: a level 20x20 platform for EastMountainTower
		# (see get_towers) — comfortably larger than the tower's own derived
		# 8.4x8.4 footprint. The
		# hill feature above is a PLATEAU, not a hill: its flat_ratio already
		# holds the top exactly level out to radius 15, comfortably past the
		# pad's own half-extent (10, ~14.1 at the rounded corners) — so this pad
		# has almost nothing to reconcile and only exists to erase the noise
		# ripple, not to fight the mountain's own slope. (A plain "hill" here
		# was tried first: pinning a flat core near ITS curved summit forced
		# the pad's shoulder to make up, in one falloff band, height the raw
		# hill spreads over a much longer radius — 53.9 degrees at a 10-unit
		# falloff, worse (52.9) at 36, because widening the band just reached
		# further into the hill's own steepest ground. The plateau's genuinely
		# flat top avoids the whole fight.)
		{"type": "flatten", "pos": Vector2(130, 22),
			"size": Vector2(20, 20), "falloff": 12.0},
	]
	return field


## Flat walkable slabs standing ON the heightfield. `y` is how far the walking
## surface rises above the ground under `pos`; `thickness` should be deep enough
## that a raised plate sinks into whatever is beneath it, with no gap.
##
## A plate is rigid, so the ground under it must be level — give every plate a
## "flatten" pad in [method get_heightfield] covering its footprint. Without one
## the plate stays flat while the land does not, and its edges float.
##
## The ground plane is no longer one of these — see [method get_heightfield].
## What belongs here now is anything architectural: a level platform, a
## foundation, anything with a hard edge the land itself should not have.
func get_plates() -> Array:
	return [
		# A raised terrace on the far side of the map, to prove the system
		# handles more than one elevation.
		{"name": "Terrace", "pos": Vector3(-25, 1.5, 20), "size": Vector2(20, 20),
			"thickness": 1.9, "material": MAT_HIGHLAND},
	]


## Staircases. `steps` x `step_height` must equal the rise to the target plate.
## `yaw` rotates the flight; 0 climbs toward +Z, 180 toward -Z, 90 toward +X.
func get_staircases() -> Array:
	return [
		# --- Terrace, rise 1.5 (5 x 0.3) ---
		{"name": "TerraceStairs", "pos": Vector3(-25, 0, 32), "yaw": 180.0,
			"steps": 5, "width": 6.0},
	]


## Standalone sculpted hills, built as their own mesh with their own collider.
##
## Empty now: the one hill this zone had is a heightfield feature instead, which
## streams and takes detail levels, neither of which a TerrainMound can do.
## Kept available for the case a heightfield cannot express — a hill with an
## overhang, or one that has to sit on top of a plate rather than on the land.
func get_mounds() -> Array:
	return []


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
	return {"chunk_size": 32.0, "unload_margin": 48.0, "skirt_depth": 2.0,
		"tile_resolution": 32,
		"ring_count": 5,
		"max_screen_error_px": 24.0,
		"collision_level_maximum": 0,
		"horizon_distance": 480.0}


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
	return {"fog_begin_fraction": 0.35, "fog_end_fraction": 0.95,
		"fog_curve": 1.6, "fog_opacity": 1.0,
		"fog_color": Color(0.65098, 0.72549, 0.792157),
		"fog_sun_scatter": 0.1, "fog_sky_affect": 0.0,
		"far_margin": 1.05, "shadow_distance": 55.0}


## Wall-to-wall grass, streamed in square chunks around the player rather
## than a fixed set of hand-placed patches — see grass_manager.gd. Blades now
## find the ground by asking the heightfield instead of raycasting, which is
## both faster and, more importantly, works before the terrain tile beneath a
## chunk has been built. `density` is blades per square metre, same dial as
## before. `load_radius` is sized to clear everything the isometric camera can
## show at a bit past the default zoom in any direction the player rotates to,
## so a chunk should never visibly pop in or out.
func get_grass_manager() -> Dictionary:
	return {"chunk_size": 20.0, "load_radius": 90.0, "unload_radius": 120.0,
		"density": 45.0, "max_slope": 42.0, "seed": 20240}


## Footprints, in world XZ, where grass must not grow.
##
## The heightfield describes the ground UNDER a building, not its floor, so
## without these, blades sprout through it. The old raycast placement dodged
## this by accident — a downward ray struck the roof first — which is also why
## it used to plant grass on rooftops.
##
## Each entry must cover the object's footprint; check a new building's `pos`
## and `size` in [method get_buildings] against this list.
func get_grass_exclusions() -> Array:
	return [
		# StoneKeep: centred (-26, -14), 16 x 12.
		Rect2(-34.0, -20.0, 16.0, 12.0),
		# Terrace: centred (-25, 20), 20 x 20. Grass under a solid plate is
		# invisible and still costs a blade, so it is simply not planted.
		Rect2(-35.0, 10.0, 20.0, 20.0),
		# EastMountainTower: centred (130, 22). Tower's footprint is derived
		# from its stair geometry rather than authored (see tower.gd), so it
		# is asked directly rather than duplicated here as a literal.
		_tower_exclusion_rect(Vector2(130, 22)),
	]


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
	return [
		# Turned to put the front door on the north face. The default camera
		# looks toward -X/-Z, so a door on the -Z face would never be seen.
		{"name": "StoneKeep", "pos": Vector3(-26, 0, -14), "yaw": 180.0,
			"size": Vector2(16, 12), "levels": 3, "level_height": 3.2},
	]


## Tall, narrow towers with a spiral interior stair — see tower.gd. pos is
## the ground the base slab sits on; yaw turns it (the door is on the -Z
## side before rotation, same convention as get_buildings).
func get_towers() -> Array:
	return [
		# EastMountain summit tower: sits on the "future tower" pad (see
		# get_heightfield's summit flatten) and inside _generate_mountain_trees'
		# clear_radius. yaw 90 puts the door on the WEST face — verified with a
		# headless probe of Basis(UP, yaw) against the compass convention in
		# compass.gd — approached from the mountain's western shoulder, which
		# is also where the treeline and the climbable slope both are.
		{"name": "EastMountainTower", "pos": Vector3(130, 0, 22), "yaw": 90.0,
			"height": 30.0},
	]


## NPCs. Visual only for now — no health, no aggro, no attacks — see
## [[DESIGN_GOALS.md]]. Placed south of spawn on the open plane: clear of the
## Terrace (x in [-35,-15], z in [10,30]) and the keep (x in [-34,-18],
## z in [-20,-8]) footprints, so they don't spawn inside solid ground. Check
## new footprints against those before adding an NPC position.
func get_npcs() -> Array:
	return [
		{"scene": WITCH_SCENE, "pos": Vector3(-18, 0, 50), "wander_radius": 5.0},
		{"scene": MEDIEVAL_SCENE, "pos": Vector3(14, 0, 16), "wander_radius": 5.0},
	]


## Static scenery with collision. Scattered by hand so there is something to
## bump into and something to judge distance against.
##
## `pos.y` is clearance above the land, like everything else here, so 0 means
## "standing on the ground wherever that turns out to be". An optional `sink`
## buries the base — see [method _ground] for when that is wanted.
func get_props() -> Array:
	return [
		# Rocks sit half-buried anyway, and burying them a little further hides
		# the sliver of ground a sphere leaves visible on a slope.
		{"scene": ROCK_SCENE, "pos": Vector3(6, 0, 14), "yaw": 0.0, "scale": 1.0, "sink": 0.15},
		{"scene": ROCK_SCENE, "pos": Vector3(-4, 0, 18), "yaw": 60.0, "scale": 1.4, "sink": 0.15},
		{"scene": ROCK_SCENE, "pos": Vector3(20, 0, -6), "yaw": 120.0, "scale": 1.2, "sink": 0.15},

		# Six metres long, so on rolling ground one end lifts clear — see
		# _ground()'s note on `sink`. 0.5 covers the worst this land does across
		# that span; a wall on genuinely steep ground would need a foundation.
		{"scene": WALL_SCENE, "pos": Vector3(-14, 0, 24), "yaw": 0.0, "scale": 1.0, "sink": 0.5},
		{"scene": WALL_SCENE, "pos": Vector3(-35, 0, 6), "yaw": 90.0, "scale": 1.0, "sink": 0.5},

		# Pines (see PineTreeProp.tscn) — the first real tree-model asset, and
		# the proving ground for wind response on something other than grass.
		#
		# STALE, AS WARNED: originally strung out along Wind.direction_degrees
		# (-45) so a gust would visibly reach one tree after the next.
		# direction_degrees is now 90 (see wind.gd — the camera default yaw
		# changing from 45 to 0 broke the old perpendicularity, so the wind
		# axis moved to restore it), and these five hand-placed positions were
		# never re-laid to match. They still catch gusts and sway correctly —
		# gust_total() samples wherever a tree actually stands — they just no
		# longer form a deliberate line along the wind. The 160-tree forest
		# below (_generate_forest) reads Wind.direction_degrees live and has
		# no such staleness risk; prefer that pattern over hardcoded positions
		# for anything meant to stay aligned with the wind axis.
		{"scene": PINE_TREE_SCENE, "pos": Vector3(21, 0, 13), "yaw": 200.0, "scale": 0.9},
		{"scene": PINE_TREE_SCENE, "pos": Vector3(17, 0, 21), "yaw": 65.0, "scale": 1.15},
		{"scene": PINE_TREE_SCENE, "pos": Vector3(15, 0, 18), "yaw": 0.0, "scale": 1.0},
		{"scene": PINE_TREE_SCENE, "pos": Vector3(2, 0, 22), "yaw": 130.0, "scale": 1.05},
		{"scene": PINE_TREE_SCENE, "pos": Vector3(-1, 0, 31), "yaw": 290.0, "scale": 0.95},

	] + _generate_mountain_trees() + _generate_forest()


## EastMountain's tree cover: a mix of tight clumps and a sparse scatter
## between them, so the slope reads as a real treeline rather than a grid or a
## uniform sprinkle. Confined to an annulus around the peak at (130, 22) —
## inside [param clear_radius] is left bare for the tower this pad
## (get_heightfield()'s summit "flatten" feature) exists for, and outside
## [param outer_radius] stays clear of the steepest ground near the rim.
##
## Deterministic: seeded RNG only, same rule as [method _generate_forest].
func _generate_mountain_trees() -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20240 + 900

	var center := Vector2(130.0, 22.0)
	var clear_radius := 26.0
	var outer_radius := 92.0
	var target_count := 100

	var trees: Array = []

	# Clumps first: a handful of tight stands scattered around the slope.
	# Placed before the sparse fill so the fill can simply top up whatever
	# count the clumps didn't reach, rather than the two fighting over a
	# shared budget.
	var clump_count := 9
	for _c in clump_count:
		var clump_r := rng.randf_range(clear_radius, outer_radius - 8.0)
		var clump_angle := rng.randf() * TAU
		var clump_center := center + Vector2(cos(clump_angle), sin(clump_angle)) * clump_r
		var clump_size := rng.randi_range(6, 13)
		for _i in clump_size:
			var jitter := Vector2(rng.randf_range(-4.0, 4.0), rng.randf_range(-4.0, 4.0))
			var pos := clump_center + jitter
			# A clump anchored just outside clear_radius can still jitter a
			# tree or two across it; drop those rather than let the tower's
			# clearing grow a tree.
			if pos.distance_to(center) < clear_radius:
				continue
			trees.append({
				"scene": PINE_TREE_SCENE, "pos": Vector3(pos.x, 0.0, pos.y),
				"yaw": rng.randf_range(0.0, 360.0), "scale": rng.randf_range(0.85, 1.25),
			})

	# Sparse fill: uniform across the whole annulus, closing the gaps between
	# clumps so the slope between stands doesn't read as bare.
	while trees.size() < target_count:
		var angle := rng.randf() * TAU
		var r := rng.randf_range(clear_radius, outer_radius)
		var pos := center + Vector2(cos(angle), sin(angle)) * r
		trees.append({
			"scene": PINE_TREE_SCENE, "pos": Vector3(pos.x, 0.0, pos.y),
			"yaw": rng.randf_range(0.0, 360.0), "scale": rng.randf_range(0.8, 1.3),
		})

	return trees


## A dense pine forest, well clear of spawn — see [method get_props] for the
## header comment on the cluster this extends. Laid out as a band ROTATED 90
## DEGREES FROM the small cluster above: rows run along [member Wind]'s
## direction axis (so a gust sweeps down a row, tree after tree) and the band
## itself is long in the perpendicular axis, so the forest reads as a mass
## from any angle rather than a single-file line.
##
## Deterministic: seeded RNG only, per [[DESIGN_GOALS.md]]'s "keep generated
## content seeded" rule — rerunning build() must place the same trees.
func _generate_forest() -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20240 + 700

	# Read live from Wind rather than hardcoding the angle a second time, so the
	# forest can't quietly drift out of alignment with it the way the five
	# hand-placed pines in get_props() did.
	#
	# ...except in the EDITOR, where build() also runs and non-@tool autoloads
	# like Wind exist as bare Nodes carrying none of their script's properties —
	# reading direction_degrees there fails exactly the way Game access does,
	# which is why every Game access in this file is already guarded the same
	# way. The fallback duplicates wind.gd's own declared default, so the editor
	# preview matches the running game; if that default changes, change this too.
	var wind_degrees := 90.0
	if not Engine.is_editor_hint():
		wind_degrees = Wind.direction_degrees
	var along_wind := Vector2(sin(deg_to_rad(wind_degrees)), cos(deg_to_rad(wind_degrees)))
	var across_wind := Vector2(-along_wind.y, along_wind.x)

	# Anchored well past the small pine cluster and the SouthHill feature
	# (centred (-46,-46), radius ~24) so the two stands don't overlap and
	# neither clips the hill's steeper ground.
	var anchor := Vector2(-40.0, 90.0)

	var row_count := 4 # "several trees in width"
	var row_spacing := 4.0
	var trees_per_row := 40
	var tree_spacing := 4.0 # Close enough for a dense stand, clear of collisions.

	var trees: Array = []
	for row in row_count:
		var row_offset := (row - (row_count - 1) / 2.0) * row_spacing
		for i in trees_per_row:
			var along_offset := (i - (trees_per_row - 1) / 2.0) * tree_spacing
			# Small jitter so the stand doesn't read as a rank-and-file grid.
			var jitter := Vector2(rng.randf_range(-1.2, 1.2), rng.randf_range(-1.2, 1.2))
			var xz := anchor + across_wind * along_offset + along_wind * row_offset + jitter
			trees.append({
				"scene": PINE_TREE_SCENE,
				"pos": Vector3(xz.x, 0, xz.y),
				"yaw": rng.randf_range(0.0, 360.0),
				"scale": rng.randf_range(0.85, 1.2),
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


func build() -> void:
	for child in get_children():
		child.free()
	# Dropped so an edited layout takes effect on rebuild rather than the old
	# land quietly persisting.
	_heightfield = null
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
