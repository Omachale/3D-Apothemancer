class_name BallisticSolver
extends RefCounted

## Launch angles for a projectile that falls: given where the shooter is, where
## the target is, and how fast the thing leaves, work out which way to point.
##
## THE 3D COUNTERPART TO player_attacks.lead_aim, and deliberately shaped the
## same way — static, pure, no node and no scene, so the geometry can be checked
## by firing the answer and seeing whether it lands (see
## verify_ballistic_solver.gd). lead_aim solves intercept for a projectile that
## travels dead straight at a constant speed; this solves it for one that arcs
## under gravity and slows against the air, which is a different equation with
## genuinely different failure modes.
##
## NOT ARCHERY-SPECIFIC. It takes a speed and a gravity, not a bow — anything
## lobbed can use it. Arrow speed comes from archery_physics.gd; nothing here
## knows that.
##
## THE MATH. With horizontal distance d, height difference h and launch speed v,
## eliminating time from the two components of projectile motion gives a
## quadratic in tan(theta):
##
##     (g d^2 / 2v^2) u^2  -  d u  +  (h + g d^2 / 2v^2)  =  0,   u = tan(theta)
##
## Two roots, so up to TWO valid shots: a flat one that gets there fast and a
## lobbed one that arrives steeply. This returns the FLAT arc — it reads as aimed
## shooting rather than mortar fire, and it gives the target less time to move.
## The lob is what you want for shooting over an obstacle, but choosing it
## intelligently needs line-of-sight tests that do not exist yet, so offering it
## as a coin flip would just produce occasional inexplicable mortar shots.
##
## THAT QUADRATIC IS EXACT ONLY WITHOUT DRAG, and drag is the thing most likely
## to be retuned later — the obvious way to shorten arrow range is to raise it,
## which makes a naive parabola progressively worse. So the closed form is used
## as a STARTING GUESS and then refined against a predicted flight that includes
## drag (see [method _refine_pitch]). Heavier drag simply means the refinement
## moves the angle further; there is nothing to redesign. An earlier version
## corrected by solving the parabola at a drag-adjusted average speed instead,
## which is a first-order fix only — it gets the flight TIME right but ignores
## drag on the vertical component, and measurably missed by 0.7 m at 55 m and
## 1.5 m further out. It survives here only as the initial guess, which is what
## it is genuinely good for.
##
## WHEN THERE IS NO SOLUTION the honest answer is to fall short, not to invent
## one — the same principle lead_aim already follows for a target running faster
## than the projectile. The shot fired is then the maximum-range one in that
## direction, flagged unreachable, so the arrow travels as far as physics allows
## and drops short.
##
## THE PREDICTION MUST MATCH THE ARROW. [method predict] is the model this aims
## against; whatever actually flies has to integrate the same way or aiming is
## pointless. verify_ballistic_solver.gd cross-checks it with an integrator
## written independently, which is what stops a mistake in the model hiding
## behind itself.

## Refinement passes against the predicted flight. Six is far more than the
## secant iteration needs from a parabolic starting guess (it converges in two or
## three), and the extra passes cost only a few predictions on a shot that
## happens once per arrow.
const REFINE_PASSES := 6
## Vertical error at the target, in metres, treated as converged.
const REFINE_PRECISION_M := 0.005
## Refinement passes when leading a moving target — see [method solve_intercept].
const INTERCEPT_PASSES := 3
## Integration step for [method predict]. Fine enough that discretisation error
## sits well under REFINE_PRECISION_M over a normal shot.
const PREDICT_DT := 1.0 / 240.0
## Longest flight to predict before giving up, in seconds.
const PREDICT_MAX_TIME := 20.0
## Below this horizontal separation a shot is treated as straight up or down,
## because the quadratic's `d` appears in a denominator and the flat direction is
## undefined.
const MIN_HORIZONTAL_M := 0.001
## Below this, gravity is treated as absent and the shot is a straight line.
const MIN_GRAVITY := 0.0001
## Steepest and shallowest launch the refinement may wander to, in degrees.
const PITCH_LIMIT_DEG := 89.0


