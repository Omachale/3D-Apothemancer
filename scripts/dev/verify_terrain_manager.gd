extends Node

## Checks terrain_manager.gd streams ground correctly as the player moves: the
## right tiles exist, on the right ring, collision only where it is needed, no
## holes in the ground while rings swap over, and — the whole point of the
## exercise — the amount resident stays FLAT no matter how far the player walks.
##
## Run as a SCENE rather than with --script, because TerrainManager reaches the
## player through the Game autoload and autoloads are not set up for --script:
##   Godot --headless res://scenes/dev/VerifyTerrainManager.tscn
## Exits non-zero if any check fails.
##
## CALIBRATED AGAINST THE RUNTIME VIEWPORT, not hardcoded distances. Which ring
## a tile lands on is chosen from projected screen size (see terrain_manager.gd's
## class doc), so the distance at which any given ring starts depends on the
## actual viewport height this test happens to run at — headless Godot's window
## size is not something this file should assume. _setup_manager() reads the
## real viewport and picks max_screen_error_px so the ring boundaries land at
## known, well-separated distances regardless of environment, the same way a
## designer tuning the slider by eye would arrive at a number for their own
## screen.
##
## TILE_RESOLUTION is deliberately far below production's 32. It is a ratio
## dial, not a quality one (see terrain_manager.gd), so lowering it changes
## nothing this file is checking while cutting every tile from 1089 vertices to
## 81 — which is the difference between a test that runs and one that crawls.

const CHUNK_SIZE := 32.0
const TILE_RESOLUTION := 8
const RING_COUNT := 4
## Where the OUTERMOST ring starts, in world units — this is the number
## _setup_manager() solves max_screen_error_px for. Each ring in then starts at
## half the previous, by the formula's own inverse-proportionality (see
## terrain_manager.gd's _ring_radius): 160, 80, 40. Comfortably separated for a
## headless test to tell apart.
const OUTER_RING_START := 160.0
## Generous relative to OUTER_RING_START on purpose: the outermost ring is
## whatever is left between its own inner edge and the horizon, so a horizon
## that barely clears that edge leaves it empty and there is no last ring to
## check.
const HORIZON := 600.0
const UNLOAD_MARGIN := 64.0

var _fails := 0
var _player: Node3D = null
var _manager: TerrainManager = null
var _coarsest: int = RING_COUNT - 1


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

	_manager = _setup_manager(field)
	root.add_child(_manager)

	await _settle()
	_check_ground_under_player()
	_check_has_ground_at_requires_real_collider()
	_check_rings_grow_with_distance()
	_check_no_overlapping_rings()
	_check_collision_only_near()
	await _check_streaming_stays_flat()
	await _check_ground_never_gaps_on_approach()
	await _check_collision_anchor_survives_player_leaving()
	await _check_anchor_survives_continuous_movement()
	await _check_horizon_extends_cheaply()
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


## Builds a manager whose ring boundaries land at known distances no matter what
## viewport this happens to run in. Game.camera_rig is never set in this test, so
## terrain_manager.gd's _view_camera() falls back to its bootstrap approximation
## of the rig's default framing (player position + a fixed offset, 45 degree
## FOV) — this reads that same fallback back out rather than duplicating it, so
## the two cannot drift apart silently.
func _setup_manager(field: Heightfield) -> TerrainManager:
	var manager := TerrainManager.new()
	manager.heightfield = field
	manager.chunk_size = CHUNK_SIZE
	manager.tile_resolution = TILE_RESOLUTION
	manager.ring_count = RING_COUNT
	manager.collision_level_maximum = 0
	manager.horizon_distance = HORIZON
	manager.unload_margin = UNLOAD_MARGIN
	manager.max_concurrent_builds = 4
	# Rescan every frame. At the production 0.25s the manager has not yet
	# noticed the player moved when _settle() looks, so _settle() concludes the
	# world is finished when it has not started — and every check downstream
	# then measures a stale world that happens to look perfectly stable.
	manager.check_interval = 0.0
	# Unbatched: this is a correctness test, and batching is already covered by
	# verify_terrain_chunk.gd. Keeps the run to a few hundred frames.
	manager.vertices_per_batch = 0

	var viewport_h := float(get_tree().root.get_visible_rect().size.y)
	if viewport_h <= 0.0:
		viewport_h = 600.0 # Headless without a window at all; keep the test alive.
	var fov_rad := deg_to_rad(45.0) # Matches _view_camera()'s bootstrap fallback.
	var k := viewport_h / (2.0 * tan(fov_rad * 0.5))
	# Solving _ring_radius's own formula for the error budget that puts the
	# OUTERMOST ring's inner edge at OUTER_RING_START.
	var coarsest_spacing := CHUNK_SIZE * float(1 << _coarsest) / float(TILE_RESOLUTION)
	manager.max_screen_error_px = coarsest_spacing * k / OUTER_RING_START
	return manager


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


