@tool
class_name Building
extends Node3D

## A parametric multi-storey stone building with internal stairs.
##
## Everything is generated from the exported numbers below — floors, walls with
## door and window openings, the staircases and the roof. There is no modelling
## involved and nothing is stored in the scene file, so changing the number of
## storeys is changing one number.
##
## THE INTERESTING PART IS THE REVEAL. A solid building is opaque to a camera
## looking down at 45 degrees: walk inside and you would see a roof. So while
## the player is inside, two things happen:
##
##   * a horizontal CLIP PLANE follows their height and the stone shader
##     discards every fragment above it, and
##   * the walls whose outer face is turned toward the camera are hidden.
##
## The clip plane is the important one. It follows the player's actual height,
## so a building opens up *continuously* as they climb — the walls of the floor
## above come into view a little at a time while they are still on the stairs,
## instead of a whole storey appearing at the moment they reach the top.
## Storey-at-a-time visibility was the first attempt here and it read badly:
## you spent a flight of stairs climbing toward nothing.
##
## THERE ARE TWO PLANES, because upright and horizontal surfaces want opposite
## things. Uprights — walls, stair blocks — are cut [member head_room] above
## the player, high enough to show the flight ahead and the room being climbed
## toward. Ceilings cannot use that height: a metre up a staircase the plane
## has already risen past the floor slab above, which then draws straight over
## the player and buries them. So slabs are cut a hand's breadth above the feet
## instead ([member ceiling_clearance]), which means the one you are standing
## on shows and anything overhead does not, at every point of a climb.
##
## It clips rather than fades on purpose. An alpha fade means overlapping
## walls, floors and stair treads sorting against each other, which goes wrong
## in exactly the stairwells this is meant to reveal, and it costs shadows too.
## A hard cut has neither problem and reads perfectly clearly.
##
## THE BUILDING DOES NOT CAST SHADOWS ON ITSELF, and this is not optional. The
## clip is a per-fragment discard in the stone shader; the mesh handed to the
## shadow pass is the full, uncut box regardless. Left alone that causes two
## distinct-looking bugs that are actually the same bug: a hard, invisible edge
## in the shadow map exactly at the clip seam produces streaky self-shadow
## acne there (and it visibly crawls, because the seam height is recalculated
## from the player's feet every frame), and a kneewalled or fully hidden wall
## still throws its full, uncut shadow — a shadow with no visible object
## causing it, which is precisely the kind of thing that breaks the cutaway
## illusion. Every mesh this script creates has [member GeometryInstance3D.
## cast_shadow] turned off for exactly this reason. Trees, props and the player
## are unaffected and still cast and receive normally; only the building stops
## shadowing itself.
##
## THE HEIGHT CLIP IS GATED BY STOREY, and this matters more than it looks.
## A single global "feet + head_room" number, applied to every upright mesh
## with no other limit, reveals geometry it has no business revealing:
## head_room is deliberately larger than one storey (so the flight you are
## standing at the foot of is not sliced at the knees), which means very early
## in the *first* flight the raw number is already tall enough to poke into the
## *second* storey's walls — they fade in from the bottom with no floor under
## them yet, because that floor is gated by the tight ceiling plane and has not
## arrived. The fix is to decouple "how far can this storey grow in" from
## "is this storey allowed to be visible at all": [method _storey_of] tags
## every mesh, and only the player's current storey and the one immediately
## above it are ever eligible for the continuous clip. Anything further away is
## simply off, with no partial state to look wrong.
##
## NEAR WALLS ARE CUT TO A LOW KNEEWALL, not hidden outright. A wall that is
## just gone reads as a bug and hides the doorway along with itself, since the
## doorway has no geometry of its own to show — it is only visible as a *gap*
## in the wall around it. Cutting the near wall down to [member kneewall_height]
## keeps that gap legible while still reading as a building, which is the
## approach isometric RPGs and The Sims use for interior cutaways generally.
##
## The clip plane does not fix flights stacking on top of each other — that is
## a layout problem, and [method _flight_side] is what fixes it.

