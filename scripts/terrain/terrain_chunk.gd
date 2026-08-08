class_name TerrainChunk
extends StaticBody3D

## One square tile of ground, built by sampling [Heightfield] on a grid.
##
## This is where "draw less, more cleverly" actually happens. The tile's shape
## comes from a function, not from stored geometry, so the SAME tile can be
## built at any [member resolution] — a hundred vertices or ten thousand — and
## still be the same hill in the same place. Near the player, build it fine.
## Two hundred metres away, build it coarse for a fraction of the cost and
## nobody can tell, because it is twenty pixels tall on screen.
##
## NOT a @tool script, matching grass_field.gd: chunks are streamed in at
## runtime by terrain_manager.gd and do not appear in the editor viewport.
##
## THREE THINGS HERE ARE SUBTLER THAN THEY LOOK.
##
## 1. NORMALS COME FROM THE HEIGHTFIELD, NOT FROM THE TRIANGLES. The obvious
##    approach — SurfaceTool.generate_normals(), as terrain_mound.gd uses — only
##    averages the triangles inside THIS tile, so two neighbouring tiles
##    disagree about which way the ground faces along their shared edge and the
##    join shows up as a lit crease. Asking the heightfield directly gives an
##    answer that depends only on world position, so neighbours agree exactly
##    and the seam disappears. It also lets a coarse tile be lit as though it
##    had detail it does not geometrically have, which is the cheap half of
##    what a normal map does.
##
## 2. THE SKIRT. Where a fine tile meets a coarse one, their edges do not line
##    up: the fine tile has vertices in between the coarse tile's, and those sit
##    slightly off the straight line the coarse edge draws, leaving hairline
##    cracks you can see the sky through. Rather than matching edge vertices
##    between neighbours — which couples every tile to every neighbour and is a
##    great deal of bookkeeping — each tile drops a short vertical apron around
##    its border. The cracks are still there; they are just looking at the
##    inside of a wall. Standard practice, and much the cheaper fix.
##
## 3. COLLISION IS BUILT SEPARATELY FROM THE VISIBLE MESH, and only when asked
##    for. The skirt must not be collidable (it is a hidden wall the player
##    would otherwise catch on), and distant tiles need no collision at all
##    because nothing will ever stand on them. Far tiles therefore skip both the
##    shape and a good share of the build cost.

const DEFAULT_MATERIAL := preload("res://resources/materials/ground_grass.tres")

## Emitted once the mesh (and collision, if requested) exists. terrain_manager
## waits on this to throttle how many tiles build at once, the same way
## grass_manager waits on GrassField.built.
signal built

## Where the ground's shape comes from. Without one the tile builds nothing.
var heightfield: Heightfield = null
## Side length in world units. The tile is centred on its own origin, so it
## spans -size/2 to +size/2 on both axes — the same convention GrassField's
## square_size uses, so a terrain tile and a grass chunk of equal size line up
## exactly.
var size := 32.0
## Grid cells per side. THE DETAIL DIAL: vertex count is (resolution + 1)
## squared, so cost grows with the square of this. Halving it quarters both the
## build cost and the triangle count for the same piece of ground.
var resolution := 16
## Whether to build a collision shape. Only tiles the player can reach need
## one — see note 3 above.
var build_collision := true
## How far the border apron hangs below the tile's edge, in world units. Needs
## to exceed the worst height disagreement between this tile and a coarser
## neighbour: a couple of metres covers gentle terrain, more for dramatic hills.
## Costs nothing but a ring of triangles. 0 disables it.
var skirt_depth := 2.0
var material: Material = null
## Building yields to the tree after roughly this many vertices, so a fine tile
## is spread over several frames instead of blocking one for its whole build.
## A detailed tile costs over 10 ms in one go, which is a dropped frame landing
## exactly when the player walks somewhere new — the same problem, and the same
## fix, as grass_field.gd's samples_per_batch. 0 disables batching (builds in
## one frame).
var vertices_per_batch := 250

