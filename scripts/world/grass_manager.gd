class_name GrassManager
extends Node3D

## Streams GrassField chunks in and out around the player, instead of placing
## a fixed set of meadow patches once at zone load.
##
## The map can be grassed wall-to-wall because at any moment only the chunks
## near the player actually exist as MultiMeshes — cost is bounded by what a
## player standing at that spot could possibly see, not by the size of the
## map. This also spreads placement (raycasting) out over the time the player
## spends walking around, rather than paying for the whole map's worth of
## rays in one lump at zone load.
##
## Chunks are square, not GrassField's default circular patch: a circle either
## leaves the corners of a grid cell bald, or (sized to cover them) overlaps
## and double-plants the band shared with its neighbour. A square tiles the
## grid exactly, with no seam and no doubled density at the boundary.
##
## EACH CHUNK IS TWO LAYERS. A base layer (base_density_fraction of the target
## density) builds the moment the chunk enters load_radius, so nothing is ever
## missing. A detail layer — the remaining blades, up to full density — only
## builds once the player is within the tighter detail_radius, and grows in
## over detail_fade_time via the grass shader's `growth` uniform rather than
## snapping to full size. This exists because raising density map-wide costs
## GPU time on every loaded chunk whether or not the player is standing next
## to it; splitting density into "always this much" and "this much more, only
## up close, eased in" spends the extra blades only where they're actually
## being looked at closely, without the plain distance-tiered version's flaw
## of a chunk staying under-dense forever once built far away.

const GRASS_SCRIPT := preload("res://scripts/terrain/grass_field.gd")
const DEFAULT_GRASS_MATERIAL := preload("res://resources/materials/grass_blades.tres")

@export_group("Grid")
## Side length of one chunk, in world units. An implementation detail, not a
## visual tuning knob — changing it reshuffles where chunk boundaries fall
## but should not change what the result looks like.
@export var chunk_size := 20.0
## Distance from the player at which a chunk's base layer starts loading.
## Sized to clear everything the isometric camera can show at a little past
## the default zoom (camera_rig.gd: distance 20, pitch -45, fov 45 puts the
## far edge of the view roughly 30-35 units out at default zoom), in any
## direction the player rotates the camera to — padded well past that so
## nothing pops in mid-frame even zoomed out further.
@export var load_radius := 45.0
## Distance at which a loaded chunk (both layers) is freed entirely. Kept a
## full chunk_size or more above load_radius so a player standing near the
## boundary, drifting a step back and forth, cannot thrash a chunk in and out
## repeatedly.
@export var unload_radius := 65.0
## How often to re-scan which chunks/layers should be loaded/freed. The
## player moves slowly relative to chunk_size, so there is no need to check
## every frame.
@export var check_interval := 0.25
## Coarse guard: if the player is somehow this far from the origin, stop
## considering new chunks rather than reaching for terrain that isn't there.
@export var map_half_extent := 90.0
## At most this many layer-builds (base or detail, across all chunks) may be
## actively raycasting at once. Each one already spreads its own raycasts
## across several frames (see grass_field.gd's raycasts_per_batch) — this
## caps how many of those batches can land in the same frame, so total
## per-frame raycast cost stays bounded no matter how full the queue is.
@export var max_concurrent_builds := 1

@export_group("Grass")
@export var density := 30.0
## Fraction of density used for a chunk's base layer. The rest comes from the
## detail layer once the player is within detail_radius.
@export_range(0.05, 1.0, 0.05) var base_density_fraction := 0.4
## Distance from the player within which a chunk grows its detail layer.
## Deliberately tighter than load_radius — the base layer alone should
## already look acceptable at the edge of view, so only the ground actually
## close to the player pays for full density.
@export var detail_radius := 22.0
## Distance at which a grown-in detail layer fades out and frees, falling
## back to the base layer. Kept above detail_radius for the same
## anti-thrash reason load_radius/unload_radius are split.
@export var detail_unload_radius := 32.0
## Seconds for a detail layer to grow from nothing to full size after it
## finishes building, and to shrink back to nothing before it's freed.
@export var detail_fade_time := 1.0
## Safety ceiling per layer, same purpose as GrassField's own max_blades — it
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

