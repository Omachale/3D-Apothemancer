extends Node

## Checks the launch-angle solver in ballistic_solver.gd.
##
## THE ASSERTION IS ALWAYS "DOES THE ARROW ARRIVE", never "does the formula look
## right" — the same standard verify_aim.gd holds lead_aim to. Every check below
## takes the solver's answer, flies it through an integrator written HERE, and
## measures how far it passes from the target.
##
## THE INTEGRATOR IS DELIBERATELY NOT SHARED WITH THE SOLVER. If both used one
## flight model, a mistake in that model would cancel itself out — the solver
## would aim wrong, the test would fly it wrong the same way, and the arrow would
## "land" in a simulation that does not match the game. Stepping the motion
## independently here means the two can only agree if the closed-form solution is
## genuinely correct.
##
## WHY THIS MATTERS FOR RETUNING. A drag-free parabola is only as good as drag is
## mild, and the likeliest reason to shorten arrow range later is to RAISE drag.
## Because these checks fly the real dragged flight rather than trusting the
## equation, they encode the requirement instead of today's numbers: crank drag
## far enough that the solver can no longer land shots and this suite fails
## immediately, rather than the miss being discovered in play.
##
##   Godot --headless res://scenes/dev/VerifyBallisticSolver.tscn
## Exits non-zero if any check fails.

const BS := preload("res://scripts/combat/ballistic_solver.gd")
const AP := preload("res://scripts/combat/archery_physics.gd")

const GRAVITY := 9.81
## Metres of miss allowed. Comfortably inside a character's width, so anything
## passing here is a real hit rather than a near one.
const TOLERANCE := 0.35
## Integration step. Fine enough that the discretisation contributes far less
## error than TOLERANCE allows.
const DT := 1.0 / 600.0

## Roughly a recurve loosing a standard arrow — see verify_archery_physics.gd.
const ARROW_SPEED := 45.6
const ARROW_DECAY := 0.00414

## Chest height, so shots start where a bow would be held.
const ORIGIN := Vector3(0.0, 1.5, 0.0)

var _failures := 0


func _ready() -> void:
	_check_level_shots_land()
	_check_uphill_and_downhill_land()
	_check_the_flat_arc_is_chosen()
	_check_faster_shots_fly_flatter()
	_check_out_of_range_falls_short_at_maximum_range()
	_check_moving_targets_are_intercepted()
	_check_drag_correction_earns_its_place()
	_check_real_archery_numbers_land()
	_check_no_gravity_is_a_straight_line()
	_check_degenerate_inputs()
	if _failures == 0:
		print("ALL BALLISTIC SOLVER CHECKS PASSED")
	else:
		print("VERIFY BALLISTIC SOLVER: FAIL (%d)" % _failures)
	get_tree().quit(1 if _failures > 0 else 0)


func _fail(message: String) -> void:
	print("  FAIL: %s" % message)
	_failures += 1


# ---------------------------------------------------------------------------
# INDEPENDENT FLIGHT MODEL
# ---------------------------------------------------------------------------

## Flies a shot and reports how close it passed to the target.
##
## Speed decays over DISTANCE TRAVELLED, matching archery_physics.gd's closed
## form, while gravity bends the direction — so drag is applied to the speed
## magnitude per step and gravity to the vertical component.
func _miss_distance(direction: Vector3, speed: float, target: Vector3,
		decay := 0.0, target_velocity := Vector3.ZERO, gravity := GRAVITY) -> float:
	var position := ORIGIN
	var velocity := direction.normalized() * speed
	var elapsed := 0.0
	var closest := INF
	while elapsed < 30.0:
		var target_now := target + target_velocity * elapsed
		closest = minf(closest, position.distance_to(target_now))
		var travelled := velocity.length() * DT
		position += velocity * DT
		velocity.y -= gravity * DT
		if decay > 0.0:
			var slowed := velocity.length() * exp(-decay * travelled)
			velocity = velocity.normalized() * slowed
		elapsed += DT
		# Once it is well below the target and still falling there is nothing
		# left to measure.
		if position.y < target_now.y - 50.0 and velocity.y < 0.0:
			break
	return closest


## Furthest horizontal distance any launch angle reaches, by brute force — the
## reference the solver's out-of-range fallback is judged against.
func _best_range_by_sweep(speed: float, decay: float, target_y: float) -> Dictionary:
	var best_distance := -1.0
	var best_angle := 0.0
	for tenths in range(-400, 891):
		var angle := deg_to_rad(float(tenths) * 0.1)
		var direction := Vector3(0.0, sin(angle), cos(angle))
		var distance := _horizontal_reach(direction, speed, decay, target_y)
		if distance > best_distance:
			best_distance = distance
			best_angle = rad_to_deg(angle)
	return {"distance": best_distance, "angle_deg": best_angle}