const STAIRS_SCRIPT := preload("res://scripts/terrain/stairs.gd")
const MAT_WALL := preload("res://resources/materials/stone_wall.tres")
const MAT_FLOOR := preload("res://resources/materials/stone_floor.tres")

@export_group("Shape")
## Footprint, in metres. X by Z.
@export var size := Vector2(16.0, 12.0): set = _set_size
## How many walkable storeys. The roof sits above the topmost one.
@export_range(1, 8, 1) var levels := 3: set = _set_levels
@export_range(2.0, 8.0, 0.1) var level_height := 3.2: set = _set_level_height
@export_range(0.1, 1.5, 0.05) var wall_thickness := 0.4
@export_range(0.1, 1.0, 0.05) var floor_thickness := 0.3
## Low wall around the roof. Mostly so the silhouette reads as a building.
@export_range(0.0, 2.0, 0.1) var parapet_height := 0.8

@export_group("Openings")
@export_range(1.0, 6.0, 0.1) var door_width := 2.4
@export_range(1.8, 5.0, 0.1) var door_height := 2.6
@export_range(0.5, 4.0, 0.1) var window_width := 1.6
@export_range(0.5, 3.0, 0.1) var window_height := 1.5
## Height of the bottom of a window above its own floor.
@export_range(0.0, 3.0, 0.1) var window_sill := 1.2

@export_group("Stairs")
## Steps per flight. Rise per step works out as level_height / this.
@export_range(4, 30, 1) var stair_steps := 10
@export_range(0.2, 1.0, 0.05) var stair_going := 0.45
@export_range(1.0, 6.0, 0.1) var stair_width := 3.0
## Clear floor in front of the bottom step. This is not cosmetic: the collision
## ramp is a solid wedge, so if the foot is flush against a wall there is
## nowhere to stand to walk onto it, and the flight can only be mounted from
## the side. Leave room to approach it head-on.
@export_range(0.0, 8.0, 0.1) var stair_approach := 2.5
## How far off centre each flight sits. Successive flights alternate sides, so
## this is half the distance between them — see [method _flight_side].
@export_range(0.0, 12.0, 0.1) var stair_offset := 3.0

@export_group("Reveal")
## Turn the cutaway off to see the building as solid geometry.
@export var reveal_enabled := true
## Where the clip plane sits above the player's feet, for walls and stairs.
## Wants to be a little more than [member level_height]: that way the whole of
## the flight you are standing at the bottom of is visible, rather than its top
## few steps being sliced off, and the storey above shows as a growing band of
## wall as you climb toward it. It cannot lift a ceiling into view — slabs are
## on the other plane — so there is no penalty for being generous.
@export_range(0.5, 12.0, 0.1) var head_room := 3.5
## The same, for floor slabs. Must stay well under [member level_height] or a
## ceiling starts drawing over the player as they climb toward it. Just enough
## to keep the slab underfoot is the right amount.
@export_range(0.02, 1.0, 0.01) var ceiling_clearance := 0.15
## Below this dot product between a wall's outward face and the camera's view
## direction, the wall counts as being in the way and is cut to a kneewall
## instead of standing full height.
@export_range(-1.0, 0.0, 0.05) var near_wall_threshold := -0.2
## Height of the stub a near wall is cut down to. Tall enough to still read as
## a wall, short enough to see over — and low enough that it never obscures a
## door or window opening, since those already have no geometry to cut.
@export_range(0.2, 2.0, 0.05) var kneewall_height := 1.0

## Far enough above anything to mean "not clipped at all".
const NO_CLIP := 100000.0
## Far enough below anything to mean "clipped away entirely".
const HIDDEN := -100000.0