## Which ring a built tile is on, read back from the only thing that records it
## on the tile itself — its world size.
func _level_of(tile: TerrainChunk) -> int:
	return int(round(log(tile.size / CHUNK_SIZE) / log(2.0)))


## Whether any built tile at all covers this world XZ point. NOT the same
## question as has_ground_at(), which additionally demands collision — this is
## about whether there is a visible hole in the ground.
func _covered(x: float, z: float) -> bool:
	for tile: TerrainChunk in _tiles():
		var half: float = tile.size * 0.5
		if absf(x - tile.position.x) <= half and absf(z - tile.position.z) <= half:
			return true
	return false


## Whatever else happens, there must be ground under the player's feet, on the
## innermost ring, that they can stand on.
func _check_ground_under_player() -> void:
	var p := _player.global_position
	if not _manager.has_ground_at(p.x, p.z):
		_fail("no collidable ground under the player")
	if not _covered(p.x, p.z):
		_fail("no tile covers the player's position at all")
	var found := false
	for tile: TerrainChunk in _tiles():
		var half: float = tile.size * 0.5
		if absf(p.x - tile.position.x) <= half and absf(p.z - tile.position.z) <= half:
			found = true
			if _level_of(tile) != 0:
				_fail("the player is standing on a ring-%d tile, not the innermost" % _level_of(tile))
			elif tile.get_node_or_null("Collider") == null:
				_fail("the tile under the player has no collision")
	if found:
		print("under the player: innermost ring, collision present")


## has_ground_at() must reflect a REAL collider existing, not just the
## manager's intent to build one. This is the exact gap that let NPCs and the
## player start falling under gravity before their tile's async build had
## actually produced a Collider — a caller trusting an earlier, weaker
## version of this method (checking only the manager's own bookkeeping, set the
## instant a build is QUEUED) would see "ground ready" during that window and
## start moving into ground that was not really there yet.
func _check_has_ground_at_requires_real_collider() -> void:
	# Far outside the horizon, so nothing real is built here to confuse the
	# fake tile planted below.
	var spot := _player.global_position + Vector3(4000.0, 0.0, 4000.0)
	var key := _manager._key(_manager._cell_at(Vector2(spot.x, spot.z), 0), 0)
	if _manager.has_ground_at(spot.x, spot.z):
		_fail("has_ground_at() true for a spot with no tile built at all")

	# A tile whose bookkeeping claims collision but has no Collider (mid-build,
	# or a coarse tile masquerading) must still read as not-ready.
	var fake_chunk := Node3D.new()
	fake_chunk.name = "FakeTile"
	_manager.add_child(fake_chunk)
	_manager._active[key] = {"chunk": fake_chunk, "level": 0, "collision": true}
	if _manager.has_ground_at(spot.x, spot.z):
		_fail("has_ground_at() true for a tile with no Collider child")

	# Only once a real Collider child exists should it read as ready.
	var collider := CollisionShape3D.new()
	collider.name = "Collider"
	fake_chunk.add_child(collider)
	if not _manager.has_ground_at(spot.x, spot.z):
		_fail("has_ground_at() still false once a real Collider exists")
	else:
		print("has_ground_at(): correctly requires an actual Collider, not just bookkeeping")

	_manager._active.erase(key)
	fake_chunk.queue_free()


