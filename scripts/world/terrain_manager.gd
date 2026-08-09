class_name TerrainManager
extends Node3D

## Streams [TerrainChunk] tiles in and out around the camera, and decides how
## much detail each one gets.
##
## This is the piece that makes map size stop mattering. Ground is no longer a
## single enormous slab that exists whether or not anyone is near it — it is a
## grid of tiles, and only the ones close enough to see are built. Walk east for
## an hour and the cost never changes: tiles appear ahead, tiles are freed
## behind, and the number resident at any moment stays flat.
##
## DETAIL IS CHOSEN BY PROJECTED SCREEN SIZE, not by a fixed distance ladder.
## A tile's shape comes from a function rather than from stored geometry, so
## the same piece of ground can be built fine or coarse and it is still the
## same hill in the same place — so far tiles are built cheap, and nobody can
## tell, because they are a few pixels tall. Measured on a 32-unit tile: fine
## is about 16 ms and coarse about 0.4 ms, so the horizon costs roughly one
## fortieth of what the ground underfoot does.
##
## A FIXED-DISTANCE LADDER — the first version of this — only gets that right
## for one specific camera framing. It has no way to know the camera zoomed
## out (tiles need LESS detail per world-unit), zoomed in (MORE), or gained
## altitude (a tile 64 units away horizontally but 500 units straight down is
## nowhere near as detailed on screen as one 64 units away at eye height).
## Projected pixel size folds all three into the one number that actually
## matters: how many pixels of the screen a tile's own vertex spacing would
## cover. See [method _resolution_for].
##
## Deliberately the same shape as grass_manager.gd — periodic rescan rather than
## per-frame, hysteresis between loading and unloading so a tile cannot thrash
## on a boundary, a throttle on how many builds run at once — because that
## design is already proven here and there is no reason for two streaming
## systems in one project to be understood separately.
##
## RETILING IS SEAMLESS BY ACCIDENT OF ORDER, and it is worth knowing why.
## When a tile changes detail level it rebuilds in place, and TerrainChunk only
## swaps its mesh at the very end of a build. The old mesh therefore stays up
## for the whole rebuild and is replaced in a single frame — there is never a
## hole where ground used to be. What remains is a one-frame change in
## silhouette, which is why [member max_screen_error_px] is generous enough
## that it happens where nobody is looking closely.

const CHUNK_SCRIPT := preload("res://scripts/terrain/terrain_chunk.gd")

@export_group("Shape")
## Where ground height comes from. Without one, nothing is built at all.
@export var heightfield: Heightfield = null

