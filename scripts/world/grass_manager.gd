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
## Distance from the CAMERA at which a chunk starts loading, AT THE DEFAULT
## ZOOM. The radius actually used grows with the camera's current zoom — see
## [member radius_per_distance] — because this alone only covers one specific
## framing. Left as a floor rather than replaced outright so close-up framing
## (inspect mode, a very tight zoom) still gets a sensible minimum patch.
@export var load_radius := 80.0
## Distance at which a loaded chunk is freed entirely, at the default zoom —
## same floor-not-replacement relationship to the effective radius as
## [member load_radius]. Kept a full chunk_size or more above it so a player
## standing near the boundary, drifting a step back and forth, cannot thrash a
## chunk in and out repeatedly; that gap is preserved at every zoom level, not
## just the default one — see [method _effective_radii].
@export var unload_radius := 70.0
## World units the load radius grows per unit of camera zoom distance beyond
## the default. Without this, load_radius is only actually sized for ONE
## specific zoom level: zoomed further out, the visible ground footprint grows
## roughly with camera distance but the grass patch does not, so it shrinks to
## a disc that no longer reaches the edges of the screen. Because ground near
## the camera fills proportionally more of the screen than ground toward the
## horizon (ordinary perspective foreshortening), an undersized disc centred
## on the player does not read as "a small circle" — it reads as a wedge
## anchored near the bottom of the screen and tapering toward the player,
## which is exactly the "triangle of grass" artifact this exists to prevent.
## Same fix, same reasoning, as rain.gd's box_size_per_distance.
@export var radius_per_distance := 2.5
## Hard ceiling on the effective radius, however far radius_per_distance would
## otherwise stretch it at extreme zoom-out. Actual blade geometry stops being
## worth its cost well before that: a grass blade is a few centimetres wide,
## so past a fairly modest distance it is already thinner than a pixel and
## reads as aliasing, not detail — no amount of radius fixes that, only more
## flicker. ground_meadow.gdshader's turf layer is what carries the "there is
## grass here" appearance past this point instead, at zero geometry cost
## regardless of how far it needs to reach. Keeping this independent of
## load_radius means raising the base radius for some other reason cannot
## silently raise this ceiling too.
@export var max_radius := 120.0
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
## Passed straight through to each chunk — see GrassField.reduced_density_band_degrees.
@export var reduced_density_band_degrees := 15.0
## Passed straight through to each chunk — see GrassField.density_region_size.
@export var density_region_size := 12.0
@export var seed := 20240
@export var material: Material = null

## Vector2i cell -> GrassField.
var _active: Dictionary = {}
## Vector2i cell -> true while that chunk is queued or building. While true it
## is neither re-queued nor freed, so a build never has the ground pulled out
## from under its own in-flight await.
var _pending: Dictionary = {}
## Array of {"cell": Vector2i, "distance": float}, kept sorted nearest-first —
## same reason and same shape as terrain_manager.gd's _build_queue. A plain
## FIFO queues cells in raster-scan order, which has nothing to do with which
## one the player is standing on: when a large batch queues at once (zone
## load, or a run that crosses several chunks between rescans), the chunk
## directly underfoot can land anywhere in that sweep, and everything scanned
## earlier — regardless of distance — builds first. That is what a "grass
## exists nearby but not right where I'm standing" report actually is.
var _build_queue: Array = []
var _building := 0
var _timer := 0.0


func _process(delta: float) -> void:
	# This node exists in the editor too (Zone.build() runs there), but Game
	# is not fully constructed outside actual play — see the identical guard
	# in terrain_manager.gd's _ready(). Without this, _rescan() touches
	# Game.player every frame and errors continuously while the scene is just
	# open for editing, not only during Play.
	if Engine.is_editor_hint():
		return
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
	# The RIG's pivot, not the real Camera3D — deliberately NOT what
	# terrain_manager.gd reads for its own screen-space test. That pivot is the
	# point being looked AT (see camera_rig.gd), which follows the player with
	# only a small vertical offset, so it stays right where grass most needs to
	# exist: under the player's own feet. The real camera eye sits well back
	# and up from there (camera_rig's `distance`, currently ~20 units) — using
	# it here would pull the load disc's centre away from the player toward the
	# direction the rig is facing, which is the opposite of what a "why is
	# there no grass right where I'm standing" report wants fixed.
	var cam := Game.camera_rig.global_position if Game.camera_rig else Game.player.global_position
	if absf(cam.x) > map_half_extent or absf(cam.z) > map_half_extent:
		return
	var view_xz := Vector2(cam.x, cam.z)
	# Half the chunk's diagonal, so range checks are against the nearest
	# corner of a chunk rather than its centre — a chunk whose centre is just
	# past a radius can still have a corner inside it.
	var half_diag := chunk_size * 0.7072
	var radii := _effective_radii()

	_queue_new_chunks(view_xz, half_diag, radii[0])
	_free_out_of_range_chunks(view_xz, half_diag, radii[1])
	# Re-sorted every scan, not just appended-then-left, because the player
	# moving changes which queued cell is actually nearest — see the note on
	# _build_queue.
	_build_queue.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["distance"] < b["distance"])


