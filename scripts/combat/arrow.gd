extends Node3D

## An arrow in flight: arcs under gravity, sheds speed to the air, noses over as
## it falls, and hits for whatever energy it has left when it arrives.
##
## DAMAGE COMES FROM ENERGY, AND ENERGY FROM DISTANCE FLOWN — never from elapsed
## time or frame count. So the same arrow hitting the same target at the same
## range does the same damage on any machine at any frame rate, and range falloff
## needs no separate curve because it is already what the drag solution says. See
## archery_physics.gd.
##
## IT INTEGRATES WITH BallisticSolver.step_velocity, WHICH IS THE POINT. The
## solver chose the launch angle by predicting flight with that function; if this
## moved by any other rule the arrow would not go where the aim said, and a more
## accurate solver would not help. It also SUBSTEPS to the solver's own
## prediction step rather than taking one jump per physics frame — Euler
## integration at 60 Hz drifts about 10 cm from a 240 Hz prediction over a
## typical shot, which is small but systematic, and free to remove.
##
## THE MESH IS DELIBERATELY NOT ARROW-SIZED. A real shaft is about 8 mm across,
## and the gameplay camera renders roughly 50 pixels per metre (see
## cast_effect.gd, which measures the character at ~100 px tall) — so an honest
## arrow is 0.4 of a pixel wide and simply cannot be seen. The first version was
## built to scale and was invisible in play while still dealing damage. The shaft
## is now ~7x its true thickness and about a metre long, with red fletching for
## contrast against grass, on the same reasoning cast_effect.gd's orb is oversized:
## at this camera distance, readability beats fidelity. Length also matters at
## speed — an arrow shorter than the ~0.76 m it covers per frame reads as a dashed
## line rather than a streak.
##
## HIT DETECTION IS A RAYCAST ALONG THE PATH, not an Area3D overlap like
## projectile.gd uses. At 45 m/s an arrow crosses three quarters of a metre in one
## physics frame — comparable to the width of what it is shooting at — so overlap
## testing can miss a target entirely by stepping over it. A war bow makes that
## worse. Casting the segment it actually travelled cannot tunnel at any speed,
## and it returns the true impact point, which is what an arrow that sticks into
## things will need.

## Fired when the arrow hits something, with the impact point, what was hit, and
## the damage dealt. A hook for impact effects and sound; nothing listens yet.
signal struck(at: Vector3, body: Node3D, damage: float)
## Fired when the arrow gives up without hitting anything — spent, or timed out.
signal spent(at: Vector3)

@export_group("Flight")
@export var gravity := ArcheryPhysics.GRAVITY
## Removed once its energy falls below this many joules. Left at the shared
## default so range scales with the shot rather than being authored per arrow —
## see [constant ArcheryPhysics.DESPAWN_ENERGY_J].
@export_range(0.1, 50.0, 0.1) var despawn_energy_j := ArcheryPhysics.DESPAWN_ENERGY_J
## Absolute backstop, in seconds. Not the normal way an arrow ends — the energy
## floor is — but a shot fired straight up in a world with no ground would
## otherwise fall forever.
@export_range(1.0, 120.0, 0.5) var max_lifetime := 30.0

@export_group("Impact")
## What the arrow can hit. ENEMY and SOLID by default, which excludes the player
## who fired it without needing to exclude anything by hand.
@export_flags_3d_physics var hit_mask := Layers.ENEMY | Layers.SOLID
@export var apply_knockback_on_hit := true
## Much gentler than a spell bolt's. An arrow carries a few tens of joules; the
## shove should read as a thud, not a shunt.
@export_range(0.0, 60.0, 0.5) var knockback_force := 5.0
@export_range(0.0, 20.0, 0.5) var knockback_lift := 1.0
## Spawned at the impact point, if anything.
@export var impact_scene: PackedScene = null

## Energy the arrow left the string with, in joules — set by [method launch].
var muzzle_energy_j := 0.0
## Drag decay per metre, from the arrow's mass and drag coefficient.
var drag_decay := 0.0

var _velocity := Vector3.ZERO
var _distance_flown := 0.0
var _age := 0.0
var _flying := false
## The shooter's own collider, so an arrow leaving a hand cannot immediately hit
## the body it left. Belt and braces next to [member hit_mask], which already
## excludes the player, but an NPC archer shooting at the player needs it.
var _exclude: Array[RID] = []


