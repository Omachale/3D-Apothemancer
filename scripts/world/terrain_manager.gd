class_name TerrainManager
extends Node3D

## Streams [TerrainChunk] tiles in and out around the camera, growing the tiles
## themselves with distance so the horizon can extend without the tile count
## exploding.
##
## This is the piece that makes map size stop mattering. Ground is no longer a
## single enormous slab that exists whether or not anyone is near it — it is a
## grid of tiles, and only the ones close enough to see are built. Walk east for
## an hour and the cost never changes: tiles appear ahead, tiles are freed
## behind, and the number resident at any moment stays flat.
##
## DETAIL IS VERTEX SPACING, AND SPACING IS SET BY TILE SIZE. A tile's shape
## comes from a function rather than from stored geometry, so the same piece of
## ground can be built at any scale and it is still the same hill in the same
## place. Every tile builds at the same [member tile_resolution]; what changes
## with distance is how much WORLD each tile covers. Level L tiles are
## `chunk_size * 2^L` across, so their vertices sit `chunk_size * 2^L /
## tile_resolution` apart — far tiles are built coarse, and nobody can tell,
## because they are a few pixels tall.
##
## WHY SIZE AND NOT RESOLUTION. Both reach the same spacing: 16 units between
## vertices is a 32-unit tile at resolution 2, or a 512-unit tile at resolution
## 32. Identical detail, identical vertex count over the same ground. The
## difference is that the first needs 256 tiles to cover what the second covers
## with one. An earlier version of this file varied resolution at a fixed
## 32-unit tile size, and its detail falloff was correct — but tile COUNT is
## quadratic in [member horizon_distance] and completely independent of how
## coarse those tiles are. At a 480-unit horizon that is a 30x30 grid: nine
## hundred nodes, nine hundred draw calls, nine hundred dictionary entries
## walked four times a second, most of them holding nine vertices. A 2000-unit
## horizon would have been fifteen thousand. Doubling tile size each ring
## outward makes each ring a fixed number of tiles thick, so DOUBLING THE
## HORIZON ADDS ONE RING rather than quadrupling everything.
##
## WHICH RING A TILE LANDS IN IS CHOSEN BY PROJECTED SCREEN SIZE, not by a fixed
## distance ladder. A fixed ladder only gets that right for one specific camera
## framing: it has no way to know the camera zoomed out (tiles need LESS detail
## per world-unit), zoomed in (MORE), or gained altitude (a tile 64 units away
## horizontally but 500 units straight down is nowhere near as detailed on
## screen as one 64 units away at eye height). Projected pixel size folds all
## three into the one number that actually matters. See [method _ring_radius].
##
## Deliberately the same shape as grass_manager.gd — periodic rescan rather than
## per-frame, hysteresis between loading and unloading so a tile cannot thrash
## on a boundary, a throttle on how many builds run at once — because that
## design is already proven here and there is no reason for two streaming
## systems in one project to be understood separately.

const CHUNK_SCRIPT := preload("res://scripts/terrain/terrain_chunk.gd")

@export_group("Shape")
## Where ground height comes from. Without one, nothing is built at all.
@export var heightfield: Heightfield = null

