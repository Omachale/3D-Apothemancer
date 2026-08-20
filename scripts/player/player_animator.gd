extends Node

## Placeholder character animation, driven procedurally rather than by keyframes.
##
## Mage.glb ships with a rig but no animation clips, so instead of hand-authoring
## keyframes this poses the bones directly each frame. Two layers:
##
##   locomotion  a sine-driven walk cycle blended against an idle breathing pose
##   cast        a windup/thrust pose layered over the arms and torso
##
## To swap in real animations: drop an AnimationPlayer + AnimationTree on the
## Player scene, delete this node, and drive the tree from
## PlayerController.state_changed and SpellCaster's signals.
##
## AXES. Poses below are written in the model's *rest* space and converted into
## each bone's own space via [member _bone_to_local], so nothing here assumes a
## particular rig convention. In that rest space:
##
##   +Z is forward (the toe bones point that way)
##   +Y is up
##   the arms are in a T-pose, extending along +X (left) and -X (right)
##
## That last point matters. Because an arm lies *along* X, rotating it about X
## rolls it along its own length instead of swinging it — so arms swing about
## Y (forward/back) and lift about Z, while the legs, which hang along -Y, do
## swing about X. Use [method _pose_arm] rather than rotating an arm directly.

@export_group("Blending")
## Roughly how long a state change takes to read on screen.
@export_range(0.02, 0.5, 0.01) var blend_time := 0.12

@export_group("Rest pose")
## The rig's bind pose is a T-pose. This drops the arms to a natural hang;
## everything else is measured from the result.
@export_range(0.0, 1.6, 0.01) var arm_rest_lower := 1.22
## A touch forward of straight-down, so the silhouette is not a flat cross.
@export_range(-0.5, 0.8, 0.01) var arm_rest_forward := 0.10
@export_range(0.0, 1.0, 0.01) var arm_rest_elbow := 0.12

@export_group("Walk cycle")
## Distance covered by one full cycle (two steps). Sets the step rate.
@export_range(0.5, 6.0, 0.1) var stride_length := 2.4
@export_range(0.0, 1.5, 0.01) var walk_leg_swing := 0.42
@export_range(0.0, 1.5, 0.01) var run_leg_swing := 0.70
@export_range(0.0, 1.5, 0.01) var walk_arm_swing := 0.34
@export_range(0.0, 1.5, 0.01) var run_arm_swing := 0.62
## Arms lift away from the body as the pace picks up.
@export_range(0.0, 1.0, 0.01) var run_arm_lift := 0.30
@export_range(0.0, 2.0, 0.01) var knee_bend := 0.55
@export_range(0.0, 0.5, 0.005) var body_bob := 0.06
## Forward lean while running, in radians.
@export_range(0.0, 0.6, 0.01) var run_lean := 0.16

@export_group("Idle")
@export_range(0.0, 0.3, 0.005) var breath_amount := 0.035
@export_range(0.1, 3.0, 0.05) var breath_speed := 1.1

@export_group("Cast pose")
## Arms at the START of the windup: hands drawn in toward the chest, elbows
## folded. (lower, forward, elbow) in radians — see [method _pose_arm].
@export var cast_windup_arm := Vector3(0.34, 0.18, 1.50)
## Arms at full release: driven forward, elbows straightening. Kept a little
## below horizontal so the hat brim does not hide the hands from the gameplay
## camera, which looks down at 45 degrees.
@export var cast_release_arm := Vector3(0.20, 1.44, 0.14)
## Torso lean at windup (negative leans back) and at release.
@export_range(-0.6, 0.6, 0.01) var cast_windup_lean := -0.13
@export_range(-0.6, 0.6, 0.01) var cast_release_lean := 0.20
## How much the casting pose overrides the walk cycle's arm swing. Below 1 the
## arms keep a little of their stride while casting on the move.
@export_range(0.0, 1.0, 0.05) var cast_arm_authority := 1.0

@export_group("Wiring")
## Leave empty to auto-find the Skeleton3D and the model root under the player.
@export var skeleton_path: NodePath
@export var model_root_path: NodePath
@export var caster_path: NodePath

