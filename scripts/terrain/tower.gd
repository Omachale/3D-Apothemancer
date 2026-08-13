@tool
class_name Tower
extends Node3D

## A tall, narrow square tower with a single door and a continuous staircase
## that spirals up the inside of its walls to a parapeted platform at the top.
##
## THE STAIRCASE IS A SQUARE HELIX, not Building's per-storey alternating
## flights. Building's flights exist inside rooms with floor slabs between
## them, so a flight has to be gated to a storey or it reveals steps with no
## floor under them (see building.gd's note on [method _stair_clip]). A tower
## this narrow has no rooms — it is one open shaft from the door to the roof,
## so there is nothing for an early reveal to hang over: showing more of the
## climb above the player as they climb is just what looking up a real
## stairwell looks like. That is what makes the reveal here simpler than
## Building's: every piece uses one continuous formula driven by the player's
## own height, with no storey bookkeeping at all.
##
## THE FOOTPRINT IS DERIVED FROM THE STAIRS, not authored as an independent
## number. [member size] still exists as an export so a hand-tuned value can
## override it, but the default is picked by [method suggest_size]: the
## narrowest square that still gives every flight between corners at least
## [member min_steps_per_leg] steps at [member step_depth] going. Asking for a
## narrower tower than that would either choke the stairs down to nothing
## between turns or force a going too short to be walkable — the request was
## "as narrow as it can be", and this is what answers that literally instead
## of by feel.
##
## Four flights make one full lap of the tower and gain one "storey" of
## height; a tall, narrow tower needs many laps rather than a few tall ones,
## which is the correct trade for the footprint asked for, not an oversight.
##
## Each corner gets a small square landing to turn on, except the very first
## (the ground floor slab already covers it) and the very last (the roof slab
## does). [member step_height] is a nominal pitch used only to size the flight
## count; the actual per-step rise is solved afterward so the full climb lands
## exactly on [member height] — see [method build]'s two-pass note.

const STAIRS_SCRIPT := preload("res://scripts/terrain/stairs.gd")
const MAT_WALL := preload("res://resources/materials/stone_wall.tres")
const MAT_FLOOR := preload("res://resources/materials/stone_floor.tres")

@export_group("Shape")
## Outer footprint, X by Z, always square (Z is forced to match X). 0 means
## "derive it" — see [method suggest_size] and the class doc.
@export var size := 0.0: set = _set_size
@export_range(4.0, 60.0, 0.5) var height := 30.0: set = _set_height
@export_range(0.15, 1.0, 0.05) var wall_thickness := 0.4: set = _set_wall_thickness
@export_range(0.05, 1.0, 0.05) var floor_thickness := 0.25: set = _set_floor_thickness
## Low wall around the roof platform.
@export_range(0.0, 2.0, 0.1) var parapet_height := 1.0: set = _set_parapet_height

@export_group("Stairs")
## Walkway width, hugging the interior walls. Kept well above the player's own
## footprint (see [Player]'s 0.45-radius capsule) with enough margin either
## side not to scrape the walls on every step.
##
## This is the dominant term in [method suggest_size] — it is paid TWICE, once
## for the walkway and once for the landing it has to clear at each end — so
## it is the main dial for how wide the tower comes out. It also sets the
## width of the roof's stairwell opening (see [method _build_roof]), so the
## way out onto the platform widens with the stair rather than staying a slot.
@export_range(0.8, 4.0, 0.1) var stair_width := 2.4: set = _set_stair_width
## Horizontal run of one step. Kept fixed — this is the number that actually
## determines whether the stairs feel steep, so [method build] solves the
## rise around it rather than the other way round.
@export_range(0.2, 0.5, 0.02) var step_depth := 0.28: set = _set_step_depth
## Nominal rise per step, used only to decide how many flights the climb
## needs. atan2(step_height, step_depth) at the defaults is ~34 degrees —
## comfortably under the player's 50-degree climb limit and under typical
## "steep stairs" territory, not just barely legal.
@export_range(0.1, 0.3, 0.01) var step_height := 0.19: set = _set_step_height
## The narrowest a flight between two corners is allowed to shrink to, in
## steps, when [method suggest_size] is solving for the smallest footprint.
## Below this a landing-to-landing hop stops reading as a flight of stairs at
## all.
@export_range(3, 12, 1) var min_steps_per_leg := 10: set = _set_min_steps_per_leg

