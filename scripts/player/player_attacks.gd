extends Node

## Turns SpellCaster's cast_released signal into an actual projectile.
##
## SpellCaster only owns timing (see spell_caster.gd) and deliberately knows
## nothing about what a spell does — this is the other side of that seam: it
## reads [member SpellCaster.current_spell], the tag try_cast() was given, and
## spawns whichever bolt matches. Two spells for now (LMB/RMB); adding a third
## is one more scene reference and one more match arm, not new plumbing.
##
## AIMING IS ASSISTED, NOT AUTOMATIC. With a target selected and the cursor
## pointing roughly at it, the bolt leaves on an intercept course — LED for the
## target's motion, so a target walking in a straight line at a constant speed
## is hit rather than trailed. Everything after launch is dumb: the bolt flies
## straight (see projectile.gd) and does not steer, so a target that changes
## direction, stops, or steps behind cover is missed. That is the intended
## behaviour, not a shortcoming — the shot is aimed well, it is not guaranteed.

## Full width of the cone, in degrees, inside which assistance applies: the
## cursor may sit up to HALF this either side of the target before the shot
## stops being helped and simply goes where it was pointed. Deliberately
## generous, so it is felt rather than fought.
@export_range(0.0, 180.0, 1.0) var aim_assist_arc_degrees := 60.0
## Height above a target's origin that shots are aimed at, so bolts arrive at
## chest height instead of through the feet. Matches npc_controller.gd's own
## aim_height, which is how the NPCs already aim at the player.
@export_range(0.0, 3.0, 0.05) var target_aim_height := 1.1

@export var caster_path: NodePath
@export var primary_scene: PackedScene
@export var secondary_scene: PackedScene

var _caster: Node = null


func _ready() -> void:
	_caster = get_node_or_null(caster_path)
	if _caster == null:
		_caster = get_parent().get_node_or_null("SpellCaster")
	if _caster == null:
		push_warning("PlayerAttacks: no SpellCaster found; attacks disabled.")
		return
	_caster.cast_released.connect(_on_cast_released)


func _on_cast_released(origin: Vector3, direction: Vector3) -> void:
	var scene: PackedScene = primary_scene if _caster.current_spell == "primary" else secondary_scene
	if scene == null:
		return
	var bolt: Node3D = scene.instantiate()
	# Aimed BEFORE the bolt is in the tree but AFTER it exists, because the
	# intercept solution needs this particular bolt's own speed — a fast bolt
	# leads a moving target far less than a slow one.
	var aim := _assisted_aim(origin, direction, bolt.speed)
	var host: Node = Game.current_zone if Game.current_zone else get_parent()
	host.add_child(bolt)
	bolt.launch(origin, aim)


## The direction to actually fire in: an intercept course if there is a target
## and the shot was pointed roughly at it, otherwise exactly where the player
## aimed.
func _assisted_aim(origin: Vector3, direction: Vector3, projectile_speed: float) -> Vector3:
	if not Targeting.has_target():
		return direction
	var target := Targeting.current
	var to_target := (target.global_position + Vector3.UP * target_aim_height) - origin

	# The arc is measured FLAT. The player aims by pointing at the ground (see
	# player_controller's _update_aim), so the vertical part of `direction`
	# carries no intent and comparing it would reject shots for a difference
	# the player never expressed.
	var flat_aim := Vector3(direction.x, 0.0, direction.z)
	var flat_target := Vector3(to_target.x, 0.0, to_target.z)
	if flat_aim.length_squared() < 0.0001 or flat_target.length_squared() < 0.0001:
		return direction
	if rad_to_deg(flat_aim.angle_to(flat_target)) > aim_assist_arc_degrees * 0.5:
		return direction

	var velocity := Vector3.ZERO
	if target is CharacterBody3D:
		velocity = target.velocity
		# Horizontal only: a grounded character's vertical velocity is gravity
		# being applied and cancelled every frame, not travel, and leading it
		# would aim at the ground.
		velocity.y = 0.0
	return lead_aim(to_target, velocity, projectile_speed)


## Where to point so a projectile of [param projectile_speed] meets something
## currently at [param to_target] (relative to the shooter) moving at
## [param target_velocity]. Returns a direction, not normalised.
##
## Solves for the time t at which the projectile and the target are in the same
## place. The projectile can be anywhere on a sphere of radius speed*t; the
## target is at to_target + velocity*t. Setting those equal and squaring gives
## a quadratic in t:
##
##     t^2 (v.v - s^2) + 2t (d.v) + d.d = 0
##
## The smallest POSITIVE root is the first moment an intercept exists; negative
## roots are the algebra describing an intercept in the past. When there is no
## positive root the target simply cannot be caught — it is moving away at or
## above projectile speed — and the honest answer is to fire straight at it and
## miss, rather than to invent a solution.
##
## Static and pure so it can be tested directly, with no scene, no bolt and no
## selected target.
static func lead_aim(to_target: Vector3, target_velocity: Vector3,
		projectile_speed: float) -> Vector3:
	if projectile_speed <= 0.0:
		return to_target
	var a := target_velocity.length_squared() - projectile_speed * projectile_speed
	var b := 2.0 * to_target.dot(target_velocity)
	var c := to_target.length_squared()

	var time := -1.0
	if absf(a) < 0.0001:
		# Target receding at exactly projectile speed: the quadratic degenerates
		# to a linear one, and dividing by `a` here would be a division by zero.
		if absf(b) > 0.0001:
			time = -c / b
	else:
		var discriminant := b * b - 4.0 * a * c
		if discriminant >= 0.0:
			var root := sqrt(discriminant)
			time = _smallest_positive((-b + root) / (2.0 * a), (-b - root) / (2.0 * a))

	if time <= 0.0:
		return to_target
	return to_target + target_velocity * time


static func _smallest_positive(first: float, second: float) -> float:
	var low := minf(first, second)
	var high := maxf(first, second)
	if low > 0.0:
		return low
	return high if high > 0.0 else -1.0
