extends Node

## Checks tower.gd's derived geometry and its wiring into zone.gd.
##
## tower.gd solves its own footprint and stair layout from a handful of
## authored numbers (see the class doc's note on [method Tower.suggest_size]
## and the two-pass rise solve in [method Tower.build]) rather than having
## them typed in directly, so there is nothing to transcribe and compare like
## verify_zone_layout.gd's FOOTPRINTS table — the thing worth checking is that
## the solve actually lands where it claims to: exact total rise, a walkable
## pitch, no wall geometry punched through the door opening.
##
## Run as a SCENE rather than with --script — tower.gd and zone.gd both reach
## the Game autoload, which --script does not set up:
##   Godot --headless res://scenes/dev/VerifyTower.tscn
## Exits non-zero if any check fails.

const TOWER_SCRIPT := preload("res://scripts/terrain/tower.gd")

## Stairs must stay well under the player's climb limit (see
## player_controller.gd's floor_max_angle, 50 degrees) — checked tighter than
## that here, because "not too steep" was the explicit ask, not just
## "technically climbable".
const MAX_COMFORTABLE_ANGLE := 40.0

## Overlap between a roof strip and the final flight, in metres, below which
## the two are merely sharing the edge of the stairwell hole rather than the
## roof genuinely hanging over the climb. See
## [method _check_roof_headroom_over_final_flight].
const OVERLAP_TOLERANCE := 0.01


func _ready() -> void:
	var fails := 0
	fails += _check_standalone_tower()
	fails += _check_zone_wiring()

	print("")
	if fails == 0:
		print("ALL TOWER CHECKS PASSED")
	else:
		print("%d CHECK(S) FAILED" % fails)
	get_tree().quit(1 if fails > 0 else 0)


func _check_standalone_tower() -> int:
	var fails := 0
	var tower: Node3D = TOWER_SCRIPT.new()
	tower.height = 30.0
	add_child(tower)

	var s: float = tower.suggest_size()
	var interior: float = s - tower.wall_thickness * 2.0
	print("suggest_size(): %.3f (interior %.3f)" % [s, interior])
	# "Narrow" is a claim about PROPORTION, not a literal width. Asserting a
	# hardcoded range here meant retyping the bound every time the stair width
	# was retuned — which is a test that tracks the code rather than the
	# intent. Assert instead that the tower stays tower-shaped against its own
	# height, and still admits a player.
	if interior < 2.0:
		print("FAIL interior %.3f is too narrow to walk in" % interior)
		fails += 1
	if s > tower.height * 0.4:
		print("FAIL footprint %.3f is not narrow for a %.1f m tower" % [s, tower.height])
		fails += 1

	var group: Node = tower.get_node("Tower")
	var total_rise := 0.0
	var max_angle := 0.0
	var flight_count := 0
	var landing_count := 0
	for child in group.get_children():
		var n: String = child.name
		if n.begins_with("Flight"):
			flight_count += 1
			total_rise += child.step_count * child.step_height
			max_angle = maxf(max_angle,
				rad_to_deg(atan2(child.step_height, child.step_depth)))
		elif n.begins_with("Landing"):
			landing_count += 1

	print("flights=%d landings=%d total_rise=%.3f max_angle=%.2fdeg" % [
		flight_count, landing_count, total_rise, max_angle])

	if absf(total_rise - tower.height) > 0.01:
		print("FAIL total stair rise %.3f != tower height %.3f" % [total_rise, tower.height])
		fails += 1
	if max_angle > MAX_COMFORTABLE_ANGLE:
		print("FAIL steepest flight %.2f degrees exceeds comfortable limit %.1f" % [
			max_angle, MAX_COMFORTABLE_ANGLE])
		fails += 1
	if landing_count != flight_count - 1:
		print("FAIL expected %d landings (flights-1), got %d" % [
			flight_count - 1, landing_count])
		fails += 1

	# The roof is built as strips around a stairwell hole (see tower.gd's
	# _build_roof), not one solid slab — there should be at least one strip,
	# each with its top at exactly tower.height, and no leftover "RoofSlab"
	# from the old solid-box design.
	if group.get_node_or_null("RoofSlab") != null:
		print("FAIL RoofSlab still exists as a solid box -- no stairwell opening")
		fails += 1
	var roof_strip_count := 0
	for child in group.get_children():
		if str(child.name).begins_with("Roof"):
			roof_strip_count += 1
			var mesh: MeshInstance3D = child.get_node("Mesh")
			var top: float = child.position.y + mesh.mesh.size.y * 0.5
			if absf(top - tower.height) > 0.01:
				print("FAIL roof strip %s top at %.3f, expected %.3f" % [
					child.name, top, tower.height])
				fails += 1
	if roof_strip_count == 0:
		print("FAIL no roof strips found")
		fails += 1

	for n in ["ParapetSouth", "ParapetNorth", "ParapetWest", "ParapetEast"]:
		if group.get_node_or_null(n) == null:
			print("FAIL missing parapet piece %s" % n)
			fails += 1

	fails += _check_door_clear(tower, group, s)
	fails += _check_roof_headroom_over_final_flight(group)
	fails += _check_no_low_flight_on_door_wall(tower, group)

	if fails == 0:
		print("PASS standalone tower geometry")
	tower.queue_free()
	return fails