@export_group("Grid")
## Side length of one tile, in world units. Smaller tiles stream more smoothly
## (less work per build, finer control over what is resident) but cost more in
## draw calls and bookkeeping. An implementation detail, not a visual dial.
@export var chunk_size := 32.0
## Resolutions a tile is allowed to build at, ASCENDING (coarsest first).
## Vertex count at each is (resolution + 1) squared. [method _resolution_for]
## works out the coarsest one that still keeps error under
## [member max_screen_error_px] and uses that — never finer than necessary,
## never coarser than the budget allows.
##
## Kept as a short discrete list rather than picking an arbitrary integer
## resolution continuously: TerrainChunk's seam skirt (see its own class doc)
## is sized against how far apart two neighbouring resolutions can plausibly
## land, and an unbounded jump between arbitrary values could exceed it. This
## progression — each roughly double the last — is what [member skirt_depth]
## is tuned against.
@export var resolutions: Array[int] = [2, 4, 8, 16, 32]
## Screen-space error budget, in pixels: the largest a tile's own vertex
## spacing is allowed to project to before a finer resolution is chosen
## instead. This is the ONE dial that replaces the old fixed-distance ladder —
## see the class doc. Smaller means more detail (and more cost) everywhere;
## larger lets tiles go coarse sooner.
##
## NOT the same kind of number as a texel or UI error budget, and 2px (a
## typical value for those) is the wrong instinct here — this measures raw
## VERTEX SPACING, not the actual geometric deviation between the coarse
## surface and the true one. Two neighbouring samples straddling smooth,
## gently rolling ground disagree with the curve between them by a small
## fraction of their spacing, so a spacing budget of a few pixels would demand
## near-continuous tessellation for terrain that reads as perfectly smooth at
## twenty times that spacing. 24px is calibrated against the shape this
## project's ground actually has (chunk_size 32, resolution capped at 32, so 1
## world unit is the finest spacing available) and against a ~1080px-tall
## viewport at the default FOV: it keeps the near tile at full resolution out
## to roughly the old near tier's cutoff, and eases off from there. Tune by
## eye against how coarse tiles look at the boundary where they change,
## because the "right" number is genuinely about this project's geometry, not
## a portable constant.
@export_range(1.0, 64.0, 0.5) var max_screen_error_px := 24.0
## Only tiles built at this resolution or finer get a collision shape.
## Defaulted to the finest listed resolution — i.e. only the single nearest
## band of tiles — matching the old ladder's "only the nearest tier" rule and
## keeping collision cost bounded regardless of how the screen-space test
## tunes everything else. Anything coarser is either too far or too small on
## screen to be worth the cost of a collision shape nobody can reach.
@export var collision_resolution_minimum := 32
## Ground beyond this real (3D, not flattened) distance from the camera is not
## built at all. A screen-space test alone never reaches zero — a tile at any
## distance still projects to SOME nonzero number of pixels — so this is the
## hard edge that keeps the world finite. Set past anywhere the camera is
## expected to actually be looking; see zone.gd for the current value.
@export var horizon_distance := 480.0
## Extra distance past [member horizon_distance] before a tile is actually
## freed. Exists so a camera hovering near the boundary, drifting back and
## forth, cannot thrash a tile in and out — the same reason grass_manager
## splits load_radius from unload_radius.
@export var unload_margin := 48.0
## How often to re-scan which tiles should exist and at what detail. The
## camera moves slowly relative to chunk_size, so there is no need to check
## per frame.
@export var check_interval := 0.25
## At most this many tiles may be building at once. Each build already spreads
## itself across frames (TerrainChunk.vertices_per_batch), so this caps how many
## of those can land in the same frame.
@export var max_concurrent_builds := 1
## Passed through to each tile: how many vertices it processes before handing
## the frame back. Together with max_concurrent_builds this is the whole
## per-frame cost control. 0 makes tiles build in a single frame, which is
## faster overall but visibly hitches.
@export var vertices_per_batch := 250
## Beyond this distance from the origin, stop generating ground — the world ends
## and the player would see an edge. 0 means unbounded, which is the point of
## all this: leave it at 0 unless a zone genuinely needs a boundary.
@export var map_half_extent := 0.0

@export_group("Appearance")
## How far each tile's hidden border apron hangs down. Must exceed the worst
## height disagreement between neighbouring tiles built at different detail, or
## hairline cracks show through — see TerrainChunk's note on skirts. Dramatic
## terrain wants more.
@export var skirt_depth := 2.0
@export var material: Material = null

## Node3D -> float (radius). Anything registered here gets guaranteed
## full-detail, collidable ground under it, regardless of how far from the
## camera it has wandered.
##
## THIS EXISTS BECAUSE DETAIL IS KEYED TO THE CAMERA, AND NOT EVERYTHING THAT
## NEEDS TO STAND ON THE GROUND IS ON SCREEN. An NPC is a CharacterBody3D that
## relies on is_on_floor(); if it wanders off camera and its tile retiles down
## to a resolution with no collision, it falls straight through the world —
## which is silent, because nothing was watching for it, and looks like the NPC
## simply vanished. The player registers itself for the same reason once the
## camera can genuinely diverge from it (zoomed far out, or flying — see
## player_controller.gd). Grass, decorations, anything visual-only does not
## need this; anything with a physics body standing on the ground does.
var _anchors: Dictionary = {}
## Cells at least one anchor currently needs, recomputed every scan. Kept
## separate from _active/_pending so a moving anchor's old cells fall back to
## normal screen-space tiering the moment it leaves them.
var _protected_cells: Dictionary = {}