## One Node3D per storey, plus one more for the roof. Organisation only — the
## reveal works on the clip planes, not on per-storey visibility.
var _groups: Array[Node3D] = []
## Exterior wall pieces: mesh, the storey they belong to, and the local-space
## direction their outer face points (for the near/far camera test).
var _wall_pieces: Array = []
## Other uprights that are not stairs (currently just the roof parapet): mesh
## plus the storey they belong to. Uses the same "current + next storey"
## eligibility as walls, for the same room-preview effect.
var _upright_meshes: Array = []
## Stair treads: mesh plus the storey the flight leaves from. These get their
## own, *tighter* eligibility than every other upright — see the note in
## [method _stair_clip] for why walls can get away with previewing a storey
## early and a flight of stairs cannot.
var _stair_meshes: Array = []
## Floor slabs: mesh plus the storey they belong to. The roof slab counts as
## storey [member levels], i.e. one above the top floor, so it is gated the
## same way any other ceiling is.
var _slab_meshes: Array = []
var _last_feet := NAN
var _last_here := -1


func _ready() -> void:
	build()
	set_process(not Engine.is_editor_hint())


# ---------------------------------------------------------------------------
# QUERIES
# ---------------------------------------------------------------------------

## Total height to the top of the roof slab.
func get_height() -> float:
	return levels * level_height


## Whether a world point is within the building's footprint and height.
func contains_point(world_point: Vector3) -> bool:
	var p := to_local(world_point)
	return (absf(p.x) <= size.x * 0.5
		and absf(p.z) <= size.y * 0.5
		and p.y > -1.0
		and p.y < get_height() + 1.0)


# ---------------------------------------------------------------------------
# REVEAL
# ---------------------------------------------------------------------------

func _process(_delta: float) -> void:
	var player: Node3D = Game.player
	if player == null or _slab_meshes.is_empty():
		return

	var inside := reveal_enabled and contains_point(player.global_position)
	var feet: float = player.global_position.y if inside else NO_CLIP
	var here := _storey_of(to_local(player.global_position).y) if inside else -1

	# Skip the whole pass if nothing that would change an outcome has moved.
	# Camera rotation alone still needs a pass (near/far walls can flip), so
	# this only guards the height-driven arithmetic, not the wall loop below.
	var height_moved := not is_equal_approx(feet, _last_feet)
	_last_feet = feet
	_last_here = here

	if height_moved:
		for entry in _upright_meshes:
			entry["mesh"].set_instance_shader_parameter(
				"clip_height", _upright_clip(entry["storey"], here, feet))
		for entry in _stair_meshes:
			entry["mesh"].set_instance_shader_parameter(
				"clip_height", _stair_clip(entry["storey"], here, feet))
		for entry in _slab_meshes:
			entry["mesh"].set_instance_shader_parameter(
				"clip_height", _slab_clip(entry["storey"], here, feet))

	var view := _camera_forward()
	for entry in _wall_pieces:
		var near := false
		if inside:
			var outward: Vector3 = global_transform.basis * entry["normal"]
			near = outward.dot(view) >= near_wall_threshold
		entry["mesh"].set_instance_shader_parameter(
			"clip_height", _wall_clip(entry["storey"], here, feet, near))


## Which storey a *local* Y coordinate sits on, clamped into range. Used only
## to decide what is eligible to be revealed — the actual clip height passed to
## the shader is still the continuous foot position, not this integer.
func _storey_of(local_y: float) -> int:
	return clampi(int(floor(local_y / level_height)), 0, levels - 1)


## True if a piece belonging to [param storey] is allowed to be revealed at all
## while the player is on storey [param here] (always >= 0 by the time this is
## called — the -1 "outside" sentinel is handled by the callers before this).
## Only the player's own storey and the one directly above it qualify —
## anything higher stays off completely, no matter what the continuous
## formulas below would otherwise compute, which is what stops a distant
## storey fading in with nothing underneath it.
func _storey_eligible(storey: int, here: int) -> bool:
	return storey <= here + 1


