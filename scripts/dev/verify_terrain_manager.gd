extends Node

## Checks terrain_manager.gd streams ground correctly as the player moves: the
## right tiles exist, at the right detail, collision only where it is needed,
## and — the whole point of the exercise — the amount resident stays FLAT no
## matter how far the player walks.
##
## Run as a SCENE rather than with --script, because TerrainManager reaches the
## player through the Game autoload and autoloads are not set up for --script:
##   Godot --headless res://scenes/dev/VerifyTerrainManager.tscn
## Exits non-zero if any check fails.

const CHUNK_SIZE := 32.0
const TIERS := [
	{"distance": 40.0, "resolution": 16, "collision": true},
	{"distance": 90.0, "resolution": 8, "collision": false},
	{"distance": 160.0, "resolution": 4, "collision": false},
]

var _fails := 0
var _player: Node3D = null
var _manager: TerrainManager = null


func _ready() -> void:
	_run()


func _run() -> void:
	var root := get_tree().root
	await get_tree().process_frame

	var field := Heightfield.new()
	field.rolling_amplitude = 0.6
	field.rolling_frequency = 0.02
	field.features = [{"pos": Vector2(-46, -46), "radius": 24.0, "height": 11.0, "noise": 1.9}]

	_player = Node3D.new()
	_player.name = "FakePlayer"
	root.add_child(_player)
	Game.player = _player

	_manager = TerrainManager.new()
	_manager.heightfield = field
	_manager.chunk_size = CHUNK_SIZE
	_manager.detail_tiers = TIERS
	_manager.max_concurrent_builds = 4
	# Rescan every frame. At the production 0.25s the manager has not yet
	# noticed the player moved when _settle() looks, so _settle() concludes the
	# world is finished when it has not started — and every check downstream
	# then measures a stale world that happens to look perfectly stable.
	_manager.check_interval = 0.0
	# Unbatched: this is a correctness test, and batching is already covered by
	# verify_terrain_chunk.gd. Keeps the run to a few hundred frames.
	_manager.vertices_per_batch = 0
	root.add_child(_manager)

	await _settle()
	_check_ground_under_player()
	_check_has_ground_at_requires_real_collider()
	_check_detail_falls_off_with_distance()
	_check_collision_only_near()
	await _check_streaming_stays_flat()
	await _check_retiling_on_approach()
	await _check_collision_anchor_survives_player_leaving()
	await _check_anchor_survives_continuous_movement()
	_report_payoff()

	print("")
	if _fails == 0:
		print("ALL TERRAIN MANAGER CHECKS PASSED")
	else:
		print("%d CHECK(S) FAILED" % _fails)
	get_tree().quit(1 if _fails > 0 else 0)


func _fail(msg: String) -> void:
	print("FAIL " + msg)
	_fails += 1


## Runs frames until the manager has nothing queued or building, so checks see
## a settled world rather than one mid-load.
func _settle(limit := 4000) -> void:
	# At least two frames before believing an empty queue, so the manager has
	# certainly rescanned since whatever the caller just changed.
	await get_tree().process_frame
	for i in limit:
		await get_tree().process_frame
		var stats := _manager.debug_stats()
		if stats["queued"] == 0 and stats["building"] == 0:
			return
	_fail("world never finished loading within %d frames" % limit)


func _tiles() -> Array:
	var out: Array = []
	for child in _manager.get_children():
		if child is TerrainChunk:
			out.append(child)
	return out


## Whatever else happens, there must be ground under the player's feet, at full
## detail, that they can stand on.
func _check_ground_under_player() -> void:
	var p := _player.global_position
	if not _manager.has_ground_at(p.x, p.z):
		_fail("no full-detail ground under the player")
	var found := false
	for tile: TerrainChunk in _tiles():
		var d := Vector2(tile.position.x - p.x, tile.position.z - p.z)
		if absf(d.x) <= CHUNK_SIZE * 0.5 and absf(d.y) <= CHUNK_SIZE * 0.5:
			found = true
			if tile.get_node_or_null("Collider") == null:
				_fail("the tile under the player has no collision")
			if tile.resolution != TIERS[0]["resolution"]:
				_fail("the tile under the player is not at full detail")
	if not found:
		_fail("no tile covers the player's position at all")