## Vector2i cell -> {"chunk": TerrainChunk, "resolution": int, "collision": bool}.
var _active: Dictionary = {}
## Vector2i cell -> true while that tile is queued or building. While true it is
## neither re-queued nor freed, so a build never has the ground pulled out from
## under its own in-flight await.
var _pending: Dictionary = {}
## Array of {"cell": Vector2i, "resolution": int, "collision": bool, "distance":
## float, "protected": bool}, kept sorted so the ground nearest the camera is
## built first — EXCEPT that every protected (anchor) task sorts ahead of
## every ordinary one, regardless of distance. Without that override, a camera
## that never stops moving also never lets the queue run dry: each scan
## appends a fresh batch of nearby tasks ahead of an anchor sitting far away,
## and a same-priority task can be outranked forever. Distance-only sorting is
## fine for anything that can simply wait its turn; an anchor's tile is the
## ground an NPC is currently falling through, and that cannot wait behind
## everything closer to wherever the camera happens to be looking.
var _build_queue: Array = []
var _building := 0
var _timer := 0.0


func _ready() -> void:
	# Zone.build() runs in the editor as well as at runtime, so this node gets
	# created there too — but streaming is meaningless without a player, and the
	# Game autoload is not fully constructed in the editor. Same guard the rest
	# of zone.gd uses for the same reason.
	if Engine.is_editor_hint():
		return
	Game.register_terrain_manager(self)
	if heightfield == null:
		push_warning("TerrainManager '%s': no heightfield, no ground will exist." % name)
	resolutions.sort()
	# First scan immediately rather than after check_interval, so the player
	# does not spend a quarter second standing on nothing.
	_rescan()


func _process(delta: float) -> void:
	_timer += delta
	if _timer >= check_interval:
		_timer = 0.0
		_rescan()
	_drain_build_queue()


## True once the ground at a world XZ position is confirmed BUILT and
## collidable — not merely intended to be. The world uses this to hold
## gravity-driven bodies in place until there is actually something under
## their feet; see player_controller.gd and npc_controller.gd's
## _ground_ready().
##
## Deliberately checks the tile's actual Collider child rather than
## `_active[cell]["collision"]`. That field is set the instant a build is
## QUEUED, before TerrainChunk.build() (which can span several frames when
## batched) has produced a collision shape — a caller trusting the flag alone
## would still get a window where "ground is ready" is true but nothing is
## actually there to stand on. Confirmed as a real gap by
## scripts/dev/verify_terrain_manager.gd's own continuous-movement check,
## which had to be fixed for the exact same reason.
func has_ground_at(x: float, z: float) -> bool:
	var cell := _cell_at(Vector2(x, z))
	if not _active.has(cell) or not _active[cell]["collision"]:
		return false
	var chunk: Node = _active[cell]["chunk"]
	return chunk.get_node_or_null("Collider") != null


## Registers [param node] as needing solid, full-detail ground within [param
## radius] of itself at all times, independent of where the camera is looking —
## see the note on [member _anchors]. Typically called once from an NPC's
## _ready(), and now also from the player's. [param radius] should comfortably
## cover how far the node can move before the next rescan, e.g. an NPC's
## wander_radius plus a margin.
func register_collision_anchor(node: Node3D, radius := 8.0) -> void:
	_anchors[node] = radius


## Must be called before [param node] is freed (its _exit_tree, typically) — a
## stale entry is harmless (guarded by is_instance_valid on the next scan) but
## there is no reason to carry dead weight until then.
func unregister_collision_anchor(node: Node3D) -> void:
	_anchors.erase(node)