@export_group("Grid")
## Side length of a LEVEL 0 tile, in world units — the smallest tile size, used
## nearest the camera. Every ring outward doubles it.
@export var chunk_size := 32.0
## Grid cells per side, the same for every tile at every level. Vertex count is
## (tile_resolution + 1) squared.
##
## THIS IS NOT THE DETAIL DIAL — [member max_screen_error_px] is. Raising this
## makes every tile finer AND every ring cover more ground, which is rarely
## what anyone wants. It is really a ratio dial: it sets how many rings it takes
## to span a given range of vertex spacings, and 32 against a 32-unit
## [member chunk_size] gives spacings of 1, 2, 4, 8, 16 units across five rings.
@export_range(2, 128, 1) var tile_resolution := 32
## How many rings, i.e. how many tile sizes exist. The outermost ring is
## whatever is left between its own inner edge and [member horizon_distance], so
## too few rings does not leave a hole — it just means the far ground is coarser
## than [member max_screen_error_px] would like. Each ring past the last useful
## one costs nothing, so this is cheap to leave generous.
@export_range(1, 12, 1) var ring_count := 5
## Screen-space error budget, in pixels: the largest a tile's own vertex
## spacing is allowed to project to before the next ring in is used instead.
## THE one detail dial. Smaller means more detail (and more tiles) everywhere;
## larger lets rings start closer and the ground go coarse sooner.
##
## NOT the same kind of number as a texel or UI error budget, and 2px (a
## typical value for those) is the wrong instinct here — this measures raw
## VERTEX SPACING, not the actual geometric deviation between the coarse
## surface and the true one. Two neighbouring samples straddling smooth,
## gently rolling ground disagree with the curve between them by a small
## fraction of their spacing, so a spacing budget of a few pixels would demand
## near-continuous tessellation for terrain that reads as perfectly smooth at
## twenty times that spacing. 24px is calibrated against the shape this
## project's ground actually has and against a ~1080px-tall viewport at the
## default FOV. Tune by eye against how coarse tiles look at the boundary where
## rings change, because the "right" number is genuinely about this project's
## geometry, not a portable constant.
@export_range(1.0, 64.0, 0.5) var max_screen_error_px := 24.0
## Only tiles at this level or FINER (i.e. level <= this) get a collision shape.
## 0 means only the innermost ring — the nearest band of tiles, and the only one
## the player can physically reach. Anything coarser is too far to stand on, and
## a collision shape costs the same at any level. Anchors are the exception; see
## [member _anchors].
@export_range(0, 12, 1) var collision_level_maximum := 0
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
## How often to re-scan which tiles should exist and at what level. The
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
##
## MATTERS MORE THAN IT USED TO. Every tile is now [member tile_resolution] on a
## side regardless of how far away it is, so a far tile costs the same ~16 ms to
## build as a near one (it just covers vastly more ground). Total work over a
## given area is unchanged, but it arrives in bigger single lumps.
@export var vertices_per_batch := 250
## Beyond this distance from the origin, stop generating ground — the world ends
## and the player would see an edge. 0 means unbounded, which is the point of
## all this: leave it at 0 unless a zone genuinely needs a boundary.
@export var map_half_extent := 0.0

@export_group("Appearance")
## How far each tile's hidden border apron hangs down. Must exceed the worst
## height disagreement between neighbouring tiles of different size, or hairline
## cracks show through — see TerrainChunk's note on skirts.
##
## The ring layout is kind to this. Because tile sizes are powers of two and the
## grids are origin-aligned, a level-L tile's edge lies EXACTLY along a
## level-(L+1) tile's edge: both sample the same straight world-space line, at
## spacings differing by 2x. So the worst disagreement is the heightfield's
## deviation from linear over one coarse step — milder than the old
## vary-the-resolution scheme, where a 1-unit-spacing tile could sit against a
## 16-unit-spacing one.
@export var skirt_depth := 2.0
@export var material: Material = null

## Node3D -> float (radius). Anything registered here gets guaranteed COLLIDABLE
## ground under it, regardless of how far from the camera it has wandered.
##
## THIS EXISTS BECAUSE COLLISION IS KEYED TO THE CAMERA, AND NOT EVERYTHING THAT
## NEEDS TO STAND ON THE GROUND IS ON SCREEN. An NPC is a CharacterBody3D that
## relies on is_on_floor(); if it wanders off camera and the ground under it
## ends up on a ring with no collision, it falls straight through the world —
## which is silent, because nothing was watching for it, and looks like the NPC
## simply vanished. The player registers itself for the same reason once the
## camera can genuinely diverge from it (zoomed far out, or flying — see
## player_controller.gd). Grass, decorations, anything visual-only does not
## need this; anything with a physics body standing on the ground does.
##
## AN ANCHOR NO LONGER FORCES DETAIL, only collision. It takes whatever tile the
## ring layout already puts over it and asks for a collision shape on that. The
## alternative — subdividing all the way down to level 0 under every distant NPC
## — means punching a hole in a coarse ring and back-filling it with a graded
## funnel of smaller tiles, which is by far the most complex part of a clipmap
## and buys nothing anyone can see. The cost of not doing it is that a distant
## NPC stands on ground interpolated at coarser spacing, so it can sit slightly
## above or below true height until the player comes back and the region
## refines. At that range it is invisible.
var _anchors: Dictionary = {}
## Tile keys at least one anchor currently needs collision on, recomputed every
## scan. Kept separate from _active/_wanted so a moving anchor's old tiles fall
## back to normal ring rules the moment it leaves them.
var _protected_keys: Dictionary = {}