## No south-wall piece may cover the door opening (x in [-door_width/2,
## door_width/2], y in [0, door_height]) — that would be a door you cannot
## walk through, silently, since the gap only ever shows up as an absence of
## wall and nothing raises an error on its own.
func _check_door_clear(tower: Node3D, group: Node, s: float) -> int:
	var fails := 0
	for child in group.get_children():
		if not str(child.name).begins_with("WallSouth"):
			continue
		var mesh: MeshInstance3D = child.get_node("Mesh")
		var box: Vector3 = mesh.mesh.size
		var x0: float = child.position.x - box.x * 0.5
		var x1: float = child.position.x + box.x * 0.5
		var y0: float = child.position.y - box.y * 0.5
		var y1: float = child.position.y + box.y * 0.5
		# Jambs are laid up to exactly the edge of the opening, so they SHARE a
		# boundary with it by construction and the two edge values are not
		# guaranteed to compare equal in floating point — the same tolerance
		# reasoning as the roof check above. Only a piece reaching materially
		# INTO the opening is a door you cannot walk through.
		var hw: float = tower.door_width * 0.5
		var overlaps_x: bool = x1 > -hw + OVERLAP_TOLERANCE and x0 < hw - OVERLAP_TOLERANCE
		var overlaps_y: bool = y1 > OVERLAP_TOLERANCE and y0 < tower.door_height - OVERLAP_TOLERANCE
		if overlaps_x and overlaps_y:
			print("FAIL %s overlaps the door opening" % child.name)
			fails += 1

	var hs := s * 0.5
	var outside_door := tower.to_global(Vector3(0.0, 1.0, -hs - 0.5))
	if tower.contains_point(outside_door):
		print("FAIL a point just outside the south wall reads as inside the tower")
		fails += 1
	return fails


## The player's own capsule (see Player.tscn) is 2.0 m tall — the roof's
## stairwell opening has to clear more than that, or the final flight is
## walkable on paper (see _check_standalone_tower's total_rise check) but not
## in practice: this is the check that would have caught the reported "stairs
## don't reach the roof" bug, where the roof was one solid slab hanging at
## floor_thickness (a few tens of centimetres) above the last flight's whole
## approach.
func _check_roof_headroom_over_final_flight(group: Node) -> int:
	var last_flight: Node3D = null
	var last_index := -1
	for child in group.get_children():
		var n: String = child.name
		if n.begins_with("Flight"):
			var idx := int(n.substr(6))
			if idx > last_index:
				last_index = idx
				last_flight = child

	if last_flight == null:
		print("FAIL no Flight nodes found to check roof headroom against")
		return 1

	var flight_rect := _xz_rect(_global_aabb(last_flight))
	var fails := 0
	for child in group.get_children():
		if not str(child.name).begins_with("Roof"):
			continue
		var roof_rect := _xz_rect(_global_aabb(child))
		var overlap := flight_rect.intersection(roof_rect)
		# Strips are laid up to the edge of the stairwell hole, so a roof piece
		# SHARING a boundary with the flight is correct and expected — only an
		# overlap with real area is roof actually hanging over the climb. The
		# tolerance is what separates the two, since exact float equality on
		# that shared edge is not guaranteed.
		if overlap.size.x > OVERLAP_TOLERANCE and overlap.size.y > OVERLAP_TOLERANCE:
			print("FAIL roof piece %s overlaps the final flight (%s) by %.3f x %.3f m -- no headroom" % [
				child.name, last_flight.name, overlap.size.x, overlap.size.y])
			print("     flight x[%.3f..%.3f] z[%.3f..%.3f] / %s x[%.3f..%.3f] z[%.3f..%.3f]" % [
				flight_rect.position.x, flight_rect.end.x,
				flight_rect.position.y, flight_rect.end.y, child.name,
				roof_rect.position.x, roof_rect.end.x,
				roof_rect.position.y, roof_rect.end.y])
			fails += 1
	if fails == 0:
		print("PASS roof stairwell opening clears the final flight")
	return fails


