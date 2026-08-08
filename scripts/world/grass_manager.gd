class_name GrassManager
extends Node3D

## Streams GrassField chunks in and out around the player, instead of placing
## a fixed set of meadow patches once at zone load.
##
## The map can be grassed wall-to-wall because at any moment only the chunks
## near the player actually exist as MultiMeshes — cost is bounded by what a
## player standing at that spot could possibly see, not by the size of the
## map. Building a chunk is also cheap now: it samples a [Heightfield]
## directly rather than firing a physics ray per blade, so the per-chunk cost
## that used to matter here is placement's smaller cousin — the multimesh
## assembly itself, not finding where to put anything.
##
## Chunks are square, not GrassField's default circular patch: a circle either
## leaves the corners of a grid cell bald, or (sized to cover them) overlaps
## and double-plants the band shared with its neighbour. A square tiles the
## grid exactly, with no seam and no doubled density at the boundary.
##
## THERE USED TO BE TWO DENSITY LAYERS PER CHUNK — a sparse one everywhere, a
## denser one only near the player, fading in over a second. That existed
## purely because placement meant raycasting, and raycasting was expensive
## enough that paying it for every loaded chunk at full density was the
## thing costing frame time. Once placement stopped raycasting (see
## grass_field.gd's heightfield-based path), the ENTIRE REASON THE SPLIT
## EXISTED WAS GONE — but the split stayed, and its inner boundary
## (detail_radius) sat well inside the range the grass shader itself keeps
## fully visible, so the map showed a plainly visible ring of half-density
## chunks arranged in a grid. That is where "big squares" in the field came
## from: not a bug in placement, a boundary between two densities that had
## stopped needing to exist. Every chunk is single-density again; that
## boundary cannot show because there is nothing on either side of it to
## differ.

const GRASS_SCRIPT := preload("res://scripts/terrain/grass_field.gd")

@export_group("Grid")
## Side length of one chunk, in world units. An implementation detail, not a
## visual tuning knob — changing it reshuffles where chunk boundaries fall
## but should not change what the result looks like.
@export var chunk_size := 20.0
## Distance from the player at which a chunk starts loading. Sized to clear
## everything the isometric camera can show at a bit past the default zoom
## (camera_rig.gd: distance 20, pitch -45, fov 45 puts the far edge of the
## view roughly 30-35 units out at default zoom), in any direction the player
## rotates the camera to — padded well past that so nothing pops in mid-frame
## even zoomed out further.
@export var load_radius := 50.0
## Distance at which a loaded chunk is freed entirely. Kept a full chunk_size
## or more above load_radius so a player standing near the boundary, drifting
## a step back and forth, cannot thrash a chunk in and out repeatedly.
@export var unload_radius := 70.0
## How often to re-scan which chunks should be loaded/freed. The player moves
## slowly relative to chunk_size, so there is no need to check every frame.
@export var check_interval := 0.25
## Coarse guard: if the player is somehow this far from the origin, stop
## considering new chunks rather than reaching for terrain that isn't there.
##
## The heightfield is arithmetic and has no edge (see heightfield.gd) — ground,
## and therefore grass, is meant to generate as far as the player walks. This
## is only a sanity fallback against a wildly out-of-bounds position, so it is
## set far past anywhere a player can actually reach rather than at a distance
## that reads as a map boundary. terrain_manager.gd's equivalent guard is off
## by default for the same reason; this one stays a (very large) number rather
## than switching to that same "0 disables it" convention only to avoid
## touching _rescan's comparison below.
@export var map_half_extent := 100000.0
## At most this many chunks may be actively building at once. Each one
## already spreads its own work across frames (see grass_field.gd's
## samples_per_batch) — this caps how many of those batches can land in the
## same frame, so total per-frame cost stays bounded no matter how full the
## queue is.
@export var max_concurrent_builds := 2

@export_group("Grass")
## Where the ground is. Passed to every chunk so blades are placed by asking
## the heightfield rather than by firing a physics ray each — which matters
## more than speed now that terrain is streamed too: a ray can only find
## ground that has already been built, and a chunk unlucky enough to plant
## itself before its terrain tile arrived would come out bald and never know.
@export var heightfield: Heightfield = null
## World-space XZ rectangles where no grass grows — building footprints,
## mostly. See GrassField.exclusions.
@export var exclusions: Array = []
## Blades per square metre, uniform across every loaded chunk.
@export var density := 30.0
## Safety ceiling per chunk, same purpose as GrassField's own max_blades — it
## should sit comfortably above chunk_size * chunk_size * density (with the
## defaults above, 20 * 20 * 30 = 12000) so it only ever bites if chunk_size
## or density are changed to something unreasonable, not on every chunk.
@export var max_blades_per_chunk := 50000
@export var blade_height := 0.32
@export var blade_width := 0.05
@export var blade_segments := 4
@export var blade_droop := 0.16
@export var height_variation := 0.4
@export var max_slope_degrees := 30.0
@export var seed := 20240
@export var material: Material = null

