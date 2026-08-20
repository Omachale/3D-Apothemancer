extends Node

## Checks the cast profile system in spell_profile.gd and spell_caster.gd.
##
## The claim under test is that ONE state machine runs two different windup
## shapes correctly: a timed windup that ends on a clock exactly as every cast
## did before profiles existed, and a charged windup that ends only when the
## player lets go. Those two are easy to get subtly wrong in ways nothing
## visible catches — a charged cast that quietly also times out still fires, and
## still looks fine, it just ignores the player.
##
## CASTERS ARE DRIVEN BY HAND, not by waiting on real time. Each one is added to
## the tree so _ready() runs and get_parent() resolves, then set_process(false)
## hands the clock over: _process is called directly with synthetic deltas. That
## makes every check instant and exactly reproducible, instead of depending on
## how many frames a headless run happens to fit into a real second.
##
## This node also stands in as the caster's OWNER, answering
## get_charge_fraction — which is how the equipment seam
## (SpellProfile.charge_duration_from_owner) is exercised without any bow
## existing yet. Only a profile that opts in ever calls it, which is itself one
## of the things checked below.
##
##   Godot --headless res://scenes/dev/VerifySpellProfiles.tscn
## Exits non-zero if any check fails.

const CASTER := preload("res://scripts/player/spell_caster.gd")

## Fixed simulation step. Small enough that phase boundaries land where the
## arithmetic says they should rather than being smeared across a coarse tick.
const STEP := 1.0 / 120.0
## How long the stand-in "equipment" takes to reach full charge. Deliberately
## unlike any profile's own windup_time below, so a test can tell which of the
## two actually answered.
const OWNER_CHARGE_SECONDS := 0.5

var _failures := 0
## Charge fractions carried by each cast_released seen since the last reset.
var _released: Array[float] = []


func _ready() -> void:
	_check_timed_windup_ends_on_its_timer()
	_check_charged_windup_ignores_the_clock()
	_check_charged_windup_ends_on_release()
	_check_charge_is_bounded_and_monotonic()
	_check_release_carries_the_charge_held()
	_check_cancel_fires_nothing()
	_check_release_charge_is_a_safe_no_op()
	_check_charged_casts_do_not_buffer()
	_check_owner_supplies_charge_duration_only_when_asked()
	_check_fallback_profile_still_casts()
	_check_damage_multiplier()
	if _failures == 0:
		print("ALL SPELL PROFILE CHECKS PASSED")
	else:
		print("VERIFY SPELL PROFILES: FAIL (%d)" % _failures)
	get_tree().quit(1 if _failures > 0 else 0)


func _fail(message: String) -> void:
	print("  FAIL: %s" % message)
	_failures += 1


## Stands in for the equipment that will eventually answer this — see
## [member SpellProfile.charge_duration_from_owner]. A real implementation will
## work it out from bow draw weight and player strength; this just needs to be
## distinguishable from the profile's own clock.
func get_charge_fraction(hold: float) -> float:
	return clampf(hold / OWNER_CHARGE_SECONDS, 0.0, 1.0)


# ---------------------------------------------------------------------------
# HARNESS
# ---------------------------------------------------------------------------

## A caster wired to [param profile] as its primary spell, with the engine's
## own _process disabled so [method _step] owns the clock.
##
## The "bone not found" warning this logs is expected and harmless: there is no
## skeleton here, and cast origin is not what these checks are about.
func _make_caster(profile: SpellProfile) -> Node:
	var caster: Node = CASTER.new()
	caster.primary_profile = profile
	add_child(caster)
	caster.set_process(false)
	caster.cast_released.connect(
		func(_origin: Vector3, _direction: Vector3, charge: float) -> void:
			_released.append(charge))
	_released.clear()
	return caster


func _step(caster: Node, seconds: float) -> void:
	var elapsed := 0.0
	while elapsed < seconds:
		caster._process(STEP)
		elapsed += STEP