func _upright_clip(storey: int, here: int, feet: float) -> float:
	if here < 0:
		return NO_CLIP
	if not _storey_eligible(storey, here):
		return HIDDEN
	return feet + head_room


## A flight leaving storey [param storey] is eligible only once the player has
## actually reached that storey (`here >= storey`) — one storey tighter than
## walls, which allow a one-storey-early preview.
##
## The two cannot share a rule. A wall previewed early is still grounded: its
## bottom edge sits at the true floor height whether or not that floor's own
## slab has faded in yet, so a partial reveal just reads as a shorter wall. A
## staircase previewed early is not grounded — its tread geometry only exists
## between the storey it leaves and the one it lands on, so revealing its
## lower portion before the player has reached its own base storey shows steps
## with no floor under them at all, which is exactly the "hanging in nowhere"
## artifact reported: [method _upright_clip]'s looser bound let the *next*
## flight up start fading in while still climbing the *current* one.
func _stair_clip(storey: int, here: int, feet: float) -> float:
	if here < 0:
		return NO_CLIP
	if storey > here:
		return HIDDEN
	return feet + head_room


func _slab_clip(storey: int, here: int, feet: float) -> float:
	if here < 0:
		return NO_CLIP
	if not _storey_eligible(storey, here):
		return HIDDEN
	return feet + ceiling_clearance


## Exterior walls behave like other uprights when they are not in the way of
## the camera. When they are, they are not hidden — cut to a fixed, storey-
## relative kneewall height instead, so the wall still reads and any door or
## window opening in it stays visible as a gap in the stub.
func _wall_clip(storey: int, here: int, feet: float, near: bool) -> float:
	if here < 0:
		return NO_CLIP
	if not _storey_eligible(storey, here):
		return HIDDEN
	if near:
		return storey * level_height + kneewall_height
	return feet + head_room


## Direction the camera looks, pointing away from it into the scene.
func _camera_forward() -> Vector3:
	if Game.camera_rig == null:
		return Vector3.FORWARD
	# The rig sits on the subject and pushes the camera back along its own +Z,
	# so the rig's -Z is the view direction.
	return -Game.camera_rig.global_transform.basis.z


# ---------------------------------------------------------------------------
# BUILD
# ---------------------------------------------------------------------------

func build() -> void:
	for child in get_children():
		child.free()
	_groups.clear()
	_wall_pieces.clear()
	_upright_meshes.clear()
	_stair_meshes.clear()
	_slab_meshes.clear()

	for i in levels:
		var group := Node3D.new()
		group.name = "Level%d" % i
		add_child(group)
		_groups.append(group)

	var roof := Node3D.new()
	roof.name = "Roof"
	add_child(roof)
	_groups.append(roof)

	for i in levels:
		_build_floor(_groups[i], i)
		_build_walls(_groups[i], i)
		if i < levels - 1:
			_build_stairs(_groups[i], i)
	_build_roof(roof)

	_last_feet = NAN
	_last_here = -1


## Stair treads are made by stairs.gd rather than by [method _add_box], so they
## are gathered afterwards by walking the flight. [param storey] is the level
## the flight leaves from: tagging it that way means the flight becomes
## eligible the moment the player reaches its foot (here == storey), and stays
## visible for the whole climb, since `here` does not advance to the next
## storey until the player's feet actually cross into it.
func _collect_stair_meshes(node: Node, storey: int) -> void:
	for child in node.get_children():
		if child is MeshInstance3D:
			# Same reasoning as _add_box: this mesh gets clipped in the
			# fragment shader, so it must not cast its own, uncut shadow.
			child.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			_stair_meshes.append({"mesh": child, "storey": storey})
		_collect_stair_meshes(child, storey)


## Which side of the building the flight leaving storey [param level] sits on.
##
## Successive flights alternate. If they all sat in the same place they would
## stack: the head of the flight up from storey 1 would land exactly where you
## step off the flight up from storey 0, so arriving on a landing would put you
## nose-first against a three-metre block of stone, with the way back down
## hidden behind it. Alternating gives every flight its own stairwell, its own
## clear landing, and a plain view back down the one you came up.
func _flight_side(level: int) -> float:
	return -stair_offset if level % 2 == 0 else stair_offset