@export_group("Door")
@export_range(0.5, 3.0, 0.1) var door_width := 2.1: set = _set_door_width
@export_range(1.8, 3.0, 0.1) var door_height := 2.2: set = _set_door_height

@export_group("Reveal")
@export var reveal_enabled := true
## Where the clip plane sits above the player's feet for stairs and far walls.
@export_range(0.5, 12.0, 0.1) var head_room := 3.5
## For floor and landing slabs. Must stay small or a landing above the player
## starts drawing over them before they arrive.
@export_range(0.02, 1.0, 0.01) var ceiling_clearance := 0.15
## Below this dot product between a wall's outward face and the camera's view
## direction, the wall counts as in the way and is cut down near the player's
## own feet instead of revealed generously.
@export_range(-1.0, 0.0, 0.05) var near_wall_threshold := -0.2
@export_range(0.2, 2.0, 0.05) var kneewall_height := 1.0

const NO_CLIP := 100000.0

## {"mesh": MeshInstance3D, "normal": Vector3} — exterior walls, which need the
## near/far camera test.
var _wall_pieces: Array = []
## {"mesh": MeshInstance3D} — stairs and the parapet. Always clipped to
## feet + head_room while the player is inside; there is no storey gate.
var _upright_meshes: Array = []
## {"mesh": MeshInstance3D} — landings, the ground slab and the roof slab.
## Clipped to feet + ceiling_clearance.
var _slab_meshes: Array = []
var _last_feet := NAN


func _ready() -> void:
	build()
	set_process(not Engine.is_editor_hint())


# ---------------------------------------------------------------------------
# QUERIES
# ---------------------------------------------------------------------------

func contains_point(world_point: Vector3) -> bool:
	var p := to_local(world_point)
	var hs := _resolved_size() * 0.5
	return absf(p.x) <= hs and absf(p.z) <= hs and p.y > -1.0 and p.y < height + parapet_height + 1.0


## The narrowest square footprint that still gives every flight at least
## [member min_steps_per_leg] steps. See the class doc — this is what "as
## narrow as it can be" is solved against.
##
## A middle flight (both ends landing-bound) is the shortest one at a given
## size, so it is the binding constraint: run = S - 2*stair_width, where S is
## the interior span. Solving run >= min_steps_per_leg * step_depth for S and
## adding the walls back gives the smallest usable outer size.
func suggest_size() -> float:
	var interior := stair_width * 2.0 + min_steps_per_leg * step_depth
	return interior + wall_thickness * 2.0


func _resolved_size() -> float:
	return size if size > 0.0 else suggest_size()


# ---------------------------------------------------------------------------
# REVEAL
# ---------------------------------------------------------------------------

func _process(_delta: float) -> void:
	var player: Node3D = Game.player
	if player == null or _slab_meshes.is_empty():
		return

	var inside := reveal_enabled and contains_point(player.global_position)
	var feet: float = player.global_position.y if inside else NO_CLIP

	if not is_equal_approx(feet, _last_feet):
		_last_feet = feet
		var upright_clip: float = (feet + head_room) if inside else NO_CLIP
		var slab_clip: float = (feet + ceiling_clearance) if inside else NO_CLIP
		for entry in _upright_meshes:
			entry["mesh"].set_instance_shader_parameter("clip_height", upright_clip)
		for entry in _slab_meshes:
			entry["mesh"].set_instance_shader_parameter("clip_height", slab_clip)

	# Camera rotation alone can flip which walls are "in the way" even when
	# the player hasn't moved, so this loop is not gated on height_moved.
	var view := _camera_forward()
	for entry in _wall_pieces:
		var clip := NO_CLIP
		if inside:
			var outward: Vector3 = global_transform.basis * entry["normal"]
			var near := outward.dot(view) >= near_wall_threshold
			clip = (feet + kneewall_height) if near else (feet + head_room)
		entry["mesh"].set_instance_shader_parameter("clip_height", clip)


