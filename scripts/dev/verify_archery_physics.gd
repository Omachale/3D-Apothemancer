extends Node

## Checks the arrow economy in archery_physics.gd and the shipped bow/arrow data.
##
## THE CHECK THAT MATTERS MOST IS THE CALIBRATION ANCHOR. Every constant here
## was transcribed from a working 2D game, and a transcription error in any one
## of them — a decimal place in GRAINS_PER_KG, a swapped stat weight — still
## produces a model that runs, returns finite numbers and looks entirely
## plausible. What it does NOT do is agree with the game the numbers came from.
## ARCHERY_HANDOFF.md records that the default loadout lands around 15-20 damage
## per hit at typical range, so that figure is asserted directly: it is the one
## test that can fail on a typo anywhere in the whole chain.
##
## The rest check the RELATIONSHIPS the model exists to express — heavier arrows
## trading speed for retained energy, a bow too heavy to draw capping short of
## full, energy falling off with distance at twice the rate velocity does. Those
## are the claims the design rests on, and unlike the raw numbers they stay true
## even if the constants are retuned later.
##
##   Godot --headless res://scenes/dev/VerifyArcheryPhysics.tscn
## Exits non-zero if any check fails.

const AP := preload("res://scripts/combat/archery_physics.gd")

const BOW_SELFBOW := "res://resources/archery/bow_selfbow.tres"
const BOW_RECURVE := "res://resources/archery/bow_recurve.tres"
const BOW_WARBOW := "res://resources/archery/bow_warbow.tres"
const ARROW_LIGHT := "res://resources/archery/arrow_light.tres"
const ARROW_STANDARD := "res://resources/archery/arrow_standard.tres"
const ARROW_HEAVY := "res://resources/archery/arrow_heavy.tres"

## The handoff doc's default player.
const STRENGTH := 10.0
const ARCHERY := 10.0
## Long enough that any shipped bow reaches whatever draw it is going to reach.
const FULL_HOLD := 30.0
## "Typical range" for the calibration anchor, in metres — a plausible fighting
## distance rather than a muzzle-contact shot.
const TYPICAL_RANGE_M := 20.0

var _failures := 0


func _ready() -> void:
	_check_calibration_anchor()
	_check_shipped_data_loads()
	_check_pull_is_quadratic_in_energy()
	_check_strength_gates_full_draw()
	_check_draw_time_scales()
	_check_arrow_mass_trade()
	_check_bows_rank_by_draw_weight()
	_check_energy_decays_twice_as_fast_as_velocity()
	_check_range_definitions_agree()
	_check_aim_spread()
	_check_degenerate_inputs()
	if _failures == 0:
		print("ALL ARCHERY PHYSICS CHECKS PASSED")
	else:
		print("VERIFY ARCHERY PHYSICS: FAIL (%d)" % _failures)
	get_tree().quit(1 if _failures > 0 else 0)


func _fail(message: String) -> void:
	print("  FAIL: %s" % message)
	_failures += 1


func _bow(path: String) -> Bow:
	return load(path) as Bow


func _arrow(path: String) -> ArrowSpec:
	return load(path) as ArrowSpec


func _full_shot(bow_path: String, arrow_path: String) -> Dictionary:
	return AP.solve_shot(_bow(bow_path), _arrow(arrow_path), STRENGTH, ARCHERY, FULL_HOLD)


# ---------------------------------------------------------------------------
# CHECKS
# ---------------------------------------------------------------------------

## The anchor. See the class note — this is the check that catches a typo
## anywhere in the chain, because it is the only one comparing against a figure
## produced by the game these numbers were taken from.
func _check_calibration_anchor() -> void:
	var shot := _full_shot(BOW_RECURVE, ARROW_STANDARD)
	var at_range: float = AP.energy_at_distance(
		shot["muzzle_energy_j"], shot["decay"], TYPICAL_RANGE_M)
	var damage: float = AP.damage_from_energy(at_range)

	if damage < 15.0 or damage > 20.0:
		_fail("default loadout does %.2f damage at %.0f m; the handoff doc says 15-20"
			% [damage, TYPICAL_RANGE_M])
	else:
		print("  calibration: recurve + standard arrow does %.1f damage at %.0f m (doc: 15-20)"
			% [damage, TYPICAL_RANGE_M])

	# A real bow shoots somewhere around 45-90 m/s. Well outside that means a
	# unit conversion has gone wrong even if the damage happens to land.
	var speed: float = shot["muzzle_velocity_ms"]
	if speed < 30.0 or speed > 100.0:
		_fail("muzzle velocity %.1f m/s is not a plausible arrow speed" % speed)
	else:
		print("  calibration: muzzle velocity %.1f m/s, %.1f J at the string"
			% [speed, shot["muzzle_energy_j"]])

	# The default player is meant to be exactly matched to the default bow.
	if not is_equal_approx(shot["pull"], 1.0):
		_fail("the default player reached only %.3f draw on the default bow" % shot["pull"])