var _mesh_instance: MeshInstance3D = null
var _collider: CollisionShape3D = null
var _grid_vertex_count := 0
var _build_msec := 0
## Work actually done, with the time spent waiting for frames excluded — see
## [method _yield_now].
var _work_usec := 0
var _mark_usec := 0
var _since_yield := 0


func _ready() -> void:
	collision_layer = Layers.WORLD
	collision_mask = 0
	build()


## Vertices in this tile's ground surface, excluding the hidden skirt. The
## number that says what the tile cost, and the one that changes with
## [member resolution].
func get_vertex_count() -> int:
	return _grid_vertex_count


## Milliseconds of actual work the last build took, NOT counting time spent
## waiting between frames. The number that decides how many tiles can be built
## at once without a visible hitch.
func get_build_msec() -> int:
	return _build_msec


## Hands the frame back if this build has done enough work for now. Keeps
## [member _work_usec] counting only real work, so the cost figure stays
## comparable whether or not batching is on.
func _yield_now() -> void:
	_work_usec += Time.get_ticks_usec() - _mark_usec
	await get_tree().process_frame
	_mark_usec = Time.get_ticks_usec()


func build() -> void:
	_work_usec = 0
	_mark_usec = Time.get_ticks_usec()
	_since_yield = 0
	if heightfield == null:
		push_warning("TerrainChunk '%s': no heightfield, nothing to build." % name)
		built.emit()
		return

	var res := maxi(resolution, 1)
	var stride := res + 1
	var step := size / float(res)
	var half := size * 0.5
	var origin := global_position

	# Normals are measured over half a cell rather than over a fixed distance,
	# so each tile reports slope at the scale it is actually built at. A coarse
	# tile asking about half-metre detail it does not have would light up noisy
	# in a way its own silhouette cannot support.
	var normal_epsilon := maxf(step * 0.5, 0.01)

	# Sampled ONCE, up front, into plain arrays. The visible mesh, the collision
	# faces and the skirt all read from these — the heightfield is cheap, but
	# not so cheap that it is worth asking it the same question three times.
	# Positions are local (so the tile moves with its node); heights are sampled
	# at the world position each local point currently corresponds to.
	_grid_vertex_count = stride * stride
	var positions := PackedVector3Array()
	var normals := PackedVector3Array()
	positions.resize(_grid_vertex_count)
	normals.resize(_grid_vertex_count)
	for i in stride:
		for j in stride:
			var lx := -half + i * step
			var lz := -half + j * step
			var wx := origin.x + lx
			var wz := origin.z + lz
			var index := i * stride + j
			positions[index] = Vector3(lx, heightfield.height_at(wx, wz) - origin.y, lz)
			normals[index] = heightfield.normal_at(wx, wz, normal_epsilon)
		# Checked a row at a time rather than a vertex at a time: the same
		# granularity in practice, without a branch per vertex.
		_since_yield += stride
		if vertices_per_batch > 0 and _since_yield >= vertices_per_batch:
			_since_yield = 0
			await _yield_now()
			if not is_inside_tree():
				built.emit() # So the manager's in-flight count still clears.
				return

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in stride:
		for j in stride:
			var index := i * stride + j
			st.set_uv(Vector2(float(i) / res, float(j) / res))
			st.set_normal(normals[index])
			st.add_vertex(positions[index])
		_since_yield += stride
		if vertices_per_batch > 0 and _since_yield >= vertices_per_batch:
			_since_yield = 0
			await _yield_now()
			if not is_inside_tree():
				built.emit()
				return

	# Godot treats CLOCKWISE-wound triangles as front-facing, so the indices run
	# a-c-b rather than the a-b-c a right-hand-rule derivation suggests. Getting
	# this backwards is quietly expensive — see the same note in
	# terrain_mound.gd: the ground renders near-black AND cannot be stood on,
	# one cause producing two unrelated-looking symptoms.
	var faces := PackedVector3Array()
	if build_collision:
		faces.resize(res * res * 6)
	var face_index := 0
	for i in res:
		for j in res:
			var a := i * stride + j
			var b := a + 1
			var c := a + stride
			var d := c + 1
			st.add_index(a)
			st.add_index(c)
			st.add_index(b)
			st.add_index(b)
			st.add_index(c)
			st.add_index(d)
			if build_collision:
				# Same winding as the visual mesh above — confirmed correct in
				# isolation (a single flat quad, one StaticBody3D) by
				# scripts/dev/test_floor_winding.gd: a real CharacterBody3D
				# rests on this winding with is_on_floor() true and zero
				# residual velocity, and does NOT on the reverse. An earlier
				# edit here reversed this based on a test that (unnoticed at
				# the time) had swapped which of b/c was the +X vs +Z step
				# relative to this file's own a/b/c/d convention, so it was
				# validating a winding this file never actually used. That
				# edit is reverted — the winding was never the bug.
				faces[face_index] = positions[a]
				faces[face_index + 1] = positions[c]
				faces[face_index + 2] = positions[b]
				faces[face_index + 3] = positions[b]
				faces[face_index + 4] = positions[c]
				faces[face_index + 5] = positions[d]
				face_index += 6

	if skirt_depth > 0.0:
		_add_skirt(st, stride, positions, normals)

	var mesh := st.commit()

	if _mesh_instance == null:
		_mesh_instance = MeshInstance3D.new()
		_mesh_instance.name = "Surface"
		add_child(_mesh_instance)
	_mesh_instance.mesh = mesh
	_mesh_instance.material_override = material if material else DEFAULT_MATERIAL

	if build_collision:
		if _collider == null:
			_collider = CollisionShape3D.new()
			_collider.name = "Collider"
			add_child(_collider)
		var shape := ConcavePolygonShape3D.new()
		shape.set_faces(faces)
		_collider.shape = shape
	elif _collider != null:
		_collider.queue_free()
		_collider = null

	_work_usec += Time.get_ticks_usec() - _mark_usec
	_build_msec = int(round(_work_usec / 1000.0))
	built.emit()


