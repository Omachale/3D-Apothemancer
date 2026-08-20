class_name TreeScatterManager
extends Node3D

## Streams ambient tree cover in a grid of chunks around the player, exactly
## the way grass_manager.gd streams grass and terrain_manager.gd streams
## ground — because a tree scatter built the OTHER way (a finite pre-placed
## list, however large) always has an edge, and "trees run out if you walk
## far enough in a straight line" is a report about that edge, not about not
## having enough entries in the list. See [Zone]'s `generators.mountain_trees`
## and `generators.forest` for the other kind of tree source this does NOT
## replace: a specific, hand-tuned, finite stand IS the right tool for a
## landmark. This is only for open ground that should never run out.
##
## HOW MANY TREES A CHUNK GETS comes from low-frequency noise sampled at its
## centre — the same technique heightfield.gd already uses for rolling
## ground and mountains, just read as a tree count instead of a height. That
## is what turns "trees everywhere" into copses, glades and forests rather
## than a uniform sprinkle: a whole neighbourhood of chunks shares similar
## noise, so density rises and falls together over tens of chunks, not one
## at a time. [member trees_per_chunk_floor] is layered UNDER that noise
## rather than instead of it — every chunk gets at least that many candidate
## trees regardless of the roll, so the actual failure mode this exists to
## fix (a whole screen of bare ground) cannot happen by construction; the
## noise only ever adds density on top of the floor, up to
## [member trees_per_chunk_max].
##
## DETERMINISTIC WITHOUT BEING STORED, same principle as every other
## generated layer in this project (see [[DESIGN_GOALS.md]]): a chunk's seed
## is derived from [member seed] and its own cell coordinate, so leaving a
## chunk's range and walking back in regrows exactly the trees that were
## there before, with nothing saved to disk. Two players on the same seed see
## the same forest in the same place.
##
## Chunks are much bigger than grass's (dozens of metres, not twenty) and
## hold a handful of real StaticBody3D tree instances each, not a MultiMesh —
## unlike grass blades, trees need individual trunk collision (see
## PineTreeProp.tscn) and there are orders of magnitude fewer of them per
## chunk, so building one is cheap enough to do in a single frame with no
## batching.

const PINE_SCENE := preload("res://scenes/props/PineTreeProp.tscn")

@export_group("Grid")
## Side length of one chunk. Deliberately much larger than grass's chunk_size
## (20): a tree is visible from far further away than a grass blade, so
## covering the same view distance in grass-sized chunks would mean tracking
## many times more of them for no visual gain.
@export var chunk_size := 48.0
## Distance from the camera at which a chunk starts loading, at default zoom.
## Same floor-not-replacement relationship to zoom as grass_manager.gd's
## load_radius — see [member radius_per_distance].
@export var load_radius := 140.0
@export var unload_radius := 170.0
@export var radius_per_distance := 2.0
@export var max_radius := 260.0
@export var check_interval := 0.5
## Coarse sanity guard, same purpose and same value convention as
## grass_manager.gd's map_half_extent — the heightfield has no edge, so this
## only catches a wildly out-of-bounds position, not a real map boundary.
@export var map_half_extent := 100000.0
## At most this many chunks build in one call to [method _drain_build_queue]
## per frame. Building a chunk here is cheap (a handful of scene
## instantiations, not tens of thousands of placements like grass), so unlike
## grass_manager.gd this needs no cross-frame batching within a single
## chunk — only a cap on how many chunks can land in the same frame, for the
## case where many queue at once (zone load, or a run that crosses several
## chunks between rescans).
@export var max_chunks_per_frame := 2

@export_group("Density")
## Where the ground is — passed through to every placement so trees follow
## the actual terrain, including rolling and every feature.
@export var heightfield: Heightfield = null
## Seeds both the per-chunk placement RNG and the density noise. Changing it
## reshuffles where every tree in the world stands.
@export var seed := 30500
## How tightly the density noise repeats. Lower is broader patches (bigger
## forests and bigger glades between them); higher is a finer-grained mix.
## 0.012 puts a full feature roughly 80 world units across — copse- and
## glade-sized, not continent-sized.
@export var noise_frequency := 0.012
## Guaranteed candidate trees per chunk, before the noise adds anything.
## THIS is what prevents a chunk-sized patch of bare ground from ever
## existing by construction — see the file header. Some of these candidates
## can still be rejected individually (too steep, inside an exclusion, inside
## the spawn clearing), so the realised count can still occasionally drop to
## zero in an unlucky chunk; entire REGIONS cannot, because neighbouring
## chunks roll independently.
@export var trees_per_chunk_floor := 1
## Candidate trees per chunk at the noise's maximum, on top of the floor.
@export var trees_per_chunk_max := 10
## Noise value (roughly -1..1) below which a chunk gets no bonus above the
## floor. Set well under 0 so only a minority of chunks read as sparse —
## most land in the middle tiers between floor and max.
@export var bare_threshold := -0.15
## Ground steeper than this gets no tree, same reasoning as
## grass_field.gd's identical dial — keeps trees off stair ramps and cliff
## faces without needing to know they are there.
@export var max_slope_degrees := 35.0
## World-space rectangles where no tree is placed — building footprints,
## the same list grass_manager.gd's chunks already exclude from (see
## zone.gd's get_grass_exclusions; despite the name it is really "structure
## footprints", shared by both).
@export var exclusions: Array = []
## Circle around [member clear_center] kept free of ambient trees, so the
## starting view isn't cluttered the moment the player spawns. Independent
## of the landmark generators, which already keep their own clearings.
@export var clear_center := Vector2.ZERO
@export var clear_radius := 40.0
@export var scale_min := 0.75
@export var scale_max := 1.3
@export var scene: PackedScene = null