func _camera_forward() -> Vector3:
	if Game.camera_rig == null:
		return Vector3.FORWARD
	return -Game.camera_rig.global_transform.basis.z


# ---------------------------------------------------------------------------
# BUILD
# ---------------------------------------------------------------------------

func build() -> void:
	for child in get_children():
		child.free()
	_wall_pieces.clear()
	_upright_meshes.clear()
	_slab_meshes.clear()

	var s := _resolved_size()
	var group := Node3D.new()
	group.name = "Tower"
	add_child(group)

	_build_walls(group, s)
	_build_ground_slab(group, s)
	var legs := _plan_legs(s)
	_build_stairs_and_landings(group, legs)
	_build_roof(group, s, legs[legs.size() - 1])

	_last_feet = NAN


## Ground floor is one solid slab spanning the whole footprint — the player
## steps onto it through the door and the first flight simply starts
## somewhere on top of it, the same reasoning as building.gd's level 0.
func _build_ground_slab(group: Node3D, s: float) -> void:
	var mesh := _add_box(group, "GroundSlab",
		Vector3(0.0, -floor_thickness * 0.5, 0.0),
		Vector3(s, floor_thickness, s), MAT_FLOOR, Layers.WORLD, 0.02)
	_slab_meshes.append({"mesh": mesh})


## The four corner landing points, in the order the spiral visits them.
##
## ORDER STARTS ON THE WEST WALL, NOT THE SOUTH (DOOR) WALL, ON PURPOSE. Leg 0
## is the only flight that starts at ground level (y=0) with nothing beneath
## it — every later visit to any given wall is a full storey or more higher,
## and a flight's own solid steps only exist from its own base upward (see
## [Stairs]), so nothing above ground floor ever blocks foot-level movement.
## Ground floor itself is a different story: putting leg 0 on the SAME wall as
## the door means its steps start filling that wall's band from x=0 outward at
## y=0 — precisely where someone walking in would need to stand. Starting on
## the west wall instead leaves the door's own wall clear at ground level, and
## the corner sequence still reaches the door wall (as leg 3, comfortably
## above door_height by the time it does — see verify_tower.gd) once there is
## nothing at head height to block.
func _corners(s: float) -> Array:
	var hi := s * 0.5 - wall_thickness
	var n := hi - stair_width * 0.5
	return [
		Vector2(-n, -n), Vector2(-n, n), Vector2(n, n), Vector2(n, -n),
	]


## Local yaw, in degrees, that turns a Stairs flight (which climbs its own
## local +Z) to climb tower-local +Z, +X, -Z or -X for dir 0..3 — matching
## [method _corners]' SW->NW->NE->SE order. Confirmed against Basis(UP, yaw)
## and compass.gd's world-axis convention with a headless probe before this
## was written (see get_towers' note in zone.gd on the door's own yaw).
const _LEG_YAW := [0.0, 90.0, 180.0, 270.0]


