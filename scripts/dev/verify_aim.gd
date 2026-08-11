extends Node

## Checks the lead-aim intercept solution in player_attacks.gd.
##
## The real assertion is geometric, not "did it return a vector": fire a
## projectile along the returned direction at the given speed, advance the
## target along its own velocity, and the two must arrive at the same point at
## the same time. A lead that merely looks plausible passes a shape check and
## still misses.
##
##   Godot --headless res://scenes/dev/VerifyAim.tscn
## Exits non-zero if any check fails.

const ATTACKS := preload("res://scripts/player/player_attacks.gd")
## Metres of miss tolerated at the intercept point. Well under a character's
## width, so anything passing here is a real hit rather than a near one.
const TOLERANCE := 0.05

var _failures := 0


func _ready() -> void:
	_check_stationary()
	_check_crossing()
	_check_receding_faster_than_bolt()
	_check_zero_speed()
	_check_assist_arc()
	if _failures == 0:
		print("VERIFY AIM: PASS")
	else:
		print("VERIFY AIM: FAIL (%d)" % _failures)
	get_tree().quit(1 if _failures > 0 else 0)


func _fail(message: String) -> void:
	print("  FAIL: %s" % message)
	_failures += 1


## Flies the shot and the target forward and reports how far apart they end up
## at the moment the projectile has travelled far enough to be at the aim point.
func _miss_distance(to_target: Vector3, velocity: Vector3, speed: float) -> float:
	var aim: Vector3 = ATTACKS.lead_aim(to_target, velocity, speed)
	var travel := aim.length()
	if travel <= 0.0:
		return INF
	var time := travel / speed
	var projectile := aim.normalized() * speed * time
	var target_at := to_target + velocity * time
	return projectile.distance_to(target_at)


func _check_stationary() -> void:
	var to_target := Vector3(0.0, 0.0, 20.0)
	var aim: Vector3 = ATTACKS.lead_aim(to_target, Vector3.ZERO, 35.0)
	# With nothing to lead, the aim must be the straight line to the target.
	if aim.normalized().distance_to(to_target.normalized()) > 0.001:
		_fail("a stationary target was led anyway: aim %s vs direct %s" % [aim, to_target])
	else:
		print("  stationary: aims straight at it")


func _check_crossing() -> void:
	# A target crossing the shot at right angles is the case a naive
	# "aim where it is now" gets most wrong, so lead must be clearly non-zero.
	var to_target := Vector3(0.0, 0.0, 20.0)
	var velocity := Vector3(6.0, 0.0, 0.0)
	var speed := 35.0
	var aim: Vector3 = ATTACKS.lead_aim(to_target, velocity, speed)
	if aim.x <= 0.1:
		_fail("no lead for a target crossing at %s: aim %s" % [velocity, aim])
	var miss := _miss_distance(to_target, velocity, speed)
	if miss > TOLERANCE:
		_fail("crossing target missed by %.3f m" % miss)
	else:
		print("  crossing at %.0f m/s: leads by %.2f m, intercepts within %.3f m"
			% [velocity.length(), aim.x, miss])

	# Same check for a target running directly away, which must be led further
	# out rather than shot at where it stands.
	var away := Vector3(0.0, 0.0, 8.0)
	var away_miss := _miss_distance(to_target, away, speed)
	if away_miss > TOLERANCE:
		_fail("receding target missed by %.3f m" % away_miss)
	else:
		print("  receding at %.0f m/s: intercepts within %.3f m" % [away.length(), away_miss])


## Outrunning the bolt has no solution. The honest result is to fire straight
## at the target and miss, not to return something invented.
func _check_receding_faster_than_bolt() -> void:
	var to_target := Vector3(0.0, 0.0, 20.0)
	var aim: Vector3 = ATTACKS.lead_aim(to_target, Vector3(0.0, 0.0, 40.0), 10.0)
	if aim.normalized().distance_to(to_target.normalized()) > 0.001:
		_fail("uncatchable target produced an invented lead: %s" % aim)
	elif not is_finite(aim.x) or not is_finite(aim.z):
		_fail("uncatchable target produced a non-finite aim: %s" % aim)
	else:
		print("  uncatchable: falls back to a straight shot rather than inventing one")


## A zero or negative speed must not divide by zero or hang.
func _check_zero_speed() -> void:
	var to_target := Vector3(0.0, 0.0, 20.0)
	var aim: Vector3 = ATTACKS.lead_aim(to_target, Vector3(3.0, 0.0, 0.0), 0.0)
	if not is_finite(aim.length()):
		_fail("zero projectile speed produced a non-finite aim: %s" % aim)
	else:
		print("  zero speed: returns a finite aim instead of dividing by zero")


## The arc gate: inside it the shot is helped, outside it the shot goes exactly
## where the player pointed. Without the outside case the assist would be a
## full snap wearing an arc as decoration.
func _check_assist_arc() -> void:
	# This logs "no SpellCaster found; attacks disabled" — expected and
	# harmless. Only _assisted_aim is under test here, and it does not touch
	# the caster; wiring a real SpellCaster up would test the warning, not the
	# aim.
	var attacks := ATTACKS.new()
	add_child(attacks)

	var npc: Node3D = load("res://scenes/npc/Witch.tscn").instantiate()
	add_child(npc)
	var origin := Vector3.ZERO
	# Target due north, moving across the shot so any assist is obvious.
	npc.global_position = Vector3(0.0, 0.0, 20.0)
	npc.velocity = Vector3(6.0, 0.0, 0.0)
	Targeting.set_target(npc)
	if Targeting.current != npc:
		_fail("could not select the NPC for the arc check")
		attacks.queue_free()
		npc.queue_free()
		return

	var half: float = attacks.aim_assist_arc_degrees * 0.5

	# Pointed straight at it: helped, so the aim must lead off the direct line.
	var direct := Vector3(0.0, 0.0, 1.0)
	var helped: Vector3 = attacks.call("_assisted_aim", origin, direct, 35.0)
	if helped.normalized().distance_to(direct) < 0.001:
		_fail("shot pointed at the target was not assisted")

	# Just inside the arc: still helped.
	var inside := direct.rotated(Vector3.UP, deg_to_rad(half - 5.0))
	var inside_aim: Vector3 = attacks.call("_assisted_aim", origin, inside, 35.0)
	if inside_aim.normalized().distance_to(inside.normalized()) < 0.001:
		_fail("shot %.0f deg off (inside the %.0f deg arc) was not assisted"
			% [half - 5.0, attacks.aim_assist_arc_degrees])

	# Just outside: untouched, exactly as aimed.
	var outside := direct.rotated(Vector3.UP, deg_to_rad(half + 5.0))
	var outside_aim: Vector3 = attacks.call("_assisted_aim", origin, outside, 35.0)
	if outside_aim.normalized().distance_to(outside.normalized()) > 0.001:
		_fail("shot %.0f deg off (outside the %.0f deg arc) was assisted anyway"
			% [half + 5.0, attacks.aim_assist_arc_degrees])

	# No target at all: untouched.
	Targeting.clear()
	var free_aim: Vector3 = attacks.call("_assisted_aim", origin, inside, 35.0)
	if free_aim.normalized().distance_to(inside.normalized()) > 0.001:
		_fail("shot was assisted with no target selected")

	print("  assist arc: helps inside %.0f deg, leaves shots alone outside it and with no target"
		% attacks.aim_assist_arc_degrees)
	attacks.queue_free()
	npc.queue_free()