## The central claim of the whole design: further away means BIGGER tiles, so
## the same ground costs fewer of them.
func _check_rings_grow_with_distance() -> void:
	var by_level := {}
	for tile: TerrainChunk in _tiles():
		var d := Vector2(tile.position.x, tile.position.z).distance_to(
			Vector2(_player.global_position.x, _player.global_position.z))
		var level := _level_of(tile)
		if not by_level.has(level):
			by_level[level] = {"count": 0, "min_d": INF, "max_d": 0.0, "size": tile.size}
		by_level[level]["count"] += 1
		by_level[level]["min_d"] = minf(by_level[level]["min_d"], d)
		by_level[level]["max_d"] = maxf(by_level[level]["max_d"], d)

	var seen: Array = by_level.keys()
	seen.sort()
	var previous_min := -1.0
	for level: int in seen:
		var info: Dictionary = by_level[level]
		print("  ring %d (%4.0f-unit tiles): %3d tiles, %.0f to %.0f units away" % [
			level, info["size"], info["count"], info["min_d"], info["max_d"]])
		# Each ring out must START further than the one inside it. Compared on
		# the nearest tile of each ring, not the furthest: ring regions are
		# nested BOXES, so a corner of an inner ring reaches further than the
		# near edge of the ring outside it, and that is correct rather than a
		# fault.
		if info["min_d"] <= previous_min:
			_fail("ring %d starts no further out than the ring inside it" % level)
		previous_min = info["min_d"]
	if seen.size() != RING_COUNT:
		_fail("expected %d rings, found %d" % [RING_COUNT, seen.size()])
	else:
		print("tiles grow with distance across all %d rings" % seen.size())


## Rings must TILE the ground, not overlap it. Two tiles covering the same spot
## means z-fighting and double the cost; a gap means a hole. The nested-box
## region maths in _compute_regions exists precisely to make both impossible,
## so this checks it actually does.
func _check_no_overlapping_rings() -> void:
	var tiles := _tiles()
	var overlaps := 0
	# Sample the centre of every tile and confirm exactly one tile covers it.
	for tile: TerrainChunk in tiles:
		var covering := 0
		for other: TerrainChunk in tiles:
			var half: float = other.size * 0.5
			if absf(tile.position.x - other.position.x) < half \
					and absf(tile.position.z - other.position.z) < half:
				covering += 1
		if covering != 1:
			overlaps += 1
	if overlaps > 0:
		_fail("%d tile centres are covered by more than one tile — rings overlap" % overlaps)
	else:
		print("rings tile the ground exactly: no point covered twice")