## Counts for the debug HUD: how many tiles exist, at what resolution, and how
## much work is outstanding. per_resolution is parallel to [member resolutions].
func debug_stats() -> Dictionary:
	var per_resolution: Array = []
	for _r in resolutions.size():
		per_resolution.append(0)
	var vertices := 0
	for cell in _active:
		var entry: Dictionary = _active[cell]
		var idx := resolutions.find(entry["resolution"])
		if idx >= 0:
			per_resolution[idx] += 1
		vertices += (entry["chunk"] as TerrainChunk).get_vertex_count()
	return {
		"tiles": _active.size(),
		"resolutions": resolutions,
		"per_resolution": per_resolution,
		"vertices": vertices,
		"queued": _build_queue.size(),
		"building": _building,
	}


func _rescan() -> void:
	if heightfield == null or Game.player == null or resolutions.is_empty():
		return
	var view := _view_camera()
	var view_xz := Vector2(view["position"].x, view["position"].z)
	# Half a tile's diagonal, so range tests are against the nearest CORNER of a
	# tile rather than its centre — a tile whose centre is just past a boundary
	# can still have a corner well inside it.
	var half_diag := chunk_size * 0.7072

	_protected_cells = _compute_protected_cells()
	# Anchors first, so the general pass below sees them already pending and
	# does not separately (and possibly differently) queue the same cell.
	_queue_protected_tiles(view_xz, half_diag)
	_queue_wanted_tiles(view, view_xz, half_diag)
	_free_distant_tiles(view["position"], view_xz, half_diag)
	# Protected first, then nearest first. Re-sorted every scan rather than
	# inserted in order, because the camera moving changes the ordering of
	# tiles already waiting — see the note on _build_queue for why protected
	# tasks need to win outright rather than just being sorted by distance too.
	_build_queue.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["protected"] != b["protected"]:
			return a["protected"]
		return a["distance"] < b["distance"])


## Where the screen-space test is measured from: the real Camera3D's position
## and FOV, not the rig's own origin (which is the point being looked AT).
##
## Falls back to an approximation of the rig's default framing when no camera
## has registered yet — CameraRig sits later than Zone in World.tscn's child
## order, so the very first rescan (fired from this node's own _ready) can
## land here before Game.camera_rig exists. One formula used everywhere rather
## than a separate "just build the near tiles" bootstrap path.
func _view_camera() -> Dictionary:
	if Game.camera_rig:
		var cam: Camera3D = Game.camera_rig.get_camera()
		if cam:
			return {"position": cam.global_position, "fov_rad": deg_to_rad(cam.fov)}
	var origin := Game.player.global_position if Game.player else Vector3.ZERO
	return {"position": origin + Vector3(14.0, 14.0, 14.0), "fov_rad": deg_to_rad(45.0)}


## Every cell within radius of a live anchor. Dead anchors (freed nodes that
## missed unregistering) are pruned here rather than left to accumulate.
func _compute_protected_cells() -> Dictionary:
	var protected := {}
	for node in _anchors.keys():
		if not is_instance_valid(node):
			_anchors.erase(node)
			continue
		var radius: float = _anchors[node]
		var pos := Vector2((node as Node3D).global_position.x, (node as Node3D).global_position.z)
		var min_cell := _cell_at(pos - Vector2(radius, radius))
		var max_cell := _cell_at(pos + Vector2(radius, radius))
		for cx in range(min_cell.x, max_cell.x + 1):
			for cz in range(min_cell.y, max_cell.y + 1):
				protected[Vector2i(cx, cz)] = true
	return protected