func _check_shipped_data_loads() -> void:
	for path in [BOW_SELFBOW, BOW_RECURVE, BOW_WARBOW]:
		var bow := _bow(path)
		if bow == null:
			_fail("%s did not load as a Bow" % path)
			continue
		if bow.archetype == null:
			_fail("%s has no archetype, so it can never loose anything" % bow.id)
		elif bow.max_efficiency() <= 0.0:
			_fail("%s reports zero max efficiency" % bow.id)
	for path in [ARROW_LIGHT, ARROW_STANDARD, ARROW_HEAVY]:
		var arrow := _arrow(path)
		if arrow == null:
			_fail("%s did not load as an ArrowSpec" % path)
		elif arrow.mass_kg() <= 0.0:
			_fail("%s has no mass" % arrow.id)
	if _failures == 0:
		print("  data: three bows and three arrows load with usable values")


## Energy goes as the square of the pull, which is why a snap shot is so much
## weaker than a held one — the single most important feel property of the draw.
func _check_pull_is_quadratic_in_energy() -> void:
	var power: float = AP.bow_power_joules(20.0, 0.72)
	var full: float = AP.stored_energy_joules(power, 1.0, 1.0)
	var half: float = AP.stored_energy_joules(power, 0.5, 1.0)
	if not is_equal_approx(half, full * 0.25):
		_fail("half draw stored %.3f J against a quarter of full (%.3f J)" % [half, full * 0.25])
	else:
		print("  draw: half a draw stores a quarter of the energy")

	# And pull itself must rise with hold time and then stop.
	var early: float = AP.pull_fraction(0.2, 20.0, STRENGTH, ARCHERY)
	var later: float = AP.pull_fraction(0.6, 20.0, STRENGTH, ARCHERY)
	var forever: float = AP.pull_fraction(600.0, 20.0, STRENGTH, ARCHERY)
	if not (early < later and later <= 1.0):
		_fail("pull did not rise with hold time: %.3f then %.3f" % [early, later])
	if forever > 1.0:
		_fail("holding for ten minutes drew past full: %.3f" % forever)


## Being too weak for a bow is a hard physical ceiling, not a slow climb — the
## reason draw TIME and draw FRACTION are separate ideas throughout.
func _check_strength_gates_full_draw() -> void:
	var weak: float = AP.max_draw_fraction(32.0, 4.0, 4.0)
	var strong: float = AP.max_draw_fraction(32.0, 22.0, 22.0)
	if weak >= 1.0:
		_fail("a weak archer reached full draw on a 32 kg war bow (%.3f)" % weak)
	if strong < 1.0:
		_fail("a strong archer could not reach full draw on a 32 kg war bow (%.3f)" % strong)

	# And no amount of holding lifts the weak archer past their ceiling.
	var held: float = AP.pull_fraction(FULL_HOLD, 32.0, 4.0, 4.0)
	if absf(held - weak) > 0.001:
		_fail("holding longer pushed a capped draw from %.3f to %.3f" % [weak, held])
	else:
		print("  strength: a war bow caps a weak archer at %.0f%% draw however long they hold"
			% (weak * 100.0))


func _check_draw_time_scales() -> void:
	var light: float = AP.time_to_max_draw(12.0, STRENGTH, ARCHERY)
	var heavy: float = AP.time_to_max_draw(32.0, STRENGTH, ARCHERY)
	if heavy <= light:
		_fail("a 32 kg bow drew no slower (%.3f s) than a 12 kg one (%.3f s)" % [heavy, light])

	var unskilled: float = AP.time_to_max_draw(20.0, 0.0, 0.0)
	var skilled: float = AP.time_to_max_draw(20.0, 20.0, 20.0)
	if skilled >= unskilled:
		_fail("skill did not speed the draw: %.3f s against %.3f s" % [skilled, unskilled])
	else:
		print("  draw time: %.2f s selfbow, %.2f s war bow; skill cuts 20 kg from %.2f s to %.2f s"
			% [light, heavy, unskilled, skilled])


