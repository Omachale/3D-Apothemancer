class_name TerrainManager
extends Node3D

## Streams [TerrainChunk] tiles in and out around the player, and decides how
## much detail each one gets.
##
## This is the piece that makes map size stop mattering. Ground is no longer a
## single enormous slab that exists whether or not anyone is near it — it is a
## grid of tiles, and only the ones close enough to see are built. Walk east for
## an hour and the cost never changes: tiles appear ahead, tiles are freed
## behind, and the number resident at any moment stays flat.
##
## DETAIL FALLS OFF WITH DISTANCE, which is the other half of the trick. See
## [member detail_tiers]. Because a tile's shape comes from a function rather
## than from stored geometry, the same piece of ground can be built fine or
## coarse and it is still the same hill in the same place — so far tiles are
## built cheap, and nobody can tell, because they are a few pixels tall.
## Measured on a 32-unit tile: fine is about 16 ms and coarse about 0.4 ms, so
## the horizon costs roughly one fortieth of what the ground underfoot does.
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
## silhouette, which is why the tier boundaries below are set far enough out
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
## Detail levels, NEAREST FIRST. Each entry is a Dictionary:
##   distance    build at this detail out to this range from the player
##   resolution  grid cells per side; vertex count is (resolution + 1) squared
##   collision   whether the player can stand on it
##
## The last entry's distance is the view horizon: past it, plus
## [member unload_margin], tiles are freed entirely.
##
## Only the nearest tier needs collision — nothing can reach the others, and
## building a collision shape is a large share of a tile's cost.
##
## Kept as plain data so a zone can describe its own falloff, and so a future
## tool can write it without touching code.
@export var detail_tiers: Array = [
	{"distance": 64.0, "resolution": 32, "collision": true},
	{"distance": 144.0, "resolution": 8, "collision": false},
	{"distance": 272.0, "resolution": 4, "collision": false},
]
## Extra distance past the last tier before a tile is actually freed. Exists so
## a player standing on a boundary and drifting a step back and forth cannot
## thrash a tile in and out — the same reason grass_manager splits load_radius
## from unload_radius.
@export var unload_margin := 48.0
## How often to re-scan which tiles should exist and at what detail. The player
## moves slowly relative to chunk_size, so there is no need to check per frame.
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
## full-detail, collidable ground under it, regardless of how far the player
## has wandered.
##
## THIS EXISTS BECAUSE DETAIL IS KEYED TO THE PLAYER, AND NOT EVERYTHING THAT
## NEEDS TO STAND ON THE GROUND IS THE PLAYER. An NPC is a CharacterBody3D that
## relies on is_on_floor(); if the player walks away and the NPC's tile retiles
## down to a tier with no collision, the NPC falls straight through the world —
## which is silent, because nothing was watching for it, and looks like the NPC
## simply vanished. grass, decorations, anything visual-only does not need this;
## anything with a physics body standing on the ground does.
var _anchors: Dictionary = {}
## Cells at least one anchor currently needs, recomputed every scan. Kept
## separate from _active/_pending so a moving anchor's old cells fall back to
## normal player-distance tiering the moment it leaves them.
var _protected_cells: Dictionary = {}