## Solves the square-helix layout: how many flights, how many steps each, and
## where each one starts and ends.
##
## TWO-PASS, because the exact climb has to land on [member height] but the
## number of flights depends on how tall each one nominally is. Pass one
## estimates the flight count using [member step_height] as authored (using
## the shorter, landing-bound run at every position — very slightly
## pessimistic for the first and last flight, which never costs more than one
## extra flight). Pass two lays out the real corner-to-corner geometry per
## flight (the first and last are longer, having only one landing to clear
## instead of two) and then rescales [member step_height] uniformly, by the
## smallest amount that makes the total exact — so the pitch stays the same
## from bottom to top and the platform still sits at precisely [member height].
func _plan_legs(s: float) -> Array:
	var corners := _corners(s)

	var nominal_run := (s - wall_thickness * 2.0) - stair_width * 2.0
	var nominal_steps := maxi(1, int(floor(nominal_run / step_depth)))
	var nominal_rise := nominal_steps * step_height
	var total_legs := maxi(4, int(ceil(height / nominal_rise)))

	var legs: Array = []
	var nominal_total_steps := 0
	for k in total_legs:
		var c0: Vector2 = corners[k % 4]
		var c1: Vector2 = corners[(k + 1) % 4]
		var dir_vec := (c1 - c0).normalized()
		var inset_start := 0.0 if k == 0 else stair_width * 0.5
		var inset_end := 0.0 if k == total_legs - 1 else stair_width * 0.5
		var start_pt := c0 + dir_vec * inset_start
		var end_pt := c1 - dir_vec * inset_end
		var run := (end_pt - start_pt).length()
		var steps := maxi(1, int(floor(run / step_depth)))
		# Centre the flight in its slack rather than leaving the leftover
		# (run - steps * step_depth, always under one step_depth) as a gap at
		# one end.
		var slack := (run - steps * step_depth) * 0.5
		start_pt += dir_vec * slack

		legs.append({
			"dir": k % 4, "dir_vec": dir_vec, "start": start_pt, "steps": steps,
			"corner_after": (k + 1) % 4,
		})
		nominal_total_steps += steps

	var solved_step_height := height / float(nominal_total_steps)
	var cum := 0.0
	for leg in legs:
		leg["step_height"] = solved_step_height
		leg["start_h"] = cum
		cum += leg["steps"] * solved_step_height
		leg["end_h"] = cum
	return legs


func _build_stairs_and_landings(group: Node3D, legs: Array) -> void:
	var total := legs.size()
	for i in total:
		var leg: Dictionary = legs[i]
		var flight: Stairs = STAIRS_SCRIPT.new()
		flight.name = "Flight%02d" % i
		flight.step_count = leg["steps"]
		flight.step_height = leg["step_height"]
		flight.step_depth = step_depth
		flight.width = stair_width
		flight.material = MAT_FLOOR
		var start: Vector2 = leg["start"]
		flight.position = Vector3(start.x, leg["start_h"], start.y)
		flight.rotation = Vector3(0.0, deg_to_rad(_LEG_YAW[leg["dir"]]), 0.0)
		group.add_child(flight)
		_collect_stair_meshes(flight)

		# A landing at the corner this flight climbs to, except the last —
		# the roof slab's stairwell opening covers that one instead, see
		# _build_roof.
		if i < total - 1:
			var c: Vector2 = _corners(_resolved_size())[leg["corner_after"]]
			var y: float = leg["end_h"]
			var mesh := _add_box(group, "Landing%02d" % i,
				Vector3(c.x, y - floor_thickness * 0.5, c.y),
				Vector3(stair_width, floor_thickness, stair_width), MAT_FLOOR, Layers.WORLD)
			_slab_meshes.append({"mesh": mesh})


func _collect_stair_meshes(node: Node) -> void:
	for child in node.get_children():
		if child is MeshInstance3D:
			child.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			_upright_meshes.append({"mesh": child})
		_collect_stair_meshes(child)


