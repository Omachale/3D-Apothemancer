extends Node

## Autoload. Which enemy the player currently has selected, and the one place
## anything asks — the target panel, the outline, and spell aiming all read
## [member current] rather than each working it out from the mouse.
##
## SELECTION IS ADDITIVE TO CASTING, not instead of it. Left mouse already
## casts, and this reads the same press without consuming it, so a click on an
## enemy both selects it and fires. Making selection its own button was the
## alternative and it is worse: it puts a mandatory extra keystroke in front of
## every fight for a game whose whole input vocabulary is currently WASD and two
## mouse buttons.
##
## A MISSED CLICK LEAVES THE TARGET ALONE. Since the select button IS the cast
## button, clearing on a miss would mean every shot that goes wide also drops
## the thing being shot at — the opposite of what the player meant. Escape is
## the explicit way out.
##
## Polls in [method _process] with Input.is_action_just_pressed rather than
## implementing _unhandled_input, matching camera_rig.gd. That deliberately
## sidesteps input propagation order: as an autoload this node sits at the very
## top of the tree, and unhandled input arrives at nodes in reverse tree order,
## so an _unhandled_input here would run after every gameplay node rather than
## before them.

## Emitted when the selection changes, including to null on clear. Carries the
## target so listeners need no reference back here.
signal target_changed(target: Node3D)

## World units of visible ground per unit of camera zoom distance. Same 2.2 the
## rain box is sized from (see rain.gd's box_size_per_distance) and the same
## fact wind.gd derives its view radius from — this is how wide the camera sees
## at a given zoom, and it belongs to the camera, not to any one consumer.
const GROUND_PER_ZOOM := 2.2
## How far past the screen edge a target may drift before it is dropped. The
## brief was "roughly a screen width, then a bit more"; the slack IS the "bit
## more", kept as its own named number so it can be tuned without anyone having
## to re-derive where 2.86 came from.
const DESELECT_SLACK := 1.3
## Floor, so zoomed right in (distance 4) the deselect range does not collapse
## to ~11 units and drop targets the player is standing next to.
const MIN_DESELECT_RADIUS := 30.0
## Far enough to reach anything the camera can see, at any zoom.
const PICK_RAY_LENGTH := 500.0

var current: Node3D = null


func _process(_delta: float) -> void:
	if Input.is_action_just_pressed("target_clear"):
		clear()
	elif Input.is_action_just_pressed("target_cycle"):
		cycle()
	elif Input.is_action_just_pressed("cast_primary") and not _input_frozen():
		_try_select_under_mouse()
	_drop_if_gone()


## Select [param target], or clear if it is null or not a valid choice.
func set_target(target: Node3D) -> void:
	if target == current:
		return
	current = target if _is_targetable(target) else null
	target_changed.emit(current)


func clear() -> void:
	set_target(null)


func has_target() -> bool:
	return current != null and is_instance_valid(current)


## Step to the next target in range, wrapping at the end. With nothing
## selected — or with the current selection no longer in the list — this picks
## the nearest, so Tab is also the "just give me something" key.
##
## Ordered by distance from the player, not by screen position. Distance is
## stable: it does not change when the camera rotates, so a given Tab press
## lands on the same enemy regardless of which way the player happens to be
## looking. Left-to-right screen order reads more naturally but reshuffles the
## whole cycle every time the camera swings, which makes Tab unpredictable
## exactly when a fight is moving.
func cycle() -> void:
	var candidates := targets_in_range()
	if candidates.is_empty():
		return  # Nothing to cycle to; leave whatever is selected alone.
	# find() returns -1 when the current target is not a candidate, and -1 + 1
	# is 0, so that case correctly falls through to the nearest.
	var index := candidates.find(current)
	set_target(candidates[(index + 1) % candidates.size()])


## Every valid target within [method deselect_radius], nearest first.
##
## Walks the zone on demand rather than keeping a registry. That is a tree walk
## per Tab press, which sounds wasteful and is not: it happens on a keystroke,
## not per frame, over a scene holding a few hundred nodes. A registry would
## buy nothing measurable and would add the classic failure of going stale when
## something spawns, dies or streams out without deregistering.
func targets_in_range() -> Array[Node3D]:
	var found: Array[Node3D] = []
	var player: Node3D = Game.player
	if player == null or Game.current_zone == null:
		return found
	var radius := deselect_radius()
	var origin := player.global_position
	for node in Game.current_zone.find_children("*", "CharacterBody3D", true, false):
		var body := node as Node3D
		if body == player or not _is_targetable(body):
			continue
		if origin.distance_to(body.global_position) <= radius:
			found.append(body)
	found.sort_custom(func(a: Node3D, b: Node3D) -> bool:
		return origin.distance_squared_to(a.global_position) \
			< origin.distance_squared_to(b.global_position))
	return found


## How far a target may get before it is dropped, derived from the camera's
## LIVE zoom rather than being a fixed number. A fixed one would be correct at
## exactly one zoom level and wrong everywhere else — zoomed out, targets still
## plainly on screen would silently deselect.
func deselect_radius() -> float:
	var distance := 20.0
	if Game.camera_rig and Game.camera_rig.has_method("get_active_distance"):
		distance = Game.camera_rig.get_active_distance()
	return maxf(MIN_DESELECT_RADIUS, distance * GROUND_PER_ZOOM * DESELECT_SLACK)


## Ray from the camera through the cursor against the ENEMY layer only, so the
## pick cannot be blocked by terrain, props or the player's own body standing
## between the camera and something selectable.
func _try_select_under_mouse() -> void:
	var camera := _camera()
	if camera == null:
		return
	var mouse := camera.get_viewport().get_mouse_position()
	var from := camera.project_ray_origin(mouse)
	var query := PhysicsRayQueryParameters3D.create(
		from, from + camera.project_ray_normal(mouse) * PICK_RAY_LENGTH, Layers.ENEMY)
	var hit := camera.get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return  # A miss leaves the current target alone — see the class note.
	var body := hit.get("collider") as Node3D
	if _is_targetable(body):
		set_target(body)


## Drops a target that has died, been freed by streaming, or wandered out of
## range. Checked every frame rather than hooked to a signal because "out of
## range" has no event to fire — the player walking away is what causes it.
func _drop_if_gone() -> void:
	if current == null:
		return
	if not _is_targetable(current):
		clear()
		return
	var player: Node3D = Game.player
	if player and player.global_position.distance_to(current.global_position) > deselect_radius():
		clear()


## A valid target is alive, still in the tree, and has not opted out — a corpse
## mid-collapse clears `targetable` precisely so it cannot be picked.
func _is_targetable(node: Node3D) -> bool:
	if node == null or not is_instance_valid(node) or not node.is_inside_tree():
		return false
	if not (node.get("targetable") as bool):
		return false
	if node.has_method("get_health"):
		var health: Health = node.get_health()
		if health and not health.is_alive():
			return false
	return true


## True while a UI screen owns the left click instead of gameplay — see
## player_controller.is_input_frozen. Guarded rather than assumed present,
## since Targeting also runs against the test harnesses that build a bare
## player stand-in with no such method.
func _input_frozen() -> bool:
	var player: Node = Game.player
	return player != null and player.has_method("is_input_frozen") and player.is_input_frozen()


func _camera() -> Camera3D:
	if Game.camera_rig and Game.camera_rig.has_method("get_camera"):
		return Game.camera_rig.get_camera()
	return null
