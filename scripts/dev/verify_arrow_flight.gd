extends Node

## Checks the arrow in scripts/combat/arrow.gd, flown for real through the
## physics loop rather than simulated on paper.
##
## THE CHECK THIS SUITE EXISTS FOR is that the arrow arrives where the solver
## aimed. ballistic_solver.gd picks a launch angle by predicting a flight; if the
## thing that actually flies moves by even a slightly different rule, the aim is
## wrong by however much the two disagree and no amount of solver accuracy
## rescues it. The two now share `step_velocity` so they cannot diverge in
## principle — this proves it in practice, through the real node, the real
## physics tick and the real substepping.
##
## MEASURED AGAINST THE PATH, NOT THE SAMPLES. At 45 m/s an arrow moves three
## quarters of a metre per physics frame, so comparing frame-boundary positions to
## the target would report misses of up to ~0.4 m that never happened. Distance is
## measured to the SEGMENT flown between samples instead, which is accurate to
## well under a centimetre.
##
## The second theme is that an arrow ends by RUNNING OUT OF ENERGY rather than by
## running out of time, since that is what makes range scale with the bow instead
## of being authored per arrow.
##
##   Godot --headless res://scenes/dev/VerifyArrowFlight.tscn
## Exits non-zero if any check fails.

const ARROW_SCENE := preload("res://scenes/combat/Arrow.tscn")
const WITCH_SCENE := preload("res://scenes/npc/Witch.tscn")
const BS := preload("res://scripts/combat/ballistic_solver.gd")
const AP := preload("res://scripts/combat/archery_physics.gd")

const GRAVITY := 9.81
## Metres of miss allowed where the arrow is meant to arrive on target. Well
## inside a body's width.
const TOLERANCE := 0.25
const ORIGIN := Vector3(0.0, 1.5, 0.0)
## Physics frames any single flight may take before the test gives up.
const FRAME_LIMIT := 3000

var _failures := 0


func _ready() -> void:
	_check_step_velocity_matches_an_independent_integrator()
	await _check_arrow_lands_where_the_solver_aimed()
	await _check_energy_and_damage_fall_with_distance()
	await _check_it_ends_on_energy_not_time()
	await _check_a_stronger_bow_shoots_further()
	await _check_it_noses_over()
	await _check_it_damages_what_it_hits()
	await _check_it_cannot_tunnel_through_a_target()
	if _failures == 0:
		print("ALL ARROW FLIGHT CHECKS PASSED")
	else:
		print("VERIFY ARROW FLIGHT: FAIL (%d)" % _failures)
	get_tree().quit(1 if _failures > 0 else 0)


func _fail(message: String) -> void:
	print("  FAIL: %s" % message)
	_failures += 1


# ---------------------------------------------------------------------------
# HARNESS
# ---------------------------------------------------------------------------

func _spawn_arrow() -> Node3D:
	var arrow: Node3D = ARROW_SCENE.instantiate()
	add_child(arrow)
	return arrow


## Flies [param arrow] until it frees itself or the limit is reached, tracking
## how close its PATH passed to [param target].
func _fly(arrow: Node3D, target: Vector3) -> Dictionary:
	var closest := INF
	var frames := 0
	var previous: Vector3 = arrow.global_position
	var last_seen: Vector3 = previous
	var flown := 0.0
	while is_instance_valid(arrow) and frames < FRAME_LIMIT:
		var here: Vector3 = arrow.global_position
		closest = minf(closest, _distance_to_segment(previous, here, target))
		previous = here
		last_seen = here
		flown = arrow.distance_flown()
		await get_tree().physics_frame
		frames += 1
	return {
		"closest": closest, "frames": frames, "last_position": last_seen,
		"flown": flown, "freed": not is_instance_valid(arrow),
	}


func _distance_to_segment(a: Vector3, b: Vector3, point: Vector3) -> float:
	var span := b - a
	var length_squared := span.length_squared()
	if length_squared < 0.000000001:
		return a.distance_to(point)
	var t := clampf((point - a).dot(span) / length_squared, 0.0, 1.0)
	return (a + span * t).distance_to(point)


## A target that stays exactly where it is put: its own movement is switched off
## so gravity cannot drop it mid-test, while its collider stays in the physics
## space to be hit.
func _spawn_target(at: Vector3) -> Node3D:
	var npc: Node3D = WITCH_SCENE.instantiate()
	add_child(npc)
	npc.global_position = at
	npc.set_physics_process(false)
	npc.set_process(false)
	return npc


func _recurve_shot() -> Dictionary:
	var bow := load("res://resources/archery/bow_recurve.tres") as Bow
	var arrow := load("res://resources/archery/arrow_standard.tres") as ArrowSpec
	return AP.solve_shot(bow, arrow, 10.0, 10.0, 30.0)


# ---------------------------------------------------------------------------
# CHECKS
# ---------------------------------------------------------------------------