## The border apron described in note 2 at the top: a short vertical wall hung
## from the tile's outer edge, hiding the hairline cracks where a neighbour
## built at a different resolution puts its edge somewhere slightly different.
##
## Every skirt quad is emitted TWICE, wound both ways. Which way a panel should
## face depends on which side of the tile it is on, and getting one of the four
## sides wrong produces an invisible patch of crack-filler — the exact bug the
## skirt exists to prevent, reintroduced in a form that only shows from certain
## angles. A few dozen extra triangles per tile is a cheap price for that whole
## class of mistake not existing.
func _add_skirt(st: SurfaceTool, stride: int, positions: PackedVector3Array,
		normals: PackedVector3Array) -> void:
	var res := stride - 1
	# The border walked as a closed loop, so consecutive entries are always
	# neighbours and the corners need no special handling.
	var ring: Array[int] = []
	for i in stride:
		ring.append(i * stride)
	for j in range(1, stride):
		ring.append(res * stride + j)
	for i in range(res - 1, -1, -1):
		ring.append(i * stride + res)
	for j in range(res - 1, 0, -1):
		ring.append(j)

	# Skirt vertices are appended after every grid vertex, so grid indices used
	# above stay valid.
	var base_index := _grid_vertex_count
	for index in ring:
		var top := positions[index]
		st.set_uv(Vector2(0.0, 0.0))
		st.set_normal(normals[index])
		st.add_vertex(top)
		st.set_uv(Vector2(0.0, 1.0))
		st.set_normal(normals[index])
		st.add_vertex(Vector3(top.x, top.y - skirt_depth, top.z))

	var count := ring.size()
	for k in count:
		var next := (k + 1) % count
		var top_a := base_index + k * 2
		var bottom_a := top_a + 1
		var top_b := base_index + next * 2
		var bottom_b := top_b + 1
		st.add_index(top_a)
		st.add_index(bottom_a)
		st.add_index(top_b)
		st.add_index(top_b)
		st.add_index(bottom_a)
		st.add_index(bottom_b)
		# The same two triangles wound the other way — see the note above.
		st.add_index(top_b)
		st.add_index(bottom_a)
		st.add_index(top_a)
		st.add_index(bottom_b)
		st.add_index(bottom_a)
		st.add_index(top_b)