## How far downrange a shot gets before falling back to [param target_y].
func _horizontal_reach(direction: Vector3, speed: float, decay: float,
		target_y: float) -> float:
	var position := ORIGIN
	var velocity := direction.normalized() * speed
	var elapsed := 0.0
	while elapsed < 30.0:
		var travelled := velocity.length() * DT
		var previous := position
		position += velocity * DT
		velocity.y -= GRAVITY * DT
		if decay > 0.0:
			velocity = velocity.normalized() * (velocity.length() * exp(-decay * travelled))
		if position.y <= target_y and velocity.y < 0.0:
			return Vector2(previous.x, previous.z).length()
		elapsed += DT
	return Vector2(position.x, position.z).length()


# ---------------------------------------------------------------------------
# CHECKS
# ---------------------------------------------------------------------------

func _check_level_shots_land() -> void:
	var worst := 0.0
	for distance in [10.0, 20.0, 40.0, 60.0]:
		var target := Vector3(0.0, ORIGIN.y, distance)
		var shot := BS.solve_arc(ORIGIN, target, ARROW_SPEED, GRAVITY)
		if not shot["reachable"]:
			_fail("a level %.0f m shot was reported unreachable" % distance)
			continue
		var miss := _miss_distance(shot["direction"], ARROW_SPEED, target)
		worst = maxf(worst, miss)
		if miss > TOLERANCE:
			_fail("level %.0f m shot missed by %.3f m (angle %.2f deg)"
				% [distance, miss, shot["angle_deg"]])
	if worst <= TOLERANCE:
		print("  level: 10-60 m all land, worst miss %.3f m" % worst)


func _check_uphill_and_downhill_land() -> void:
	var worst := 0.0
	for height in [-20.0, -8.0, 8.0, 20.0]:
		var target := Vector3(0.0, ORIGIN.y + height, 35.0)
		var shot := BS.solve_arc(ORIGIN, target, ARROW_SPEED, GRAVITY)
		if not shot["reachable"]:
			_fail("a target %.0f m %s at 35 m was unreachable"
				% [absf(height), "up" if height > 0.0 else "down"])
			continue
		var miss := _miss_distance(shot["direction"], ARROW_SPEED, target)
		worst = maxf(worst, miss)
		if miss > TOLERANCE:
			_fail("target %+.0f m at 35 m missed by %.3f m (angle %.2f deg)"
				% [height, miss, shot["angle_deg"]])
	if worst <= TOLERANCE:
		print("  slopes: +/-20 m of height at 35 m all land, worst miss %.3f m" % worst)


## The flat root, not the lob. A level shot well inside range must come out under
## 45 degrees; the lobbed solution to the same shot is above it.
func _check_the_flat_arc_is_chosen() -> void:
	var target := Vector3(0.0, ORIGIN.y, 30.0)
	var shot := BS.solve_arc(ORIGIN, target, ARROW_SPEED, GRAVITY)
	if shot["angle_deg"] >= 45.0:
		_fail("a 30 m level shot came out at %.2f deg, which is the lob not the flat arc"
			% shot["angle_deg"])
	elif shot["angle_deg"] <= 0.0:
		_fail("a 30 m level shot came out at %.2f deg, which cannot reach"
			% shot["angle_deg"])
	else:
		print("  arc choice: 30 m level shot leaves at %.2f deg (flat, under 45)"
			% shot["angle_deg"])


func _check_faster_shots_fly_flatter() -> void:
	var target := Vector3(0.0, ORIGIN.y, 40.0)
	var slow := BS.solve_arc(ORIGIN, target, 30.0, GRAVITY)
	var fast := BS.solve_arc(ORIGIN, target, 70.0, GRAVITY)
	if fast["angle_deg"] >= slow["angle_deg"]:
		_fail("a faster shot did not fly flatter: %.2f deg at 70 m/s vs %.2f at 30"
			% [fast["angle_deg"], slow["angle_deg"]])
	elif fast["flight_time"] >= slow["flight_time"]:
		_fail("a faster shot did not arrive sooner")
	else:
		print("  speed: 40 m needs %.2f deg at 30 m/s but only %.2f deg at 70 m/s"
			% [slow["angle_deg"], fast["angle_deg"]])


