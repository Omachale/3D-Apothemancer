extends Node

## Turns SpellCaster's cast_released signal into an actual projectile.
##
## SpellCaster only owns timing (see spell_caster.gd) and deliberately knows
## nothing about what a spell does — this is the other side of that seam: it
## reads the [SpellProfile] the cast ran on and spawns whatever that names.
## Adding a spell is a new profile resource, with nothing to change here.
##
## AIMING IS ASSISTED, NOT AUTOMATIC. With a target selected and the cursor
## pointing roughly at it, the bolt leaves on an intercept course — LED for the
## target's motion, so a target walking in a straight line at a constant speed
## is hit rather than trailed. Everything after launch is dumb: the bolt flies
## straight (see projectile.gd) and does not steer, so a target that changes
## direction, stops, or steps behind cover is missed. That is the intended
## behaviour, not a shortcoming — the shot is aimed well, it is not guaranteed.
##
## THREE KINDS OF SHOT, chosen by [member SpellProfile.aim_mode]:
##
##   STRAIGHT_LEAD  a bolt that ignores gravity, led by lead_aim
##   BALLISTIC      an arrow that arcs and slows, solved by BallisticSolver
##   HITSCAN        a straight-line hit resolved the instant the cast releases
##
## They differ in more than the maths: a ballistic shot's speed is not a property
## of its scene but of the BOW AND THE DRAW, so it has to be worked out from the
## loadout before the projectile can be aimed, and the projectile is launched with
## the shot's energy rather than a fixed damage number. Everything above about
## assistance still applies — with no target selected, a ballistic shot arcs onto
## whatever the cursor is over, which is the same "help, do not take over" rule
## expressed for a projectile that falls.
##
## HITSCAN NEVER SPAWNS A TRAVELLING COLLIDER. There is nothing to travel — the
## hit is a straight line resolved here, this frame, against the assisted target
## or a raycast, and whatever a HITSCAN projectile scene draws afterward (see
## lightning_bolt.gd) is cosmetic and cannot change that result. This is the
## literal meaning of "the angles are cosmetic, the to-hit is straight".

## Full width of the cone, in degrees, inside which assistance applies: the
## cursor may sit up to HALF this either side of the target before the shot
## stops being helped and simply goes where it was pointed. Deliberately
## generous, so it is felt rather than fought.
@export_range(0.0, 180.0, 1.0) var aim_assist_arc_degrees := 90.0
## Height above a target's origin that shots are aimed at, so bolts arrive at
## chest height instead of through the feet. Matches npc_controller.gd's own
## aim_height, which is how the NPCs already aim at the player.
@export_range(0.0, 3.0, 0.05) var target_aim_height := 1.1

## How far out to place a free-aim landing point when the owner cannot supply one
## — see [method _free_aim_point]. Only reached by a caster whose owner has no
## get_aim_target, i.e. under test.
const FALLBACK_AIM_DISTANCE := 30.0
## How far an unassisted HITSCAN shot reaches before it is treated as a miss
## that struck nothing. A raycast has no natural range of its own the way a
## dropping arrow or a decaying bolt does, so this is the honest stand-in.
const LIGHTNING_MAX_RANGE := 60.0

@export var caster_path: NodePath
## Where the bow and arrows live, for BALLISTIC profiles. Left unset on anything
## that only casts spells.
@export var loadout_path: NodePath

var _caster: Node = null
var _loadout: ArcheryLoadout = null
## Aim scatter is sampled per shot — see ArcheryPhysics.scatter_direction. Its own
## generator rather than the global one so nothing else's random draws can shift
## where an arrow goes.
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()
	_caster = get_node_or_null(caster_path)
	if _caster == null:
		_caster = get_parent().get_node_or_null("SpellCaster")
	if _caster == null:
		push_warning("PlayerAttacks: no SpellCaster found; attacks disabled.")
		return
	_loadout = get_node_or_null(loadout_path) as ArcheryLoadout
	if _loadout == null:
		_loadout = get_parent().get_node_or_null("ArcheryLoadout") as ArcheryLoadout
	_caster.cast_released.connect(_on_cast_released)