## The roof slab cannot be one solid square the way the ground slab is: it
## would hang at height - floor_thickness directly over the final flight's
## own approach, and floor_thickness (tens of centimetres) is nowhere near a
## person's height — the player would hit the underside of the roof and never
## reach the top. building.gd's floors solve this the same way, for the same
## reason (see its [method _build_floor]): a rectangular stairwell opening cut
## over the flight, with the slab built as four strips around the hole
## instead of one box over it. The hole spans the final flight's whole run,
## not just its top few steps — a climber's head clears the floor well before
## their feet reach the last tread.
func _build_roof(group: Node3D, s: float, last_leg: Dictionary) -> void:
	var hi := s * 0.5 - wall_thickness
	var start: Vector2 = last_leg["start"]
	var dir_vec: Vector2 = last_leg["dir_vec"]
	var run: float = last_leg["steps"] * step_depth
	var end: Vector2 = start + dir_vec * run
	var half_w := stair_width * 0.5

	var hole_x0: float
	var hole_x1: float
	var hole_z0: float
	var hole_z1: float
	if dir_vec.x != 0.0:
		hole_x0 = minf(start.x, end.x)
		hole_x1 = maxf(start.x, end.x)
		hole_z0 = start.y - half_w
		hole_z1 = start.y + half_w
	else:
		hole_z0 = minf(start.y, end.y)
		hole_z1 = maxf(start.y, end.y)
		hole_x0 = start.x - half_w
		hole_x1 = start.x + half_w

	var y := height
	_roof_slab(group, "RoofWest", y, -hi, hole_x0, -hi, hi)
	_roof_slab(group, "RoofEast", y, hole_x1, hi, -hi, hi)
	_roof_slab(group, "RoofSouth", y, hole_x0, hole_x1, -hi, hole_z0)
	_roof_slab(group, "RoofNorth", y, hole_x0, hole_x1, hole_z1, hi)

	if parapet_height <= 0.0:
		return
	var hs := s * 0.5
	var cy := height + parapet_height * 0.5
	var t := wall_thickness
	var pieces := [
		["ParapetSouth", Vector3(0.0, cy, -hs + t * 0.5), Vector3(s, parapet_height, t)],
		["ParapetNorth", Vector3(0.0, cy, hs - t * 0.5), Vector3(s, parapet_height, t)],
		["ParapetWest", Vector3(-hs + t * 0.5, cy, 0.0), Vector3(t, parapet_height, s - t * 2.0)],
		["ParapetEast", Vector3(hs - t * 0.5, cy, 0.0), Vector3(t, parapet_height, s - t * 2.0)],
	]
	for p in pieces:
		var m := _add_box(group, p[0], p[1], p[2], MAT_WALL, Layers.OBSTACLE)
		_upright_meshes.append({"mesh": m})


## One strip of the roof slab, spanning the given local rectangle with its
## top surface at [param y]. Degenerate strips (the hole flush against a
## wall) are skipped rather than emitting a zero-width sliver — same reasoning
## as building.gd's identical helper.
func _roof_slab(group: Node3D, node_name: String, y: float,
		x0: float, x1: float, z0: float, z1: float) -> void:
	if x1 - x0 <= 0.01 or z1 - z0 <= 0.01:
		return
	var mesh := _add_box(group, node_name,
		Vector3((x0 + x1) * 0.5, y - floor_thickness * 0.5, (z0 + z1) * 0.5),
		Vector3(x1 - x0, floor_thickness, z1 - z0), MAT_FLOOR, Layers.WORLD)
	_slab_meshes.append({"mesh": mesh})