## Vector2i cell -> {"base": GrassField, "detail": GrassField|null,
## "detail_state": "none"|"pending"|"active"|"fading_out"}.
var _active: Dictionary = {}
## Vector2i cell -> true while a chunk's base layer is queued or building.
## While true the chunk cannot be unloaded and its detail layer is left alone.
var _pending_base: Dictionary = {}
## String task key -> true while that specific layer-build is queued or
## actively building. Purely a concurrency counter for max_concurrent_builds.
var _building: Dictionary = {}
## Array of {"cell": Vector2i, "kind": "base"|"detail"}, FIFO.
var _build_queue: Array = []
var _timer := 0.0


func _process(delta: float) -> void:
	_timer += delta
	if _timer >= check_interval:
		_timer = 0.0
		_rescan()
	_drain_build_queue()


## Queues newly-in-range base layers, starts/stops detail layers on chunks
## that already have a base, and frees whole chunks that drifted well out of
## range.
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

	_queue_new_base_chunks(player_xz, half_diag)
	_update_detail_layers(player_xz, half_diag)
	_free_out_of_range_chunks(player_xz, half_diag)


func _queue_new_base_chunks(player_xz: Vector2, half_diag: float) -> void:
	var p := player_xz
	var cell_min_x := int(floor((p.x - load_radius) / chunk_size))
	var cell_max_x := int(floor((p.x + load_radius) / chunk_size))
	var cell_min_z := int(floor((p.y - load_radius) / chunk_size))
	var cell_max_z := int(floor((p.y + load_radius) / chunk_size))

	for cx in range(cell_min_x, cell_max_x + 1):
		for cz in range(cell_min_z, cell_max_z + 1):
			var cell := Vector2i(cx, cz)
			if _active.has(cell) or _pending_base.has(cell):
				continue
			if p.distance_to(_cell_center(cell)) - half_diag > load_radius:
				continue
			_pending_base[cell] = true
			_build_queue.append({"cell": cell, "kind": "base"})


func _update_detail_layers(player_xz: Vector2, half_diag: float) -> void:
	for cell in _active.keys():
		if _pending_base.has(cell):
			continue # Base isn't finished yet; leave detail alone until it is.
		var entry: Dictionary = _active[cell]
		var dist := player_xz.distance_to(_cell_center(cell)) - half_diag
		match entry["detail_state"]:
			"none":
				if dist <= detail_radius:
					entry["detail_state"] = "pending"
					_build_queue.append({"cell": cell, "kind": "detail"})
			"active":
				if dist > detail_unload_radius:
					entry["detail_state"] = "fading_out"
					_fade_out_detail(cell)
			_:
				pass # "pending" or "fading_out" — let it finish first.


func _free_out_of_range_chunks(player_xz: Vector2, half_diag: float) -> void:
	var to_free: Array = []
	for cell in _active.keys():
		# Leave chunks whose base is still building, or whose detail is mid
		# transition, alone — freeing now would free a node out from under its
		# own in-flight await or tween. Caught on a later scan once settled.
		if _pending_base.has(cell):
			continue
		var entry: Dictionary = _active[cell]
		if entry["detail_state"] == "pending" or entry["detail_state"] == "fading_out":
			continue
		if player_xz.distance_to(_cell_center(cell)) - half_diag > unload_radius:
			to_free.append(cell)
	for cell in to_free:
		var entry: Dictionary = _active[cell]
		_active.erase(cell)
		entry["base"].queue_free()
		if entry["detail"] != null:
			entry["detail"].queue_free()


func _drain_build_queue() -> void:
	while _building.size() < max_concurrent_builds and not _build_queue.is_empty():
		var task: Dictionary = _build_queue.pop_front()
		if task["kind"] == "base":
			_spawn_base(task["cell"])
		else:
			_spawn_detail(task["cell"])