## Tile key -> true, for every tile that SHOULD be built right now. Recomputed
## each scan by [method _compute_regions].
var _wanted: Dictionary = {}
## Tile key -> true, for every tile that should be KEPT if it already exists.
## A superset of _wanted, reaching [member unload_margin] further out — the
## hysteresis band that stops a tile thrashing on the horizon boundary.
var _retained: Dictionary = {}

## Tile key -> {"chunk": TerrainChunk, "level": int, "collision": bool}.
##
## KEYED BY Vector3i(cell.x, cell.z, level), not by cell alone: each ring has
## its own grid, and the same patch of world is addressed by a different cell on
## every one of them. The level has to be part of the identity or a level-1 tile
## and the level-0 tile inside it collide in the dictionary.
var _active: Dictionary = {}
## Tile key -> true while that tile is queued or building. While true it is
## neither re-queued nor freed, so a build never has the ground pulled out from
## under its own in-flight await.
var _pending: Dictionary = {}
## Array of {"key": Vector3i, "collision": bool, "distance": float,
## "protected": bool}, kept sorted so the ground nearest the camera is built
## first — EXCEPT that every protected (anchor) task sorts ahead of every
## ordinary one, regardless of distance. Without that override, a camera that
## never stops moving also never lets the queue run dry: each scan appends a
## fresh batch of nearby tasks ahead of an anchor sitting far away, and a
## same-priority task can be outranked forever. Distance-only sorting is fine
## for anything that can simply wait its turn; an anchor's tile is the ground an
## NPC is currently falling through, and that cannot wait behind everything
## closer to wherever the camera happens to be looking.
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
	# First scan immediately rather than after check_interval, so the player
	# does not spend a quarter second standing on nothing.
	_rescan()


func _process(delta: float) -> void:
	# Same reasoning as the editor-hint guard in _ready(): this node exists in
	# the editor too (Zone.build() runs there), but Game is not fully
	# constructed outside actual play, so touching Game.player every frame via
	# _rescan() would error continuously rather than just once at startup.
	if Engine.is_editor_hint():
		return
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
## `_active[key]["collision"]`. That field is set the instant a build is
## QUEUED, before TerrainChunk.build() (which can span several frames when
## batched) has produced a collision shape — a caller trusting the flag alone
## would still get a window where "ground is ready" is true but nothing is
## actually there to stand on. Confirmed as a real gap by
## scripts/dev/verify_terrain_manager.gd's own continuous-movement check,
## which had to be fixed for the exact same reason.
##
## Every ring is checked rather than just the one the layout currently puts over
## this point, because during a ring transition BOTH the outgoing coarse tile
## and its incoming finer replacements legitimately exist at once (see
## [method _free_unwanted]). Any of them being collidable means there is
## genuinely something to stand on.
func has_ground_at(x: float, z: float) -> bool:
	var xz := Vector2(x, z)
	for level in ring_count:
		var key := _key(_cell_at(xz, level), level)
		if not _active.has(key) or not _active[key]["collision"]:
			continue
		var chunk: Node = _active[key]["chunk"]
		if chunk.get_node_or_null("Collider") != null:
			return true
	return false


