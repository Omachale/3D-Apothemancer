extends SceneTree

## Checks terrain_chunk.gd builds ground that matches the heightfield, joins up
## with its neighbours, and gets cheaper at lower detail — without launching the
## game. The seam checks are the point: a tile that is individually correct can
## still leave a visible crack against a neighbour built at different detail,
## and that is exactly the failure that is hard to spot by eye and easy to
## measure here.
##
## Run: Godot --headless --script res://scripts/dev/verify_terrain_chunk.gd
## Exits non-zero if any check fails.

var _fails := 0


func _init() -> void:
	_run()


func _run() -> void:
	# _init runs before the scene tree is live, and a node only builds itself
	# once it is actually in the tree. One frame's grace fixes that — the same
	# reason grass_field.gd waits a physics frame before planting.
	await process_frame

	var field := Heightfield.new()
	field.rolling_amplitude = 0.8
	field.rolling_frequency = 0.02
	field.features = [
		{"pos": Vector2(16, 16), "radius": 40.0, "height": 9.0, "noise": 1.2},
	]

	_check_shape_matches_heightfield(field)
	_check_vertex_counts(field)
	_check_collision_optional(field)
	_check_neighbour_seam_same_detail(field)
	_check_neighbour_seam_across_detail(field)
	_check_normals_agree_across_tiles(field)
	await _check_batching(field)
	_report_cost(field)

	print("")
	if _fails == 0:
		print("ALL TERRAIN CHUNK CHECKS PASSED")
	else:
		print("%d CHECK(S) FAILED" % _fails)
	quit(1 if _fails > 0 else 0)


func _fail(msg: String) -> void:
	print("FAIL " + msg)
	_fails += 1


## Batching off, so the tile is finished by the time add_child returns and the
## checks can stay straightforward. Batched building is exercised separately by
## [method _check_batching], which is where it matters.
func _make(field: Heightfield, at: Vector3, size: float, res: int,
		collision := true) -> TerrainChunk:
	var chunk := TerrainChunk.new()
	chunk.heightfield = field
	chunk.size = size
	chunk.resolution = res
	chunk.build_collision = collision
	chunk.vertices_per_batch = 0
	chunk.position = at
	root.add_child(chunk)
	return chunk


## Every vertex the tile draws must sit exactly where the heightfield says the
## ground is. If this drifts, nothing downstream can be trusted.
func _check_shape_matches_heightfield(field: Heightfield) -> void:
	var chunk := _make(field, Vector3(0, 0, 0), 32.0, 16)
	var verts: PackedVector3Array = chunk.get_node("Surface").mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var worst := 0.0
	# Only the grid vertices; the skirt's dropped twins are deliberately below
	# the surface and would fail this by design.
	for i in chunk.get_vertex_count():
		var v := verts[i]
		var world := chunk.global_position + v
		worst = maxf(worst, absf(world.y - field.height_at(world.x, world.z)))
	if worst > 0.0001:
		_fail("mesh drifts from heightfield by up to %f" % worst)
	print("shape: %d vertices, worst drift from heightfield %.6f" % [
		chunk.get_vertex_count(), worst])
	chunk.free()


## Resolution is the detail dial, so vertex count must follow it as (res+1)^2.
func _check_vertex_counts(field: Heightfield) -> void:
	var line := []
	for res in [4, 8, 16, 32]:
		var chunk := _make(field, Vector3.ZERO, 32.0, res, false)
		var want: int = (res + 1) * (res + 1)
		if chunk.get_vertex_count() != want:
			_fail("res %d gave %d vertices, want %d" % [res, chunk.get_vertex_count(), want])
		line.append("res %d -> %d verts" % [res, chunk.get_vertex_count()])
		chunk.free()
	print("detail dial: " + ", ".join(line))