## The shared flight model, against an integrator written here from the same
## physics but not the same code. If these disagree the model is wrong, and both
## the solver and the arrow are wrong together in a way nothing else would catch.
func _check_step_velocity_matches_an_independent_integrator() -> void:
	var decay := 0.00414
	var dt := 1.0 / 240.0
	var shared := Vector3(30.0, 12.0, -4.0)
	var mine := shared
	var worst := 0.0
	for _step in 500:
		shared = BS.step_velocity(shared, GRAVITY, decay, dt)
		# Independently: drag scales the speed after gravity has acted, over the
		# distance covered at the incoming speed.
		var travelled := mine.length() * dt
		var after_gravity := Vector3(mine.x, mine.y - GRAVITY * dt, mine.z)
		var speed := after_gravity.length()
		mine = after_gravity.normalized() * (speed * exp(-decay * travelled)) \
			if speed > 0.0 else after_gravity
		worst = maxf(worst, shared.distance_to(mine))
	if worst > 0.0001:
		_fail("the shared flight step drifted %.6f from an independent one" % worst)
	else:
		print("  model: step_velocity matches an independent integrator over 500 steps")


## The whole point — see the class note.
func _check_arrow_lands_where_the_solver_aimed() -> void:
	var shot := _recurve_shot()
	var speed: float = shot["muzzle_velocity_ms"]
	var decay: float = shot["decay"]
	var worst := 0.0
	for distance in [15.0, 30.0, 50.0]:
		var target := Vector3(0.0, ORIGIN.y + 0.4, distance)
		var aim := BS.solve_arc(ORIGIN, target, speed, GRAVITY, decay)
		if not aim["reachable"]:
			_fail("the solver called a %.0f m shot unreachable" % distance)
			continue
		var arrow := _spawn_arrow()
		arrow.launch(ORIGIN, aim["direction"], speed, shot["muzzle_energy_j"], decay)
		var flight := await _fly(arrow, target)
		worst = maxf(worst, flight["closest"])
		if flight["closest"] > TOLERANCE:
			_fail("at %.0f m the arrow passed %.3f m from where the solver aimed"
				% [distance, flight["closest"]])
	if worst <= TOLERANCE:
		print("  aim: the real arrow arrives within %.3f m of the solver's answer at 15-50 m"
			% worst)


func _check_energy_and_damage_fall_with_distance() -> void:
	var shot := _recurve_shot()
	var arrow := _spawn_arrow()
	arrow.launch(ORIGIN, Vector3(0.0, 0.15, 1.0).normalized(),
		shot["muzzle_velocity_ms"], shot["muzzle_energy_j"], shot["decay"])

	if not is_equal_approx(arrow.current_energy(), shot["muzzle_energy_j"]):
		_fail("a fresh arrow reported %.3f J, expected the muzzle's %.3f J"
			% [arrow.current_energy(), shot["muzzle_energy_j"]])

	# Sample partway and compare against the closed form for the distance flown.
	var previous_energy: float = arrow.current_energy()
	var falling := true
	for _frame in 60:
		if not is_instance_valid(arrow):
			break
		await get_tree().physics_frame
		if not is_instance_valid(arrow):
			break
		var energy: float = arrow.current_energy()
		var expected: float = AP.energy_at_distance(
			shot["muzzle_energy_j"], shot["decay"], arrow.distance_flown())
		if absf(energy - expected) > 0.001:
			_fail("energy %.4f J disagreed with the closed form's %.4f J at %.2f m"
				% [energy, expected, arrow.distance_flown()])
			break
		if energy > previous_energy + 0.0001:
			falling = false
		previous_energy = energy
	if not falling:
		_fail("arrow energy rose during flight")
	if is_instance_valid(arrow):
		var damage: float = arrow.current_damage()
		var muzzle_damage: float = AP.damage_from_energy(shot["muzzle_energy_j"])
		if damage >= muzzle_damage:
			_fail("damage did not fall with distance: %.3f against %.3f at the muzzle"
				% [damage, muzzle_damage])
		else:
			print("  energy: matches the closed form throughout; damage %.1f at the muzzle, %.1f after %.1f m"
				% [muzzle_damage, damage, arrow.distance_flown()])
		arrow.queue_free()


## Range must come from the shot rather than from a clock, which is what makes a
## war bow reach further without anyone authoring a range for it.
func _check_it_ends_on_energy_not_time() -> void:
	var shot := _recurve_shot()
	var arrow := _spawn_arrow()
	# Fired flat and high so nothing but drag ends it.
	arrow.launch(ORIGIN, Vector3(0.0, 0.6, 1.0).normalized(),
		shot["muzzle_velocity_ms"], shot["muzzle_energy_j"], shot["decay"])
	var expected: float = shot["max_flight_distance_m"]
	var flight := await _fly(arrow, Vector3(0.0, -10000.0, 0.0))
	if not flight["freed"]:
		_fail("the arrow never ended: %.1f m flown over %d frames"
			% [flight["flown"], flight["frames"]])
		return
	if absf(flight["flown"] - expected) > 1.0:
		_fail("the arrow stopped after %.1f m; the energy floor predicts %.1f m"
			% [flight["flown"], expected])
	elif flight["frames"] >= FRAME_LIMIT:
		_fail("the arrow hit the frame limit rather than the energy floor")
	else:
		print("  endurance: spent after %.1f m against a predicted %.1f m (not a time cap)"
			% [flight["flown"], expected])