func _timed_profile() -> SpellProfile:
	var profile := SpellProfile.new()
	profile.id = &"test_timed"
	profile.windup_mode = SpellProfile.WindupMode.TIMED
	profile.windup_time = 0.30
	profile.release_time = 0.10
	profile.recover_time = 0.20
	profile.cooldown_time = 0.10
	return profile


func _charged_profile() -> SpellProfile:
	var profile := SpellProfile.new()
	profile.id = &"test_charged"
	profile.windup_mode = SpellProfile.WindupMode.CHARGED
	profile.windup_time = 1.00
	profile.release_time = 0.10
	profile.recover_time = 0.20
	profile.cooldown_time = 0.10
	return profile


# ---------------------------------------------------------------------------
# CHECKS
# ---------------------------------------------------------------------------

## The regression case: a timed cast must behave exactly as it did before
## profiles existed.
func _check_timed_windup_ends_on_its_timer() -> void:
	var caster := _make_caster(_timed_profile())
	caster.try_cast("primary")
	_step(caster, 0.20)
	if caster.phase != CASTER.Phase.WINDUP:
		_fail("timed cast left WINDUP early (phase %d at 0.20s of a 0.30s windup)" % caster.phase)
	_step(caster, 0.15)
	if caster.phase == CASTER.Phase.WINDUP:
		_fail("timed cast was still in WINDUP after its 0.30s windup elapsed")
	elif _released.size() != 1:
		_fail("timed cast emitted %d releases, expected 1" % _released.size())
	else:
		print("  timed: holds through its windup, then fires on the clock")
	caster.queue_free()


## The whole point of the charged mode. A charged windup that also times out
## still fires and still looks correct — it just silently ignores the player,
## which is exactly the kind of bug nothing visible catches.
func _check_charged_windup_ignores_the_clock() -> void:
	var caster := _make_caster(_charged_profile())
	caster.try_cast("primary")
	# Ten times the profile's own windup_time. Nothing may fire.
	_step(caster, 10.0)
	if caster.phase != CASTER.Phase.WINDUP:
		_fail("charged cast left WINDUP on its own (phase %d after 10s held)" % caster.phase)
	elif not _released.is_empty():
		_fail("charged cast fired without the player releasing (%d releases)" % _released.size())
	else:
		print("  charged: held for 10s against a 1s windup_time, still drawn")
	caster.queue_free()


func _check_charged_windup_ends_on_release() -> void:
	var caster := _make_caster(_charged_profile())
	caster.try_cast("primary")
	_step(caster, 0.50)
	if not caster.is_charging():
		_fail("is_charging() was false midway through a charged windup")
	# The wrong button must not loose the shot.
	if caster.release_charge("secondary"):
		_fail("releasing the SECONDARY input fired a primary draw")
	if caster.phase != CASTER.Phase.WINDUP:
		_fail("a mismatched release tag ended the windup anyway")
	if not caster.release_charge("primary"):
		_fail("release_charge on a live charged windup returned false")
	if caster.phase != CASTER.Phase.RELEASE:
		_fail("release_charge did not enter RELEASE (phase %d)" % caster.phase)
	elif _released.size() != 1:
		_fail("release_charge emitted %d releases, expected 1" % _released.size())
	else:
		print("  charged: fires on release, and only for its own input tag")
	caster.queue_free()


func _check_charge_is_bounded_and_monotonic() -> void:
	var caster := _make_caster(_charged_profile())
	caster.try_cast("primary")
	var previous := -1.0
	var elapsed := 0.0
	while elapsed < 2.0:
		caster._process(STEP)
		elapsed += STEP
		var value: float = caster.charge
		if value < 0.0 or value > 1.0:
			_fail("charge left 0..1 at %.2fs: %.4f" % [elapsed, value])
			break
		if value < previous - 0.0001:
			_fail("charge fell at %.2fs: %.4f after %.4f" % [elapsed, value, previous])
			break
		previous = value
	# windup_time is 1.0 and this held for 2.0, so it must be pinned at full.
	if not is_equal_approx(caster.charge, 1.0):
		_fail("charge held past full reached %.4f, expected 1.0" % caster.charge)
	else:
		print("  charge: stays within 0..1, never falls, and caps at full")
	caster.queue_free()


