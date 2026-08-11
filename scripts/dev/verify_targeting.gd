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
	if _failures == 0:
		print("VERIFY TARGETING: PASS")
	else:
		print("VERIFY TARGETING: FAIL (%d)" % _failures)
	get_tree().quit(1 if _failures > 0 else 0)


func _fail(message: String) -> void:
	print("  FAIL: %s" % message)
	_failures += 1


func _spawn_npc() -> Node3D:
	var npc: Node3D = load("res://scenes/npc/Witch.tscn").instantiate()
	add_child(npc)
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