## Collision is a large share of a tile's cost, so it must exist only where the
## player could actually stand — the innermost ring, plus anchors (none yet).
func _check_collision_only_near() -> void:
	var with_collision := 0
	var without := 0
	for tile: TerrainChunk in _tiles():
		if tile.get_node_or_null("Collider") != null:
			with_collision += 1
			if _level_of(tile) != 0:
				_fail("a ring-%d tile built collision it does not need" % _level_of(tile))
		else:
			without += 1
	if with_collision == 0:
		_fail("nothing has collision — the player would fall through the world")
	print("collision: %d innermost tiles have it, %d distant tiles skip it" % [
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
		_player.global_position += Vector3(200.0, 0.0, 0.0)
		await _settle()

	var before := _manager.debug_stats()
	var before_cells := _cell_set()

	# Far enough again that not one tile from the first measurement can remain
	# — the world is HORIZON across, so this must clear its full diameter.
	for step in 14:
		_player.global_position += Vector3(200.0, 0.0, 0.0)
		await _settle()

	var after := _manager.debug_stats()
	var after_cells := _cell_set()

	var overlap := 0
	for cell in after_cells:
		if before_cells.has(cell):
			overlap += 1
	if overlap != 0:
		_fail("%d tiles survived a 2800-unit walk — the player did not really leave" % overlap)

	# A relative tolerance, not the near-exact one a single-tile-size grid could
	# hold to. Ring regions snap to whole cells of the ring OUTSIDE them, so the
	# outermost boundary moves in 2-tile steps hundreds of units wide; crossing
	# one legitimately adds or drops a whole row of coarse tiles. The claim being
	# tested is that cost plateaus, not that it is frame-identical.
	var tile_drift: float = absf(float(after["tiles"] - before["tiles"])) / float(before["tiles"])
	var vertex_drift: float = absf(float(after["vertices"] - before["vertices"])) / float(before["vertices"])
	if tile_drift > 0.25:
		_fail("tile count drifted %.0f%% (from %d to %d) over the walk" % [
			tile_drift * 100.0, before["tiles"], after["tiles"]])
	if vertex_drift > 0.25:
		_fail("vertex count drifted %.0f%% over the walk" % (vertex_drift * 100.0))
	print("steady state, then 2800 units further: tiles %d -> %d, vertices %d -> %d, %d in common" % [
		before["tiles"], after["tiles"], before["vertices"], after["vertices"], overlap])


func _cell_set() -> Dictionary:
	var out := {}
	for tile: TerrainChunk in _tiles():
		out[Vector3(tile.position.x, tile.size, tile.position.z)] = true
	return out


## THE RISK THE RING LAYOUT INTRODUCES, and the reason _free_unwanted() waits.
##
## Under the old single-tile-size grid, walking toward a coarse tile rebuilt it
## finer IN PLACE, which could not gap: TerrainChunk swaps its mesh only at the
## very end of a build, so the old one stayed up throughout. Rings do not work
## that way. A tile never changes size, so approaching one means freeing a big
## tile and building four smaller ones that do not exist yet — and freeing first
## leaves a visible hole in the ground for as long as those four take.
##
## So: pick a point far ahead, walk onto it WITHOUT ever letting the queue
## settle, and assert that once the ground there exists it never once stops
## existing. Checked every frame, because a hole lasting a single frame is still
## a hole the player can see (and fall through).
func _check_ground_never_gaps_on_approach() -> void:
	var start := _player.global_position
	var target := start + Vector3(OUTER_RING_START * 2.0, 0.0, 0.0)
	if not _covered(target.x, target.z):
		_fail("nothing covers the approach target to begin with")
		return
	var start_level := _level_at(target.x, target.z)

	var gaps := 0
	var steps := 120
	for i in steps:
		# Continuous movement, never settling — the realistic case, and the one
		# where a free can outrun the builds meant to replace it.
		_player.global_position = start.lerp(target, float(i + 1) / float(steps))
		await get_tree().process_frame
		if not _covered(target.x, target.z):
			gaps += 1

	var end_level := _level_at(target.x, target.z)
	if gaps > 0:
		_fail("ground under the approach target vanished on %d of %d frames — a hole in the world" % [
			gaps, steps])
	elif end_level >= start_level:
		_fail("walking onto the target did not move it to a finer ring (%d -> %d)" % [
			start_level, end_level])
	else:
		print("approach: ring %d -> %d underfoot, ground never gapped across %d frames" % [
			start_level, end_level, steps])


## The ring of the smallest tile covering a point, or -1 if nothing does.
func _level_at(x: float, z: float) -> int:
	var best := -1
	for tile: TerrainChunk in _tiles():
		var half: float = tile.size * 0.5
		if absf(x - tile.position.x) <= half and absf(z - tile.position.z) <= half:
			var level := _level_of(tile)
			if best < 0 or level < best:
				best = level
	return best


## The bug this was written to catch: an NPC standing still while the player
## wanders far away must keep its collision, because it is a physics body that
## falls through the world the instant its tile loses one. Without registering
## as an anchor, the ground under the NPC would end up on a ring that carries no
## collision once it falls outside the innermost band measured from the camera.
##
## Note what is NOT asserted any more: that the anchor's ground is at full
## detail. An anchor buys collision, not detail — see terrain_manager.gd's note
## on _anchors. has_ground_at() is exactly the question an NPC asks before
## trusting the floor, so it is exactly what this checks.
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

	if not _manager.has_ground_at(npc_spot.x, npc_spot.z):
		_fail("registering an anchor did not give its ground collision")
	else:
		print("anchor: registered far from the player, got collidable ground immediately")

	# Walk the player far away in the OPPOSITE direction — the anchor's ground is
	# now well outside the innermost ring. It must stay collidable anyway.
	_player.global_position += Vector3(-900.0, 0.0, 0.0)
	await _settle()
	if not _manager.has_ground_at(npc_spot.x, npc_spot.z):
		_fail("anchor's ground lost collision once the player left — an NPC here would fall through the world")
	else:
		print("anchor: ground stayed collidable with the player 900 units away")

	_manager.unregister_collision_anchor(npc)
	await _settle()
	print("anchor: after unregistering, ground %s (expected to eventually lose collision like any distant tile)" % (
		"still collidable" if _manager.has_ground_at(npc_spot.x, npc_spot.z) else "released"))
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
	_player.global_position = Vector3.ZERO
	await _settle()
	var anchor_pos := Vector3(96.0, 0.0, 0.0)
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
	_manager.vertices_per_batch = 40
	_manager.register_collision_anchor(npc, 8.0)

	var settled_by_frame := -1
	for i in 600:
		# A tight, continuous circle around a point close to the anchor — near
		# enough that the player's own tiles keep demanding builds every scan,
		# so there is always something competing for the single build slot and
		# the queue never gets the chance to empty.
		var angle := float(i) * 0.15
		_player.global_position = Vector3(cos(angle) * 15.0, 0.0, sin(angle) * 15.0)
		await get_tree().process_frame
		# has_ground_at() rather than the manager's own bookkeeping: that flag is
		# set the instant a build is QUEUED, not when it finishes, and with a
		# batched multi-frame build there is a real window where the manager
		# already claims collision but the TerrainChunk has no Collider yet. What
		# actually stops an NPC falling through is the collider existing.
		if _manager.has_ground_at(anchor_pos.x, anchor_pos.z) and settled_by_frame < 0:
			settled_by_frame = i

	# A generous but real ceiling: a couple of dozen frames covers the anchor's
	# own build (a handful of yields) plus however many frames it plausibly
	# waits behind whatever was already mid-build when it was queued. Anything
	# past that means the priority fix is not actually winning the anchor its
	# turn — a slow eventual fix is still an NPC visibly sunk into the ground
	# for a second or more.
	if settled_by_frame < 0:
		_fail("anchor ground never gained collision across 600 frames of continuous player movement")
	elif settled_by_frame > 30:
		_fail("anchor ground took %d frames to gain collision under continuous movement — too slow, an NPC would visibly sink" % settled_by_frame)
	else:
		print("anchor under continuous movement (batched, 1 build slot): collidable by frame %d" % settled_by_frame)
	npc.queue_free()
	_manager.unregister_collision_anchor(npc)
	_manager.vertices_per_batch = 0
	_manager.max_concurrent_builds = 4


## WHAT TASK #16 ACTUALLY EXISTS FOR, as a pass/fail rather than a claim.
##
## Under the old fixed-tile-size grid, tile count was quadratic in the horizon:
## doubling the view distance meant FOUR TIMES the tiles, which is why the
## horizon could not extend. Rings make it roughly logarithmic — double the
## horizon, add one ring, and the tile count barely moves, because the extra
## ground is covered by tiles twice as wide.
##
## Both halves matter. Doubling the horizon WITHOUT adding a ring leaves the
## outermost ring to absorb all the new area at its existing tile size, which is
## quadratic again — the ring count is what buys the scaling, and this asserts
## the pair together.
func _check_horizon_extends_cheaply() -> void:
	_player.global_position = Vector3.ZERO
	await _settle()
	var before: int = _manager.debug_stats()["tiles"]

	_manager.horizon_distance = HORIZON * 2.0
	_manager.ring_count = RING_COUNT + 1
	await _settle()
	var after: int = _manager.debug_stats()["tiles"]

	var ratio := float(after) / float(before)
	# Quadratic growth would be ~4x. Anything under 1.6x is unambiguously the
	# ring behaviour rather than the old one.
	if ratio > 1.6:
		_fail("doubling the horizon multiplied tiles by %.2fx — not ring scaling" % ratio)
	else:
		print("horizon %.0f -> %.0f with one more ring: tiles %d -> %d (%.2fx, quadratic would be 4x)" % [
			HORIZON, HORIZON * 2.0, before, after, ratio])

	_manager.horizon_distance = HORIZON
	_manager.ring_count = RING_COUNT
	await _settle()


## What all of this actually bought, as one number.
func _report_payoff() -> void:
	var stats := _manager.debug_stats()
	# What the same square of ground would have cost at one fixed tile size.
	var uniform := int(pow(2.0 * HORIZON / CHUNK_SIZE, 2.0))
	print("")
	print("payoff: %d tiles resident, %d vertices" % [stats["tiles"], stats["vertices"]])
	print("        per ring (innermost first): %s" % str(stats["per_level"]))
	print("        a uniform %.0f-unit grid to the same horizon would be %d tiles" % [
		CHUNK_SIZE, uniform])
	print("        growing tiles with distance saves %.0f%% of them" % (
		(1.0 - float(stats["tiles"]) / float(uniform)) * 100.0))
