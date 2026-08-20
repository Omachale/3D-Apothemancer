extends Node

## Cast state machine. Owns *timing and intent* only — it deliberately knows
## nothing about what a spell does.
##
## A cast runs through three phases:
##
##   WINDUP   arms draw back, energy gathers   -> cast_started
##   RELEASE  arms thrust out, spell leaves    -> cast_released(origin, dir, charge)
##   RECOVER  arms settle back to locomotion   -> cast_finished
##
## Anything that wants to *do* something (spawn a projectile, apply damage,
## drain mana, check a cooldown of its own) connects to [signal cast_released]
## and reads what it is handed. That is the single seam between this
## animation-facing code and whatever rules system comes later, so the rules can
## be rewritten repeatedly without touching the character at all.
##
## TIMING AND SHAPE COME FROM A [SpellProfile], not from this node. Every spell
## carries its own durations, its own animation tag and its own windup shape;
## this class executes whichever profile the current cast named. See
## spell_profile.gd for why that indirection exists.
##
## THE WINDUP HAS TWO SHAPES and that is the whole reason profiles arrived.
## A TIMED windup ends on a clock, as every cast did before. A CHARGED windup
## ends only when [method release_charge] is called — the player letting go —
## and the [member charge] it reached travels with the shot. Everything after
## WINDUP is identical for both, which is exactly the point: the two shapes
## share the state machine rather than each having one.
##
## WEIGHT, CHARGE AND EXTEND ARE THREE DIFFERENT THINGS. They used to be two,
## because a fixed windup let "how blended-in is the cast pose" and "how far
## through the windup are we" ramp together. A two-second draw separates them:
## the pose must blend in quickly and then hold, while the draw itself creeps
## up over the whole hold. Consumers read whichever they actually mean —
## see the members below.

## Fired the instant a cast begins. Nothing has left the hands yet.
signal cast_started
## Fired at the top of RELEASE — this is the moment a projectile should spawn.
## [param origin] is the world position of the casting hand. [param charge] is
## how far the windup got, 0..1; always 1.0 for a timed cast, so a listener that
## does not care about charging can ignore it.
signal cast_released(origin: Vector3, direction: Vector3, charge: float)
## Fired once RECOVER ends and the character is free again.
signal cast_finished
## Fired when a cast is abandoned before anything left the hands — see
## [method cancel]. Deliberately NOT followed by cast_finished: nothing was
## cast, so a listener counting shots must not see this as one.
signal cast_cancelled

enum Phase { READY, WINDUP, RELEASE, RECOVER, COOLDOWN }

## How long the cast POSE takes to blend in on a charged cast, in seconds.
##
## A timed cast blends its pose in over its whole windup, which is short. A
## charged windup can run for seconds, and ramping the pose across all of it
## would leave the character barely in a casting stance for most of the draw.
## So the pose blends in over this fixed, short duration instead and then holds,
## while [member charge] carries the actual draw progress.
const CHARGED_POSE_BLEND_IN := 0.25

@export_group("Spells")
## Profile cast by the "primary" tag. Falls back to the timing exports below
## when unset.
@export var primary_profile: SpellProfile = null
## Profile cast by the "secondary" tag.
@export var secondary_profile: SpellProfile = null

@export_group("Fallback timing")
## Used only when the cast tag resolves to no profile at all.
##
## KEPT RATHER THAN DELETED so this node is still usable bare — the verify
## suites build a SpellCaster with nothing attached and drive it directly, and
## a class that cannot run without an authored resource would be much harder to
## test. These feed an internal profile built once in [method _ready], so the
## rest of this file never branches on "is there a profile".
@export_range(0.05, 3.0, 0.01) var windup_time := 0.30
@export_range(0.02, 1.0, 0.01) var release_time := 0.14
@export_range(0.0, 2.0, 0.01) var recover_time := 0.32
@export_range(0.0, 5.0, 0.05) var cooldown_time := 0.15
@export_range(0.0, 1.0, 0.05) var move_scale_while_casting := 0.25

@export_group("Behaviour")
## How long a too-early press stays queued. WHETHER a given spell queues at all
## is the profile's call — see [method SpellProfile.buffers_input].
@export_range(0.0, 0.5, 0.01) var input_buffer := 0.15
## Bone the spell is considered to leave from. `handslot.r` is an attachment
## point the Mage rig already provides for held items.
@export var cast_bone := "handslot.r"

var phase: Phase = Phase.READY
## 0..1 blend of the cast pose over locomotion. How much the character looks
## like it is casting at all — NOT how far through the cast it is.
var weight := 0.0
## 0..1 windup progress: how far the energy gathered, or how far the string was
## drawn. Rises through WINDUP and then HOLDS its released value through the
## rest of the cast, so anything reading it after release sees what was
## actually fired rather than a value already decaying back to zero.
var charge := 0.0
## 0 = drawn back (windup), 1 = thrust out (release). The animator reads this.
var extend := 0.0
## Which spell is in flight through the current cast — the tag try_cast() was
## given. Kept alongside [member current_profile] because input maps to tags,
## not to resources: the controller knows the player pressed "secondary", not
## which resource that currently resolves to.
var current_spell: String = "primary"
## The profile being executed. Never null while a cast is running.
var current_profile: SpellProfile = null