## Points the arrow and starts it moving. Call straight after adding it to the
## tree.
##
## Takes plain numbers rather than the dictionary
## [method ArcheryPhysics.solve_shot] returns, so this stays ignorant of that
## dictionary's shape and can be flown with arbitrary values under test.
func launch(from: Vector3, direction: Vector3, muzzle_speed: float,
		energy_j: float, decay: float, shooter: Node3D = null) -> void:
	global_position = from
	muzzle_energy_j = energy_j
	drag_decay = decay
	_velocity = direction.normalized() * maxf(muzzle_speed, 0.0)
	_distance_flown = 0.0
	_age = 0.0
	_exclude.clear()
	if shooter is CollisionObject3D:
		_exclude.append((shooter as CollisionObject3D).get_rid())
	_face_travel()
	_flying = true


## Energy the arrow currently carries, in joules.
##
## Read from the closed form on distance flown rather than from ½mv² of the
## current velocity, and the difference is deliberate: the live velocity also
## carries whatever gravity has added, so a lobbed arrow would gain energy on the
## way down and hit harder than a flat shot at the same range. That is true of
## real arrows and is NOT the model this game is calibrated against — see
## archery_physics.gd, whose damage figures assume energy is a function of
## distance flown alone.
func current_energy() -> float:
	return ArcheryPhysics.energy_at_distance(muzzle_energy_j, drag_decay, _distance_flown)


## Damage this arrow would do if it hit right now.
func current_damage() -> float:
	return ArcheryPhysics.damage_from_energy(current_energy())


## Metres flown so far — what damage is a function of.
func distance_flown() -> float:
	return _distance_flown


func _physics_process(delta: float) -> void:
	if not _flying:
		return
	_age += delta
	if _age >= max_lifetime:
		_expire()
		return

	# Substep to the solver's own prediction step, so the flight matches the
	# aim — see the class note.
	var substeps := maxi(int(ceil(delta / BallisticSolver.PREDICT_DT)), 1)
	var step_delta := delta / float(substeps)
	for _i in substeps:
		if _advance(step_delta):
			return


## One substep. Returns true if the arrow is finished and must not be stepped
## again — it has hit something, or run out of energy.
func _advance(delta: float) -> bool:
	var from := global_position
	var to := from + _velocity * delta
	var hit := _cast(from, to)
	if not hit.is_empty():
		_impact(hit)
		return true

	global_position = to
	_distance_flown += from.distance_to(to)
	_velocity = BallisticSolver.step_velocity(_velocity, gravity, drag_decay, delta)
	_face_travel()

	if current_energy() <= despawn_energy_j:
		_expire()
		return true
	return false


func _cast(from: Vector3, to: Vector3) -> Dictionary:
	if from.is_equal_approx(to):
		return {}
	var world := get_world_3d()
	if world == null:
		return {}
	var query := PhysicsRayQueryParameters3D.create(from, to, hit_mask)
	query.exclude = _exclude
	return world.direct_space_state.intersect_ray(query)


func _impact(hit: Dictionary) -> void:
	_flying = false
	var point: Vector3 = hit.get("position", global_position)
	global_position = point
	var body := hit.get("collider") as Node3D
	var damage := current_damage()

	# Duck-typed the same way projectile.gd does it: anything that can be hurt
	# implements take_damage, and this stays ignorant of what it hit.
	if body and damage > 0.0 and body.has_method("take_damage"):
		body.take_damage(damage)
	if body and apply_knockback_on_hit and body.has_method("apply_knockback"):
		body.apply_knockback(_velocity.normalized(), knockback_force, knockback_lift)
	if impact_scene:
		var effect: Node3D = impact_scene.instantiate()
		var host := get_parent()
		if host:
			host.add_child(effect)
			effect.global_position = point

	struck.emit(point, body, damage)
	queue_free()


func _expire() -> void:
	_flying = false
	spent.emit(global_position)
	queue_free()


## Turns the arrow to follow its own travel, so it visibly noses over as it
## falls. look_at points -Z at the target, so the mesh is built extending along
## +Z with the tip at the origin.
##
## Guarded because look_at is degenerate for a direction parallel to its up
## vector — an arrow at the very top of a steep lob, or one fired straight down.
func _face_travel() -> void:
	if _velocity.length_squared() < 0.000001:
		return
	var direction := _velocity.normalized()
	if absf(direction.dot(Vector3.UP)) > 0.999:
		return
	look_at(global_position + direction, Vector3.UP)