## The stairwell opening for the flight leaving [param level], in local XZ as
## [x_min, x_max, z_min, z_max].
##
## The flight climbs east, starting [member stair_approach] clear of the west
## wall. The opening covers the whole flight: a climber's head rises above the
## upper floor about a third of the way up, so an opening that only covered the
## top would clip them.
func _stairwell(level: int) -> Array:
	var foot := -size.x * 0.5 + wall_thickness + stair_approach
	var run := stair_steps * stair_going
	var z := _flight_side(level)
	return [foot, foot + run, z - stair_width * 0.5, z + stair_width * 0.5]


## Floors are laid as four strips around the stairwell rather than as one slab
## with a hole, which keeps every piece a plain box. The climber steps off the
## head of the flight onto the east strip; the west strip is reached by walking
## around the opening on either side.
func _build_floor(group: Node3D, level: int) -> void:
	var y := level * level_height
	var hx := size.x * 0.5
	var hz := size.y * 0.5

	if level == 0:
		# Ground floor is solid: the stairs up from it stand on top of it.
		#
		# Its surface is exactly level with the terrain it sits on, which means
		# the two are coplanar and the ground wins the depth fight. Lifting the
		# *mesh* a couple of centimetres settles that; the collider stays flush,
		# so there is no lip at the doorway for the player to catch on.
		_add_box(group, "Slab", level, Vector3(0.0, y - floor_thickness * 0.5, 0.0),
			Vector3(size.x, floor_thickness, size.y), MAT_FLOOR, Layers.WORLD,
			0.02, true)
		return

	# Inset to the wall's inner face rather than the building's outer edge.
	# The wall below stands on the full perimeter band out to that outer edge,
	# so a slab reaching the same distance would have its top face exactly
	# coplanar with, and overlapping, the top of the wall beneath it — two
	# opaque surfaces fighting for the same depth, which is what caused the
	# flickering line at every floor level. Stopping the slab at the wall's
	# inner face removes the overlap entirely; the visible ring at that height
	# is then just the wall's own cap, not a second, differently-coloured slab
	# edge poking out from under it.
	var ix := hx - wall_thickness
	var iz := hz - wall_thickness
	var hole := _stairwell(level - 1)
	_add_slab(group, "SlabWest", level, y, -ix, hole[0], -iz, iz)
	_add_slab(group, "SlabEast", level, y, hole[1], ix, -iz, iz)
	_add_slab(group, "SlabSouth", level, y, hole[0], hole[1], -iz, hole[2])
	_add_slab(group, "SlabNorth", level, y, hole[0], hole[1], hole[3], iz)


## Adds one floor strip spanning the given local rectangle, with its walking
## surface at [param y]. Degenerate strips are skipped so the stairwell can sit
## flush against an edge without producing zero-width slivers.
func _add_slab(group: Node3D, node_name: String, level: int, y: float,
		x0: float, x1: float, z0: float, z1: float) -> void:
	if x1 - x0 <= 0.01 or z1 - z0 <= 0.01:
		return
	_add_box(group, node_name, level,
		Vector3((x0 + x1) * 0.5, y - floor_thickness * 0.5, (z0 + z1) * 0.5),
		Vector3(x1 - x0, floor_thickness, z1 - z0), MAT_FLOOR, Layers.WORLD,
		0.0, true)