## Registers [param node] as needing solid ground within [param radius] of
## itself at all times, independent of where the camera is looking — see the
## note on [member _anchors]. Typically called once from an NPC's _ready(), and
## now also from the player's. [param radius] should comfortably cover how far
## the node can move before the next rescan, e.g. an NPC's wander_radius plus a
## margin.
func register_collision_anchor(node: Node3D, radius := 8.0) -> void:
	_anchors[node] = radius


## Must be called before [param node] is freed (its _exit_tree, typically) — a
## stale entry is harmless (guarded by is_instance_valid on the next scan) but
## there is no reason to carry dead weight until then.
func unregister_collision_anchor(node: Node3D) -> void:
	_anchors.erase(node)


## Counts for the debug HUD: how many tiles exist, on which ring, and how much
## work is outstanding. per_level is indexed by level, 0 (finest) first.
func debug_stats() -> Dictionary:
	var per_level: Array = []
	for _l in ring_count:
		per_level.append(0)
	var vertices := 0
	for key in _active:
		var level: int = _active[key]["level"]
		if level >= 0 and level < per_level.size():
			per_level[level] += 1
		vertices += (_active[key]["chunk"] as TerrainChunk).get_vertex_count()
	return {
		"tiles": _active.size(),
		"levels": ring_count,
		"per_level": per_level,
		"vertices": vertices,
		"queued": _build_queue.size(),
		"building": _building,
	}


func _rescan() -> void:
	if heightfield == null or Game.player == null or ring_count < 1:
		return
	var view := _view_camera()
	var projection_k := _projection_k(view["fov_rad"])

	_compute_regions(view["position"], projection_k)
	# Anchors first, so the general pass below sees their tiles already marked
	# as needing collision and does not queue the same tile without it.
	_protected_keys = _compute_protected_keys()
	_queue_protected_tiles(view["position"])
	_queue_wanted_tiles(view["position"])
	_free_unwanted()
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


## How many pixels one world unit covers at one world unit of distance — the
## constant half of the standard perspective size estimate, `L * k / D`.
func _projection_k(fov_rad: float) -> float:
	var viewport_height := float(get_viewport().get_visible_rect().size.y)
	return viewport_height / (2.0 * tan(fov_rad * 0.5))


## The distance at which level [param level]'s vertex spacing finally projects
## to no more than [member max_screen_error_px], i.e. where that ring is allowed
## to start.
##
## A world-space length L, D units from the camera, covers roughly `L * k / D`
## pixels of screen. Setting L to this level's vertex spacing and solving
## `spacing * k / D <= max_screen_error_px` for D gives the nearest distance at
## which building this coarse is still under budget. Level 0 comes out
## nonzero, which is correct and simply unused: nothing is finer, so level 0
## covers everything inside its own start distance too.
func _ring_radius(level: int, projection_k: float) -> float:
	return _spacing(level) * projection_k / maxf(max_screen_error_px, 0.001)


