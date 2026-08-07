extends Node

## Cast state machine. Owns *timing and intent* only — it deliberately knows
## nothing about what a spell does.
##
## A cast runs through three timed phases:
##
##   WINDUP   arms draw back, energy gathers   -> cast_started
##   RELEASE  arms thrust out, spell leaves    -> cast_released(origin, direction)
##   RECOVER  arms settle back to locomotion   -> cast_finished
##
## Anything that wants to *do* something (spawn a projectile, apply damage,
## drain mana, check a cooldown of its own) connects to [signal cast_released]
## and reads the origin/direction handed to it. That is the single seam between
## this animation-facing code and whatever rules system comes later, so the
## rules can be rewritten repeatedly without touching the character at all.

## Fired the instant a cast begins. Nothing has left the hands yet.
signal cast_started
## Fired at the top of RELEASE — this is the moment a projectile should spawn.
## [param origin] is the world position of the casting hand.
signal cast_released(origin: Vector3, direction: Vector3)
## Fired once RECOVER ends and the character is free again.
signal cast_finished

enum Phase { READY, WINDUP, RELEASE, RECOVER, COOLDOWN }

@export_group("Timing")
## Arms drawing back. Longer reads as a heavier spell.
@export_range(0.05, 3.0, 0.01) var windup_time := 0.30
## The thrust itself. Short and sharp; this is the "hit" of the animation.
@export_range(0.02, 1.0, 0.01) var release_time := 0.14
## Settling back. Overlaps with being able to move again.
@export_range(0.0, 2.0, 0.01) var recover_time := 0.32
## Dead time after recovery before another cast is accepted.
@export_range(0.0, 5.0, 0.05) var cooldown_time := 0.15

@export_group("Behaviour")
## Movement multiplier while a cast is in flight. 0 roots the caster, 1 lets
## them cast at full speed. Rooted casting is the usual ARPG feel, but this is
## exactly the kind of thing worth trying both ways.
@export_range(0.0, 1.0, 0.05) var move_scale_while_casting := 0.25
## Whether the character snaps to face the aim point for the duration.
@export var face_aim_while_casting := true
## Queue a cast pressed slightly too early rather than dropping it. Makes
## repeated casting feel responsive instead of eating inputs.
@export_range(0.0, 0.5, 0.01) var input_buffer := 0.15
## Bone the spell is considered to leave from. `handslot.r` is an attachment
## point the Mage rig already provides for held items.
@export var cast_bone := "handslot.r"

var phase: Phase = Phase.READY
## 0..1 blend of the cast pose over locomotion. The animator reads this.
var weight := 0.0
## 0 = drawn back (windup), 1 = thrust out (release). The animator reads this.
var extend := 0.0

var _timer := 0.0
var _buffered := 0.0
var _skeleton: Skeleton3D = null
var _bone_id := -1


func _ready() -> void:
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


## Request a cast. Returns true if it started or was buffered.
func try_cast() -> bool:
	if phase == Phase.READY:
		_begin_windup()
		return true
	# Late in the cast, buffer instead of dropping the press.
	if phase == Phase.RECOVER or phase == Phase.COOLDOWN:
		_buffered = input_buffer
		return true
	return false


## True while the character is committed to a cast (windup or release).
func is_casting() -> bool:
	return phase == Phase.WINDUP or phase == Phase.RELEASE


## Movement multiplier the controller should apply this frame.
func get_move_scale() -> float:
	return move_scale_while_casting if is_casting() else 1.0


## World transform of the casting hand, for spawning effects and projectiles.
func get_cast_origin() -> Vector3:
	if _skeleton and _bone_id != -1:
		return (_skeleton.global_transform * _skeleton.get_bone_global_pose(_bone_id)).origin
	var body := get_parent() as Node3D
	return body.global_position + Vector3.UP * 1.2 if body else Vector3.ZERO


func _begin_windup() -> void:
	phase = Phase.WINDUP
	_timer = 0.0
	extend = 0.0
	cast_started.emit()


func _advance(delta: float) -> void:
	if phase == Phase.READY:
		return
	_timer += delta
	match phase:
		Phase.WINDUP:
			if _timer >= windup_time:
				_timer -= windup_time
				phase = Phase.RELEASE
				var body := get_parent() as Node3D
				var dir := Vector3.FORWARD
				if body and "aim_direction" in body:
					dir = body.aim_direction
				cast_released.emit(get_cast_origin(), dir)
		Phase.RELEASE:
			if _timer >= release_time:
				_timer -= release_time
				phase = Phase.RECOVER
		Phase.RECOVER:
			if _timer >= recover_time:
				_timer -= recover_time
				phase = Phase.COOLDOWN
				cast_finished.emit()
		Phase.COOLDOWN:
			if _timer >= cooldown_time:
				phase = Phase.READY
				_timer = 0.0
				if _buffered > 0.0:
					_buffered = 0.0
					_begin_windup()


## Turns the phase + timer into the two smooth 0..1 values the animator poses
## from. Kept here so the animator stays a pure consumer.
func _update_pose_values(delta: float) -> void:
	var weight_goal := 0.0
	var extend_goal := 0.0
	match phase:
		Phase.WINDUP:
			# Ease in over the windup so the arms lift rather than snap.
			weight_goal = clampf(_timer / maxf(windup_time, 0.001), 0.0, 1.0)
			extend_goal = 0.0
		Phase.RELEASE:
			weight_goal = 1.0
			extend_goal = clampf(_timer / maxf(release_time, 0.001), 0.0, 1.0)
		Phase.RECOVER:
			weight_goal = 1.0 - clampf(_timer / maxf(recover_time, 0.001), 0.0, 1.0)
			extend_goal = 1.0
		_:
			weight_goal = 0.0
			extend_goal = 0.0

	# The thrust snaps out fast and eases back; the overall blend is smoothed
	# both ways so entering and leaving a cast never pops.
	var w := 1.0 - exp(-delta / 0.06)
	weight = lerpf(weight, weight_goal, w)
	extend = lerpf(extend, extend_goal, 1.0 - exp(-delta / 0.045))


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