func _build_walls(group: Node3D, level: int) -> void:
	var y := level * level_height
	var hx := size.x * 0.5
	var hz := size.y * 0.5
	var inset := wall_thickness * 0.5
	var long_offset := size.x * 0.28

	# The front door replaces the windows on the ground floor's south wall.
	var south_openings: Array = []
	if level == 0:
		south_openings = [_opening(0.0, door_width, 0.0, door_height)]
	else:
		south_openings = [_window(-long_offset), _window(long_offset)]

	_wall(group, level, "WallSouth", Vector3(0.0, y, -hz + inset), true, size.x,
		Vector3(0.0, 0.0, -1.0), south_openings)
	_wall(group, level, "WallNorth", Vector3(0.0, y, hz - inset), true, size.x,
		Vector3(0.0, 0.0, 1.0), [_window(-long_offset), _window(long_offset)])

	# The end walls butt against the long ones, hence the shortened span.
	var end_span := size.y - wall_thickness * 2.0
	_wall(group, level, "WallWest", Vector3(-hx + inset, y, 0.0), false, end_span,
		Vector3(-1.0, 0.0, 0.0), [_window(0.0)])
	_wall(group, level, "WallEast", Vector3(hx - inset, y, 0.0), false, end_span,
		Vector3(1.0, 0.0, 0.0), [_window(0.0)])


func _build_stairs(group: Node3D, level: int) -> void:
	var flight: Stairs = STAIRS_SCRIPT.new()
	flight.name = "Stairs%d" % level
	flight.step_count = stair_steps
	flight.step_height = level_height / float(stair_steps)
	flight.step_depth = stair_going
	flight.width = stair_width
	flight.material = MAT_FLOOR
	# Stairs climb toward their own +Z, so a quarter turn aims them east. They
	# start at the foot of the stairwell opening, not at the wall.
	flight.position = Vector3(_stairwell(level)[0], level * level_height,
		_flight_side(level))
	flight.rotation = Vector3(0.0, deg_to_rad(90.0), 0.0)
	group.add_child(flight)
	_collect_stair_meshes(flight, level)


func _build_roof(group: Node3D) -> void:
	var y := get_height()
	# The roof slab is the ceiling of the top floor, so it is tagged one storey
	# above it — the same "current + 1" gate that governs every other ceiling.
	# Inset the same way as every other ceiling slab — see the note in
	# _build_floor — so it does not overlap the top storey's wall cap.
	_add_box(group, "RoofSlab", levels, Vector3(0.0, y - floor_thickness * 0.5, 0.0),
		Vector3(size.x - wall_thickness * 2.0, floor_thickness, size.y - wall_thickness * 2.0),
		MAT_FLOOR, Layers.WORLD, 0.0, true)
	if parapet_height <= 0.0:
		return
	var hx := size.x * 0.5
	var hz := size.y * 0.5
	var cy := y + parapet_height * 0.5
	var t := wall_thickness
	_add_box(group, "ParapetSouth", levels, Vector3(0.0, cy, -hz + t * 0.5),
		Vector3(size.x, parapet_height, t), MAT_WALL, Layers.OBSTACLE)
	_add_box(group, "ParapetNorth", levels, Vector3(0.0, cy, hz - t * 0.5),
		Vector3(size.x, parapet_height, t), MAT_WALL, Layers.OBSTACLE)
	_add_box(group, "ParapetWest", levels, Vector3(-hx + t * 0.5, cy, 0.0),
		Vector3(t, parapet_height, size.y - t * 2.0), MAT_WALL, Layers.OBSTACLE)
	_add_box(group, "ParapetEast", levels, Vector3(hx - t * 0.5, cy, 0.0),
		Vector3(t, parapet_height, size.y - t * 2.0), MAT_WALL, Layers.OBSTACLE)


# ---------------------------------------------------------------------------
# PIECES
# ---------------------------------------------------------------------------

func _window(offset: float) -> Dictionary:
	return _opening(offset, window_width, window_sill, window_height)


func _opening(offset: float, width: float, sill: float, height: float) -> Dictionary:
	return {"offset": offset, "width": width, "sill": sill, "height": height}