## The number the whole charged mode exists to deliver. Held for a quarter of
## the full-charge time, the shot must carry about a quarter.
func _check_release_carries_the_charge_held() -> void:
	var caster := _make_caster(_charged_profile())
	caster.try_cast("primary")
	_step(caster, 0.25)
	caster.release_charge("primary")
	if _released.size() != 1:
		_fail("expected exactly one release, got %d" % _released.size())
	elif absf(_released[0] - 0.25) > 0.02:
		_fail("a 0.25s hold of a 1.0s draw reported charge %.4f" % _released[0])
	else:
		print("  release: carries the charge actually held (%.3f)" % _released[0])
	caster.queue_free()


func _check_cancel_fires_nothing() -> void:
	var caster := _make_caster(_charged_profile())
	var cancelled := [false]
	caster.cast_cancelled.connect(func() -> void: cancelled[0] = true)
	caster.try_cast("primary")
	_step(caster, 0.40)
	caster.cancel()
	if caster.phase != CASTER.Phase.READY:
		_fail("cancel() left the caster in phase %d, expected READY" % caster.phase)
	if not _released.is_empty():
		_fail("cancel() fired a shot anyway (%d releases)" % _released.size())
	if not cancelled[0]:
		_fail("cancel() did not emit cast_cancelled")
	if not is_zero_approx(caster.charge):
		_fail("cancel() left charge at %.4f, expected 0" % caster.charge)
	# And the caster must be usable again immediately.
	if not caster.try_cast("primary"):
		_fail("could not start a new cast after cancel()")
	else:
		print("  cancel: aborts to READY, fires nothing, and casting still works after")
	caster.queue_free()


## A stray release event, or one on a spell that does not charge at all, must
## cost nothing rather than short-circuiting a timed windup.
func _check_release_charge_is_a_safe_no_op() -> void:
	var caster := _make_caster(_timed_profile())
	if caster.release_charge("primary"):
		_fail("release_charge fired with nothing being cast")
	caster.try_cast("primary")
	_step(caster, 0.10)
	if caster.release_charge("primary"):
		_fail("release_charge cut a TIMED windup short")
	if caster.phase != CASTER.Phase.WINDUP:
		_fail("release_charge moved a timed cast out of WINDUP")
	elif not _released.is_empty():
		_fail("release_charge fired a timed cast early")
	else:
		print("  release_charge: a no-op when idle and on timed casts")
	caster.queue_free()


## A buffered draw would begin and end in the same breath and loose a dud —
## see SpellProfile.buffers_input.
func _check_charged_casts_do_not_buffer() -> void:
	var charged := _charged_profile()
	if charged.buffers_input():
		_fail("a charged profile reported that it buffers input")
	var timed := _timed_profile()
	if not timed.buffers_input():
		_fail("a timed profile with allow_input_buffer on refused to buffer")
	timed.allow_input_buffer = false
	if timed.buffers_input():
		_fail("a timed profile with allow_input_buffer off buffered anyway")

	# And end to end: a press during RECOVER must not queue for a charged spell.
	var caster := _make_caster(_charged_profile())
	caster.try_cast("primary")
	caster.release_charge("primary")
	_step(caster, 0.15)
	if caster.phase != CASTER.Phase.RECOVER:
		_fail("expected RECOVER 0.15s after release, got phase %d" % caster.phase)
	if caster.try_cast("primary"):
		_fail("a charged cast was buffered during RECOVER")
	else:
		print("  buffering: charged casts drop an early press instead of queueing a dud")
	caster.queue_free()