## The average speed sustained over [param distance] by a projectile leaving at
## [param speed] and decaying at [param decay] per metre.
##
## Not the arithmetic mean of start and end speed — the mean that reproduces the
## right FLIGHT TIME, which is what the launch angle depends on. Speed falls as
## v0*exp(-k*x), so the time to cover d is the integral of dx/v(x), giving
## (exp(k*d) - 1) / (k*v0), and dividing distance by that yields the expression
## below. Tends to [param speed] as decay tends to zero, which is why the
## no-drag path needs no special case beyond guarding the division.
static func effective_speed(speed: float, decay: float, distance: float) -> float:
	if decay <= 0.0 or distance <= 0.0 or speed <= 0.0:
		return speed
	var growth := exp(decay * distance)
	if growth - 1.0 < 0.0000001:
		return speed
	return distance * decay * speed / (growth - 1.0)


## THE FLIGHT MODEL: one integration step of gravity and air drag.
##
## THE SINGLE SOURCE OF TRUTH FOR HOW A LOBBED PROJECTILE MOVES, used both by
## [method predict] when aiming and by whatever actually flies. Sharing it is not
## tidiness — if the thing in flight integrated differently from the thing that
## chose the angle, the aim would be wrong by however much the two models
## disagreed, and no amount of solver accuracy would fix it. arrow.gd calls this;
## anything else lobbed should too.
##
## Drag decays speed over DISTANCE TRAVELLED, not over time, matching
## archery_physics.gd's closed form — which is what keeps damage-at-range honest
## regardless of frame rate. The distance for this step is measured from the
## INCOMING velocity, so callers must apply their position update with that same
## velocity before calling this.
##
## Scaling the vector by exp() is exactly equivalent to renormalising it and
## rescaling its length, since drag changes only the magnitude.
static func step_velocity(velocity: Vector3, gravity: float, decay: float,
		dt: float) -> Vector3:
	var travelled := velocity.length() * dt
	var next := velocity
	next.y -= gravity * dt
	if decay > 0.0:
		next *= exp(-decay * travelled)
	return next


## Flies a shot in the vertical plane and reports where it is after covering
## [param range_m] of horizontal ground.
##
## Planar on purpose: nothing about the problem varies across the third axis. X
## carries horizontal distance and Y height; Z stays zero, kept as a Vector3 only
## so [method step_velocity] can be shared with real 3D flight verbatim rather
## than transcribed into a second version.
##
## Returns keys: reached (whether it got that far at all), height (metres above
## launch when it did), time (seconds taken, INF if it never arrived), shortfall
## (metres of horizontal ground it never covered, 0 when it arrived).
static func predict(range_m: float, speed: float, launch_angle: float,
		gravity: float, decay := 0.0) -> Dictionary:
	var position := Vector3.ZERO
	var velocity := Vector3(cos(launch_angle), sin(launch_angle), 0.0) * speed
	var elapsed := 0.0
	while elapsed < PREDICT_MAX_TIME:
		var previous := position
		position += velocity * PREDICT_DT
		velocity = step_velocity(velocity, gravity, decay, PREDICT_DT)
		elapsed += PREDICT_DT
		if position.x >= range_m:
			# Interpolate across the step that crossed the line, so the answer is
			# not quantised to whole steps.
			var span := position.x - previous.x
			var fraction := (range_m - previous.x) / span if span > 0.0 else 1.0
			return {
				"reached": true,
				"height": lerpf(previous.y, position.y, fraction),
				"time": elapsed - PREDICT_DT * (1.0 - fraction),
				"shortfall": 0.0,
			}
		# Going backwards or standing still means it can never get there.
		if velocity.x <= 0.0:
			break
	return {
		"reached": false, "height": position.y, "time": INF,
		"shortfall": maxf(range_m - position.x, 0.0),
	}


