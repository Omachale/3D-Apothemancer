extends Node3D

## Checks that a drawn bow actually produces an arrow — the seams between the cast
## state machine, the loadout, the physics and the projectile.
##
## THE PIECES WERE EACH VERIFIED IN ISOLATION AND THAT IS NOT THE SAME THING. The
## energy model, the launch solver and the arrow all pass their own suites; what
## those cannot catch is a profile whose windup mode disagrees with its aim mode, a
## loadout nobody found, or a charge that never reaches the shot. Every check below
## drives the real nodes through a real draw and release.
##
## This node stands in for the player: it parents the caster, answers
## get_charge_fraction by delegating to the loadout exactly as
## player_controller.gd does, and supplies a get_aim_target for free aim. The real
## delegation is checked separately against the shipped Player scene.
##
##   Godot --headless res://scenes/dev/VerifyArcheryWiring.tscn
## Exits non-zero if any check fails.

const CASTER := preload("res://scripts/player/spell_caster.gd")
const ATTACKS := preload("res://scripts/player/player_attacks.gd")
const LOADOUT := preload("res://scripts/combat/archery_loadout.gd")
const ANIMATOR := preload("res://scripts/player/player_animator.gd")
const AP := preload("res://scripts/combat/archery_physics.gd")
const PLAYER_SCENE := preload("res://scenes/player/Player.tscn")
const BOW_PROFILE := "res://resources/spells/bow_shot.tres"

const STEP := 1.0 / 120.0

var _failures := 0
## Set while a harness is assembled, so get_charge_fraction has something to
## delegate to — see the class note.
var _loadout: ArcheryLoadout = null
var _aim_target := Vector3(0.0, 0.5, 30.0)


func _ready() -> void:
	_check_loadout_answers_only_when_equipped()
	_check_pull_and_hold_time_agree()
	_check_caster_falls_back_when_the_owner_declines()
	_check_caster_uses_the_owner_when_it_answers()
	_check_shipped_profile_is_coherent()
	_check_player_scene_is_wired()
	_check_a_full_draw_looses_an_arrow()
	_check_a_flicked_draw_looses_nothing()
	_check_animator_knows_the_draw()
	if _failures == 0:
		print("ALL ARCHERY WIRING CHECKS PASSED")
	else:
		print("VERIFY ARCHERY WIRING: FAIL (%d)" % _failures)
	get_tree().quit(1 if _failures > 0 else 0)


func _fail(message: String) -> void:
	print("  FAIL: %s" % message)
	_failures += 1


## Mirrors player_controller.gd — see the class note.
func get_charge_fraction(hold_time: float) -> float:
	return _loadout.charge_fraction(hold_time) if _loadout else -1.0


func get_aim_target() -> Vector3:
	return _aim_target


# ---------------------------------------------------------------------------
# HARNESS
# ---------------------------------------------------------------------------

func _make_loadout(equipped := true) -> ArcheryLoadout:
	var loadout: ArcheryLoadout = LOADOUT.new()
	loadout.name = "ArcheryLoadout"
	if equipped:
		loadout.bow = load("res://resources/archery/bow_recurve.tres") as Bow
		loadout.arrow = load("res://resources/archery/arrow_standard.tres") as ArrowSpec
	add_child(loadout)
	_loadout = loadout
	return loadout


## A caster and an attacks node parented to this one, with the bow bound to the
## secondary slot, driven by hand so the draw length is exact.
func _make_archer() -> Dictionary:
	var loadout := _make_loadout()
	var caster: Node = CASTER.new()
	caster.name = "SpellCaster"
	caster.secondary_profile = load(BOW_PROFILE) as SpellProfile
	add_child(caster)
	caster.set_process(false)
	var attacks: Node = ATTACKS.new()
	attacks.name = "PlayerAttacks"
	add_child(attacks)
	return {"caster": caster, "attacks": attacks, "loadout": loadout}