## The equipment seam. A profile that opts in must reach full charge on the
## OWNER's schedule; one that does not must ignore the owner entirely, even
## though the very same owner is sitting right there answering.
func _check_owner_supplies_charge_duration_only_when_asked() -> void:
	var asking := _charged_profile()
	asking.charge_duration_from_owner = true
	var caster := _make_caster(asking)
	caster.try_cast("primary")
	# OWNER_CHARGE_SECONDS is 0.5 against the profile's own 1.0, so at 0.5s the
	# two answers are unmistakably different: 1.0 versus 0.5.
	_step(caster, 0.50)
	if not is_equal_approx(snappedf(caster.charge, 0.01), 1.0):
		_fail("profile asked the owner for charge but got %.4f, expected full" % caster.charge)
	caster.queue_free()

	var not_asking := _charged_profile()
	var own_clock := _make_caster(not_asking)
	own_clock.try_cast("primary")
	_step(own_clock, 0.50)
	if absf(own_clock.charge - 0.50) > 0.02:
		_fail("profile charging on its own clock read %.4f, expected ~0.5" % own_clock.charge)
	else:
		print("  equipment seam: consulted only by profiles that opt in")
	own_clock.queue_free()


## A SpellCaster with nothing authored must still run a complete cast off its
## own exports — the verify suites depend on that, and so does anyone dropping
## the node in before writing a profile.
func _check_fallback_profile_still_casts() -> void:
	var caster: Node = CASTER.new()
	add_child(caster)
	caster.set_process(false)
	_released.clear()
	caster.cast_released.connect(
		func(_o: Vector3, _d: Vector3, charge: float) -> void: _released.append(charge))

	if not caster.try_cast("primary"):
		_fail("a caster with no profiles refused to cast")
	_step(caster, 0.05)
	if caster.phase != CASTER.Phase.WINDUP:
		_fail("fallback cast was not in WINDUP shortly after starting")
	# Default exports total 0.30 + 0.14 + 0.32 + 0.15 = 0.91s.
	_step(caster, 1.20)
	if caster.phase != CASTER.Phase.READY:
		_fail("fallback cast did not return to READY (phase %d)" % caster.phase)
	elif _released.size() != 1:
		_fail("fallback cast emitted %d releases, expected 1" % _released.size())
	elif not is_equal_approx(_released[0], 1.0):
		_fail("a timed fallback cast reported charge %.4f, expected 1.0" % _released[0])
	else:
		print("  fallback: an unconfigured caster still runs a full timed cast")
	caster.queue_free()


## Timed spells must be untouched by charge, so nothing downstream has to
## branch on the windup mode to work out whether a multiplier applies.
func _check_damage_multiplier() -> void:
	var timed := _timed_profile()
	timed.charge_damage_scale = Vector2(0.1, 9.0)
	if not is_equal_approx(timed.damage_multiplier_at(0.0), 1.0) \
			or not is_equal_approx(timed.damage_multiplier_at(1.0), 1.0):
		_fail("a TIMED profile applied charge_damage_scale anyway")

	var charged := _charged_profile()
	charged.charge_damage_scale = Vector2(0.5, 2.5)
	if not is_equal_approx(charged.damage_multiplier_at(0.0), 0.5):
		_fail("charged multiplier at zero charge was %.4f, expected 0.5"
			% charged.damage_multiplier_at(0.0))
	if not is_equal_approx(charged.damage_multiplier_at(1.0), 2.5):
		_fail("charged multiplier at full charge was %.4f, expected 2.5"
			% charged.damage_multiplier_at(1.0))
	if not is_equal_approx(charged.damage_multiplier_at(0.5), 1.5):
		_fail("charged multiplier at half charge was %.4f, expected 1.5"
			% charged.damage_multiplier_at(0.5))
	# Out-of-range input must clamp rather than extrapolate into nonsense.
	if not is_equal_approx(charged.damage_multiplier_at(4.0), 2.5):
		_fail("charge above 1.0 extrapolated the multiplier past its maximum")
	else:
		print("  damage: ignored by timed spells, lerped and clamped for charged ones")
