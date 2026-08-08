extends SceneTree

## Checks heightfield.gd's maths without launching the game — the terrain mesh,
## its collision and grass placement all read from that one function, so a
## mistake in it is a mistake in everything downstream, and it is far easier to
## catch here than by staring at a hillside.
##
## Run: Godot --headless --script res://scripts/dev/verify_heightfield.gd
## Exits non-zero if any check fails.

func _init() -> void:
	var fails := 0

	# --- Flat base, no features: should be exactly flat and exactly level. ---
	var flat := Heightfield.new()
	flat.base_elevation = 0.0
	for p in [Vector2(0, 0), Vector2(500, -900), Vector2(-13.7, 42.1)]:
		var h := flat.height_at(p.x, p.y)
		if not is_zero_approx(h):
			print("FAIL flat height at %s = %f, want 0" % [p, h]); fails += 1
		var n := flat.normal_at(p.x, p.y)
		if not n.is_equal_approx(Vector3.UP):
			print("FAIL flat normal at %s = %s, want UP" % [p, n]); fails += 1
		var s := flat.slope_degrees_at(p.x, p.y)
		if not is_zero_approx(s):
			print("FAIL flat slope at %s = %f, want 0" % [p, s]); fails += 1
	print("flat base: height 0, normal UP, slope 0 everywhere")

	# --- Base elevation should shift the whole surface, not tilt it. ---
	var raised := Heightfield.new()
	raised.base_elevation = 7.5
	if not is_equal_approx(raised.height_at(120.0, -60.0), 7.5):
		print("FAIL base_elevation not applied"); fails += 1
	print("base_elevation 7.5 -> height 7.5 far from origin")

	# --- A hill matching the existing SouthHill (radius 24, height 11). ---
	var hilly := Heightfield.new()
	hilly.features = [{"type": "hill", "pos": Vector2(-46, -46),
		"radius": 24.0, "height": 11.0, "noise": 0.0}]
	var peak := hilly.height_at(-46.0, -46.0)
	if not is_equal_approx(peak, 11.0):
		print("FAIL hill peak = %f, want 11" % peak); fails += 1
	var rim := hilly.height_at(-46.0 + 24.0, -46.0)
	if not is_zero_approx(rim):
		print("FAIL hill rim = %f, want 0" % rim); fails += 1
	var outside := hilly.height_at(-46.0 + 40.0, -46.0)
	if not is_zero_approx(outside):
		print("FAIL outside radius = %f, want 0" % outside); fails += 1
	var midway := hilly.height_at(-46.0 + 12.0, -46.0)
	if not is_equal_approx(midway, 5.5):
		print("FAIL hill midpoint = %f, want 5.5 (smoothstep is symmetric)" % midway); fails += 1
	print("hill r24 h11: peak 11.0, midpoint %.2f, rim 0.0, outside 0.0" % midway)

	# Summit and rim must be level; the flank must lean away from the centre.
	var summit_slope := hilly.slope_degrees_at(-46.0, -46.0)
	if summit_slope > 1.0:
		print("FAIL summit slope = %f, want ~0 (smoothstep is flat-tangent on top)" % summit_slope); fails += 1
	var flank := hilly.normal_at(-46.0 + 12.0, -46.0)
	if flank.x <= 0.0:
		print("FAIL flank normal.x = %f, want > 0 (leaning away from centre)" % flank.x); fails += 1
	var flank_slope := hilly.slope_degrees_at(-46.0 + 12.0, -46.0)
	print("hill slopes: summit %.2f deg, steepest flank %.2f deg" % [summit_slope, flank_slope])

	# The predicted worst case must actually bound the measured worst case.
	var predicted: float = hilly.feature_max_slope_degrees(hilly.features[0])
	var measured := 0.0
	for i in 400:
		var dist := 24.0 * float(i) / 400.0
		measured = maxf(measured, hilly.slope_degrees_at(-46.0 + dist, -46.0))
	if measured > predicted + 0.5:
		print("FAIL measured slope %.2f exceeds predicted bound %.2f" % [measured, predicted]); fails += 1
	if predicted > 50.0:
		print("FAIL SouthHill predicted %.2f deg, above the player's 50 deg limit" % predicted); fails += 1
	print("slope bound: predicted <= %.2f deg, measured %.2f deg, player limit 50" % [predicted, measured])

	# --- A basin is just a hill with negative height. ---
	var basin := Heightfield.new()
	basin.features = [{"pos": Vector2.ZERO, "radius": 10.0, "height": -4.0}]
	if not is_equal_approx(basin.height_at(0.0, 0.0), -4.0):
		print("FAIL basin floor = %f, want -4" % basin.height_at(0.0, 0.0)); fails += 1
	print("basin: negative height digs down to -4.0")

	# --- A plateau should be genuinely flat on top, then fall away. ---
	var mesa := Heightfield.new()
	mesa.features = [{"type": "plateau", "pos": Vector2.ZERO,
		"radius": 20.0, "height": 6.0, "flat_ratio": 0.5}]
	if not is_equal_approx(mesa.height_at(0.0, 0.0), 6.0):
		print("FAIL plateau centre != 6"); fails += 1
	# Anywhere inside the flat ratio (0.5 * 20 = 10 units) must be full height.
	if not is_equal_approx(mesa.height_at(9.0, 0.0), 6.0):
		print("FAIL plateau not flat at 9 units: %f" % mesa.height_at(9.0, 0.0)); fails += 1
	if mesa.slope_degrees_at(5.0, 0.0) > 0.01:
		print("FAIL plateau top is not level"); fails += 1
	if not is_zero_approx(mesa.height_at(20.0, 0.0)):
		print("FAIL plateau rim != 0"); fails += 1
	print("plateau: flat 6.0 out to 9 units, level on top, 0.0 at the rim")

	# --- Features must sum, not overwrite. ---
	var stacked := Heightfield.new()
	stacked.features = [
		{"pos": Vector2.ZERO, "radius": 20.0, "height": 5.0},
		{"pos": Vector2.ZERO, "radius": 20.0, "height": 3.0},
	]
	if not is_equal_approx(stacked.height_at(0.0, 0.0), 8.0):
		print("FAIL overlapping features = %f, want 8 (summed)" % stacked.height_at(0.0, 0.0)); fails += 1
	print("overlapping features sum: 5 + 3 -> 8.0")

	# --- Rolling noise: undulates, stays inside its amplitude, is repeatable. ---
	var rolling := Heightfield.new()
	rolling.rolling_amplitude = 0.6
	rolling.rolling_frequency = 0.02
	var lo := INF
	var hi := -INF
	var varied := false
	for i in 500:
		var h := rolling.height_at(float(i) * 3.3, float(i) * -1.7)
		lo = minf(lo, h)
		hi = maxf(hi, h)
		if absf(h) > 0.001:
			varied = true
	if not varied:
		print("FAIL rolling noise produced a flat surface"); fails += 1
	if lo < -0.6001 or hi > 0.6001:
		print("FAIL rolling exceeded amplitude: %f .. %f" % [lo, hi]); fails += 1
	print("rolling amplitude 0.6: observed %.3f .. %.3f over 500 samples" % [lo, hi])

	# --- Determinism: same numbers in, same surface out, every time. ---
	var a := Heightfield.new()
	a.seed = 4242
	a.rolling_amplitude = 1.0
	a.features = [{"pos": Vector2(5, 5), "radius": 30.0, "height": 8.0, "noise": 1.5}]
	var b := Heightfield.new()
	b.seed = 4242
	b.rolling_amplitude = 1.0
	b.features = [{"pos": Vector2(5, 5), "radius": 30.0, "height": 8.0, "noise": 1.5}]
	var drift := 0.0
	for i in 300:
		var x := float(i) * 1.9 - 200.0
		var z := float(i) * -2.3 + 90.0
		drift = maxf(drift, absf(a.height_at(x, z) - b.height_at(x, z)))
	if not is_zero_approx(drift):
		print("FAIL two identical heightfields disagree by %f" % drift); fails += 1
	# A different seed must actually change the irregularity.
	var c := Heightfield.new()
	c.seed = 99
	c.rolling_amplitude = 1.0
	if is_equal_approx(c.height_at(37.0, 91.0), a.height_at(37.0, 91.0)):
		print("FAIL seed had no effect on the surface"); fails += 1
	print("determinism: identical configs agree exactly, differing seeds differ")

	# --- The unclimbable-feature check should catch a bad layout. ---
	var steep := Heightfield.new()
	steep.features = [
		{"pos": Vector2.ZERO, "radius": 24.0, "height": 11.0},
		{"pos": Vector2(200, 0), "radius": 5.0, "height": 40.0},
	]
	var offenders := steep.find_unclimbable_features(50.0)
	if offenders.size() != 1:
		print("FAIL expected exactly 1 unclimbable feature, got %d" % offenders.size()); fails += 1
	print("unclimbable check flagged %d of 2 features: %s" % [offenders.size(), offenders])

	# --- Cost: this has to be cheap enough to replace a raycast. ---
	var perf := Heightfield.new()
	perf.rolling_amplitude = 0.5
	perf.features = [{"pos": Vector2(-46, -46), "radius": 24.0, "height": 11.0, "noise": 1.9}]
	var samples := 100000
	var started := Time.get_ticks_usec()
	var sink := 0.0
	for i in samples:
		sink += perf.height_at(float(i) * 0.37, float(i) * -0.61)
	var elapsed := Time.get_ticks_usec() - started
	print("cost: %d height lookups in %.1f ms (%.3f us each), sink %.1f" % [
		samples, elapsed / 1000.0, float(elapsed) / float(samples), sink])

	print("")
	if fails == 0:
		print("ALL HEIGHTFIELD CHECKS PASSED")
	else:
		print("%d CHECK(S) FAILED" % fails)
	quit(1 if fails > 0 else 0)