## Builds one wall as a run of boxes with gaps left for the openings.
##
## [param along_x] picks whether the wall runs along X or Z; [param base] is the
## midpoint of its foot; [param outward] is the direction its outer face points,
## which is what the reveal test uses.
func _wall(group: Node3D, level: int, name_prefix: String, base: Vector3,
		along_x: bool, length: float, outward: Vector3, openings: Array) -> void:
	var index := 0
	for r in _wall_rects(length, level_height, openings):
		var along_centre: float = (r[0] + r[1]) * 0.5
		var along_size: float = r[1] - r[0]
		var y_centre: float = base.y + (r[2] + r[3]) * 0.5
		var y_size: float = r[3] - r[2]

		var centre: Vector3
		var box: Vector3
		if along_x:
			centre = Vector3(along_centre, y_centre, base.z)
			box = Vector3(along_size, y_size, wall_thickness)
		else:
			centre = Vector3(base.x, y_centre, along_centre)
			box = Vector3(wall_thickness, y_size, along_size)

		var body := _add_box(group, "%s%d" % [name_prefix, index], level, centre,
			box, MAT_WALL, Layers.OBSTACLE, 0.0, false, false)
		var mesh: MeshInstance3D = body.get_node("Mesh")
		_wall_pieces.append({"mesh": mesh, "normal": outward, "storey": level})
		index += 1


## Slices a wall of [param length] x [param height] into solid rectangles,
## leaving the openings empty. Each opening contributes a sill below it and a
## lintel above, where those have any height.
##
## Returns rectangles as [along_min, along_max, y_min, y_max], with `along`
## measured from the centre of the wall.
func _wall_rects(length: float, height: float, openings: Array) -> Array:
	var rects: Array = []
	var ordered := openings.duplicate()
	ordered.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["offset"] < b["offset"])

	var cursor := -length * 0.5
	for o in ordered:
		var o0: float = o["offset"] - o["width"] * 0.5
		var o1: float = o["offset"] + o["width"] * 0.5
		if o0 > cursor + 0.001:
			rects.append([cursor, o0, 0.0, height])
		if o["sill"] > 0.001:
			rects.append([o0, o1, 0.0, o["sill"]])
		var top: float = o["sill"] + o["height"]
		if top < height - 0.001:
			rects.append([o0, o1, top, height])
		cursor = maxf(cursor, o1)
	if cursor < length * 0.5 - 0.001:
		rects.append([cursor, length * 0.5, 0.0, height])
	return rects


## Creates one collidable box, tagged with the storey it belongs to for the
## reveal to gate on. [param mesh_lift] nudges only the visual up, for surfaces
## that would otherwise be coplanar with something else. [param horizontal]
## routes the piece to the ceiling clip plane rather than the upright one.
## [param route], when false, skips the automatic bookkeeping — used only by
## exterior walls, which need the extra `normal` field and so register
## themselves into [member _wall_pieces] instead.
func _add_box(parent: Node3D, node_name: String, level: int, centre: Vector3,
		box: Vector3, material: Material, layer: int, mesh_lift := 0.0,
		horizontal := false, route := true) -> StaticBody3D:
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
	# The clip is a fragment-shader discard; the shadow pass would otherwise
	# use this box at full, uncut size. See the class doc for why that matters.
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	body.add_child(mesh)
	if route:
		var entry := {"mesh": mesh, "storey": level}
		if horizontal:
			_slab_meshes.append(entry)
		else:
			_upright_meshes.append(entry)

	var collider := CollisionShape3D.new()
	collider.name = "Collider"
	var shape := BoxShape3D.new()
	shape.size = box
	collider.shape = shape
	body.add_child(collider)
	return body


func _set_size(value: Vector2) -> void:
	size = Vector2(maxf(value.x, 4.0), maxf(value.y, 4.0))
	if is_inside_tree():
		build()


func _set_levels(value: int) -> void:
	levels = maxi(value, 1)
	if is_inside_tree():
		build()


func _set_level_height(value: float) -> void:
	level_height = maxf(value, 2.0)
	if is_inside_tree():
		build()