## Which way to point to hit [param target] from [param origin].
##
## Returns keys:
##   direction    unit Vector3 to fire along
##   flight_time  seconds until it arrives (INF if it never does)
##   reachable    false when the target is out of range and this falls short
##   angle_deg    launch pitch, positive upward — for animation and debugging
##   speed_used   the speed the answer was solved at
static func solve_arc(origin: Vector3, target: Vector3, speed: float,
		gravity: float, drag_decay := 0.0) -> Dictionary:
	var to_target := target - origin
	if speed <= 0.0:
		return _failed(to_target)

	# No gravity: a straight line, and none of the quadratic applies.
	if gravity < MIN_GRAVITY:
		var distance := to_target.length()
		var straight := effective_speed(speed, drag_decay, distance)
		return {
			"direction": to_target.normalized() if distance > 0.0 else Vector3.FORWARD,
			"flight_time": distance / maxf(straight, 0.0001),
			"reachable": true,
			"angle_deg": rad_to_deg(asin(clampf(to_target.normalized().y, -1.0, 1.0)))
				if distance > 0.0 else 0.0,
			"speed_used": straight,
		}

	var flat := Vector3(to_target.x, 0.0, to_target.z)
	var d := flat.length()
	var h := to_target.y
	if d < MIN_HORIZONTAL_M:
		return _vertical_shot(h, speed, gravity, drag_decay)
	var flat_direction := flat / d

	# Reachability is decided by FLYING the longest available shot, not by the
	# drag-free discriminant — with drag the closed form is optimistic, and a
	# target it calls reachable can genuinely be out of reach.
	var ceiling := _max_range_angle(h, speed, gravity)
	var probe := predict(d, speed, ceiling, gravity, drag_decay)
	if not probe["reached"] or probe["height"] < h:
		return {
			"direction": _direction_at(flat_direction, ceiling),
			"flight_time": probe["time"],
			"reachable": false,
			"angle_deg": rad_to_deg(ceiling),
			"speed_used": speed,
		}

	# Initial guess from the closed form, at a drag-adjusted average speed, then
	# refined against the real flight.
	var guess_speed := effective_speed(speed, drag_decay, to_target.length())
	var angle := _flat_arc_angle(d, h, guess_speed, gravity)
	if not is_finite(angle):
		angle = ceiling
	angle = _refine_pitch(d, h, speed, gravity, drag_decay, angle, ceiling)

	var final := predict(d, speed, angle, gravity, drag_decay)
	var flight_time: float = final["time"]
	if not is_finite(flight_time):
		var horizontal := guess_speed * cos(angle)
		flight_time = d / horizontal if horizontal > 0.0001 else INF
	return {
		"direction": _direction_at(flat_direction, angle),
		"flight_time": flight_time,
		"reachable": true,
		"angle_deg": rad_to_deg(angle),
		"speed_used": speed,
	}


## Which way to point to hit something that is moving.
##
## CIRCULAR BY NATURE, hence the loop: the arc determines the flight time, the
## flight time determines where the target will be, and where the target will be
## determines the arc. Each pass aims at where the previous pass said the target
## would be by the time the shot arrived, which converges quickly for anything
## moving slower than the projectile — the same regime lead_aim is useful in.
static func solve_intercept(origin: Vector3, target: Vector3,
		target_velocity: Vector3, speed: float, gravity: float,
		drag_decay := 0.0) -> Dictionary:
	var solution := solve_arc(origin, target, speed, gravity, drag_decay)
	if target_velocity.length_squared() < 0.000001:
		return solution
	for _pass in INTERCEPT_PASSES:
		var flight_time: float = solution["flight_time"]
		if not is_finite(flight_time):
			break
		var predicted := target + target_velocity * flight_time
		solution = solve_arc(origin, predicted, speed, gravity, drag_decay)
		# An unreachable prediction cannot be improved by predicting further —
		# the shot is already the longest one available in that direction.
		if not solution["reachable"]:
			break
	return solution


## Nudges the launch angle until the predicted flight actually passes through the
## target, by secant iteration on the vertical error.
##
## Secant rather than bisection because the starting guess is already close (a
## parabola is the right answer with drag switched off) so the error function is
## near-linear over the interval that matters, and two or three passes converge
## to millimetres. Bisection would need a bracket and many more predictions for
## the same result.
static func _refine_pitch(d: float, h: float, speed: float, gravity: float,
		decay: float, initial: float, ceiling: float) -> float:
	var limit := deg_to_rad(PITCH_LIMIT_DEG)
	var angle_a := clampf(initial, -limit, limit)
	var error_a := _height_error(d, h, speed, angle_a, gravity, decay)
	if absf(error_a) <= REFINE_PRECISION_M:
		return angle_a
	# Second sample, offset toward the steeper side, since a shot that misses
	# usually falls short.
	var angle_b := clampf(angle_a + deg_to_rad(0.5), -limit, limit)
	var error_b := _height_error(d, h, speed, angle_b, gravity, decay)

	var best := angle_a
	var best_error := absf(error_a)
	for _pass in REFINE_PASSES:
		if absf(error_b) < best_error:
			best = angle_b
			best_error = absf(error_b)
		if best_error <= REFINE_PRECISION_M:
			return best
		var spread := error_b - error_a
		if absf(spread) < 0.0000001:
			break
		var next := clampf(angle_b - error_b * (angle_b - angle_a) / spread, -limit, limit)
		angle_a = angle_b
		error_a = error_b
		angle_b = next
		error_b = _height_error(d, h, speed, angle_b, gravity, decay)
	if absf(error_b) < best_error:
		best = angle_b
	# Never return something steeper than the longest shot available; past that
	# the arc is losing range rather than gaining height.
	return minf(best, ceiling) if h >= 0.0 else best


