extends Node

## Checks targeting.gd's selection rules, which are mostly about what must NOT
## happen: a missed click must not drop the target, a corpse must not stay
## selected, and a target must not survive walking out of range.
##
## Run as a SCENE — targeting.gd is an autoload and reaches Game:
##   Godot --headless res://scenes/dev/VerifyTargeting.tscn
## Exits non-zero if any check fails.

var _failures := 0


func _ready() -> void:
	_check_selection_rules()
	await _check_death_clears()
	_check_deselect_radius()
	_check_highlight()
	_check_cycle()
	if _failures == 0:
		print("VERIFY TARGETING: PASS")
	else:
		print("VERIFY TARGETING: FAIL (%d)" % _failures)
	get_tree().quit(1 if _failures > 0 else 0)


func _fail(message: String) -> void:
	print("  FAIL: %s" % message)
	_failures += 1


func _spawn_npc() -> Node3D:
	return _spawn_npc_in(self)


func _spawn_npc_in(parent: Node) -> Node3D:
	var npc: Node3D = load("res://scenes/npc/Witch.tscn").instantiate()
	parent.add_child(npc)
	return npc


func _check_selection_rules() -> void:
	var npc := _spawn_npc()
	Targeting.set_target(npc)
	if Targeting.current != npc:
		_fail("set_target did not select a valid NPC")
	if not Targeting.has_target():
		_fail("has_target() false with a target selected")

	# A signal must fire on change, and must NOT fire when re-selecting the
	# same target — a listener that rebuilds UI would otherwise thrash.
	var changes := [0]
	Targeting.target_changed.connect(func(_t: Node3D) -> void: changes[0] += 1)
	Targeting.set_target(npc)
	if changes[0] != 0:
		_fail("target_changed fired re-selecting the same target")

	# Escape clears.
	Targeting.clear()
	if Targeting.current != null:
		_fail("clear() left a target selected")
	if changes[0] != 1:
		_fail("target_changed fired %d times on clear, expected 1" % changes[0])

	# An untargetable node must be refused rather than accepted.
	npc.targetable = false
	Targeting.set_target(npc)
	if Targeting.current != null:
		_fail("selected an NPC with targetable = false")
	npc.targetable = true

	print("  selection: selects, refuses untargetable, clears, no duplicate signals")
	npc.queue_free()


func _check_death_clears() -> void:
	var npc := _spawn_npc()
	Targeting.set_target(npc)
	npc.take_damage(999.0)
	# The corpse is still in the tree while it collapses; it must already be
	# deselected, or the panel keeps showing a dead thing's name.
	await get_tree().process_frame
	await get_tree().process_frame
	if Targeting.current != null:
		_fail("killing the target left it selected during its collapse")
	else:
		print("  death: clears the selection while the corpse is still collapsing")
	await get_tree().create_timer(2.0).timeout


## The radius must track the camera's zoom rather than being fixed, and must
## comfortably exceed what the camera can actually see at the default zoom.
func _check_deselect_radius() -> void:
	var radius := Targeting.deselect_radius()
	var floor_value: float = Targeting.MIN_DESELECT_RADIUS
	if radius < floor_value:
		_fail("deselect radius %.1f is under its own floor %.1f" % [radius, floor_value])

	# Default zoom is distance 20, so the camera sees ~44 units across. The
	# radius must be bigger than that, or targets deselect while on screen.
	var visible_width: float = 20.0 * Targeting.GROUND_PER_ZOOM
	if radius <= visible_width:
		_fail("deselect radius %.1f does not exceed the ~%.0f units visible at default zoom"
			% [radius, visible_width])
	print("  deselect radius: %.1f units, against ~%.0f visible at default zoom"
		% [radius, visible_width])


## The tint must go on when a target is selected and come off when it is not,
## and — the part that is easy to get wrong — must not touch an overlay that
## something else owns, because the death shroud uses the same mechanism.
func _check_highlight() -> void:
	var highlight := Node.new()
	highlight.set_script(load("res://scripts/combat/target_highlight.gd"))
	add_child(highlight)

	var npc := _spawn_npc()
	var meshes: Array = highlight.call("_find_meshes", npc)
	if meshes.is_empty():
		_fail("NPC has no MeshInstance3D for the highlight to tint")
		npc.queue_free()
		highlight.queue_free()
		return

	Targeting.set_target(npc)
	var tinted: int = meshes.filter(
		func(m: MeshInstance3D) -> bool: return m.material_overlay != null).size()
	if tinted == 0:
		_fail("selecting a target tinted none of its %d meshes" % meshes.size())

	Targeting.clear()
	var still: int = meshes.filter(
		func(m: MeshInstance3D) -> bool: return m.material_overlay != null).size()
	if still != 0:
		_fail("deselecting left %d meshes still tinted" % still)
	print("  highlight: tints %d meshes on select, removes them all on clear" % tinted)

	# A mesh already carrying someone else's overlay must be left alone, or the
	# tint overwrites the death shroud on a target killed while selected.
	var owned := StandardMaterial3D.new()
	meshes[0].material_overlay = owned
	Targeting.set_target(npc)
	if meshes[0].material_overlay != owned:
		_fail("highlight overwrote an overlay it did not own")
	Targeting.clear()
	if meshes[0].material_overlay != owned:
		_fail("highlight cleared an overlay it did not own")
	print("  highlight: leaves a foreign overlay (the death shroud) untouched")

	npc.queue_free()
	highlight.queue_free()


## Tab must walk every target in range and wrap, and must pick the nearest when
## nothing is selected.
##
## Builds a stand-in player and zone first. targets_in_range() searches
## Game.current_zone relative to Game.player, and this scene is not the World —
## neither is registered, so without this the search correctly finds nothing.
## The fix belongs here rather than in a fallback in targeting.gd: "look
## through the whole tree when there is no zone" would be production code
## existing solely to make a test pass.
func _check_cycle() -> void:
	var zone := Node3D.new()
	add_child(zone)
	Game.register_zone(zone)

	var player := CharacterBody3D.new()
	add_child(player)
	Game.register_player(player)
	var origin := player.global_position

	var near := _spawn_npc_in(zone)
	var far := _spawn_npc_in(zone)
	near.global_position = origin + Vector3(3.0, 0.0, 0.0)
	far.global_position = origin + Vector3(12.0, 0.0, 0.0)

	Targeting.clear()
	var in_range := Targeting.targets_in_range()
	if in_range.size() < 2:
		_fail("only %d targets in range, expected at least the 2 just placed" % in_range.size())
		near.queue_free()
		far.queue_free()
		return
	if in_range[0].global_position.distance_to(origin) 			> in_range[1].global_position.distance_to(origin):
		_fail("targets_in_range is not sorted nearest-first")

	# From nothing, Tab takes the nearest.
	Targeting.cycle()
	if Targeting.current != in_range[0]:
		_fail("cycle from no target did not pick the nearest")

	# Then it walks the rest, and wraps back round to the start.
	var seen: Array = [Targeting.current]
	for i in in_range.size() - 1:
		Targeting.cycle()
		if Targeting.current in seen:
			_fail("cycle revisited %s before covering every target" % Targeting.current)
			break
		seen.append(Targeting.current)
	Targeting.cycle()
	if Targeting.current != in_range[0]:
		_fail("cycle did not wrap back to the first target")
	print("  cycle: nearest-first, visits all %d in range, wraps" % in_range.size())

	Targeting.clear()
	near.queue_free()
	far.queue_free()
	player.queue_free()
	zone.queue_free()