## Works out, for every ring, exactly which tiles should exist — filling
## [member _wanted] and [member _retained].
##
## THE REGIONS ARE NESTED BOXES OF WHOLE CELLS, NOT CIRCLES, and that is not a
## shortcut. The tempting version — walk every cell and let each one
## independently ask "which ring am I in?" — produces overlaps and holes right
## at the ring boundaries, because a coarse cell and the finer cells inside it
## have different centres and so can disagree about which side of a boundary
## they fall on. Instead each ring's outer edge is snapped OUTWARD to a whole
## number of the NEXT ring's cells, so the next ring out can subtract it
## exactly. Coverage is then exact by construction, and neighbouring tiles are
## guaranteed to be at most one level apart — which is what keeps the skirt
## able to hide the seams (see [member skirt_depth]).
##
## HYSTERESIS COMES FROM THE SNAPPING, mostly. A ring boundary only moves when
## the camera crosses a whole coarse cell — 64 units at the level 0/1 boundary
## and more further out — so thrash would need the camera to oscillate across
## that exact line. [member unload_margin] then covers the outermost edge, which
## is the one boundary with no coarser ring outside it to snap against.
func _compute_regions(cam_pos: Vector3, projection_k: float) -> void:
	_wanted = {}
	_retained = {}
	var cam_xz := Vector2(cam_pos.x, cam_pos.z)
	var keep_limit := horizon_distance + unload_margin

	# The box, in THIS level's cell indices, that all finer levels together
	# already cover and this level must therefore leave alone.
	var has_inner := false
	var inner_min := Vector2i.ZERO
	var inner_max := Vector2i.ZERO

	for level in ring_count:
		var last := level == ring_count - 1
		# How far out this ring reaches: to where the next ring becomes good
		# enough, or — for the outermost, which has no next ring — to the
		# unload boundary. Never past that boundary either way.
		var reach := keep_limit
		if not last:
			reach = minf(_ring_radius(level + 1, projection_k), keep_limit)

		var size := _tile_size(level)
		var outer_min := _cell_at(cam_xz - Vector2(reach, reach), level)
		var outer_max := _cell_at(cam_xz + Vector2(reach, reach), level)
		# Snap so this ring covers a whole number of the NEXT ring's cells: the
		# low edge to an even cell index, the high edge to an odd one (a cell
		# range is inclusive, so min even + max odd means an even cell COUNT
		# starting on a pair boundary). Skipped on the outermost ring, which has
		# nothing outside it that needs to subtract it.
		if not last:
			outer_min = Vector2i(_even_down(outer_min.x), _even_down(outer_min.y))
			outer_max = Vector2i(_odd_up(outer_max.x), _odd_up(outer_max.y))
		# Guarantees the subtraction below is well defined even when a ring's
		# own reach falls short of what the finer rings already cover — which
		# happens whenever horizon_distance is tighter than the ring layout
		# would like. That ring simply comes out empty.
		if has_inner:
			outer_min = Vector2i(mini(outer_min.x, inner_min.x), mini(outer_min.y, inner_min.y))
			outer_max = Vector2i(maxi(outer_max.x, inner_max.x), maxi(outer_max.y, inner_max.y))

		var half_diag := size * 0.7072
		for cx in range(outer_min.x, outer_max.x + 1):
			for cz in range(outer_min.y, outer_max.y + 1):
				if has_inner and cx >= inner_min.x and cx <= inner_max.x \
						and cz >= inner_min.y and cz <= inner_max.y:
					continue
				var cell := Vector2i(cx, cz)
				var centre := _cell_center(cell, level)
				if map_half_extent > 0.0 and (absf(centre.x) > map_half_extent
						or absf(centre.y) > map_half_extent):
					continue
				# Real 3D distance to the tile's own ground height, measured to
				# its NEAREST corner rather than its centre. 3D rather than
				# flattened because a tile straight down from a high camera is
				# genuinely far away; nearest-corner because a 512-unit tile
				# whose centre is just past the horizon can still have most of
				# itself well inside it.
				var ground_y := heightfield.height_at(centre.x, centre.y)
				var distance := cam_pos.distance_to(Vector3(centre.x, ground_y, centre.y))
				var near_edge := distance - half_diag
				if near_edge > keep_limit:
					continue
				var key := _key(cell, level)
				_retained[key] = true
				if near_edge <= horizon_distance:
					_wanted[key] = distance

		if last:
			break
		# This ring's footprint, re-expressed in the next ring's cells. Both
		# divisions are exact because of the snap above, so integer division
		# rounding toward zero cannot bite on negative indices.
		inner_min = Vector2i(outer_min.x / 2, outer_min.y / 2)
		inner_max = Vector2i((outer_max.x - 1) / 2, (outer_max.y - 1) / 2)
		has_inner = true


