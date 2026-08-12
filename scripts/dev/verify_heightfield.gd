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

	# --- Levelling pads: the one feature that blends instead of summing. ---
	# Built on deliberately lumpy ground, so "it is flat" is a real claim rather
	# than something inherited from a flat base.
	var padded := Heightfield.new()
	padded.rolling_amplitude = 2.0
	padded.rolling_frequency = 0.02
	padded.features = [
		{"type": "flatten", "pos": Vector2(40, -20),
			"size": Vector2(16, 12), "falloff": 8.0},
	]
	var unlevelled := Heightfield.new()
	unlevelled.rolling_amplitude = 2.0
	unlevelled.rolling_frequency = 0.02

	# The core must be level everywhere, not merely at the middle — that is the
	# whole difference between a pad and a spot height.
	var pad_level := padded.height_at(40.0, -20.0)
	var core_spread := 0.0
	var core_slope := 0.0
	for i in 21:
		for j in 21:
			var px := 40.0 - 8.0 + 16.0 * float(i) / 20.0
			var pz := -20.0 - 6.0 + 12.0 * float(j) / 20.0
			core_spread = maxf(core_spread, absf(padded.height_at(px, pz) - pad_level))
			# Slope is measured a quarter-unit either side of the point, so a
			# sample sitting exactly on the core's edge reaches out into the
			# falloff band and reports its slope rather than the core's. Inset
			# by more than that: the claim being tested is that the core is
			# level, not that the boundary is.
			if absf(px - 40.0) < 7.5 and absf(pz + 20.0) < 5.5:
				core_slope = maxf(core_slope, padded.slope_degrees_at(px, pz))
	if core_spread > 0.001:
		print("FAIL pad core varies by %f, want level" % core_spread); fails += 1
	if core_slope > 0.01:
		print("FAIL pad core slope %f deg, want 0" % core_slope); fails += 1
	print("pad 16x12: core level to %.6f over 441 samples, slope %.4f deg" % [
		core_spread, core_slope])

	# Its level should be the height the land ALREADY had there, so the pad
	# settles onto the ground rather than pinning it to an arbitrary number.
	if not is_equal_approx(pad_level, unlevelled.height_at(40.0, -20.0)):
		print("FAIL pad level %f, want the unlevelled surface's %f" % [
			pad_level, unlevelled.height_at(40.0, -20.0)]); fails += 1
	if is_zero_approx(pad_level):
		print("FAIL pad landed at 0, so this proves nothing about following the land")
		fails += 1
	print("pad level %.3f matches the unlevelled surface at its centre" % pad_level)

	# Past the falloff the land must be exactly as it would have been — a pad is
	# local, and anything else would make placing one a world-wide edit.
	var far_drift := 0.0
	for i in 200:
		var angle := TAU * float(i) / 200.0
		var px := 40.0 + cos(angle) * 60.0
		var pz := -20.0 + sin(angle) * 60.0
		far_drift = maxf(far_drift, absf(padded.height_at(px, pz) - unlevelled.height_at(px, pz)))
	if not is_zero_approx(far_drift):
		print("FAIL pad changed the land %f at 60 units away" % far_drift); fails += 1
	print("pad influence is local: 0.0 drift at 60 units out")

	# The band between must be continuous — a pad exists to remove creases, so
	# introducing one at its own edge would be self-defeating. Walked outward in
	# small steps, asserting no sample jumps away from its neighbour.
	var worst_step := 0.0
	for i in 64:
		var angle := TAU * float(i) / 64.0
		var dir := Vector2(cos(angle), sin(angle))
		var previous := pad_level
		for j in range(1, 401):
			var p := Vector2(40, -20) + dir * (30.0 * float(j) / 400.0)
			var h := padded.height_at(p.x, p.y)
			worst_step = maxf(worst_step, absf(h - previous))
			previous = h
	if worst_step > 0.25:
		print("FAIL pad edge jumps %f over a 0.075-unit step" % worst_step); fails += 1
	print("pad band is continuous: worst neighbouring-sample step %.4f" % worst_step)

	# An explicit level overrides the default, for the case where a structure's
	# height is fixed by something other than the land.
	var pinned := Heightfield.new()
	pinned.rolling_amplitude = 2.0
	pinned.features = [{"type": "flatten", "pos": Vector2.ZERO,
		"size": Vector2(10, 10), "falloff": 5.0, "level": 12.5}]
	if not is_equal_approx(pinned.height_at(3.0, -4.0), 12.5):
		print("FAIL explicit pad level ignored: %f" % pinned.height_at(3.0, -4.0)); fails += 1
	print("explicit level 12.5 honoured across the core")

	# A pad's steepness has to be measured, not predicted — see heightfield.gd.
	# One levelling flat ground is flat; one cut into a hillside is not, and the
	# check must be able to tell them apart or it is worth nothing.
	var terraced := Heightfield.new()
	terraced.features = [
		{"pos": Vector2.ZERO, "radius": 40.0, "height": 30.0, "noise": 0.0},
		{"type": "flatten", "pos": Vector2(22, 0),
			"size": Vector2(10, 10), "falloff": 3.0},
	]
	var cut_slope: float = terraced.feature_max_slope_degrees(terraced.features[1])
	if cut_slope < 50.0:
		print("FAIL pad cut into a hillside measured %.1f deg, expected steep" % cut_slope)
		fails += 1
	var gentle_slope: float = padded.feature_max_slope_degrees(padded.features[0])
	if gentle_slope > 50.0:
		print("FAIL pad on gentle ground measured %.1f deg" % gentle_slope); fails += 1
	if terraced.find_unclimbable_features(50.0).size() < 1:
		print("FAIL unclimbable check missed a pad cut into a hillside"); fails += 1
	print("pad slope measured: %.1f deg on gentle ground, %.1f deg cut into a hill" % [
		gentle_slope, cut_slope])

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