const BONES := {
	"hips": "hips",
	"spine": "spine",
	"chest": "chest",
	"head": "head",
	"upperleg_l": "upperleg.l",
	"lowerleg_l": "lowerleg.l",
	"upperleg_r": "upperleg.r",
	"lowerleg_r": "lowerleg.r",
	"upperarm_l": "upperarm.l",
	"lowerarm_l": "lowerarm.l",
	"upperarm_r": "upperarm.r",
	"lowerarm_r": "lowerarm.r",
}

var _skeleton: Skeleton3D = null
var _model_root: Node3D = null
var _body: CharacterBody3D = null
var _caster: Node = null
var _bone_ids := {}
## Per bone, the inverse of its global rest basis. Lets the poses above be
## written in one intuitive space and converted to whatever the rig's local
## bone orientation happens to be, instead of assuming one.
var _bone_to_local := {}
var _model_base_y := 0.0

## Cast pose sets keyed by [member SpellProfile.animation_tag], built in
## [method _ready] — see [method _build_pose_sets].
var _pose_sets: Dictionary = {}

var _phase := 0.0
var _time := 0.0
var _move_blend := 0.0
var _run_blend := 0.0


func _ready() -> void:
	_build_pose_sets()
	_body = get_parent() as CharacterBody3D
	_model_root = get_node_or_null(model_root_path) as Node3D
	if _model_root == null and _body:
		_model_root = _body.get_node_or_null("Model") as Node3D
	if _model_root:
		_model_base_y = _model_root.position.y

	_caster = get_node_or_null(caster_path)
	if _caster == null and _body:
		_caster = _body.get_node_or_null("SpellCaster")

	_skeleton = get_node_or_null(skeleton_path) as Skeleton3D
	if _skeleton == null:
		_skeleton = _find_skeleton(_body if _body else get_parent())

	if _skeleton == null:
		push_warning("PlayerAnimator: no Skeleton3D found; animation disabled.")
		set_process(false)
		return

	for key in BONES:
		var id := _skeleton.find_bone(BONES[key])
		if id == -1:
			push_warning("PlayerAnimator: bone '%s' not found on %s." % [BONES[key], _skeleton.name])
			continue
		_bone_ids[key] = id
		_bone_to_local[key] = _skeleton.get_bone_global_rest(id).basis.orthonormalized().inverse()


## The cast poses, keyed by the tag a [SpellProfile] names.
##
## THE POSES LIVE HERE AND NOT ON THE PROFILE, deliberately. Every value below
## is written in Mage.glb's rest space (see this class's header) and means
## nothing on another rig — carrying them in a spell resource would tie spell
## data to one character model. A profile names WHICH animation; this owns WHAT
## that animation is. It also means the eventual swap to real keyframed
## animation, which this class's header already sketches, changes nothing about
## the profiles.
##
## Each set has three stages — the pose at the start of the windup, at full
## charge, and at full release — and each stage is PER ARM. A spell that does not
## charge sets the first two stages the same, and a symmetric one sets both arms
## the same, which is why "bolt" (every spell that existed before charging did) is
## untouched by either interpolation.
##
## PER ARM BECAUSE A BOW IS NOT SYMMETRIC. The bow arm holds still and extended
## while the string arm travels from the bow to the cheek — one pose applied to
## both arms cannot express that, and a two-handed draw where both fists pull back
## together reads as pantomime. Spells that want both arms doing the same thing
## simply say so twice.
##
## Adding a set is an entry here plus the matching animation_tag on the profile.
## No other code changes.
func _build_pose_sets() -> void:
	_pose_sets[&"bolt"] = {
		"windup_arm_l": cast_windup_arm, "windup_arm_r": cast_windup_arm,
		"charged_arm_l": cast_windup_arm, "charged_arm_r": cast_windup_arm,
		"release_arm_l": cast_release_arm, "release_arm_r": cast_release_arm,
		"windup_lean": cast_windup_lean,
		"charged_lean": cast_windup_lean,
		"release_lean": cast_release_lean,
	}
	# A bow draw. (lower, forward, elbow) per arm, in radians — see _pose_arm.
	# The left arm holds the bow and barely moves across all three stages; the
	# right hand starts at the string, ends drawn past the cheek (elbow folded
	# hard, arm swung back), and opens on release.
	_pose_sets[&"draw_bow"] = {
		"windup_arm_l": Vector3(0.26, 1.38, 0.12),
		"charged_arm_l": Vector3(0.26, 1.38, 0.12),
		"release_arm_l": Vector3(0.28, 1.30, 0.18),
		"windup_arm_r": Vector3(0.32, 1.15, 0.35),
		"charged_arm_r": Vector3(0.40, 0.20, 1.75),
		"release_arm_r": Vector3(0.42, 0.10, 1.55),
		# Leans back into the draw, then settles forward as the string goes.
		"windup_lean": -0.02,
		"charged_lean": -0.10,
		"release_lean": 0.06,
	}