## Out of range must fall short honestly AND fire the longest shot available, so
## the arrow at least travels as far as physics allows toward the target.
func _check_out_of_range_falls_short_at_maximum_range() -> void:
	var reference := _best_range_by_sweep(ARROW_SPEED, 0.0, ORIGIN.y)
	# Well past anything reachable at this speed.
	var target := Vector3(0.0, ORIGIN.y, reference["distance"] * 1.6)
	var shot := BS.solve_arc(ORIGIN, target, ARROW_SPEED, GRAVITY)
	if shot["reachable"]:
		_fail("a target at %.0f m was claimed reachable when the maximum is %.0f m"
			% [target.z, reference["distance"]])
	# The fallback must be the maximum-range angle, judged against brute force.
	if absf(shot["angle_deg"] - reference["angle_deg"]) > 1.5:
		_fail("out-of-range fallback fired at %.2f deg; the furthest angle is %.2f deg"
			% [shot["angle_deg"], reference["angle_deg"]])
	else:
		print("  out of range: %.0f m target flagged unreachable, fired at %.1f deg against a %.1f deg optimum (reach %.0f m)"
			% [target.z, shot["angle_deg"], reference["angle_deg"], reference["distance"]])


func _check_moving_targets_are_intercepted() -> void:
	var worst := 0.0
	var cases := [
		{"pos": Vector3(0.0, ORIGIN.y, 35.0), "vel": Vector3(6.0, 0.0, 0.0), "name": "crossing"},
		{"pos": Vector3(0.0, ORIGIN.y, 35.0), "vel": Vector3(0.0, 0.0, 7.0), "name": "fleeing"},
		{"pos": Vector3(0.0, ORIGIN.y, 40.0), "vel": Vector3(0.0, 0.0, -7.0), "name": "charging"},
		{"pos": Vector3(0.0, ORIGIN.y + 6.0, 30.0), "vel": Vector3(5.0, 0.0, 3.0), "name": "uphill diagonal"},
	]
	for case in cases:
		var shot := BS.solve_intercept(
			ORIGIN, case["pos"], case["vel"], ARROW_SPEED, GRAVITY)
		if not shot["reachable"]:
			_fail("the %s target was unreachable" % case["name"])
			continue
		var miss := _miss_distance(
			shot["direction"], ARROW_SPEED, case["pos"], 0.0, case["vel"])
		worst = maxf(worst, miss)
		if miss > TOLERANCE:
			_fail("%s target missed by %.3f m" % [case["name"], miss])
		# A lead must actually have happened for anything moving across the shot.
		if case["name"] == "crossing" and absf(shot["direction"].x) < 0.01:
			_fail("no lead was applied to a target crossing at 6 m/s")
	if worst <= TOLERANCE:
		print("  moving: crossing, fleeing, charging and diagonal all intercepted, worst %.3f m"
			% worst)


## The check that keeps the solver honest if drag is retuned. Solving WITHOUT
## drag and flying WITH it must miss; solving with it must not. If the first ever
## stops missing, drag has become negligible and the correction is free anyway —
## if the second ever starts missing, the correction has stopped being adequate
## and needs more than a closed form.
func _check_drag_correction_earns_its_place() -> void:
	var target := Vector3(0.0, ORIGIN.y, 55.0)
	var ignorant := BS.solve_arc(ORIGIN, target, ARROW_SPEED, GRAVITY, 0.0)
	var corrected := BS.solve_arc(ORIGIN, target, ARROW_SPEED, GRAVITY, ARROW_DECAY)
	var ignorant_miss := _miss_distance(ignorant["direction"], ARROW_SPEED, target, ARROW_DECAY)
	var corrected_miss := _miss_distance(corrected["direction"], ARROW_SPEED, target, ARROW_DECAY)

	if corrected_miss > TOLERANCE:
		_fail("the drag-corrected 55 m shot still missed by %.3f m" % corrected_miss)
	if corrected_miss >= ignorant_miss:
		_fail("correcting for drag did not improve the shot: %.3f m against %.3f m"
			% [corrected_miss, ignorant_miss])
	else:
		print("  drag: at 55 m ignoring it misses by %.2f m, correcting for it by %.3f m"
			% [ignorant_miss, corrected_miss])

	# And with drag corrected for, the whole practical range must land.
	var worst := 0.0
	for distance in [15.0, 30.0, 45.0, 70.0]:
		var far := Vector3(0.0, ORIGIN.y, distance)
		var shot := BS.solve_arc(ORIGIN, far, ARROW_SPEED, GRAVITY, ARROW_DECAY)
		if not shot["reachable"]:
			_fail("a %.0f m shot was unreachable with drag" % distance)
			continue
		worst = maxf(worst, _miss_distance(shot["direction"], ARROW_SPEED, far, ARROW_DECAY))
	if worst <= TOLERANCE:
		print("  drag: 15-70 m all land with drag modelled, worst miss %.3f m" % worst)
	else:
		_fail("with drag modelled the worst miss over 15-70 m was %.3f m" % worst)