## Queues every protected cell that is not already at the finest resolution,
## regardless of how far it is from the camera — an anchor off screen still
## needs solid ground, since an NPC nobody is looking at is still simulated.
## Pinned to the finest resolution rather than run through the screen-space
## test: the whole point of an anchor is that visual size does not matter,
## only that real collision geometry exists.
func _queue_protected_tiles(view_xz: Vector2, half_diag: float) -> void:
	var finest: int = resolutions[resolutions.size() - 1]
	for cell in _protected_cells:
		if _pending.has(cell):
			continue
		if _active.has(cell) and _active[cell]["resolution"] == finest:
			continue
		var distance := maxf(view_xz.distance_to(_cell_center(cell)) - half_diag, 0.0)
		_pending[cell] = true
		_build_queue.append({"cell": cell, "resolution": finest, "collision": true,
			"distance": distance, "protected": true})


## Walks every cell inside the horizon and queues anything that is missing, or
## present at the wrong resolution.
func _queue_wanted_tiles(view: Dictionary, view_xz: Vector2, half_diag: float) -> void:
	# The XZ search box is sized off horizon_distance directly, which over-
	# scans once the camera has any altitude (the real 3D horizon reaches less
	# far in XZ than a camera at ground level would) — deliberately: it is a
	# cheap, safe over-approximation, and the real per-cell 3D distance check
	# below is what actually decides whether a cell gets built.
	var min_cell := _cell_at(view_xz - Vector2(horizon_distance, horizon_distance))
	var max_cell := _cell_at(view_xz + Vector2(horizon_distance, horizon_distance))

	for cx in range(min_cell.x, max_cell.x + 1):
		for cz in range(min_cell.y, max_cell.y + 1):
			var cell := Vector2i(cx, cz)
			if _pending.has(cell):
				continue
			var centre := _cell_center(cell)
			if map_half_extent > 0.0 and (absf(centre.x) > map_half_extent
					or absf(centre.y) > map_half_extent):
				continue
			var picked := _resolution_for(centre, view)
			if picked.is_empty():
				continue
			var distance: float = picked["distance"]
			var resolution: int = picked["resolution"]
			if _active.has(cell) and _active[cell]["resolution"] == resolution:
				continue
			_pending[cell] = true
			_build_queue.append({"cell": cell, "resolution": resolution,
				"collision": resolution >= collision_resolution_minimum,
				"distance": distance, "protected": false})


## Decides the resolution a tile centred at [param centre] should build at,
## from how many pixels its own vertex spacing would project to. Returns {} if
## the tile is past [member horizon_distance] and should not be built at all.
##
## THE METRIC: for a tile of world size [member chunk_size] built at
## resolution R, neighbouring vertices are chunk_size/R world units apart. A
## world-space length L, D units from the camera, covers roughly
## `L * viewport_height / (2 * D * tan(fov/2))` pixels of screen — the
## standard perspective-projection size estimate. Solving that for the
## smallest R that keeps the projected spacing under
## [member max_screen_error_px] gives the resolution actually needed; anything
## finer is spending vertices on detail nobody's screen can resolve, and
## anything coarser would show as visible faceting. [member resolutions] is
## then searched for the coarsest listed value that still meets that bound.
##
## Distance is real 3D distance to the tile's own ground height (via
## [member heightfield], which answers instantly for any point — see its
## class doc) rather than flattened XZ distance, which is what makes this
## metric correct from altitude: a tile straight down from a high camera is
## FAR in 3D even though it is at XZ distance 0, and gets tiered accordingly.
func _resolution_for(centre: Vector2, view: Dictionary) -> Dictionary:
	var ground_y := heightfield.height_at(centre.x, centre.y)
	var world_point := Vector3(centre.x, ground_y, centre.y)
	var cam_pos: Vector3 = view["position"]
	var distance := cam_pos.distance_to(world_point)
	if distance > horizon_distance:
		return {}

	var viewport_height := float(get_viewport().get_visible_rect().size.y)
	var fov_rad: float = view["fov_rad"]
	var projection_k := viewport_height / (2.0 * tan(fov_rad * 0.5))
	# How many world units currently project to one pixel, at this distance.
	var world_units_per_pixel := maxf(distance, 0.001) / maxf(projection_k, 0.001)
	# The finest resolution possible cannot be beaten, so this loop looks for
	# the FIRST (coarsest, since resolutions is sorted ascending) entry whose
	# vertex spacing still fits the budget; falling through the loop means even
	# the finest listed resolution is tighter than the budget technically
	# demands, in which case it is used anyway — there is nothing finer to
	# reach for.
	var chosen: int = resolutions[resolutions.size() - 1]
	for res in resolutions:
		var spacing := chunk_size / float(res)
		if spacing / world_units_per_pixel <= max_screen_error_px:
			chosen = res
			break
	return {"resolution": chosen, "distance": distance}