var _timer := 0.0
var _buffered := 0.0
var _buffered_spell: String = "primary"
var _fallback_profile: SpellProfile = null
var _skeleton: Skeleton3D = null
var _bone_id := -1


func _ready() -> void:
	_fallback_profile = _build_fallback_profile()
	current_profile = _fallback_profile
	var body := get_parent()
	_skeleton = _find_skeleton(body)
	if _skeleton:
		_bone_id = _skeleton.find_bone(cast_bone)
	if _bone_id == -1:
		push_warning("SpellCaster: bone '%s' not found; cast origin falls back to the body." % cast_bone)


func _process(delta: float) -> void:
	_buffered = maxf(0.0, _buffered - delta)
	_advance(delta)
	_update_pose_values(delta)


## Request a cast. [param spell] is a tag resolved to a profile by
## [method _profile_for]. Returns true if it started or was buffered.
func try_cast(spell: String = "primary") -> bool:
	if phase == Phase.READY:
		_begin_windup(spell)
		return true
	# Late in the cast, buffer instead of dropping the press — but only for a
	# profile that wants that. See SpellProfile.buffers_input for why a charged
	# cast must not.
	if phase == Phase.RECOVER or phase == Phase.COOLDOWN:
		if not _profile_for(spell).buffers_input():
			return false
		_buffered = input_buffer
		_buffered_spell = spell
		return true
	return false


## The player let go. Ends a CHARGED windup and fires at whatever charge was
## reached; a no-op in every other situation, so a stray release event costs
## nothing.
##
## [param spell] guards against the wrong button ending a draw: pass the tag
## whose input was released and a mismatch is ignored. Empty accepts any.
##
## Returns true if this actually loosed a shot.
func release_charge(spell: String = "") -> bool:
	if not is_charging():
		return false
	if spell != "" and spell != current_spell:
		return false
	charge = _compute_charge(_timer)
	_timer = 0.0
	_begin_release()
	return true


## Reassigns which profile a cast tag resolves to — the seam the character
## screen equips through. Safe to call mid-cast: [member current_profile] was
## already snapshotted by [method _begin_windup] and is not re-read from
## [member primary_profile]/[member secondary_profile] until the NEXT cast
## begins, so swapping a slot never glitches whatever is already in flight.
func set_profile(spell: String, profile: SpellProfile) -> void:
	if spell == "primary":
		primary_profile = profile
	elif spell == "secondary":
		secondary_profile = profile
	else:
		push_warning("SpellCaster.set_profile: unknown slot '%s'" % spell)


## Abandon the cast without firing. For anything that interrupts mid-cast —
## death, a heavy hit, swapping weapons — which a long charged draw makes
## genuinely likely rather than theoretical.
func cancel() -> void:
	if phase == Phase.READY:
		return
	phase = Phase.READY
	_timer = 0.0
	charge = 0.0
	extend = 0.0
	_buffered = 0.0
	cast_cancelled.emit()


## True while the character is committed to a cast (windup or release).
func is_casting() -> bool:
	return phase == Phase.WINDUP or phase == Phase.RELEASE


## True while a charged windup is waiting on the player to let go.
func is_charging() -> bool:
	return phase == Phase.WINDUP and current_profile != null and current_profile.is_charged()


## Movement multiplier the controller should apply this frame.
func get_move_scale() -> float:
	if not is_casting():
		return 1.0
	return current_profile.move_scale_while_casting if current_profile else move_scale_while_casting


## Whether the character should be turned to face its aim point right now.
## Read as a method rather than a property because the answer is per-spell and
## so lives on the profile.
func wants_face_aim() -> bool:
	return current_profile.face_aim_while_casting if current_profile else true


## Animation tag of the cast in flight — see [member SpellProfile.animation_tag].
func get_animation_tag() -> StringName:
	return current_profile.animation_tag if current_profile else &"bolt"


## World transform of the casting hand, for spawning effects and projectiles.
func get_cast_origin() -> Vector3:
	if _skeleton and _bone_id != -1:
		return (_skeleton.global_transform * _skeleton.get_bone_global_pose(_bone_id)).origin
	var body := get_parent() as Node3D
	return body.global_position + Vector3.UP * 1.2 if body else Vector3.ZERO


## The profile a cast tag resolves to. Never returns null — an unassigned slot
## falls back to the timing exports, so an unconfigured caster still casts
## rather than silently doing nothing.
func _profile_for(spell: String) -> SpellProfile:
	if spell == "primary" and primary_profile != null:
		return primary_profile
	if spell == "secondary" and secondary_profile != null:
		return secondary_profile
	return _fallback_profile


func _begin_windup(spell: String) -> void:
	current_spell = spell
	current_profile = _profile_for(spell)
	phase = Phase.WINDUP
	_timer = 0.0
	charge = 0.0
	extend = 0.0
	cast_started.emit()