## has_ground_at() must reflect a REAL collider existing, not just the
## manager's intent to build one. This is the exact gap that let NPCs and the
## player start falling under gravity before their tile's async build had
## actually produced a Collider — a caller trusting an earlier, weaker
## version of this method (checking only _active[cell]["tier"] == 0, set the
## instant a build is QUEUED) would see "ground ready" during that window and
## start moving into ground that was not really there yet.
func _check_has_ground_at_requires_real_collider() -> void:
	var spot := _player.global_position + Vector3(400.0, 0.0, 400.0)
	var cell := _manager._cell_at(Vector2(spot.x, spot.z))
	if _manager.has_ground_at(spot.x, spot.z):
		_fail("has_ground_at() true for a cell with no tile built at all")

	# A tile whose bookkeeping claims tier 0 but has no Collider (mid-build, or
	# a coarse tile masquerading) must still read as not-ready.
	var fake_chunk := Node3D.new()
	fake_chunk.name = "FakeTile"
	_manager.add_child(fake_chunk)
	_manager._active[cell] = {"chunk": fake_chunk, "tier": 0}
	if _manager.has_ground_at(spot.x, spot.z):
		_fail("has_ground_at() true for a tile with no Collider child")

	# Only once a real Collider child exists should it read as ready.
	var collider := CollisionShape3D.new()
	collider.name = "Collider"
	fake_chunk.add_child(collider)
	if not _manager.has_ground_at(spot.x, spot.z):
		_fail("has_ground_at() still false once a real Collider exists")
	else:
		print("has_ground_at(): correctly requires an actual Collider, not just tier bookkeeping")

	_manager._active.erase(cell)
	fake_chunk.queue_free()
	print("under the player: full detail, collision present")


## The central claim of the whole design: further away means fewer vertices.
func _check_detail_falls_off_with_distance() -> void:
	var by_tier := {}
	for tile: TerrainChunk in _tiles():
		var d := Vector2(tile.position.x, tile.position.z).distance_to(
			Vector2(_player.global_position.x, _player.global_position.z))
		var res: int = tile.resolution
		if not by_tier.has(res):
			by_tier[res] = {"count": 0, "min_d": INF, "max_d": 0.0}
		by_tier[res]["count"] += 1
		by_tier[res]["min_d"] = minf(by_tier[res]["min_d"], d)
		by_tier[res]["max_d"] = maxf(by_tier[res]["max_d"], d)

	var resolutions: Array = by_tier.keys()
	resolutions.sort()
	resolutions.reverse() # Finest first.
	var previous_max := -1.0
	for res: int in resolutions:
		var info: Dictionary = by_tier[res]
		print("  res %2d: %3d tiles, %.0f to %.0f units away" % [
			res, info["count"], info["min_d"], info["max_d"]])
		# Each coarser band must start beyond where the finer one started.
		if info["min_d"] < previous_max - CHUNK_SIZE:
			_fail("res %d tiles appear closer than the finer band above them" % res)
		previous_max = info["min_d"]
	if resolutions.size() != TIERS.size():
		_fail("expected %d detail bands, found %d" % [TIERS.size(), resolutions.size()])
	print("detail falls off with distance across %d bands" % resolutions.size())


## Collision is a large share of a tile's cost, so it must exist only where the
## player could actually stand.
func _check_collision_only_near() -> void:
	var with_collision := 0
	var without := 0
	for tile: TerrainChunk in _tiles():
		if tile.get_node_or_null("Collider") != null:
			with_collision += 1
			if tile.resolution != TIERS[0]["resolution"]:
				_fail("a distant tile built collision it does not need")
		else:
			without += 1
	if with_collision == 0:
		_fail("nothing has collision — the player would fall through the world")
	print("collision: %d near tiles have it, %d distant tiles skip it" % [
		with_collision, without])