## Frees immediately rather than queueing, and that is load-bearing. These checks
## run synchronously inside one _ready, so a queue_free()d node is still a child
## when the next check builds its own — whereupon add_child RENAMES the new one to
## avoid the clash, and PlayerAttacks' get_node("ArcheryLoadout") resolves to the
## stale, discarded, unequipped one. That cost a failing test that looked exactly
## like a broken product.
func _teardown(archer: Dictionary) -> void:
	(archer["attacks"] as Node).free()
	(archer["caster"] as Node).free()
	(archer["loadout"] as Node).free()
	_loadout = null
	for child in get_children():
		if "muzzle_energy_j" in child:
			child.free()


## Returns the time actually stepped, which is a whole number of STEPs and so
## slightly over what was asked for — a caller comparing against a formula needs
## the real figure, not the request.
func _step(caster: Node, seconds: float) -> float:
	var elapsed := 0.0
	while elapsed < seconds:
		caster._process(STEP)
		elapsed += STEP
	return elapsed


## Any arrow currently parented to this node.
func _find_arrow() -> Node3D:
	for child in get_children():
		if "muzzle_energy_j" in child:
			return child as Node3D
	return null


# ---------------------------------------------------------------------------
# CHECKS
# ---------------------------------------------------------------------------

## Declining with -1 is the contract that lets an unequipped archer fall back to
## the profile's clock instead of being stuck at never-drawn or always-full.
func _check_loadout_answers_only_when_equipped() -> void:
	var empty := _make_loadout(false)
	if empty.is_ready_to_shoot():
		_fail("an empty loadout claimed it was ready to shoot")
	if empty.charge_fraction(1.0) >= 0.0:
		_fail("an empty loadout answered %.3f instead of declining with -1"
			% empty.charge_fraction(1.0))
	if empty.solve_at_pull(1.0)["muzzle_velocity_ms"] != 0.0:
		_fail("an empty loadout produced a live shot")
	empty.free()
	_loadout = null

	var full := _make_loadout()
	if not full.is_ready_to_shoot():
		_fail("the shipped recurve and standard arrow were not ready to shoot")
	var half := full.charge_fraction(full.time_to_full_draw() * 0.5)
	if absf(half - 0.5) > 0.02:
		_fail("half the draw time gave a pull of %.3f, expected ~0.5" % half)
	if not is_equal_approx(full.draw_ceiling(), 1.0):
		_fail("the default archer could not fully draw the default bow (%.3f)"
			% full.draw_ceiling())
	else:
		print("  loadout: declines when empty, reaches full draw in %.2f s when equipped"
			% full.time_to_full_draw())
	full.free()
	_loadout = null


## The refactor that split pull out of the shot solve must not have changed any
## number, since the calibration rests on them.
func _check_pull_and_hold_time_agree() -> void:
	var bow := load("res://resources/archery/bow_recurve.tres") as Bow
	var arrow := load("res://resources/archery/arrow_standard.tres") as ArrowSpec
	for hold in [0.2, 0.7, 1.4, 30.0]:
		var by_time: Dictionary = AP.solve_shot(bow, arrow, 10.0, 10.0, hold)
		var by_pull: Dictionary = AP.solve_shot_at_pull(
			bow, arrow, 10.0, AP.pull_fraction(hold, bow.draw_weight_kg, 10.0, 10.0))
		for key in by_time:
			if absf(by_time[key] - by_pull[key]) > 0.000001:
				_fail("solving by pull disagreed on '%s' at a %.1f s hold: %.6f vs %.6f"
					% [key, hold, by_pull[key], by_time[key]])
				return
	print("  refactor: solving from a pull matches solving from a hold time exactly")


func _check_caster_falls_back_when_the_owner_declines() -> void:
	_loadout = _make_loadout(false)
	var caster: Node = CASTER.new()
	caster.secondary_profile = load(BOW_PROFILE) as SpellProfile
	add_child(caster)
	caster.set_process(false)
	caster.try_cast("secondary")
	# The profile's own windup_time is 1.33 s, so half of that is a half charge.
	_step(caster, 0.665)
	if absf(caster.charge - 0.5) > 0.03:
		_fail("with the owner declining, charge was %.3f after half the profile's windup"
			% caster.charge)
	else:
		print("  fallback: an unequipped archer charges on the profile's own clock")
	caster.free()
	_loadout.free()
	_loadout = null