func _begin_release() -> void:
	phase = Phase.RELEASE
	var body := get_parent() as Node3D
	var origin := get_cast_origin()
	var dir := Vector3.FORWARD
	# Prefer the 3D aim point over the flattened direction, so a shot can travel
	# up or down. aim_direction is kept as the fallback for any caster whose
	# owner does not provide one.
	if body and body.has_method("get_aim_target"):
		dir = body.get_aim_target() - origin
	elif body and "aim_direction" in body:
		dir = body.aim_direction
	cast_released.emit(origin, dir, charge)


func _advance(delta: float) -> void:
	if phase == Phase.READY:
		return
	_timer += delta
	match phase:
		Phase.WINDUP:
			charge = _compute_charge(_timer)
			# A charged windup has no timeout at all: holding past full draw
			# simply sits at full. Only release_charge() gets out of here, which
			# is what makes the hold a decision rather than a countdown.
			if current_profile.is_charged():
				return
			if _timer >= _windup_duration():
				_timer -= _windup_duration()
				_begin_release()
		Phase.RELEASE:
			if _timer >= current_profile.release_time:
				_timer -= current_profile.release_time
				phase = Phase.RECOVER
		Phase.RECOVER:
			if _timer >= current_profile.recover_time:
				_timer -= current_profile.recover_time
				phase = Phase.COOLDOWN
				cast_finished.emit()
		Phase.COOLDOWN:
			if _timer >= current_profile.cooldown_time:
				phase = Phase.READY
				_timer = 0.0
				if _buffered > 0.0:
					_buffered = 0.0
					_begin_windup(_buffered_spell)


## How far along the windup is, 0..1, after holding for [param hold] seconds.
##
## A profile can hand this question to the caster's owner — see
## [member SpellProfile.charge_duration_from_owner], which is where a bow's draw
## weight and the player's strength enter. Everything else charges on its own
## clock, and the clamp means an owner returning nonsense cannot push charge
## outside 0..1 and corrupt a damage calculation downstream.
##
## AN OWNER MAY DECLINE by returning a NEGATIVE number, which falls back to the
## profile's own clock. That matters because the owner having the method and the
## owner being able to answer are different things — a player with no bow
## equipped cannot say how far a bow is drawn, and guessing 0 (never charges) or
## 1 (instantly full) would both be wrong.
func _compute_charge(hold: float) -> float:
	if current_profile and current_profile.charge_duration_from_owner:
		var body := get_parent()
		if body and body.has_method("get_charge_fraction"):
			var answer: float = body.get_charge_fraction(hold)
			if answer >= 0.0:
				return clampf(answer, 0.0, 1.0)
	return clampf(hold / maxf(_windup_duration(), 0.001), 0.0, 1.0)


func _windup_duration() -> float:
	return current_profile.windup_time if current_profile else windup_time


## Turns the phase + timer into the smooth values the animator and the cast
## effect pose from. Kept here so both stay pure consumers.
func _update_pose_values(delta: float) -> void:
	var weight_goal := 0.0
	var extend_goal := 0.0
	match phase:
		Phase.WINDUP:
			# Ease in so the arms lift rather than snap. A timed cast blends
			# across its whole (short) windup, exactly as before profiles
			# existed; a charged one blends over a fixed short window and then
			# holds, because its windup can run for seconds.
			var blend_over := _windup_duration()
			if current_profile and current_profile.is_charged():
				blend_over = CHARGED_POSE_BLEND_IN
			weight_goal = clampf(_timer / maxf(blend_over, 0.001), 0.0, 1.0)
			extend_goal = 0.0
		Phase.RELEASE:
			weight_goal = 1.0
			extend_goal = clampf(_timer / maxf(current_profile.release_time, 0.001), 0.0, 1.0)
		Phase.RECOVER:
			weight_goal = 1.0 - clampf(_timer / maxf(current_profile.recover_time, 0.001), 0.0, 1.0)
			extend_goal = 1.0
		_:
			weight_goal = 0.0
			extend_goal = 0.0

	# The thrust snaps out fast and eases back; the overall blend is smoothed
	# both ways so entering and leaving a cast never pops.
	var w := 1.0 - exp(-delta / 0.06)
	weight = lerpf(weight, weight_goal, w)
	extend = lerpf(extend, extend_goal, 1.0 - exp(-delta / 0.045))


## The profile used when a cast tag resolves to nothing, assembled from this
## node's own exports so a bare SpellCaster behaves exactly as it did before
## profiles existed.
func _build_fallback_profile() -> SpellProfile:
	var profile := SpellProfile.new()
	profile.id = &"fallback"
	profile.windup_mode = SpellProfile.WindupMode.TIMED
	profile.windup_time = windup_time
	profile.release_time = release_time
	profile.recover_time = recover_time
	profile.cooldown_time = cooldown_time
	profile.move_scale_while_casting = move_scale_while_casting
	return profile


func _find_skeleton(node: Node) -> Skeleton3D:
	if node == null:
		return null
	for child in node.get_children():
		if child is Skeleton3D:
			return child
		var found := _find_skeleton(child)
		if found:
			return found
	return null