## Vector2i cell -> Node3D (the chunk's container).
var _active: Dictionary = {}
var _pending: Dictionary = {}
## Array of {"cell": Vector2i, "distance": float}, nearest-first — same
## reasoning as grass_manager.gd's _build_queue.
var _build_queue: Array = []
var _timer := 0.0
var _density_noise := FastNoiseLite.new()
var _noise_ready := false


func _process(delta: float) -> void:
	# Zone.build() runs in the editor too, where Game is not fully
	# constructed — identical guard to grass_manager.gd's _process.
	if Engine.is_editor_hint():
		return
	_timer += delta
	if _timer >= check_interval:
		_timer = 0.0
		_rescan()
	_drain_build_queue()


func _rescan() -> void:
	if Game.player == null:
		return
	var cam := Game.camera_rig.global_position if Game.camera_rig else Game.player.global_position
	if absf(cam.x) > map_half_extent or absf(cam.z) > map_half_extent:
		return
	var view_xz := Vector2(cam.x, cam.z)
	var half_diag := chunk_size * 0.7072
	var radii := _effective_radii()

	_queue_new_chunks(view_xz, half_diag, radii[0])
	_free_out_of_range_chunks(view_xz, half_diag, radii[1])
	_build_queue.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["distance"] < b["distance"])


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
		var chunk: Node3D = _active[cell]
		_active.erase(cell)
		chunk.queue_free()


func _drain_build_queue() -> void:
	var built := 0
	while built < max_chunks_per_frame and not _build_queue.is_empty():
		var task: Dictionary = _build_queue.pop_front()
		var cell: Vector2i = task["cell"]
		if not _pending.has(cell):
			continue
		_spawn(cell)
		_pending.erase(cell)
		built += 1


## Builds one chunk's trees synchronously — cheap enough (at most
## trees_per_chunk_max scene instantiations) that no cross-frame batching is
## needed, unlike grass_field.gd's per-blade placement.
func _spawn(cell: Vector2i) -> void:
	if not _noise_ready:
		_density_noise.seed = seed
		_density_noise.frequency = noise_frequency
		_density_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		_density_noise.fractal_octaves = 2
		_noise_ready = true

	var center := _cell_center(cell)
	var chunk := Node3D.new()
	chunk.name = "TreeChunk_%d_%d" % [cell.x, cell.y]
	chunk.position = Vector3(center.x, 0.0, center.y)

	var half := chunk_size * 0.5
	var count := _tree_count_for_chunk(center)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed ^ (cell.x * 92821) ^ (cell.y * 68917)
	var min_up := cos(deg_to_rad(max_slope_degrees))
	var tree_scene: PackedScene = scene if scene else PINE_SCENE

	for _i in count:
		var x := center.x + rng.randf_range(-half, half)
		var z := center.y + rng.randf_range(-half, half)
		if Vector2(x, z).distance_to(clear_center) < clear_radius:
			continue
		if _is_excluded(x, z):
			continue
		var height := heightfield.height_at(x, z)
		var up := heightfield.slope_cosine_at(x, z, height)
		if up < min_up:
			continue
		var tree: Node3D = tree_scene.instantiate()
		tree.position = Vector3(x - center.x, height, z - center.y)
		tree.rotation = Vector3(0.0, rng.randf_range(0.0, TAU), 0.0)
		var s := rng.randf_range(scale_min, scale_max)
		tree.scale = Vector3(s, s, s)
		chunk.add_child(tree)

	add_child(chunk)
	_active[cell] = chunk


## Candidate tree count for the chunk centred at [param center]: the
## guaranteed floor, plus a noise-driven bonus that reads as copses and
## glades rather than uniform density — see the file header. Some candidates
## are still rejected individually in [method _spawn] (slope, exclusions,
## the spawn clearing), so this is an upper bound, not the realised count.
func _tree_count_for_chunk(center: Vector2) -> int:
	if not _noise_ready:
		_density_noise.seed = seed
		_density_noise.frequency = noise_frequency
		_density_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		_density_noise.fractal_octaves = 2
		_noise_ready = true
	var n := _density_noise.get_noise_2d(center.x, center.y)
	if n <= bare_threshold:
		return trees_per_chunk_floor
	var t := clampf((n - bare_threshold) / (1.0 - bare_threshold), 0.0, 1.0)
	var bonus := int(round(t * (trees_per_chunk_max - trees_per_chunk_floor)))
	return trees_per_chunk_floor + bonus


func _is_excluded(x: float, z: float) -> bool:
	if exclusions.is_empty():
		return false
	var p := Vector2(x, z)
	for rect: Rect2 in exclusions:
		if rect.has_point(p):
			return true
	return false


func _cell_center(cell: Vector2i) -> Vector2:
	return Vector2((cell.x + 0.5) * chunk_size, (cell.y + 0.5) * chunk_size)