## Ties the two modules together: the speed and decay a real bow produces, fired
## at a real fighting distance, must land.
func _check_real_archery_numbers_land() -> void:
	var bow := load("res://resources/archery/bow_recurve.tres") as Bow
	var arrow := load("res://resources/archery/arrow_standard.tres") as ArrowSpec
	if bow == null or arrow == null:
		_fail("could not load the recurve and standard arrow")
		return
	var solved: Dictionary = AP.solve_shot(bow, arrow, 10.0, 10.0, 30.0)
	var speed: float = solved["muzzle_velocity_ms"]
	var decay: float = solved["decay"]
	var worst := 0.0
	for distance in [12.0, 25.0, 45.0]:
		var target := Vector3(0.0, ORIGIN.y + 0.6, distance)
		var shot := BS.solve_arc(ORIGIN, target, speed, GRAVITY, decay)
		if not shot["reachable"]:
			_fail("a real recurve shot at %.0f m was unreachable" % distance)
			continue
		worst = maxf(worst, _miss_distance(shot["direction"], speed, target, decay))
	if worst <= TOLERANCE:
		print("  end to end: real recurve (%.1f m/s) lands 12-45 m, worst miss %.3f m"
			% [speed, worst])
	else:
		_fail("real recurve numbers gave a worst miss of %.3f m" % worst)


func _check_no_gravity_is_a_straight_line() -> void:
	var target := Vector3(10.0, ORIGIN.y + 5.0, 30.0)
	var shot := BS.solve_arc(ORIGIN, target, ARROW_SPEED, 0.0)
	var expected := (target - ORIGIN).normalized()
	if shot["direction"].distance_to(expected) > 0.001:
		_fail("with no gravity the shot was not a straight line: %s against %s"
			% [shot["direction"], expected])
	elif not shot["reachable"]:
		_fail("a straight-line shot was reported unreachable")
	else:
		print("  no gravity: fires straight at the target")


func _check_degenerate_inputs() -> void:
	# Straight up, within reach and beyond it.
	var reachable_up := BS.solve_arc(ORIGIN, ORIGIN + Vector3.UP * 10.0, 30.0, GRAVITY)
	if not reachable_up["reachable"]:
		_fail("10 m straight up at 30 m/s was reported unreachable")
	if reachable_up["direction"].distance_to(Vector3.UP) > 0.001:
		_fail("a shot straight up did not point up: %s" % reachable_up["direction"])
	var too_high := BS.solve_arc(ORIGIN, ORIGIN + Vector3.UP * 500.0, 30.0, GRAVITY)
	if too_high["reachable"]:
		_fail("500 m straight up at 30 m/s was claimed reachable")

	# Straight down is always reachable.
	var down := BS.solve_arc(ORIGIN, ORIGIN + Vector3.DOWN * 20.0, 30.0, GRAVITY)
	if not down["reachable"] or down["direction"].distance_to(Vector3.DOWN) > 0.001:
		_fail("a shot straight down was not handled: %s" % down)

	# Zero and negative speed must not divide by zero or return NAN.
	for speed in [0.0, -5.0]:
		var dead := BS.solve_arc(ORIGIN, Vector3(0.0, 1.5, 20.0), speed, GRAVITY)
		if dead["reachable"]:
			_fail("a shot at %.1f m/s was claimed reachable" % speed)
		if not _is_finite_vector(dead["direction"]):
			_fail("a shot at %.1f m/s produced a non-finite direction" % speed)

	# The shooter's own position, where the flat direction is undefined.
	var here := BS.solve_arc(ORIGIN, ORIGIN, ARROW_SPEED, GRAVITY)
	if not _is_finite_vector(here["direction"]):
		_fail("targeting the origin produced a non-finite direction")

	# A stationary target must take the plain solve_arc path unchanged.
	var target := Vector3(0.0, ORIGIN.y, 30.0)
	var still := BS.solve_intercept(ORIGIN, target, Vector3.ZERO, ARROW_SPEED, GRAVITY)
	var direct := BS.solve_arc(ORIGIN, target, ARROW_SPEED, GRAVITY)
	if still["direction"].distance_to(direct["direction"]) > 0.0001:
		_fail("a stationary target was led anyway")
	else:
		print("  degenerate: vertical shots, dead speeds and zero-distance all fail safe")


func _is_finite_vector(v: Vector3) -> bool:
	return is_finite(v.x) and is_finite(v.y) and is_finite(v.z)