## Vector2i cell -> GrassField.
var _active: Dictionary = {}
## Vector2i cell -> true while that chunk is queued or building. While true it
## is neither re-queued nor freed, so a build never has the ground pulled out
## from under its own in-flight await.
var _pending: Dictionary = {}
## Array of Vector2i, FIFO.
var _build_queue: Array = []
var _building := 0
var _timer := 0.0


func _process(delta: float) -> void:
	_timer += delta
	if _timer >= check_interval:
		_timer = 0.0
		_rescan()
	_drain_build_queue()


## Queues newly-in-range chunks and frees whole chunks that drifted well out
## of range.
func _rescan() -> void:
	if Game.player == null:
		return
	var p := Game.player.global_position
	if absf(p.x) > map_half_extent or absf(p.z) > map_half_extent:
		return
	var player_xz := Vector2(p.x, p.z)
	# Half the chunk's diagonal, so range checks are against the nearest
	# corner of a chunk rather than its centre — a chunk whose centre is just
	# past a radius can still have a corner inside it.
	var half_diag := chunk_size * 0.7072

	_queue_new_chunks(player_xz, half_diag)
	_free_out_of_range_chunks(player_xz, half_diag)


func _queue_new_chunks(player_xz: Vector2, half_diag: float) -> void:
	var p := player_xz
	var cell_min_x := int(floor((p.x - load_radius) / chunk_size))
	var cell_max_x := int(floor((p.x + load_radius) / chunk_size))
	var cell_min_z := int(floor((p.y - load_radius) / chunk_size))
	var cell_max_z := int(floor((p.y + load_radius) / chunk_size))

	for cx in range(cell_min_x, cell_max_x + 1):
		for cz in range(cell_min_z, cell_max_z + 1):
			var cell := Vector2i(cx, cz)
			if _active.has(cell) or _pending.has(cell):
				continue
			if p.distance_to(_cell_center(cell)) - half_diag > load_radius:
				continue
			_pending[cell] = true
			_build_queue.append(cell)


func _free_out_of_range_chunks(player_xz: Vector2, half_diag: float) -> void:
	var to_free: Array = []
	for cell in _active.keys():
		if player_xz.distance_to(_cell_center(cell)) - half_diag > unload_radius:
			to_free.append(cell)
	for cell in to_free:
		var field: GrassField = _active[cell]
		_active.erase(cell)
		field.queue_free()


func _drain_build_queue() -> void:
	while _building < max_concurrent_builds and not _build_queue.is_empty():
		var cell: Vector2i = _build_queue.pop_front()
		# The chunk may have been freed between being queued and being reached.
		if not _pending.has(cell):
			continue
		_spawn(cell)


func _spawn(cell: Vector2i) -> void:
	var field: GrassField = GRASS_SCRIPT.new()
	field.heightfield = heightfield
	field.exclusions = exclusions
	field.square_size = chunk_size
	field.density = density
	field.max_blades = max_blades_per_chunk
	field.blade_height = blade_height
	field.blade_width = blade_width
	field.blade_segments = blade_segments
	field.blade_droop = blade_droop
	field.height_variation = height_variation
	field.max_slope_degrees = max_slope_degrees
	field.seed = seed ^ (cell.x * 92821) ^ (cell.y * 68917)
	field.name = "Chunk_%d_%d" % [cell.x, cell.y]
	field.material = material
	var center := _cell_center(cell)
	field.position = Vector3(center.x, 0.0, center.y)

	_building += 1
	field.built.connect(_on_built.bind(cell))
	add_child(field)
	_active[cell] = field


func _on_built(cell: Vector2i) -> void:
	_building = maxi(_building - 1, 0)
	_pending.erase(cell)


func _cell_center(cell: Vector2i) -> Vector2:
	return Vector2((cell.x + 0.5) * chunk_size, (cell.y + 0.5) * chunk_size)