## The point of streaming: walking a long way must not accumulate cost.
##
## Measured between two points DURING the walk, not against the cold start. A
## freshly loaded world is the cheapest the world ever is — once moving, the
## band between the horizon and unload_margin legitimately holds tiles that
## have gone out of range but are not far enough out to be worth freeing, which
## is the anti-thrash hysteresis doing its job. Comparing against the cold start
## would flag that as a leak. What actually matters is that the number PLATEAUS.
func _check_streaming_stays_flat() -> void:
	# Walk far enough to reach the moving steady state before measuring.
	for step in 6:
		_player.global_position += Vector3(64.0, 0.0, 0.0)
		await _settle()

	var before := _manager.debug_stats()
	var before_cells := _cell_set()

	# Far enough again that not one tile from the first measurement can remain.
	for step in 12:
		_player.global_position += Vector3(64.0, 0.0, 0.0)
		await _settle()

	var after := _manager.debug_stats()
	var after_cells := _cell_set()

	var overlap := 0
	for cell in after_cells:
		if before_cells.has(cell):
			overlap += 1
	if overlap != 0:
		_fail("%d tiles survived a 768-unit walk — the player did not really leave" % overlap)

	var tile_drift: int = absi(after["tiles"] - before["tiles"])
	var vertex_drift: float = absf(float(after["vertices"] - before["vertices"])) / float(before["vertices"])
	if tile_drift > 2:
		_fail("tile count drifted from %d to %d over the walk" % [before["tiles"], after["tiles"]])
	if vertex_drift > 0.05:
		_fail("vertex count drifted %.0f%% over the walk" % (vertex_drift * 100.0))
	print("steady state, then 768 units further: tiles %d -> %d, vertices %d -> %d, %d in common" % [
		before["tiles"], after["tiles"], before["vertices"], after["vertices"], overlap])


func _cell_set() -> Dictionary:
	var out := {}
	for tile: TerrainChunk in _tiles():
		out[Vector2i(int(tile.position.x), int(tile.position.z))] = true
	return out


## A tile the player walks toward must gain detail, and gain collision, without
## ever ceasing to exist along the way.
func _check_retiling_on_approach() -> void:
	# Pick a tile currently in the coarsest band, well ahead of the player.
	var target: TerrainChunk = null
	for tile: TerrainChunk in _tiles():
		if tile.resolution == TIERS[TIERS.size() - 1]["resolution"]:
			if target == null or tile.position.x > target.position.x:
				target = tile
	if target == null:
		_fail("no coarse tile to walk toward")
		return
	var target_pos := target.position
	var coarse_res: int = target.resolution
	print("approaching a tile at %.0f, %.0f (currently res %d)" % [
		target_pos.x, target_pos.z, coarse_res])

	_player.global_position = Vector3(target_pos.x, 0.0, target_pos.z)
	await _settle()

	var arrived: TerrainChunk = null
	for tile: TerrainChunk in _tiles():
		if tile.position.is_equal_approx(target_pos):
			arrived = tile
	if arrived == null:
		_fail("the tile vanished instead of gaining detail")
		return
	if arrived.resolution != TIERS[0]["resolution"]:
		_fail("tile stayed at res %d after the player stood on it" % arrived.resolution)
	if arrived.get_node_or_null("Collider") == null:
		_fail("tile gained detail but no collision")
	if arrived != target:
		_fail("tile was replaced rather than rebuilt in place — that would flicker")
	print("on arrival: same tile object, rebuilt res %d -> %d, collision added" % [
		coarse_res, arrived.resolution])


## The bug this was written to catch: an NPC standing still while the player
## wanders far away must keep its collision, because it is a physics body that
## falls through the world the instant its tile loses one. Without registering
## as an anchor, the NPC's tile would retile down to a collisionless tier once
## it falls outside every detail band measured from the player alone.
func _check_collision_anchor_survives_player_leaving() -> void:
	var npc_spot := _player.global_position + Vector3(300.0, 0.0, 0.0)
	var npc := Node3D.new()
	npc.name = "FakeAnchor"
	# Added to the tree BEFORE setting global_position: the setter needs a
	# world to place the node into, which does not exist yet on an orphan node.
	get_tree().root.add_child(npc)
	npc.global_position = npc_spot
	_manager.register_collision_anchor(npc, 8.0)
	await _settle()

	var cell := _manager._cell_at(Vector2(npc_spot.x, npc_spot.z))
	if not _manager._active.has(cell) or _manager._active[cell]["tier"] != 0:
		_fail("registering an anchor did not bring its ground to full detail")
	else:
		print("anchor: registered far from the player, got full-detail ground immediately")

	# Walk the player far away in the OPPOSITE direction — the anchor's tile is
	# now outside every distance-based tier. It must survive anyway.
	_player.global_position += Vector3(-500.0, 0.0, 0.0)
	await _settle()
	if not _manager._active.has(cell) or _manager._active[cell]["tier"] != 0:
		_fail("anchor's ground was freed or downgraded once the player left — an NPC here would fall through the world")
	else:
		print("anchor: ground survived the player walking 500 units away")

	_manager.unregister_collision_anchor(npc)
	await _settle()
	var still_active := _manager._active.has(cell)
	print("anchor: after unregistering, tile %s (expected to eventually free or retile like any other distant tile)" % (
		"still present" if still_active else "freed"))
	npc.queue_free()