func _check_caster_uses_the_owner_when_it_answers() -> void:
	var archer := _make_archer()
	var caster: Node = archer["caster"]
	var loadout: ArcheryLoadout = archer["loadout"]
	# Deliberately made a clumsy archer, so the bow's draw time is nowhere near the
	# profile's fallback. The shipped profile's windup_time is set to roughly what
	# the default archer takes on the default bow — sensible as a fallback, useless
	# for telling the two clocks apart, so the test moves the loadout instead of
	# asking the shipped data to be inconsistent.
	loadout.archery = 0.0
	var full_at := loadout.time_to_full_draw()
	var profile: SpellProfile = load(BOW_PROFILE) as SpellProfile
	if absf(full_at - profile.windup_time) < 0.2:
		_fail("the test cannot tell the two clocks apart: %.3f s against %.3f s"
			% [full_at, profile.windup_time])
		_teardown(archer)
		return

	caster.try_cast("secondary")
	var held := _step(caster, full_at * 0.5)
	# The claim is AGREEMENT WITH THE LOADOUT, not any particular number. Half the
	# draw TIME is deliberately not half the draw: this archer's pull capacity caps
	# them below full draw whatever they do, so progress and ceiling multiply. That
	# is the model working (verify_archery_physics checks it directly) and asserting
	# 0.5 here would be asserting the model is wrong.
	var expected := loadout.charge_fraction(held)
	var profile_clock := held / profile.windup_time
	if absf(caster.charge - expected) > 0.002:
		_fail("the caster read %.4f where the loadout says %.4f" % [caster.charge, expected])
	elif absf(caster.charge - profile_clock) < 0.05:
		_fail("cannot tell the clocks apart: loadout %.3f, profile would give %.3f"
			% [expected, profile_clock])
	else:
		print("  equipment: %.3f charge after %.2f s — the bow's answer, not the profile's %.3f"
			% [caster.charge, held, profile_clock])
	_teardown(archer)


func _check_shipped_profile_is_coherent() -> void:
	var profile := load(BOW_PROFILE) as SpellProfile
	if profile == null:
		_fail("%s did not load as a SpellProfile" % BOW_PROFILE)
		return
	if not profile.is_charged():
		_fail("the bow profile is not a CHARGED windup")
	if profile.aim_mode != SpellProfile.AimMode.BALLISTIC:
		_fail("the bow profile does not use BALLISTIC aim")
	if not profile.charge_duration_from_owner:
		_fail("the bow profile does not defer its draw time to the loadout")
	if profile.shows_cast_glow:
		_fail("the bow profile would put a glowing orb in the archer's fist")
	if profile.projectile_scene == null:
		_fail("the bow profile has no arrow to loose")
	if profile.buffers_input():
		_fail("the bow profile would buffer a draw")
	if _failures == 0:
		print("  profile: charged, ballistic, equipment-timed, unglowing, unbuffered")


## The shipped player, rather than this node's stand-in: the real delegation and
## the real slots.
func _check_player_scene_is_wired() -> void:
	var player: Node3D = PLAYER_SCENE.instantiate()
	add_child(player)
	var loadout := player.get_node_or_null("ArcheryLoadout") as ArcheryLoadout
	if loadout == null:
		_fail("the Player scene has no ArcheryLoadout")
	elif not loadout.is_ready_to_shoot():
		_fail("the Player scene's loadout has no bow or arrow equipped")
	if not player.has_method("get_charge_fraction"):
		_fail("the Player does not answer get_charge_fraction")
	else:
		var answered: float = player.get_charge_fraction(10.0)
		if answered < 0.0:
			_fail("the shipped Player declined to report a draw fraction")
		elif not is_equal_approx(answered, 1.0):
			_fail("a ten-second hold reported %.3f draw, expected full" % answered)
	var caster := player.get_node_or_null("SpellCaster")
	if caster == null:
		_fail("the Player scene has no SpellCaster")
	elif caster.secondary_profile == null or caster.secondary_profile.id != &"bow_shot":
		_fail("the bow is not bound to the secondary cast slot")
	else:
		print("  player scene: bow on secondary, loadout equipped, delegation live")
	player.free()