## The trade the whole mass model exists for: light leaves faster, heavy carries
## further and hits harder. Neither is simply better.
func _check_arrow_mass_trade() -> void:
	var light := _full_shot(BOW_RECURVE, ARROW_LIGHT)
	var heavy := _full_shot(BOW_RECURVE, ARROW_HEAVY)

	if light["muzzle_velocity_ms"] <= heavy["muzzle_velocity_ms"]:
		_fail("the light arrow did not leave faster (%.1f vs %.1f m/s)"
			% [light["muzzle_velocity_ms"], heavy["muzzle_velocity_ms"]])
	if heavy["efficiency"] <= light["efficiency"]:
		_fail("the heavy arrow did not take energy more efficiently (%.3f vs %.3f)"
			% [heavy["efficiency"], light["efficiency"]])
	if heavy["muzzle_energy_j"] <= light["muzzle_energy_j"]:
		_fail("the heavy arrow did not carry more energy (%.2f vs %.2f J)"
			% [heavy["muzzle_energy_j"], light["muzzle_energy_j"]])
	if heavy["effective_range_m"] <= light["effective_range_m"]:
		_fail("the heavy arrow did not reach further (%.1f vs %.1f m)"
			% [heavy["effective_range_m"], light["effective_range_m"]])
	else:
		print("  arrow mass: light %.1f m/s / %.1f J, heavy %.1f m/s / %.1f J, reach %.0f m vs %.0f m"
			% [light["muzzle_velocity_ms"], light["muzzle_energy_j"],
				heavy["muzzle_velocity_ms"], heavy["muzzle_energy_j"],
				light["effective_range_m"], heavy["effective_range_m"]])


## A heavier bow must hit harder, with the archer strong enough to use it — the
## claim that makes draw weight the number a bow is authored in.
func _check_bows_rank_by_draw_weight() -> void:
	var strong := 30.0
	var arrow := _arrow(ARROW_STANDARD)
	var energies: Array[float] = []
	for path in [BOW_SELFBOW, BOW_RECURVE, BOW_WARBOW]:
		var shot: Dictionary = AP.solve_shot(_bow(path), arrow, strong, strong, FULL_HOLD)
		energies.append(shot["muzzle_energy_j"])
	if not (energies[0] < energies[1] and energies[1] < energies[2]):
		_fail("bows did not rank selfbow < recurve < warbow: %.1f, %.1f, %.1f J"
			% [energies[0], energies[1], energies[2]])
	else:
		print("  bows: selfbow %.1f J < recurve %.1f J < war bow %.1f J at full draw"
			% [energies[0], energies[1], energies[2]])


## Energy goes as v squared, so it must decay at exactly twice the rate.
func _check_energy_decays_twice_as_fast_as_velocity() -> void:
	var decay: float = AP.decay_rate(0.000153, 0.037)
	var distance := 50.0
	var v_ratio: float = AP.velocity_at_distance(1.0, decay, distance)
	var e_ratio: float = AP.energy_at_distance(1.0, decay, distance)
	if not is_equal_approx(e_ratio, v_ratio * v_ratio):
		_fail("energy ratio %.6f is not the square of the velocity ratio %.6f"
			% [e_ratio, v_ratio])
	else:
		print("  flight: over %.0f m velocity falls to %.1f%% and energy to %.1f%% (its square)"
			% [distance, v_ratio * 100.0, e_ratio * 100.0])

	# Lighter arrows shed speed faster for the same drag.
	if AP.decay_rate(0.000153, 0.025) <= AP.decay_rate(0.000153, 0.060):
		_fail("a lighter arrow did not decay faster than a heavier one")


## The two derived ranges must mean what they claim: 1/e of the energy at
## effective range, and the despawn floor at maximum flight distance.
func _check_range_definitions_agree() -> void:
	var shot := _full_shot(BOW_RECURVE, ARROW_STANDARD)
	var decay: float = shot["decay"]
	var muzzle: float = shot["muzzle_energy_j"]

	var at_effective: float = AP.energy_at_distance(muzzle, decay, shot["effective_range_m"])
	if absf(at_effective / muzzle - exp(-1.0)) > 0.001:
		_fail("energy at effective range was %.4f of muzzle, expected 1/e (%.4f)"
			% [at_effective / muzzle, exp(-1.0)])

	var at_max: float = AP.energy_at_distance(muzzle, decay, shot["max_flight_distance_m"])
	if absf(at_max - AP.DESPAWN_ENERGY_J) > 0.01:
		_fail("energy at max flight distance was %.3f J, expected the %.1f J floor"
			% [at_max, AP.DESPAWN_ENERGY_J])
	else:
		print("  ranges: 1/e of energy at %.0f m, down to the %.0f J floor at %.0f m"
			% [shot["effective_range_m"], AP.DESPAWN_ENERGY_J, shot["max_flight_distance_m"]])