## The pose set for [param tag], falling back to "bolt" for an unknown or empty
## one — a spell with a tag nobody has authored poses for still animates as an
## ordinary cast rather than snapping to the rest pose.
func _pose_set_for(tag: StringName) -> Dictionary:
	return _pose_sets.get(tag, _pose_sets[&"bolt"])


func _process(delta: float) -> void:
	_time += delta

	var speed := 0.0
	var walk_speed := 4.0
	var run_speed := 7.5
	if _body and _body.has_method("get_planar_speed"):
		speed = _body.get_planar_speed()
		walk_speed = _body.walk_speed
		run_speed = _body.run_speed

	# Two independent blends: idle->walk, then walk->run on top.
	var move_goal := clampf(speed / maxf(walk_speed, 0.01), 0.0, 1.0)
	var run_goal := clampf((speed - walk_speed) / maxf(run_speed - walk_speed, 0.01), 0.0, 1.0)
	var weight := 1.0 - exp(-delta / maxf(blend_time, 0.001))
	_move_blend = lerpf(_move_blend, move_goal, weight)
	_run_blend = lerpf(_run_blend, run_goal, weight)

	# Step rate follows actual ground speed, so the feet never look like
	# they are skating regardless of walk/run.
	_phase = wrapf(_phase + TAU * (speed / maxf(stride_length, 0.01)) * delta, 0.0, TAU)

	var cast_weight := 0.0
	var cast_charge := 0.0
	var cast_extend := 0.0
	var pose: Dictionary = _pose_sets[&"bolt"]
	if _caster:
		cast_weight = _caster.weight
		cast_charge = _caster.charge
		cast_extend = _caster.extend
		if _caster.has_method("get_animation_tag"):
			pose = _pose_set_for(_caster.get_animation_tag())

	_pose_legs()
	_pose_arms(pose, cast_weight, cast_charge, cast_extend)
	_pose_body(pose, cast_weight, cast_charge, cast_extend)


func _pose_legs() -> void:
	var swing := lerpf(walk_leg_swing, run_leg_swing, _run_blend) * _move_blend
	var cycle := sin(_phase)

	# Legs hang along -Y, so they genuinely do swing about X.
	_set_bone_rot("upperleg_l", Vector3.RIGHT, cycle * swing)
	_set_bone_rot("upperleg_r", Vector3.RIGHT, -cycle * swing)
	# Knees only ever fold one way, hence the clamped half-wave.
	_set_bone_rot("lowerleg_l", Vector3.RIGHT, -maxf(0.0, sin(_phase - 0.7)) * knee_bend * _move_blend)
	_set_bone_rot("lowerleg_r", Vector3.RIGHT, -maxf(0.0, sin(_phase + PI - 0.7)) * knee_bend * _move_blend)


func _pose_arms(pose: Dictionary, cast_weight: float, cast_charge: float,
		cast_extend: float) -> void:
	var swing := lerpf(walk_arm_swing, run_arm_swing, _run_blend) * _move_blend
	var lift := arm_rest_lower - run_arm_lift * _run_blend * _move_blend
	var elbow := arm_rest_elbow + 0.35 * _run_blend * _move_blend
	var cycle := sin(_phase)

	# (lower, forward, elbow) per arm. Arms counter-swing against the same-side
	# leg, so the left arm leads when the left leg trails.
	var left := Vector3(lift, arm_rest_forward - cycle * swing, elbow)
	var right := Vector3(lift, arm_rest_forward + cycle * swing, elbow)

	if cast_weight > 0.001:
		var authority := cast_weight * cast_arm_authority
		left = left.lerp(_staged_arm(pose, "l", cast_charge, cast_extend), authority)
		right = right.lerp(_staged_arm(pose, "r", cast_charge, cast_extend), authority)

	_pose_arm("upperarm_l", "lowerarm_l", 1.0, left)
	_pose_arm("upperarm_r", "lowerarm_r", -1.0, right)