## The whole path, end to end.
func _check_a_full_draw_looses_an_arrow() -> void:
	var archer := _make_archer()
	var caster: Node = archer["caster"]
	var loadout: ArcheryLoadout = archer["loadout"]
	var expected := loadout.solve_at_pull(1.0)

	caster.try_cast("secondary")
	_step(caster, loadout.time_to_full_draw() * 1.5)
	if not is_equal_approx(caster.charge, 1.0):
		_fail("holding past full draw gave a charge of %.3f" % caster.charge)
	caster.release_charge("secondary")

	var arrow := _find_arrow()
	if arrow == null:
		_fail("a full draw released produced no arrow")
		_teardown(archer)
		return
	if absf(arrow.muzzle_energy_j - expected["muzzle_energy_j"]) > 0.01:
		_fail("the arrow carries %.2f J but the shot solved to %.2f J"
			% [arrow.muzzle_energy_j, expected["muzzle_energy_j"]])
	if absf(arrow.drag_decay - expected["decay"]) > 0.000001:
		_fail("the arrow's drag decay does not match the shot's")
	if absf(arrow.current_damage() - expected["impact_damage"]) > 0.01:
		_fail("the fresh arrow would do %.2f damage against the shot's %.2f"
			% [arrow.current_damage(), expected["impact_damage"]])
	# Free aim with a target 30 m out must produce an ARC, not a flat line: the
	# arrow has to leave above the horizontal to come down on the mark.
	var forward := -arrow.global_transform.basis.z
	if forward.y <= 0.0:
		_fail("a 30 m free-aim shot left flat or downward (pitch %.3f)" % forward.y)
	else:
		print("  end to end: full draw looses %.1f J at %.1f m/s for %.1f damage, pitched %+.2f up"
			% [arrow.muzzle_energy_j, expected["muzzle_velocity_ms"],
				arrow.current_damage(), forward.y])
	_teardown(archer)


## A tap must not drop an arrow at the archer's feet — that reads as a bug rather
## than as a weak shot.
func _check_a_flicked_draw_looses_nothing() -> void:
	var archer := _make_archer()
	var caster: Node = archer["caster"]
	caster.try_cast("secondary")
	_step(caster, 0.01)
	caster.release_charge("secondary")
	if _find_arrow() != null:
		_fail("a 0.01 s draw loosed an arrow anyway")
	else:
		print("  flick: a draw with no energy in it looses nothing")
	_teardown(archer)


func _check_animator_knows_the_draw() -> void:
	var animator: Node = ANIMATOR.new()
	animator.call("_build_pose_sets")
	var sets: Dictionary = animator.get("_pose_sets")
	if not sets.has(&"draw_bow"):
		_fail("the animator has no draw_bow pose set")
		animator.free()
		return
	var bow: Dictionary = sets[&"draw_bow"]
	# The bow arm holds still while the string arm travels — if both moved the
	# same way the draw would read as pantomime.
	if bow["windup_arm_l"] != bow["charged_arm_l"]:
		_fail("the bow arm moves during the draw; it should hold the bow steady")
	if bow["windup_arm_r"] == bow["charged_arm_r"]:
		_fail("the string arm does not move during the draw")
	# And the pre-existing spell pose must still be symmetric, as it was before
	# per-arm poses existed.
	var bolt: Dictionary = sets[&"bolt"]
	if bolt["windup_arm_l"] != bolt["windup_arm_r"] \
			or bolt["release_arm_l"] != bolt["release_arm_r"]:
		_fail("the bolt pose stopped being symmetric")
	elif bolt["windup_arm_l"] != bolt["charged_arm_l"]:
		_fail("the bolt pose now moves with charge; it did not before")
	else:
		print("  animation: draw_bow moves only the string arm, bolt unchanged")
	animator.free()