## Distant tiles skip collision entirely; near tiles must have it, and it must
## cover the tile's whole surface.
func _check_collision_optional(field: Heightfield) -> void:
	var near := _make(field, Vector3.ZERO, 32.0, 16, true)
	var far := _make(field, Vector3(200, 0, 0), 32.0, 4, false)

	var near_shape := near.get_node_or_null("Collider")
	if near_shape == null or near_shape.shape == null:
		_fail("near tile has no collision shape")
	else:
		var faces: PackedVector3Array = near_shape.shape.get_faces()
		var want := 16 * 16 * 6
		if faces.size() != want:
			_fail("collision has %d face vertices, want %d" % [faces.size(), want])
		print("collision: near tile %d triangles covering the full surface" % (faces.size() / 3))
	if far.get_node_or_null("Collider") != null:
		_fail("far tile built a collision shape it was told to skip")
	print("collision: far tile correctly has none")
	near.free()
	far.free()


## Two tiles at the same detail share an edge exactly, so their vertices along
## it must coincide to the last decimal.
func _check_neighbour_seam_same_detail(field: Heightfield) -> void:
	var a := _make(field, Vector3(-16, 0, 0), 32.0, 16, false)
	var b := _make(field, Vector3(16, 0, 0), 32.0, 16, false)
	var gap := _worst_edge_gap(a, b, 0.0)
	if gap > 0.0001:
		_fail("same-detail neighbours disagree along their seam by %f" % gap)
	print("seam, equal detail: worst height disagreement %.6f" % gap)
	a.free()
	b.free()


## The hard case: a fine tile against a coarse one. Their shared vertices must
## still match exactly; in between, the fine tile bulges off the coarse tile's
## straight edge, and that gap is precisely what the skirt has to be deep enough
## to hide.
func _check_neighbour_seam_across_detail(field: Heightfield) -> void:
	var fine := _make(field, Vector3(-16, 0, 0), 32.0, 32, false)
	var coarse := _make(field, Vector3(16, 0, 0), 32.0, 4, false)
	var gap := _worst_edge_gap(fine, coarse, 0.0)
	var skirt: float = fine.skirt_depth
	if gap >= skirt:
		_fail("seam gap %.3f reaches or exceeds skirt_depth %.3f — cracks would show" % [gap, skirt])
	print("seam, 32 vs 4 detail: worst gap %.3f, skirt covers %.1f (%.0f%% headroom)" % [
		gap, skirt, (1.0 - gap / skirt) * 100.0])
	fine.free()
	coarse.free()


## Worst vertical disagreement between two tiles along the plane x = [param
## seam_x], comparing each tile's edge vertices against the other tile's edge
## as a straight line between its own vertices — which is what the eye actually
## sees, and what a crack is.
func _worst_edge_gap(a: TerrainChunk, b: TerrainChunk, seam_x: float) -> float:
	var edge_a := _edge_points(a, seam_x)
	var edge_b := _edge_points(b, seam_x)
	if edge_a.is_empty() or edge_b.is_empty():
		_fail("one of the tiles has no vertices on the seam")
		return INF
	return maxf(_worst_deviation(edge_a, edge_b), _worst_deviation(edge_b, edge_a))


## A tile's grid vertices that lie on the seam plane, as (z, height) pairs in
## world space, sorted along the seam.
func _edge_points(chunk: TerrainChunk, seam_x: float) -> Array:
	var verts: PackedVector3Array = chunk.get_node("Surface").mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var out: Array = []
	for i in chunk.get_vertex_count():
		var world: Vector3 = chunk.global_position + verts[i]
		if absf(world.x - seam_x) < 0.0001:
			out.append(Vector2(world.z, world.y))
	out.sort_custom(func(p: Vector2, q: Vector2) -> bool: return p.x < q.x)
	return out


## How far [param points] stray from the line [param other] draws between its
## own vertices.
func _worst_deviation(points: Array, other: Array) -> float:
	var worst := 0.0
	for p: Vector2 in points:
		worst = maxf(worst, absf(p.y - _sample_polyline(other, p.x)))
	return worst


func _sample_polyline(line: Array, at: float) -> float:
	if at <= line[0].x:
		return line[0].y
	for i in range(1, line.size()):
		var prev: Vector2 = line[i - 1]
		var cur: Vector2 = line[i]
		if at <= cur.x:
			var span: float = cur.x - prev.x
			if span < 0.000001:
				return cur.y
			return lerpf(prev.y, cur.y, (at - prev.x) / span)
	return line[line.size() - 1].y