## How far above the target the shot passes at the target's own distance.
## Negative means short. A shot that never gets there is reported as short by its
## whole shortfall, which keeps the error continuous so the secant has a gradient
## to follow instead of a cliff.
static func _height_error(d: float, h: float, speed: float, launch_angle: float,
		gravity: float, decay: float) -> float:
	var flight := predict(d, speed, launch_angle, gravity, decay)
	if not flight["reached"]:
		return flight["height"] - h - flight["shortfall"]
	return flight["height"] - h


## The flat root of the quadratic in tan(theta) — see the class note. NAN when
## the target is out of reach at this speed, which callers treat as "use the
## maximum-range angle instead".
static func _flat_arc_angle(d: float, h: float, v: float, gravity: float) -> float:
	var a := gravity * d * d / (2.0 * v * v)
	var discriminant := d * d - 4.0 * a * (h + a)
	if discriminant < 0.0:
		return NAN
	return atan((d - sqrt(discriminant)) / (2.0 * a))


## The launch angle that reaches furthest when the landing point sits [param h]
## above the launch — 45 degrees on level ground, flatter downhill, steeper
## uphill.
##
## Derived rather than guessed at: an earlier version used the vertex of the
## quadratic above, on the reasoning that the vertex is where the two roots meet
## and therefore the limit of what is reachable. That is true only for a target
## at exactly maximum range; for anything further the vertex angle keeps
## shrinking, so the fallback got FLATTER the more out of reach the target was —
## fired at 32 degrees for a shot whose best angle was 45.
static func _max_range_angle(h: float, speed: float, gravity: float) -> float:
	var radical := speed * speed - 2.0 * gravity * h
	if radical <= 0.0:
		# Not enough speed to reach that height at all; straight up is as close
		# as it gets.
		return deg_to_rad(PITCH_LIMIT_DEG)
	return atan(speed / sqrt(radical))


static func _direction_at(flat_direction: Vector3, pitch: float) -> Vector3:
	return (flat_direction * cos(pitch) + Vector3.UP * sin(pitch)).normalized()


## A target directly overhead or underfoot, where the flat direction is
## undefined. Straight up may genuinely be out of reach; straight down never is.
static func _vertical_shot(h: float, speed: float, gravity: float,
		drag_decay: float) -> Dictionary:
	var v := effective_speed(speed, drag_decay, absf(h))
	var up := h > 0.0
	var radical := v * v - 2.0 * gravity * h if up else v * v + 2.0 * gravity * absf(h)
	if up and radical < 0.0:
		return {
			"direction": Vector3.UP, "flight_time": INF, "reachable": false,
			"angle_deg": 90.0, "speed_used": v,
		}
	var root := sqrt(maxf(radical, 0.0))
	var time := (v - root) / gravity if up else (root - v) / gravity
	return {
		"direction": Vector3.UP if up else Vector3.DOWN,
		"flight_time": maxf(time, 0.0),
		"reachable": true,
		"angle_deg": 90.0 if up else -90.0,
		"speed_used": v,
	}


## No shot is possible at all — a zero or negative speed. Points at the target
## so a caller that ignores `reachable` still fires somewhere sensible rather
## than along an arbitrary axis.
static func _failed(to_target: Vector3) -> Dictionary:
	var direction := to_target.normalized() if to_target.length_squared() > 0.0 \
		else Vector3.FORWARD
	return {
		"direction": direction, "flight_time": INF, "reachable": false,
		"angle_deg": 0.0, "speed_used": 0.0,
	}