## Every tile an anchor currently needs collision on. Dead anchors (freed nodes
## that missed unregistering) are pruned here rather than left to accumulate.
##
## Walks the anchor's radius in LEVEL 0 cells and resolves each to whatever tile
## actually covers it, rather than assuming a single tile does: an anchor
## standing near a ring boundary can genuinely straddle two tiles of different
## size, and the one it is about to walk onto needs collision just as much as
## the one it is on.
func _compute_protected_keys() -> Dictionary:
	var protected := {}
	for node in _anchors.keys():
		if not is_instance_valid(node):
			_anchors.erase(node)
			continue
		var radius: float = _anchors[node]
		var pos := Vector2((node as Node3D).global_position.x, (node as Node3D).global_position.z)
		var min_cell := _cell_at(pos - Vector2(radius, radius), 0)
		var max_cell := _cell_at(pos + Vector2(radius, radius), 0)
		for cx in range(min_cell.x, max_cell.x + 1):
			for cz in range(min_cell.y, max_cell.y + 1):
				protected[_covering_key(_cell_center(Vector2i(cx, cz), 0))] = true
	return protected


## The tile that covers a world XZ point: whichever ring's region contains it.
## Falls back to the outermost ring for a point past the horizon entirely —
## an anchor out there still needs ground, and the coarsest tile is the
## cheapest way to give it some.
func _covering_key(xz: Vector2) -> Vector3i:
	for level in ring_count:
		var key := _key(_cell_at(xz, level), level)
		if _retained.has(key):
			return key
	var outermost := ring_count - 1
	return _key(_cell_at(xz, outermost), outermost)


## Queues every anchor tile that does not exist, or exists without collision.
## These sort ahead of everything else — see the note on [member _build_queue].
func _queue_protected_tiles(cam_pos: Vector3) -> void:
	for key in _protected_keys:
		if _pending.has(key):
			continue
		if _active.has(key) and _active[key]["collision"]:
			continue
		_pending[key] = true
		_build_queue.append({"key": key, "collision": true,
			"distance": _distance_to(key, cam_pos), "protected": true})


## Queues anything the ring layout wants that is missing, or present without the
## collision it should have.
func _queue_wanted_tiles(cam_pos: Vector3) -> void:
	for key in _wanted:
		if _pending.has(key) or _protected_keys.has(key):
			continue
		var collision: bool = key.z <= collision_level_maximum
		if _active.has(key) and _active[key]["collision"] == collision:
			continue
		_pending[key] = true
		_build_queue.append({"key": key, "collision": collision,
			"distance": _wanted[key], "protected": false})


## Frees tiles the ring layout no longer wants — but only once nothing being
## built overlaps them.
##
## THE DELAY IS THE WHOLE POINT. When a ring boundary sweeps past, a coarse tile
## is not rebuilt finer in place; it is replaced by four smaller tiles that do
## not exist yet. Freeing it the moment it stops being wanted leaves a hole in
## the ground for however many frames those four take to build — and at
## [member vertices_per_batch] granularity that is a very visible hole. Holding
## the old tile until its replacements have actually landed makes the swap
## seamless, the same way TerrainChunk only swaps its own mesh at the very end
## of a build. This also subsumes the older "never free a tile that is itself
## mid-build" rule, which was the same problem one tile at a time.
func _free_unwanted() -> void:
	var to_free: Array = []
	for key in _active:
		if _retained.has(key) or _protected_keys.has(key):
			continue
		if _pending.has(key):
			continue
		if _overlaps_pending(key):
			continue
		to_free.append(key)
	for key in to_free:
		var entry: Dictionary = _active[key]
		_active.erase(key)
		(entry["chunk"] as Node).queue_free()


## Whether any tile currently queued or building shares ground with [param key].
## Both sets are small — pending is bounded by the build throttle, and tiles
## stop being wanted only along a moving ring boundary — so a plain rectangle
## test against each is cheaper than maintaining an index.
func _overlaps_pending(key: Vector3i) -> bool:
	var rect := _tile_rect(key)
	for other in _pending:
		if rect.intersects(_tile_rect(other)):
			return true
	return false


func _drain_build_queue() -> void:
	while _building < max_concurrent_builds and not _build_queue.is_empty():
		var task: Dictionary = _build_queue.pop_front()
		var key: Vector3i = task["key"]
		# The tile may have been freed between being queued and being reached.
		if not _pending.has(key):
			continue
		_building += 1
		if _active.has(key):
			_rebuild(key, task["collision"])
		else:
			_spawn(key, task["collision"])