## Vector2i cell -> {"chunk": TerrainChunk, "tier": int}.
var _active: Dictionary = {}
## Vector2i cell -> true while that tile is queued or building. While true it is
## neither re-queued nor freed, so a build never has the ground pulled out from
## under its own in-flight await.
var _pending: Dictionary = {}
## Array of {"cell": Vector2i, "tier": int, "distance": float, "protected":
## bool}, kept sorted so the ground nearest the player is built first —
## EXCEPT that every protected (anchor) task sorts ahead of every ordinary
## one, regardless of distance. Without that override, a player who never
## stops moving also never lets the queue run dry: each scan appends a fresh
## batch of nearby tasks ahead of an anchor sitting far away, and a
## same-priority task can be outranked forever. Distance-only sorting is fine
## for anything that can simply wait its turn; an anchor's tile is the ground
## an NPC is currently falling through, and that cannot wait behind
## everything closer to wherever the player happens to be.
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
## `_active[cell]["tier"]`. That field is set the instant a build is QUEUED,
## before TerrainChunk.build() (which can span several frames when batched)
## has produced a collision shape — a caller trusting the tier flag alone
## would still get a window where "ground is ready" is true but nothing is
## actually there to stand on. Confirmed as a real gap by
## scripts/dev/verify_terrain_manager.gd's own continuous-movement check,
## which had to be fixed for the exact same reason.
func has_ground_at(x: float, z: float) -> bool:
	var cell := _cell_at(Vector2(x, z))
	if not _active.has(cell) or _active[cell]["tier"] != 0:
		return false
	var chunk: Node = _active[cell]["chunk"]
	return chunk.get_node_or_null("Collider") != null


## Registers [param node] as needing solid, full-detail ground within [param
## radius] of itself at all times, independent of the player's position — see
## the note on [member _anchors]. Typically called once from an NPC's _ready().
## [param radius] should comfortably cover how far the node can move before the
## next rescan, e.g. an NPC's wander_radius plus a margin.
func register_collision_anchor(node: Node3D, radius := 8.0) -> void:
	_anchors[node] = radius


## Must be called before [param node] is freed (its _exit_tree, typically) — a
## stale entry is harmless (guarded by is_instance_valid on the next scan) but
## there is no reason to carry dead weight until then.
func unregister_collision_anchor(node: Node3D) -> void:
	_anchors.erase(node)


## Counts for the debug HUD: how many tiles exist, at what detail, and how much
## work is outstanding.
func debug_stats() -> Dictionary:
	var per_tier: Array = []
	for _t in detail_tiers.size():
		per_tier.append(0)
	var vertices := 0
	for cell in _active:
		var entry: Dictionary = _active[cell]
		per_tier[entry["tier"]] += 1
		vertices += (entry["chunk"] as TerrainChunk).get_vertex_count()
	return {
		"tiles": _active.size(),
		"per_tier": per_tier,
		"vertices": vertices,
		"queued": _build_queue.size(),
		"building": _building,
	}


func _rescan() -> void:
	if heightfield == null or Game.player == null or detail_tiers.is_empty():
		return
	var p := Game.player.global_position
	var player_xz := Vector2(p.x, p.z)
	# Half a tile's diagonal, so range tests are against the nearest CORNER of a
	# tile rather than its centre — a tile whose centre is just past a boundary
	# can still have a corner well inside it.
	var half_diag := chunk_size * 0.7072

	_protected_cells = _compute_protected_cells()
	# Anchors first, so the general pass below sees them already pending and
	# does not separately (and possibly differently) queue the same cell.
	_queue_protected_tiles(player_xz, half_diag)
	_queue_wanted_tiles(player_xz, half_diag)
	_free_distant_tiles(player_xz, half_diag)
	# Protected first, then nearest first. Re-sorted every scan rather than
	# inserted in order, because the player moving changes the ordering of
	# tiles already waiting — see the note on _build_queue for why protected
	# tasks need to win outright rather than just being sorted by distance too.
	_build_queue.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["protected"] != b["protected"]:
			return a["protected"]
		return a["distance"] < b["distance"])


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


## Queues every protected cell that is not already at full detail, regardless
## of how far it is from the player — an anchor far from the player still needs
## solid ground.
func _queue_protected_tiles(player_xz: Vector2, half_diag: float) -> void:
	for cell in _protected_cells:
		if _pending.has(cell):
			continue
		if _active.has(cell) and _active[cell]["tier"] == 0:
			continue
		var distance := maxf(player_xz.distance_to(_cell_center(cell)) - half_diag, 0.0)
		_pending[cell] = true
		_build_queue.append({"cell": cell, "tier": 0, "distance": distance, "protected": true})