func _on_cast_released(origin: Vector3, direction: Vector3, charge: float) -> void:
	var profile: SpellProfile = _caster.current_profile
	if profile == null or profile.projectile_scene == null:
		return
	match profile.aim_mode:
		SpellProfile.AimMode.BALLISTIC:
			_loose_arrow(profile, origin, direction, charge)
		SpellProfile.AimMode.HITSCAN:
			_cast_lightning(profile, origin, direction, charge)
		_:
			_cast_bolt(profile, origin, direction, charge)


func _cast_bolt(profile: SpellProfile, origin: Vector3, direction: Vector3,
		charge: float) -> void:
	var bolt: Node3D = profile.projectile_scene.instantiate()
	# What holding the button longer actually buys. A timed cast always reports
	# a multiplier of exactly 1.0, so this line is a no-op for every spell that
	# does not charge — see SpellProfile.damage_multiplier_at, and the note
	# there on why archery does NOT come through this path.
	if "damage" in bolt:
		bolt.damage *= profile.damage_multiplier_at(charge)
	# Aimed BEFORE the bolt is in the tree but AFTER it exists, because the
	# intercept solution needs this particular bolt's own speed — a fast bolt
	# leads a moving target far less than a slow one.
	var aim := _assisted_aim(origin, direction, bolt.speed)
	var host: Node = Game.current_zone if Game.current_zone else get_parent()
	host.add_child(bolt)
	bolt.launch(origin, aim)


## Looses an arrow: the shot is solved from the draw, the arc from the shot, and
## the damage from neither — the arrow works that out itself on impact from how
## far it flew (see arrow.gd).
func _loose_arrow(profile: SpellProfile, origin: Vector3, direction: Vector3,
		charge: float) -> void:
	if _loadout == null or not _loadout.is_ready_to_shoot():
		return
	var shot := _loadout.solve_at_pull(charge)
	var speed: float = shot["muzzle_velocity_ms"]
	# A draw barely begun has no energy worth an arrow. Firing anyway would drop
	# one at the archer's feet, which reads as a bug rather than as a weak shot.
	if speed <= 0.0 or shot["muzzle_energy_j"] <= ArcheryPhysics.DESPAWN_ENERGY_J:
		return

	var aim := _ballistic_aim(origin, direction, speed, shot["decay"])
	aim = ArcheryPhysics.scatter_direction(aim, shot["aim_stddev_deg"], _rng)
	var arrow: Node3D = profile.projectile_scene.instantiate()
	var host: Node = Game.current_zone if Game.current_zone else get_parent()
	host.add_child(arrow)
	arrow.launch(origin, aim, speed, shot["muzzle_energy_j"], shot["decay"],
		get_parent() as Node3D)


## Resolves a straight-line hit and hands it, already decided, to a purely
## cosmetic bolt — see the class note on why HITSCAN never spawns a travelling
## collider. Damage multiplier is read off the spawned scene exactly like
## [method _cast_bolt] does, so a charged HITSCAN profile works the same way a
## charged bolt does even though nothing here charges today.
func _cast_lightning(profile: SpellProfile, origin: Vector3, direction: Vector3,
		charge: float) -> void:
	var hit := _lightning_target(origin, direction)
	var bolt: Node3D = profile.projectile_scene.instantiate()
	if "damage" in bolt:
		bolt.damage *= profile.damage_multiplier_at(charge)
	var host: Node = Game.current_zone if Game.current_zone else get_parent()
	host.add_child(bolt)
	bolt.strike(origin, hit["point"], hit["body"])