func _spawn(key: Vector3i, collision: bool) -> void:
	var chunk: TerrainChunk = CHUNK_SCRIPT.new()
	chunk.name = "Tile_L%d_%d_%d" % [key.z, key.x, key.y]
	_configure(chunk, key.z, collision)
	var centre := _cell_center(Vector2i(key.x, key.y), key.z)
	chunk.position = Vector3(centre.x, 0.0, centre.y)
	chunk.built.connect(_on_built.bind(key), CONNECT_ONE_SHOT)
	_active[key] = {"chunk": chunk, "level": key.z, "collision": collision}
	add_child(chunk)


## Rebuilds an existing tile in place. A tile never changes SIZE — that is what
## the ring layout is for — so the only thing that brings us here is an anchor
## turning collision on for ground that is already built. The old mesh stays up
## for the whole rebuild and is replaced in a single frame, so there is never a
## hole where ground used to be.
func _rebuild(key: Vector3i, collision: bool) -> void:
	var entry: Dictionary = _active[key]
	var chunk: TerrainChunk = entry["chunk"]
	entry["collision"] = collision
	_configure(chunk, key.z, collision)
	chunk.built.connect(_on_built.bind(key), CONNECT_ONE_SHOT)
	chunk.build()


func _configure(chunk: TerrainChunk, level: int, collision: bool) -> void:
	chunk.heightfield = heightfield
	chunk.size = _tile_size(level)
	chunk.resolution = tile_resolution
	chunk.build_collision = collision
	chunk.skirt_depth = skirt_depth
	chunk.vertices_per_batch = vertices_per_batch
	chunk.material = material


func _on_built(key: Vector3i) -> void:
	_building = maxi(_building - 1, 0)
	_pending.erase(key)


# ---------------------------------------------------------------------------
# GRID MATHS
#
# Every ring has its own square grid. Level L cells are chunk_size * 2^L across
# and all grids share the world origin, so they nest exactly: one level-L cell
# is precisely four level-(L-1) cells, and a boundary on any grid is also a
# boundary on every coarser one. That nesting is what lets _compute_regions
# subtract one ring's footprint from the next without gaps, and what keeps
# neighbouring tiles' edges on the same world-space line.
# ---------------------------------------------------------------------------

func _tile_size(level: int) -> float:
	return chunk_size * float(1 << level)


## World units between neighbouring vertices on a level [param level] tile —
## the number that actually decides how the ground looks.
func _spacing(level: int) -> float:
	return _tile_size(level) / float(maxi(tile_resolution, 1))


func _cell_at(xz: Vector2, level: int) -> Vector2i:
	var s := _tile_size(level)
	return Vector2i(int(floor(xz.x / s)), int(floor(xz.y / s)))


func _cell_center(cell: Vector2i, level: int) -> Vector2:
	var s := _tile_size(level)
	return Vector2((cell.x + 0.5) * s, (cell.y + 0.5) * s)


func _key(cell: Vector2i, level: int) -> Vector3i:
	return Vector3i(cell.x, cell.y, level)


func _tile_rect(key: Vector3i) -> Rect2:
	var s := _tile_size(key.z)
	return Rect2(float(key.x) * s, float(key.y) * s, s, s)


func _distance_to(key: Vector3i, cam_pos: Vector3) -> float:
	var centre := _cell_center(Vector2i(key.x, key.y), key.z)
	var ground_y := heightfield.height_at(centre.x, centre.y)
	return cam_pos.distance_to(Vector3(centre.x, ground_y, centre.y))


## Nearest even integer at or below [param v]. posmod rather than % so negative
## cell indices — which are ordinary, the grid spans the origin — round the same
## way positive ones do.
func _even_down(v: int) -> int:
	return v - posmod(v, 2)


## Nearest odd integer at or above [param v].
func _odd_up(v: int) -> int:
	return v + (1 - posmod(v, 2))
