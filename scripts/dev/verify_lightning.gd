extends Node3D

## Checks the lightning attack: the straight-line hit resolution in
## player_attacks.gd, and the purely cosmetic bolt in lightning_bolt.gd.
##
## THE CLAIM UNDER TEST IS THE SPLIT ITSELF — see SpellProfile.AimMode.HITSCAN
## and player_attacks.gd's class note. The hit is decided BEFORE the jagged
## bolt is even built, and the bolt's own timing (instant today, delayed once
## travel_speed_mps is tuned above zero) must not be able to change who or what
## got hit, only WHEN the damage lands. Both halves are checked directly rather
## than inferred from one end-to-end pass, because either half could be broken
## while the other still looks fine.
##
##   Godot --headless res://scenes/dev/VerifyLightning.tscn
## Exits non-zero if any check fails.

const ATTACKS := preload("res://scripts/player/player_attacks.gd")
const CASTER := preload("res://scripts/player/spell_caster.gd")
const BOLT_SCENE := preload("res://scenes/combat/LightningBolt.tscn")
const WALL_SCENE := preload("res://scenes/props/WallProp.tscn")
const WITCH_SCENE := preload("res://scenes/npc/Witch.tscn")
const LIGHTNING_PROFILE := "res://resources/spells/lightning_bolt.tres"

const STEP := 1.0 / 60.0

var _failures := 0
## What get_aim_target() answers — see the class note on VerifyArcheryWiring
## for why a test harness stands in for the player this way.
var _aim_target := Vector3(0.0, 1.1, 10.0)


## A minimal duck-typed target: counts what landed on it without pulling in
## Health or a real body, so the bolt-timing checks do not depend on anything
## outside lightning_bolt.gd itself.
class FakeTarget:
	extends Node3D
	var hits := 0
	var last_damage := 0.0
	var knocked := false
	func take_damage(amount: float) -> void:
		hits += 1
		last_damage = amount
	func apply_knockback(_dir: Vector3, _force: float, _lift: float) -> void:
		knocked = true


func _ready() -> void:
	_check_bolt_hits_instantly_by_default()
	_check_bolt_delays_the_hit_when_given_a_travel_speed()
	_check_path_is_jagged_but_bounded()
	_check_target_resolves_to_the_assisted_target()
	await _check_target_falls_back_to_a_raycast()
	_check_target_misses_into_open_air()
	_check_cast_lightning_end_to_end()
	if _failures == 0:
		print("VERIFY LIGHTNING: PASS")
	else:
		print("VERIFY LIGHTNING: FAIL (%d)" % _failures)
	get_tree().quit(1 if _failures > 0 else 0)


func _fail(message: String) -> void:
	print("  FAIL: %s" % message)
	_failures += 1


func get_aim_target() -> Vector3:
	return _aim_target


# ---------------------------------------------------------------------------
# HARNESS
# ---------------------------------------------------------------------------

func _spawn_bolt() -> Node3D:
	var bolt: Node3D = BOLT_SCENE.instantiate()
	add_child(bolt)
	return bolt


## A caster and an attacks node parented to this stand-in, exactly the shape
## _make_archer() builds in verify_archery_wiring.gd for the same reason: the
## real seams (PlayerAttacks finding "SpellCaster" by name off its own parent)
## only get exercised by matching the real node layout.
func _make_shooter() -> Dictionary:
	var caster: Node = CASTER.new()
	caster.name = "SpellCaster"
	caster.secondary_profile = load(LIGHTNING_PROFILE) as SpellProfile
	add_child(caster)
	caster.set_process(false)
	var attacks: Node = ATTACKS.new()
	attacks.name = "PlayerAttacks"
	add_child(attacks)
	return {"caster": caster, "attacks": attacks}


func _step(caster: Node, seconds: float) -> void:
	var elapsed := 0.0
	while elapsed < seconds:
		caster._process(STEP)
		elapsed += STEP


# ---------------------------------------------------------------------------
# CHECKS — the bolt's own timing
# ---------------------------------------------------------------------------