## Normals come from the heightfield rather than from each tile's own
## triangles, so two tiles must agree about which way the ground faces along
## their shared edge — otherwise the join shows as a lit crease even when the
## geometry lines up perfectly.
func _check_normals_agree_across_tiles(field: Heightfield) -> void:
	var a := _make(field, Vector3(-16, 0, 0), 32.0, 16, false)
	var b := _make(field, Vector3(16, 0, 0), 32.0, 16, false)
	var na := _edge_normals(a, 0.0)
	var nb := _edge_normals(b, 0.0)
	var worst := 0.0
	var upright := true
	for key in na:
		if nb.has(key):
			worst = maxf(worst, (na[key] as Vector3).distance_to(nb[key]))
		if (na[key] as Vector3).y <= 0.0:
			upright = false
	if worst > 0.0001:
		_fail("neighbouring tiles disagree on surface direction by %f" % worst)
	if not upright:
		_fail("some normals point downward — ground would render black and be unstandable")
	print("seam normals: worst disagreement %.6f, all pointing upward" % worst)
	a.free()
	b.free()


func _edge_normals(chunk: TerrainChunk, seam_x: float) -> Dictionary:
	var arrays: Array = chunk.get_node("Surface").mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var out := {}
	for i in chunk.get_vertex_count():
		var world: Vector3 = chunk.global_position + verts[i]
		if absf(world.x - seam_x) < 0.0001:
			out[snappedf(world.z, 0.001)] = norms[i]
	return out


## A batched build must spread itself over several frames AND produce exactly
## the same ground as an unbatched one. Spreading the work is only useful if it
## does not quietly change the result.
func _check_batching(field: Heightfield) -> void:
	var whole := _make(field, Vector3(64, 0, 64), 32.0, 32, true)

	var batched := TerrainChunk.new()
	batched.heightfield = field
	batched.size = 32.0
	batched.resolution = 32
	batched.build_collision = true
	batched.vertices_per_batch = 250
	batched.position = Vector3(64, 0, 64)
	var first_frame := Engine.get_process_frames()
	root.add_child(batched)
	await batched.built
	var frames := Engine.get_process_frames() - first_frame

	if frames < 2:
		_fail("batched build finished in %d frame(s) — it is not actually spreading" % frames)

	var va: PackedVector3Array = whole.get_node("Surface").mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var vb: PackedVector3Array = batched.get_node("Surface").mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	if va.size() != vb.size():
		_fail("batched tile has %d vertices, unbatched has %d" % [vb.size(), va.size()])
	else:
		var worst := 0.0
		for i in va.size():
			worst = maxf(worst, va[i].distance_to(vb[i]))
		if worst > 0.0001:
			_fail("batched and unbatched tiles differ by up to %f" % worst)
		print("batching: spread over %d frames, identical geometry (worst diff %.6f)" % [
			frames, worst])
	print("batching: %d ms of work, so roughly %.1f ms per frame" % [
		batched.get_build_msec(), float(batched.get_build_msec()) / maxf(float(frames), 1.0)])
	# queue_free, not free: execution resumes here from inside built.emit(), and
	# Godot forbids destroying an object part-way through emitting one of its
	# own signals. Worth remembering for terrain_manager, which will be
	# listening to exactly this signal.
	whole.queue_free()
	batched.queue_free()


## What a tile actually costs, and how much of that a lower detail level saves.
## These are the numbers terrain_manager will budget against.
func _report_cost(field: Heightfield) -> void:
	print("")
	print("cost per 32-unit tile:")
	for res in [4, 8, 16, 32, 64]:
		# Timed over several builds; a single one is too quick to measure well.
		var started := Time.get_ticks_usec()
		var runs := 8
		var verts := 0
		for _r in runs:
			var chunk := _make(field, Vector3.ZERO, 32.0, res, res >= 16)
			verts = chunk.get_vertex_count()
			chunk.free()
		var each := float(Time.get_ticks_usec() - started) / float(runs) / 1000.0
		print("  res %2d: %5d verts, %s, %.2f ms" % [
			res, verts, "with collision" if res >= 16 else "no collision   ", each])