## Scatter must cluster around the aim rather than spreading evenly, and must
## tighten with skill down to a floor.
func _check_aim_spread() -> void:
	var unskilled: float = AP.aim_stddev_degrees(0.0)
	var skilled: float = AP.aim_stddev_degrees(10.0)
	var expert: float = AP.aim_stddev_degrees(1000.0)
	if skilled >= unskilled:
		_fail("archery skill did not tighten the spread (%.2f vs %.2f deg)" % [skilled, unskilled])
	if not is_equal_approx(expert, AP.AIM_MIN_STDDEV_DEG):
		_fail("spread did not floor at %.2f deg, got %.2f" % [AP.AIM_MIN_STDDEV_DEG, expert])

	# Statistical: the spread of the sampled directions must match the stddev
	# asked for (halved, since scatter applies only horizontal), and the average
	# must still point where the player aimed. Vertical component is untouched.
	var rng := RandomNumberGenerator.new()
	rng.seed = 20240
	var aim := Vector3(0.0, 0.0, 1.0)
	var stddev := 6.0
	var expected_spread := stddev * 0.5
	var samples := 4000
	var sum_squares := 0.0
	var mean := Vector3.ZERO
	for _i in samples:
		var shot: Vector3 = AP.scatter_direction(aim, stddev, rng)
		if absf(shot.length() - 1.0) > 0.001:
			_fail("scatter changed the length of the aim vector: %.4f" % shot.length())
			break
		var offset := rad_to_deg(aim.angle_to(shot))
		sum_squares += offset * offset
		mean += shot
	var measured := sqrt(sum_squares / float(samples))
	if absf(measured - expected_spread) > 0.5:
		_fail("sampled spread was %.2f deg against the %.2f expected (%.2f stddev halved)"
			% [measured, expected_spread, stddev])
	var bias := rad_to_deg(aim.angle_to(mean.normalized()))
	if bias > 1.0:
		_fail("scatter was biased %.2f deg off the aim point" % bias)
	else:
		print("  aim: %.2f deg spread over %d shots (asked %.1f), %.2f deg bias, floors at %.1f deg"
			% [measured, samples, stddev, bias, expert])


## Nothing here may divide by zero, return NAN, or invent a shot from an
## unusable loadout — a caller must see "this did nothing", not a crash.
func _check_degenerate_inputs() -> void:
	var blank: Dictionary = AP.solve_shot(null, null, STRENGTH, ARCHERY, FULL_HOLD)
	if blank["muzzle_velocity_ms"] != 0.0 or blank["impact_damage"] != 0.0:
		_fail("a null loadout produced a live shot")

	var no_archetype := Bow.new()
	no_archetype.draw_weight_kg = 20.0
	var orphan: Dictionary = AP.solve_shot(
		no_archetype, _arrow(ARROW_STANDARD), STRENGTH, ARCHERY, FULL_HOLD)
	if orphan["muzzle_energy_j"] != 0.0:
		_fail("a bow with no archetype loosed %.3f J" % orphan["muzzle_energy_j"])

	if AP.muzzle_velocity(10.0, 0.0) != 0.0:
		_fail("a massless arrow did not return zero velocity")
	if AP.max_draw_fraction(0.0, STRENGTH, ARCHERY) != 0.0:
		_fail("a weightless bow did not return zero draw")
	if not is_inf(AP.effective_range_m(0.0)):
		_fail("zero drag did not give infinite effective range")

	var shot: Dictionary = AP.solve_shot(
		_bow(BOW_RECURVE), _arrow(ARROW_STANDARD), STRENGTH, ARCHERY, 0.0)
	if shot["muzzle_velocity_ms"] != 0.0:
		_fail("a zero-length hold loosed an arrow at %.3f m/s" % shot["muzzle_velocity_ms"])
	for key in shot:
		var value = shot[key]
		if value is float and is_nan(value):
			_fail("solve_shot returned NAN for '%s'" % key)
	if _failures == 0:
		print("  degenerate: null loadouts, massless arrows and zero holds all fail safe")