func _check_bolt_hits_instantly_by_default() -> void:
	var bolt := _spawn_bolt()
	var target := FakeTarget.new()
	add_child(target)
	bolt.strike(Vector3.ZERO, Vector3(0.0, 0.0, 10.0), target)
	if target.hits != 1:
		_fail("an instant bolt (travel_speed_mps=0) did not hit synchronously inside strike(): %d hits"
			% target.hits)
	elif absf(target.last_damage - bolt.damage) > 0.001:
		_fail("instant bolt dealt %.2f, expected its authored %.2f" % [target.last_damage, bolt.damage])
	elif not target.knocked:
		_fail("instant bolt did not apply knockback")
	else:
		print("  instant: strike() damages and shoves synchronously, before any frame passes")
	bolt.free()
	target.free()


## THE VELOCITY SEAM, exercised directly: turning travel_speed_mps above zero
## must delay the hit to distance / speed and not a moment sooner.
func _check_bolt_delays_the_hit_when_given_a_travel_speed() -> void:
	var bolt := _spawn_bolt()
	bolt.travel_speed_mps = 20.0
	var target := FakeTarget.new()
	add_child(target)
	# 10 m at 20 m/s: the hit must land at ~0.5 s, not at strike() and not late.
	bolt.strike(Vector3.ZERO, Vector3(0.0, 0.0, 10.0), target)
	if target.hits != 0:
		_fail("a 20 m/s bolt over 10 m hit before any time passed at all")
		bolt.free()
		target.free()
		return

	var elapsed := 0.0
	while elapsed < 0.4:
		bolt._process(STEP)
		elapsed += STEP
	if target.hits != 0:
		_fail("a ~0.5 s travel time bolt had already hit by %.2f s" % elapsed)

	while elapsed < 0.6:
		bolt._process(STEP)
		elapsed += STEP
	if target.hits != 1:
		_fail("a ~0.5 s travel time bolt had not hit by %.2f s (%d hits)" % [elapsed, target.hits])
	else:
		print("  travel: a %.0f m/s bolt over 10 m delays the hit to ~0.5 s instead of hitting instantly"
			% bolt.travel_speed_mps)

	# Run it out through sustain and fade; the impact must not fire twice.
	while elapsed < 1.5 and is_instance_valid(bolt):
		bolt._process(STEP)
		elapsed += STEP
	if target.hits > 1:
		_fail("the bolt applied its impact %d times instead of once" % target.hits)
	if is_instance_valid(bolt):
		bolt.free()
	target.free()


## The jagged path must actually wrap the straight line — longer than it, by
## construction — without the recursive kick blowing up into something absurd.
func _check_path_is_jagged_but_bounded() -> void:
	var bolt := _spawn_bolt()
	var from := Vector3.ZERO
	var to := Vector3(0.0, 0.0, 20.0)
	bolt.strike(from, to)
	var straight: float = from.distance_to(to)
	var total: float = bolt.get("_total_length")
	if total < straight:
		_fail("the jagged path (%.2f m) is shorter than the %.2f m straight line it wraps"
			% [total, straight])
	elif total > straight * 3.0:
		_fail("the jagged path (%.2f m) is wildly longer than the %.2f m straight line"
			% [total, straight])
	else:
		print("  path: %.1f m of jagged bolt drawn over a %.1f m straight shot" % [total, straight])
	bolt.free()


# ---------------------------------------------------------------------------
# CHECKS — where player_attacks.gd decides the hit landed
# ---------------------------------------------------------------------------

## With a target selected and the shot pointed roughly at it, the hit must be
## the target itself — not a raycast repeating work Targeting already did.
func _check_target_resolves_to_the_assisted_target() -> void:
	var shooter := _make_shooter()
	var attacks: Node = shooter["attacks"]
	var witch: Node3D = WITCH_SCENE.instantiate()
	add_child(witch)
	witch.global_position = Vector3(0.0, 0.0, 10.0)
	Targeting.set_target(witch)

	var hit: Dictionary = attacks.call("_lightning_target", Vector3.ZERO, Vector3(0.0, 0.0, 1.0))
	var expected_point: Vector3 = witch.global_position + Vector3.UP * attacks.target_aim_height
	if hit["body"] != witch:
		_fail("a selected target in the assist arc was ignored; hit body was %s" % [hit["body"]])
	elif (hit["point"] as Vector3).distance_to(expected_point) > 0.01:
		_fail("assisted hit point %s did not match the target's aim point %s"
			% [hit["point"], expected_point])
	else:
		print("  assisted: a selected target in the assist arc is hit directly, no raycast needed")

	Targeting.clear()
	witch.free()
	(shooter["caster"] as Node).free()
	attacks.free()