func _free_distant_tiles(cam_pos: Vector3, view_xz: Vector2, half_diag: float) -> void:
	var horizon := horizon_distance + unload_margin
	var to_free: Array = []
	for cell in _active:
		# A tile mid-rebuild is left alone; it will be caught on a later scan
		# once it has settled.
		if _pending.has(cell):
			continue
		# An anchor standing here needs this ground however far the camera is.
		if _protected_cells.has(cell):
			continue
		var centre := _cell_center(cell)
		var ground_y := heightfield.height_at(centre.x, centre.y)
		var distance := cam_pos.distance_to(Vector3(centre.x, ground_y, centre.y))
		if distance - half_diag > horizon:
			to_free.append(cell)
	for cell in to_free:
		var entry: Dictionary = _active[cell]
		_active.erase(cell)
		(entry["chunk"] as Node).queue_free()


func _drain_build_queue() -> void:
	while _building < max_concurrent_builds and not _build_queue.is_empty():
		var task: Dictionary = _build_queue.pop_front()
		var cell: Vector2i = task["cell"]
		# The tile may have been freed between being queued and being reached.
		if not _pending.has(cell):
			continue
		_building += 1
		if _active.has(cell):
			_retile(cell, task["resolution"], task["collision"])
		else:
			_spawn(cell, task["resolution"], task["collision"])


func _spawn(cell: Vector2i, resolution: int, collision: bool) -> void:
	var chunk: TerrainChunk = CHUNK_SCRIPT.new()
	chunk.name = "Tile_%d_%d" % [cell.x, cell.y]
	_configure(chunk, resolution, collision)
	var centre := _cell_center(cell)
	chunk.position = Vector3(centre.x, 0.0, centre.y)
	chunk.built.connect(_on_built.bind(cell), CONNECT_ONE_SHOT)
	_active[cell] = {"chunk": chunk, "resolution": resolution, "collision": collision}
	add_child(chunk)


## Rebuilds an existing tile at a different resolution. The old mesh stays up
## until the new one is finished — see the note at the top about why this is
## seamless rather than a gap.
func _retile(cell: Vector2i, resolution: int, collision: bool) -> void:
	var entry: Dictionary = _active[cell]
	var chunk: TerrainChunk = entry["chunk"]
	entry["resolution"] = resolution
	entry["collision"] = collision
	_configure(chunk, resolution, collision)
	chunk.built.connect(_on_built.bind(cell), CONNECT_ONE_SHOT)
	chunk.build()


func _configure(chunk: TerrainChunk, resolution: int, collision: bool) -> void:
	chunk.heightfield = heightfield
	chunk.size = chunk_size
	chunk.resolution = resolution
	chunk.build_collision = collision
	chunk.skirt_depth = skirt_depth
	chunk.vertices_per_batch = vertices_per_batch
	chunk.material = material


func _on_built(cell: Vector2i) -> void:
	_building = maxi(_building - 1, 0)
	_pending.erase(cell)


func _cell_at(xz: Vector2) -> Vector2i:
	return Vector2i(int(floor(xz.x / chunk_size)), int(floor(xz.y / chunk_size)))


func _cell_center(cell: Vector2i) -> Vector2:
	return Vector2((cell.x + 0.5) * chunk_size, (cell.y + 0.5) * chunk_size)