## Where a HITSCAN shot hits and what it hits, as one straight line — the
## assisted target if the shot was pointed roughly at it (see
## [method _assist_target]), otherwise a raycast along [param direction].
## Returns \{"point": Vector3, "body": Node3D or null\}; a raycast that hits
## nothing still returns a point, at [constant LIGHTNING_MAX_RANGE], so the
## bolt has somewhere honest to end rather than nowhere at all.
func _lightning_target(origin: Vector3, direction: Vector3) -> Dictionary:
	var target := _assist_target(origin, direction)
	if target:
		return {"point": target.global_position + Vector3.UP * target_aim_height, "body": target}

	var body := get_parent() as Node3D
	var world := body.get_world_3d() if body else null
	if world == null or direction.length_squared() < 0.0001:
		return {"point": origin + direction * LIGHTNING_MAX_RANGE, "body": null}
	var to := origin + direction.normalized() * LIGHTNING_MAX_RANGE
	var query := PhysicsRayQueryParameters3D.create(origin, to, Layers.SOLID | Layers.ENEMY)
	if body is CollisionObject3D:
		query.exclude = [(body as CollisionObject3D).get_rid()]
	var hit := world.direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return {"point": to, "body": null}
	return {"point": hit["position"], "body": hit.get("collider") as Node3D}


## The arc to fire along: onto the selected target if the shot was pointed roughly
## at it, otherwise onto whatever the cursor is over.
##
## Free aim lands the arrow AT A POINT rather than sending it along a ray, because
## a falling projectile pointed along a direction has no defined destination — it
## simply comes down somewhere. Solving to the cursor's ground point is what makes
## an unassisted shot mean anything.
func _ballistic_aim(origin: Vector3, direction: Vector3, speed: float,
		decay: float) -> Vector3:
	var gravity: float = ArcheryPhysics.GRAVITY
	var target := _assist_target(origin, direction)
	if target == null:
		var point := _free_aim_point(origin, direction)
		return BallisticSolver.solve_arc(origin, point, speed, gravity, decay)["direction"]
	var aim_point := target.global_position + Vector3.UP * target_aim_height
	return BallisticSolver.solve_intercept(origin, aim_point,
		_target_velocity(target), speed, gravity, decay)["direction"]


## Where an unassisted shot should land. Prefers the player's own aim point, which
## is the cursor raycast against the real world, and falls back to projecting the
## direction out — for any owner that does not provide one, whose `direction` is a
## unit vector and would otherwise put the landing point a metre from the archer's
## feet.
func _free_aim_point(origin: Vector3, direction: Vector3) -> Vector3:
	var body := get_parent()
	if body and body.has_method("get_aim_target"):
		return body.get_aim_target()
	return origin + direction * FALLBACK_AIM_DISTANCE


## The direction to actually fire in: an intercept course if there is a target
## and the shot was pointed roughly at it, otherwise exactly where the player
## aimed.
func _assisted_aim(origin: Vector3, direction: Vector3, projectile_speed: float) -> Vector3:
	var target := _assist_target(origin, direction)
	if target == null:
		return direction
	var to_target := (target.global_position + Vector3.UP * target_aim_height) - origin
	return lead_aim(to_target, _target_velocity(target), projectile_speed)


## The selected target, if there is one and the shot was pointed close enough to
## it to deserve help — otherwise null, meaning "fire exactly where aimed".
##
## The arc is measured FLAT. The player aims by pointing at the ground (see
## player_controller's _update_aim), so the vertical part of `direction` carries
## no intent and comparing it would reject shots for a difference the player never
## expressed.
func _assist_target(origin: Vector3, direction: Vector3) -> Node3D:
	if not Targeting.has_target():
		return null
	var target := Targeting.current
	var to_target := (target.global_position + Vector3.UP * target_aim_height) - origin
	var flat_aim := Vector3(direction.x, 0.0, direction.z)
	var flat_target := Vector3(to_target.x, 0.0, to_target.z)
	if flat_aim.length_squared() < 0.0001 or flat_target.length_squared() < 0.0001:
		return null
	if rad_to_deg(flat_aim.angle_to(flat_target)) > aim_assist_arc_degrees * 0.5:
		return null
	return target


## How fast the target is travelling, for leading. Horizontal only: a grounded
## character's vertical velocity is gravity being applied and cancelled every
## frame, not travel, and leading it would aim at the ground.
func _target_velocity(target: Node3D) -> Vector3:
	if not (target is CharacterBody3D):
		return Vector3.ZERO
	var velocity: Vector3 = (target as CharacterBody3D).velocity
	velocity.y = 0.0
	return velocity


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