## With nothing selected, the shot must fall back to a straight raycast and
## report whatever solid thing is actually in the way.
func _check_target_falls_back_to_a_raycast() -> void:
	var shooter := _make_shooter()
	var attacks: Node = shooter["attacks"]
	var wall: Node3D = WALL_SCENE.instantiate()
	add_child(wall)
	wall.global_position = Vector3(0.0, 1.0, 10.0)
	# A freshly added collider is not yet visible to a space query on the same
	# frame it was added — the physics server only picks it up on the next
	# physics step. Every other spawn-then-raycast suite in this project waits
	# for the same reason (see verify_arrow_flight._spawn_target).
	await get_tree().physics_frame

	var hit: Dictionary = attacks.call("_lightning_target", Vector3(0.0, 1.0, 0.0), Vector3(0.0, 0.0, 1.0))
	if hit["body"] == null:
		_fail("a wall directly in the shot's path was not reported as hit")
	elif (hit["point"] as Vector3).distance_to(wall.global_position) > 1.0:
		_fail("the raycast hit point %s was not near the wall at %s" % [hit["point"], wall.global_position])
	else:
		print("  raycast: with nothing selected, a solid in the way is hit at %s" % hit["point"])

	wall.free()
	(shooter["caster"] as Node).free()
	attacks.free()


## With nothing selected and nothing in the way, the shot must still return a
## usable endpoint — at the max range — rather than nothing at all.
func _check_target_misses_into_open_air() -> void:
	var shooter := _make_shooter()
	var attacks: Node = shooter["attacks"]

	var direction := Vector3(0.0, 0.0, 1.0)
	var hit: Dictionary = attacks.call("_lightning_target", Vector3.ZERO, direction)
	var expected: Vector3 = direction * ATTACKS.LIGHTNING_MAX_RANGE
	if hit["body"] != null:
		_fail("a shot into open air reported a hit: %s" % [hit["body"]])
	elif (hit["point"] as Vector3).distance_to(expected) > 0.01:
		_fail("an open-air miss landed at %s, expected the max range point %s" % [hit["point"], expected])
	else:
		print("  miss: open air still returns an honest endpoint, at the %.0f m max range"
			% ATTACKS.LIGHTNING_MAX_RANGE)

	(shooter["caster"] as Node).free()
	attacks.free()


## The whole path, end to end: a real timed cast, on a real target, through
## the real SpellCaster -> PlayerAttacks -> LightningBolt chain.
func _check_cast_lightning_end_to_end() -> void:
	var shooter := _make_shooter()
	var caster: Node = shooter["caster"]
	var attacks: Node = shooter["attacks"]
	var witch: Node3D = WITCH_SCENE.instantiate()
	add_child(witch)
	witch.global_position = Vector3(0.0, 0.0, 10.0)
	_aim_target = witch.global_position + Vector3.UP * 1.1
	Targeting.set_target(witch)

	var health: Health = witch.get_health()
	if health == null:
		_fail("the test target has no Health to lose")
		Targeting.clear()
		witch.free()
		caster.free()
		attacks.free()
		return
	var before := health.current

	var profile: SpellProfile = load(LIGHTNING_PROFILE) as SpellProfile
	caster.try_cast("secondary")
	_step(caster, profile.windup_time * 1.1)
	if caster.phase != CASTER.Phase.RELEASE and caster.phase != CASTER.Phase.RECOVER:
		_fail("a timed lightning cast did not reach release after its own windup_time")

	var bolt: Node3D = null
	for child in get_children():
		if "travel_speed_mps" in child:
			bolt = child
			break
	if bolt == null:
		_fail("casting lightning at a target produced no LightningBolt")
	elif before - health.current < 1.0:
		_fail("the target's health barely moved: %.1f -> %.1f" % [before, health.current])
	else:
		print("  end to end: a timed lightning cast hits its target for %.1f damage and spawns a bolt"
			% (before - health.current))

	Targeting.clear()
	witch.free()
	caster.free()
	attacks.free()
	if bolt and is_instance_valid(bolt):
		bolt.free()