## Walks every cell inside the outermost tier and queues anything that is
## missing, or present at the wrong detail.
func _queue_wanted_tiles(player_xz: Vector2, half_diag: float) -> void:
	var horizon: float = detail_tiers[detail_tiers.size() - 1]["distance"]
	var min_cell := _cell_at(player_xz - Vector2(horizon, horizon))
	var max_cell := _cell_at(player_xz + Vector2(horizon, horizon))

	for cx in range(min_cell.x, max_cell.x + 1):
		for cz in range(min_cell.y, max_cell.y + 1):
			var cell := Vector2i(cx, cz)
			if _pending.has(cell):
				continue
			var centre := _cell_center(cell)
			if map_half_extent > 0.0 and (absf(centre.x) > map_half_extent
					or absf(centre.y) > map_half_extent):
				continue
			# Distance to the tile's nearest corner, floored at 0 for the tile
			# the player is standing on.
			var distance := maxf(player_xz.distance_to(centre) - half_diag, 0.0)
			var tier := _tier_for(distance)
			if tier < 0:
				continue
			if _active.has(cell) and _active[cell]["tier"] == tier:
				continue
			_pending[cell] = true
			_build_queue.append({"cell": cell, "tier": tier, "distance": distance, "protected": false})


func _free_distant_tiles(player_xz: Vector2, half_diag: float) -> void:
	var horizon: float = detail_tiers[detail_tiers.size() - 1]["distance"] + unload_margin
	var to_free: Array = []
	for cell in _active:
		# A tile mid-rebuild is left alone; it will be caught on a later scan
		# once it has settled.
		if _pending.has(cell):
			continue
		# An anchor standing here needs this ground however far the player is.
		if _protected_cells.has(cell):
			continue
		if player_xz.distance_to(_cell_center(cell)) - half_diag > horizon:
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
			_retile(cell, task["tier"])
		else:
			_spawn(cell, task["tier"])


func _spawn(cell: Vector2i, tier: int) -> void:
	var chunk: TerrainChunk = CHUNK_SCRIPT.new()
	chunk.name = "Tile_%d_%d" % [cell.x, cell.y]
	_configure(chunk, tier)
	var centre := _cell_center(cell)
	chunk.position = Vector3(centre.x, 0.0, centre.y)
	chunk.built.connect(_on_built.bind(cell), CONNECT_ONE_SHOT)
	_active[cell] = {"chunk": chunk, "tier": tier}
	add_child(chunk)


## Rebuilds an existing tile at a different detail level. The old mesh stays up
## until the new one is finished — see the note at the top about why this is
## seamless rather than a gap.
func _retile(cell: Vector2i, tier: int) -> void:
	var entry: Dictionary = _active[cell]
	var chunk: TerrainChunk = entry["chunk"]
	entry["tier"] = tier
	_configure(chunk, tier)
	chunk.built.connect(_on_built.bind(cell), CONNECT_ONE_SHOT)
	chunk.build()


func _configure(chunk: TerrainChunk, tier: int) -> void:
	var spec: Dictionary = detail_tiers[tier]
	chunk.heightfield = heightfield
	chunk.size = chunk_size
	chunk.resolution = spec.get("resolution", 16)
	chunk.build_collision = spec.get("collision", false)
	chunk.skirt_depth = skirt_depth
	chunk.vertices_per_batch = vertices_per_batch
	chunk.material = material


func _on_built(cell: Vector2i) -> void:
	_building = maxi(_building - 1, 0)
	_pending.erase(cell)


## Which detail tier a given distance falls in, or -1 if past the horizon.
func _tier_for(distance: float) -> int:
	for i in detail_tiers.size():
		if distance <= float(detail_tiers[i]["distance"]):
			return i
	return -1


func _cell_at(xz: Vector2) -> Vector2i:
	return Vector2i(int(floor(xz.x / chunk_size)), int(floor(xz.y / chunk_size)))


func _cell_center(cell: Vector2i) -> Vector2:
	return Vector2((cell.x + 0.5) * chunk_size, (cell.y + 0.5) * chunk_size)