## The gap the previous check missed. A real player never stops moving and
## never waits for the build queue to empty, so every scan appends a fresh
## batch of near-player tasks BEFORE an already-waiting anchor task gets a
## turn — with max_concurrent_builds at its default of 1, an anchor whose task
## is not prioritised can be outranked indefinitely. This drives the player in
## a tight, continuous circle near — but not on top of — a stationary anchor,
## the way an NPC and a player wandering nearby actually behave, and never
## lets the queue settle before checking.
func _check_anchor_survives_continuous_movement() -> void:
	var anchor_pos := _player.global_position + Vector3(96.0, 0.0, 0.0)
	var npc := Node3D.new()
	npc.name = "ContinuousAnchor"
	get_tree().root.add_child(npc)
	npc.global_position = anchor_pos
	# Realistic, not the generous max_concurrent_builds=4 / vertices_per_batch=0
	# the rest of this suite uses. Batched builds take several frames each,
	# which is what actually gives the queue a chance to accumulate a backlog —
	# an unbatched build completes the instant it is popped, which trivially
	# "fixes" the starvation this test exists to catch without proving
	# anything. check_interval is still forced to 0 rather than the production
	# 0.25s: real elapsed time per headless frame is far below a millisecond,
	# so a wall-clock timer would take far too many frames to ever fire here.
	# Rescanning every frame instead just means MORE chances to append fresh
	# near-player tasks ahead of the anchor — if anything a harder case, not
	# an easier one.
	_manager.max_concurrent_builds = 1
	_manager.vertices_per_batch = 250
	_manager.register_collision_anchor(npc, 8.0)

	var cell := _manager._cell_at(Vector2(anchor_pos.x, anchor_pos.z))
	var settled_by_frame := -1
	for i in 600:
		# A tight, continuous circle around a point close to the anchor — near
		# enough that the player's own tiles keep demanding (re)builds every
		# scan, so there is always something competing for the single build
		# slot and the queue never gets the chance to empty.
		var angle := float(i) * 0.15
		_player.global_position = Vector3(cos(angle) * 15.0, 0.0, sin(angle) * 15.0)
		await get_tree().process_frame

		# NOT _active[cell]["tier"] == 0: that flag is set the instant a build
		# is QUEUED, not when it finishes — with a batched, multi-frame build
		# there is a real window where the manager already claims tier 0 but
		# the TerrainChunk has no Collider yet. What actually stops an NPC
		# falling through is the collider existing, so that is what this checks.
		var has_collision := false
		if _manager._active.has(cell):
			var chunk: Node = _manager._active[cell]["chunk"]
			has_collision = chunk.get_node_or_null("Collider") != null
		if has_collision and settled_by_frame < 0:
			settled_by_frame = i

	# A generous but real ceiling: a couple of dozen frames covers the anchor's
	# own build (a handful of yields) plus however many frames it plausibly
	# waits behind whatever was already mid-build when it was queued. Anything
	# past that means the priority fix is not actually winning the anchor its
	# turn — a slow eventual fix is still an NPC visibly sunk into the ground
	# for a second or more.
	if settled_by_frame < 0:
		_fail("anchor tile never gained collision across 600 frames of continuous player movement")
	elif settled_by_frame > 30:
		_fail("anchor tile took %d frames to gain collision under continuous movement — too slow, an NPC would visibly sink" % settled_by_frame)
	else:
		print("anchor under continuous movement (batched, 1 build slot): collidable by frame %d" % settled_by_frame)
	npc.queue_free()
	_manager.unregister_collision_anchor(npc)
	_manager.vertices_per_batch = 0


## What all of this actually bought, as one number.
func _report_payoff() -> void:
	var stats := _manager.debug_stats()
	var resident: int = stats["vertices"]
	# What the same ground would have cost built uniformly at full detail.
	var finest: int = TIERS[0]["resolution"]
	var uniform: int = stats["tiles"] * (finest + 1) * (finest + 1)
	print("")
	print("payoff: %d tiles resident, %d vertices" % [stats["tiles"], resident])
	print("        uniform full detail would be %d vertices" % uniform)
	print("        detail falloff saves %.0f%%" % ((1.0 - float(resident) / float(uniform)) * 100.0))