func _pose_body(pose: Dictionary, cast_weight: float, cast_charge: float,
		cast_extend: float) -> void:
	var idle_weight := 1.0 - _move_blend
	var breath := sin(_time * breath_speed * TAU * 0.5) * breath_amount * idle_weight
	var twist := sin(_phase) * 0.10 * _move_blend
	# Same two-stage interpolation as the arms — see [method _pose_arms].
	var drawn_lean: float = lerpf(pose["windup_lean"], pose["charged_lean"], cast_charge)
	var lean := lerpf(drawn_lean, pose["release_lean"], cast_extend) * cast_weight

	_set_bone_rot("spine", Vector3.UP, -twist)
	# Chest carries the breathing rise, half the counter-twist and the cast
	# lean, so the rotations have to be composed rather than set in turn.
	_set_bone_quat("chest",
		Quaternion(_local_axis("chest", Vector3.RIGHT), breath + lean)
		* Quaternion(_local_axis("chest", Vector3.UP), twist * 0.5))
	# The head stays levelled against the lean so the character keeps looking
	# at what it is casting at rather than at the sky.
	_set_bone_quat("head",
		Quaternion(_local_axis("head", Vector3.RIGHT), -lean * 0.55)
		* Quaternion(_local_axis("head", Vector3.UP), -twist * 0.6))

	if _model_root == null:
		return
	# Vertical bob peaks twice per cycle, once per footfall.
	var bob := absf(sin(_phase)) * body_bob * _move_blend
	_model_root.position.y = _model_base_y + bob
	_model_root.rotation.x = -run_lean * _run_blend * _move_blend


## One arm's pose at the current point in the cast, for [param side] "l" or "r".
##
## Two interpolations, not one: charge moves the arm through the windup (a bow
## drawing back), then extend throws it out. For a pose set whose start and charged
## poses are the same — every spell that does not charge — the first lerp is the
## identity and the result is exactly what it was before charging existed.
func _staged_arm(pose: Dictionary, side: String, charge: float, extend: float) -> Vector3:
	var drawn: Vector3 = pose["windup_arm_" + side].lerp(pose["charged_arm_" + side], charge)
	return drawn.lerp(pose["release_arm_" + side], extend)


## Poses one arm from a (lower, forward, elbow) triple, in radians.
##
## [param side] is +1 for the left arm and -1 for the right. `lower` swings the
## arm down from the T-pose, `forward` swings it toward +Z, and `elbow` folds
## the forearm forward. The sign flips between arms are handled here so callers
## can describe both arms with the same positive numbers.
func _pose_arm(upper_key: String, lower_key: String, side: float, pose: Vector3) -> void:
	# Lower about Z first, then swing forward about the (world-vertical) Y, so
	# the swing stays horizontal regardless of how far the arm has dropped.
	var down := Quaternion(_local_axis(upper_key, Vector3.BACK), -side * pose.x)
	var fwd := Quaternion(_local_axis(upper_key, Vector3.UP), -side * pose.y)
	_set_bone_quat(upper_key, fwd * down)
	# The elbow bends in the upper arm's frame, which is what makes the forearm
	# follow the shoulder around instead of folding in a fixed world direction.
	_set_bone_quat(lower_key, Quaternion(_local_axis(lower_key, Vector3.UP), -side * pose.z))


## Rotates a bone by [param angle] about an axis given in the model's rest
## space, regardless of how that bone's own axes happen to be oriented.
func _set_bone_rot(key: String, rest_axis: Vector3, angle: float) -> void:
	_set_bone_quat(key, Quaternion(_local_axis(key, rest_axis), angle))


## Converts an axis in the model's rest space into the given bone's local space.
func _local_axis(key: String, rest_axis: Vector3) -> Vector3:
	var conversion: Basis = _bone_to_local.get(key, Basis.IDENTITY)
	return (conversion * rest_axis).normalized()


## Applies [param delta_rotation] in bone-local space on top of the rest pose.
func _set_bone_quat(key: String, delta_rotation: Quaternion) -> void:
	var id: int = _bone_ids.get(key, -1)
	if id == -1:
		return
	var rest := _skeleton.get_bone_rest(id).basis.get_rotation_quaternion()
	_skeleton.set_bone_pose_rotation(id, rest * delta_rotation)


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