## Leg 0 is the only flight that starts at y=0 with nothing below it (see
## tower.gd's _corners doc) — every OTHER wall visit is at least one full
## storey up. If a flight on the south (door) wall ever starts below
## door_height, its steps sit in the path of someone walking in.
func _check_no_low_flight_on_door_wall(tower: Node3D, group: Node) -> int:
	var fails := 0
	for child in group.get_children():
		if not str(child.name).begins_with("Flight"):
			continue
		# yaw 270 is the south-wall direction — see tower.gd's _LEG_YAW.
		if is_equal_approx(fposmod(child.rotation_degrees.y, 360.0), 270.0):
			if child.position.y < tower.door_height - 0.01:
				print("FAIL %s is on the door wall but starts at y=%.3f, below door_height %.3f" % [
					child.name, child.position.y, tower.door_height])
				fails += 1
	if fails == 0:
		print("PASS no low flight blocks the door wall")
	return fails


## World-space box enclosing every MeshInstance3D at or under [param node].
## Returns a zero-size AABB when there is no mesh anywhere below it, which is
## how callers tell "nothing here" apart from "a box at the origin".
##
## Types are spelled out rather than inferred: `transform * aabb` is one of
## the expressions GDScript cannot infer a type for, and an un-inferable `:=`
## is a PARSE error — which means the script never loads, `quit()` is never
## reached, and a headless run idles forever instead of failing. See
## run_verify.ps1's header.
func _global_aabb(node: Node3D) -> AABB:
	var box := AABB()
	var found := false
	for child in node.get_children():
		if not (child is Node3D):
			continue
		var node_child: Node3D = child
		if node_child is MeshInstance3D:
			var mesh_child: MeshInstance3D = node_child
			if mesh_child.mesh != null:
				var global_box: AABB = mesh_child.global_transform * mesh_child.mesh.get_aabb()
				box = global_box if not found else box.merge(global_box)
				found = true
		var child_box: AABB = _global_aabb(node_child)
		if child_box.size != Vector3.ZERO:
			box = child_box if not found else box.merge(child_box)
			found = true
	return box


func _xz_rect(box: AABB) -> Rect2:
	return Rect2(box.position.x, box.position.z, box.size.x, box.size.z)


func _check_zone_wiring() -> int:
	var fails := 0
	var zone := Zone.new()

	var towers: Array = zone.get_towers()
	if towers.size() != 1:
		print("FAIL expected exactly 1 tower entry, got %d" % towers.size())
		fails += 1
	else:
		var data: Dictionary = towers[0]
		var pos: Vector3 = data["pos"]
		var dist := Vector2(pos.x, pos.z).distance_to(Vector2(130, 22))
		if dist > 0.01:
			print("FAIL tower not centred on the mountain summit pad (%.2f off)" % dist)
			fails += 1

	var excl: Array = zone.get_grass_exclusions()
	var covered := false
	for r in excl:
		if (r as Rect2).has_point(Vector2(130, 22)):
			covered = true
	if not covered:
		print("FAIL no grass exclusion rect covers the tower site")
		fails += 1

	zone.free()
	if fails == 0:
		print("PASS zone wiring (towers entry, grass exclusion)")
	return fails