## The load/unload radii actually in use right now: [member load_radius] and
## [member unload_radius] scaled up for the camera's current zoom — see
## [member radius_per_distance] — then capped at [member max_radius]. The gap
## between the two (the anti-thrash hysteresis band) is preserved at every
## zoom level rather than only at the default, since scaling each
## independently could let zooming in shrink that gap below chunk_size and
## start thrashing; the cap is applied after that so it shrinks the whole band
## rather than eating the margin first.
func _effective_radii() -> Array:
	var distance := 20.0
	if Game.camera_rig and Game.camera_rig.has_method("get_active_distance"):
		distance = Game.camera_rig.get_active_distance()
	var load := minf(maxf(load_radius, distance * radius_per_distance), max_radius)
	var unload := minf(load + (unload_radius - load_radius), max_radius + (unload_radius - load_radius))
	return [load, unload]


func _queue_new_chunks(view_xz: Vector2, half_diag: float, radius: float) -> void:
	var p := view_xz
	var cell_min_x := int(floor((p.x - radius) / chunk_size))
	var cell_max_x := int(floor((p.x + radius) / chunk_size))
	var cell_min_z := int(floor((p.y - radius) / chunk_size))
	var cell_max_z := int(floor((p.y + radius) / chunk_size))

	for cx in range(cell_min_x, cell_max_x + 1):
		for cz in range(cell_min_z, cell_max_z + 1):
			var cell := Vector2i(cx, cz)
			if _active.has(cell) or _pending.has(cell):
				continue
			var dist := p.distance_to(_cell_center(cell))
			if dist - half_diag > radius:
				continue
			_pending[cell] = true
			_build_queue.append({"cell": cell, "distance": dist})


func _free_out_of_range_chunks(view_xz: Vector2, half_diag: float, radius: float) -> void:
	var to_free: Array = []
	for cell in _active.keys():
		if view_xz.distance_to(_cell_center(cell)) - half_diag > radius:
			to_free.append(cell)
	for cell in to_free:
		var field: GrassField = _active[cell]
		_active.erase(cell)
		# A chunk can still be mid-build here — _spawn() adds to _active before
		# the field's own _build() coroutine (which yields across frames, see
		# grass_field.gd's samples_per_batch) has finished. Freeing it out from
		# under that coroutine means it never reaches its own `built.emit()`, so
		# without this, _on_built() never fires: _building stays incremented and
		# _pending[cell] never clears. Do that bookkeeping here instead, since
		# the signal never will. Enough of these leaks (max_concurrent_builds
		# worth) permanently wedges _drain_build_queue — no new chunk can ever
		# start — which is exactly the "grass stopped streaming" symptom this
		# fixes: wander far enough, mid-build chunks get freed behind you, and
		# eventually every build slot is leaked this way.
		if _pending.has(cell):
			_pending.erase(cell)
			_building = maxi(_building - 1, 0)
		field.queue_free()


func _drain_build_queue() -> void:
	while _building < max_concurrent_builds and not _build_queue.is_empty():
		var task: Dictionary = _build_queue.pop_front()
		var cell: Vector2i = task["cell"]
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
	field.reduced_density_band_degrees = reduced_density_band_degrees
	field.density_region_size = density_region_size
	# NOT per-cell like `seed` below: a density-tier region (see
	# GrassField._density_factor) can straddle two chunks, and both halves
	# must hash to the same tier or the seam between them shows as a hard
	# density edge exactly where none is meant to exist.
	field.density_seed = seed
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