func _spawn_base(cell: Vector2i) -> void:
	var field := _make_field(cell, density * base_density_fraction, 0x0)
	field.name = "Chunk_%d_%d_base" % [cell.x, cell.y]
	field.material = material if material else null # DEFAULT_MATERIAL is used automatically.
	var key := _task_key("base", cell)
	_building[key] = true
	field.built.connect(_on_base_built.bind(cell, key))
	add_child(field)
	_active[cell] = {"base": field, "detail": null, "detail_state": "none"}


func _on_base_built(cell: Vector2i, key: String) -> void:
	_building.erase(key)
	_pending_base.erase(cell)


func _spawn_detail(cell: Vector2i) -> void:
	var remaining := density * (1.0 - base_density_fraction)
	# Different seed offset from the base layer so the two scatters interleave
	# instead of landing on the same spots.
	var field := _make_field(cell, remaining, 0x2b1a)
	field.name = "Chunk_%d_%d_detail" % [cell.x, cell.y]
	var mat: ShaderMaterial = (material if material else DEFAULT_GRASS_MATERIAL).duplicate()
	mat.set_shader_parameter("growth", 0.0)
	field.material = mat
	var key := _task_key("detail", cell)
	_building[key] = true
	field.built.connect(_on_detail_built.bind(cell, key))
	add_child(field)
	_active[cell]["detail"] = field


func _on_detail_built(cell: Vector2i, key: String) -> void:
	_building.erase(key)
	var entry: Dictionary = _active.get(cell, {})
	var field: GrassField = entry.get("detail")
	if field == null:
		return # Chunk (or just this layer) was freed while building.
	entry["detail_state"] = "active"
	var mat: Material = field.material
	var tween := create_tween()
	tween.tween_method(func(v: float) -> void: mat.set_shader_parameter("growth", v),
		0.0, 1.0, detail_fade_time)


func _fade_out_detail(cell: Vector2i) -> void:
	var entry: Dictionary = _active[cell]
	var field: GrassField = entry["detail"]
	var mat: Material = field.material
	var tween := create_tween()
	tween.tween_method(func(v: float) -> void: mat.set_shader_parameter("growth", v),
		1.0, 0.0, detail_fade_time)
	tween.finished.connect(_on_detail_faded_out.bind(cell, field))


func _on_detail_faded_out(cell: Vector2i, field: GrassField) -> void:
	if is_instance_valid(field):
		field.queue_free()
	# The chunk itself may have been freed entirely while this was fading;
	# only clear the layer state if it's still around.
	if _active.has(cell) and _active[cell]["detail"] == field:
		_active[cell]["detail"] = null
		_active[cell]["detail_state"] = "none"


func _make_field(cell: Vector2i, layer_density: float, seed_salt: int) -> GrassField:
	var field: GrassField = GRASS_SCRIPT.new()
	field.square_size = chunk_size
	field.density = layer_density
	field.max_blades = max_blades_per_chunk
	field.blade_height = blade_height
	field.blade_width = blade_width
	field.blade_segments = blade_segments
	field.blade_droop = blade_droop
	field.height_variation = height_variation
	field.max_slope_degrees = max_slope_degrees
	# Deterministic per chunk (and per layer, via seed_salt) so reloading the
	# same area looks the same, while neighbours and layers don't repeat an
	# identical scatter.
	field.seed = seed ^ (cell.x * 92821) ^ (cell.y * 68917) ^ seed_salt
	var center := _cell_center(cell)
	field.position = Vector3(center.x, 0.0, center.y)
	return field


func _task_key(kind: String, cell: Vector2i) -> String:
	return "%s:%d:%d" % [kind, cell.x, cell.y]


func _cell_center(cell: Vector2i) -> Vector2:
	return Vector2((cell.x + 0.5) * chunk_size, (cell.y + 0.5) * chunk_size)