func _check_a_stronger_bow_shoots_further() -> void:
	var distances: Array[float] = []
	for bow_path in ["res://resources/archery/bow_selfbow.tres",
			"res://resources/archery/bow_warbow.tres"]:
		var bow := load(bow_path) as Bow
		var spec := load("res://resources/archery/arrow_standard.tres") as ArrowSpec
		var shot: Dictionary = AP.solve_shot(bow, spec, 30.0, 30.0, 30.0)
		var arrow := _spawn_arrow()
		arrow.launch(ORIGIN, Vector3(0.0, 0.6, 1.0).normalized(),
			shot["muzzle_velocity_ms"], shot["muzzle_energy_j"], shot["decay"])
		var flight := await _fly(arrow, Vector3(0.0, -10000.0, 0.0))
		distances.append(flight["flown"])
	if distances[1] <= distances[0]:
		_fail("the war bow's arrow did not outrange the selfbow's: %.1f m vs %.1f m"
			% [distances[1], distances[0]])
	else:
		print("  reach: selfbow %.0f m, war bow %.0f m, from energy alone"
			% [distances[0], distances[1]])


## A lobbed arrow must visibly turn over rather than flying tip-first the whole
## way, which is the difference between an arrow and a thrown stick.
func _check_it_noses_over() -> void:
	var shot := _recurve_shot()
	var arrow := _spawn_arrow()
	arrow.launch(ORIGIN, Vector3(0.0, 1.0, 1.0).normalized(),
		shot["muzzle_velocity_ms"], shot["muzzle_energy_j"], shot["decay"])
	# -Z is forward, as look_at leaves it.
	var launch_pitch: float = -arrow.global_transform.basis.z.y
	if launch_pitch <= 0.0:
		_fail("the arrow did not leave pointing upward (%.3f)" % launch_pitch)
	var descending := 0.0
	for _frame in 400:
		if not is_instance_valid(arrow):
			break
		await get_tree().physics_frame
		if not is_instance_valid(arrow):
			break
		descending = -arrow.global_transform.basis.z.y
		if descending < -0.3:
			break
	if descending >= -0.3:
		_fail("the arrow never turned over: forward pitch reached only %.3f" % descending)
	else:
		print("  attitude: leaves at pitch %+.2f and noses over to %+.2f on the way down"
			% [launch_pitch, descending])
	if is_instance_valid(arrow):
		arrow.queue_free()


func _check_it_damages_what_it_hits() -> void:
	var shot := _recurve_shot()
	var target := _spawn_target(Vector3(0.0, 0.0, 18.0))
	await get_tree().physics_frame
	var health: Health = target.get_health()
	if health == null:
		_fail("the test target has no Health to lose")
		target.queue_free()
		return
	var before := health.current

	var aim_point := target.global_position + Vector3.UP * 1.0
	var aim := BS.solve_arc(ORIGIN, aim_point, shot["muzzle_velocity_ms"],
		GRAVITY, shot["decay"])
	var arrow := _spawn_arrow()
	var struck := [false, 0.0]
	arrow.struck.connect(func(_at: Vector3, _body: Node3D, damage: float) -> void:
		struck[0] = true
		struck[1] = damage)
	arrow.launch(ORIGIN, aim["direction"], shot["muzzle_velocity_ms"],
		shot["muzzle_energy_j"], shot["decay"])
	await _fly(arrow, aim_point)

	if not struck[0]:
		_fail("an arrow aimed at a target 18 m away never reported a hit")
	elif health.current >= before:
		_fail("the target took no damage (%.1f before, %.1f after)" % [before, health.current])
	else:
		var expected: float = struck[1]
		var lost: float = before - health.current
		if absf(lost - expected) > 0.01:
			_fail("the hit reported %.2f damage but %.2f was lost" % [expected, lost])
		else:
			print("  impact: hit at 18 m for %.1f damage, health %.1f -> %.1f"
				% [expected, before, health.current])
	target.queue_free()


## The reason hits are a raycast rather than an area overlap. At this speed a
## single substep is longer than the target is wide, so overlap testing would step
## straight over it.
func _check_it_cannot_tunnel_through_a_target() -> void:
	var speed := 500.0
	var target := _spawn_target(Vector3(0.0, 0.0, 40.0))
	await get_tree().physics_frame
	var aim_point := target.global_position + Vector3.UP * 1.0
	var arrow := _spawn_arrow()
	var hit := [false]
	arrow.struck.connect(func(_at: Vector3, _b: Node3D, _d: float) -> void: hit[0] = true)
	arrow.launch(ORIGIN, (aim_point - ORIGIN).normalized(), speed, 200.0, 0.0)
	var step := speed / 240.0
	await _fly(arrow, aim_point)
	if not hit[0]:
		_fail("an arrow at %.0f m/s (%.2f m per substep) passed through the target"
			% [speed, step])
	else:
		print("  tunnelling: %.0f m/s, %.2f m per substep, still hits a %.1f m wide body"
			% [speed, step, 0.9])
	target.queue_free()