## Door sits on local -Z, the same "front, before rotation" convention
## building.gd uses, so zone.gd can aim it with a plain yaw. North/South walls
## run the full outer length; East/West are shortened to butt against them —
## see building.gd's identical `end_span` note.
func _build_walls(group: Node3D, s: float) -> void:
	var hs := s * 0.5
	var inset := wall_thickness * 0.5

	var south_pieces := _door_wall_rects(s)
	for i in south_pieces.size():
		var r: Array = south_pieces[i]
		var centre := Vector3((r[0] + r[1]) * 0.5, (r[2] + r[3]) * 0.5, -hs + inset)
		var box := Vector3(r[1] - r[0], r[3] - r[2], wall_thickness)
		var m := _add_box(group, "WallSouth%d" % i, centre, box, MAT_WALL, Layers.OBSTACLE)
		_wall_pieces.append({"mesh": m, "normal": Vector3(0.0, 0.0, -1.0)})

	var north := _add_box(group, "WallNorth", Vector3(0.0, height * 0.5, hs - inset),
		Vector3(s, height, wall_thickness), MAT_WALL, Layers.OBSTACLE)
	_wall_pieces.append({"mesh": north, "normal": Vector3(0.0, 0.0, 1.0)})

	var end_span := s - wall_thickness * 2.0
	var west := _add_box(group, "WallWest", Vector3(-hs + inset, height * 0.5, 0.0),
		Vector3(wall_thickness, height, end_span), MAT_WALL, Layers.OBSTACLE)
	_wall_pieces.append({"mesh": west, "normal": Vector3(-1.0, 0.0, 0.0)})

	var east := _add_box(group, "WallEast", Vector3(hs - inset, height * 0.5, 0.0),
		Vector3(wall_thickness, height, end_span), MAT_WALL, Layers.OBSTACLE)
	_wall_pieces.append({"mesh": east, "normal": Vector3(1.0, 0.0, 0.0)})


## South wall sliced around the door: left jamb, right jamb, lintel above.
## Returns rects as [x_min, x_max, y_min, y_max] in Tower-local space.
func _door_wall_rects(s: float) -> Array:
	var hs := s * 0.5
	var hw := door_width * 0.5
	var rects: Array = [
		[-hs, -hw, 0.0, height],
		[hw, hs, 0.0, height],
	]
	if door_height < height - 0.001:
		rects.append([-hw, hw, door_height, height])
	return rects


func _add_box(parent: Node3D, node_name: String, centre: Vector3, box: Vector3,
		material: Material, layer: int, mesh_lift := 0.0) -> MeshInstance3D:
	var body := StaticBody3D.new()
	body.name = node_name
	body.collision_layer = layer
	body.collision_mask = 0
	body.position = centre
	parent.add_child(body)

	var mesh := MeshInstance3D.new()
	mesh.name = "Mesh"
	var box_mesh := BoxMesh.new()
	box_mesh.size = box
	mesh.mesh = box_mesh
	mesh.material_override = material
	mesh.position.y = mesh_lift
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	body.add_child(mesh)

	var collider := CollisionShape3D.new()
	collider.name = "Collider"
	var shape := BoxShape3D.new()
	shape.size = box
	collider.shape = shape
	body.add_child(collider)
	return mesh


func _set_size(value: float) -> void:
	size = maxf(value, 0.0)
	if is_inside_tree():
		build()


func _set_height(value: float) -> void:
	height = maxf(value, 4.0)
	if is_inside_tree():
		build()


func _set_wall_thickness(value: float) -> void:
	wall_thickness = maxf(value, 0.1)
	if is_inside_tree():
		build()


func _set_floor_thickness(value: float) -> void:
	floor_thickness = maxf(value, 0.05)
	if is_inside_tree():
		build()


func _set_parapet_height(value: float) -> void:
	parapet_height = maxf(value, 0.0)
	if is_inside_tree():
		build()


func _set_stair_width(value: float) -> void:
	stair_width = maxf(value, 0.6)
	if is_inside_tree():
		build()


func _set_step_depth(value: float) -> void:
	step_depth = maxf(value, 0.15)
	if is_inside_tree():
		build()


func _set_step_height(value: float) -> void:
	step_height = maxf(value, 0.05)
	if is_inside_tree():
		build()


func _set_min_steps_per_leg(value: int) -> void:
	min_steps_per_leg = maxi(value, 2)
	if is_inside_tree():
		build()


func _set_door_width(value: float) -> void:
	door_width = maxf(value, 0.5)
	if is_inside_tree():
		build()


func _set_door_height(value: float) -> void:
	door_height = maxf(value, 1.5)
	if is_inside_tree():
		build()
