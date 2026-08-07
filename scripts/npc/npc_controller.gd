extends CharacterBody3D

## NPC behaviour: wander aimlessly, and — if [member attack_enabled] — stop and
## throw a bolt at the player when one comes within range.
##
## There is still no health and no damage anywhere in this. The attack shoves
## the player and nothing else, which is a real, readable interaction that
## commits to none of the undecided magic rules. Damage hangs off
## `projectile.gd` when those rules exist.
##
## One script drives every character. Built against Quaternius-style exports
## specifically: a root node containing a Skeleton3D and a sibling
## AnimationPlayer with baked, in-place clips (no root motion), found by
## search rather than by a fixed node path so a new character with the same
## export shape needs no code change.

enum State { IDLE, WALK, ATTACK }

@export_group("Wander")
@export_range(1.0, 20.0, 0.5) var wander_radius := 6.0
@export_range(0.3, 10.0, 0.1) var walk_speed := 2.2
@export_range(0.0, 10.0, 0.1) var idle_time_min := 1.5
@export_range(0.0, 10.0, 0.1) var idle_time_max := 4.0
## How close counts as "arrived", so it does not jitter trying to stand on the
## exact target point.
@export_range(0.05, 2.0, 0.05) var arrive_distance := 0.3
@export_range(1.0, 20.0, 0.5) var turn_speed := 6.0
@export_range(0.0, 4.0, 0.05) var gravity_scale := 1.5

@export_group("Attack")
## Off by default: most characters just wander. The Witch turns this on.
@export var attack_enabled := false
@export var projectile_scene: PackedScene
## How close the player has to be before this NPC will attack.
@export_range(2.0, 60.0, 0.5) var attack_range := 18.0
## Seconds between the attack starting and the bolt actually leaving, so the
## animation has time to wind up before anything appears.
@export_range(0.0, 3.0, 0.05) var attack_windup := 0.45
## Seconds spent finishing the animation after the bolt is away.
@export_range(0.0, 3.0, 0.05) var attack_recover := 0.4
@export_range(0.0, 20.0, 0.1) var attack_cooldown := 2.5
## Where the bolt appears, relative to the NPC — chest height and slightly
## forward. Not bone-attached on purpose: at the gameplay camera distance the
## hand position is not readable, and a fixed offset cannot be thrown off by
## whatever the animation is doing at that instant.
@export var muzzle_offset := Vector3(0.0, 1.35, 0.5)
## How much the NPC leads its aim toward the player's upper body rather than
## their feet, so bolts arrive at chest height.
@export_range(0.0, 3.0, 0.05) var aim_height := 1.1

@export_group("Animation")
@export var idle_clip := "Idle"
@export var walk_clip := "Walk"
## Quaternius rigs ship a "Gun_Shoot" clip: raise, point, recoil. With no gun
## mesh on the character it reads perfectly well as throwing a spell.
@export var attack_clip := "Gun_Shoot"
## Yaw correction for the visual only, in case the rig does not face Godot's
## -Z forward. Quaternius exports do, hence 0 — flip to 180 if a character
## walks backwards.
@export var model_yaw_offset := 0.0

var state: State = State.IDLE
var _origin := Vector3.ZERO
var _target := Vector3.ZERO
var _idle_timer := 0.0
var _anim: AnimationPlayer = null
var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
var _attack_timer := 0.0
var _cooldown := 0.0
var _bolt_fired := false


func _ready() -> void:
	collision_layer = Layers.ENEMY
	collision_mask = Layers.SOLID
	floor_max_angle = deg_to_rad(50.0)
	floor_snap_length = 0.6
	_origin = global_position
	_anim = _find_animation_player(self)
	if _anim == null:
		push_warning("NpcWander: no AnimationPlayer found under %s." % name)
	else:
		# Baked clips are not guaranteed to loop on export; force it rather
		# than have idling or walking play once and freeze. The attack clip is
		# left alone — it should play through once, not cycle.
		_force_loop(idle_clip)
		_force_loop(walk_clip)
	_enter_idle()


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= _gravity * gravity_scale * delta

	_cooldown = maxf(0.0, _cooldown - delta)

	match state:
		State.IDLE:
			_process_idle(delta)
		State.WALK:
			_process_walk(delta)
		State.ATTACK:
			_process_attack(delta)

	move_and_slide()


func _process_idle(delta: float) -> void:
	velocity.x = 0.0
	velocity.z = 0.0
	if _try_start_attack():
		return
	_idle_timer -= delta
	if _idle_timer <= 0.0:
		_enter_walk()


func _process_walk(delta: float) -> void:
	if _try_start_attack():
		return

	var to_target := _target - global_position
	to_target.y = 0.0
	var distance := to_target.length()

	if distance <= arrive_distance:
		_enter_idle()
		return

	var direction := to_target / distance
	velocity.x = direction.x * walk_speed
	velocity.z = direction.z * walk_speed
	_face(direction, delta)


# ---------------------------------------------------------------------------
# ATTACK
# ---------------------------------------------------------------------------

## Stands still, faces the player, and fires once part-way through the clip.
func _process_attack(delta: float) -> void:
	velocity.x = 0.0
	velocity.z = 0.0
	_attack_timer += delta

	var player := Game.player
	if player:
		var facing := player.global_position - global_position
		facing.y = 0.0
		# Keep turning through the whole attack, so a bolt fired at a moving
		# player still leaves in roughly the right direction.
		_face(facing.normalized(), delta)

	if not _bolt_fired and _attack_timer >= attack_windup:
		_bolt_fired = true
		_fire()

	if _attack_timer >= attack_windup + attack_recover:
		_cooldown = attack_cooldown
		_enter_idle()


## Whether an attack should start this frame, and starts it if so.
func _try_start_attack() -> bool:
	if not attack_enabled or projectile_scene == null or _cooldown > 0.0:
		return false
	var player := Game.player
	if player == null:
		return false
	if global_position.distance_to(player.global_position) > attack_range:
		return false
	if not _has_line_of_sight(player):
		return false

	state = State.ATTACK
	_attack_timer = 0.0
	_bolt_fired = false
	_play(attack_clip)
	return true


## Stops the NPC shooting through walls, and — more visibly — stops it firing
## at a player who has gone inside the keep and is no longer reachable.
func _has_line_of_sight(player: Node3D) -> bool:
	var space := get_world_3d().direct_space_state
	var from := global_position + Vector3.UP * muzzle_offset.y
	var to := player.global_position + Vector3.UP * aim_height
	var query := PhysicsRayQueryParameters3D.create(from, to, Layers.SOLID)
	query.exclude = [get_rid()]
	return space.intersect_ray(query).is_empty()


func _fire() -> void:
	var player := Game.player
	if player == null:
		return
	var origin := global_position + (global_transform.basis * muzzle_offset)
	var aim := (player.global_position + Vector3.UP * aim_height) - origin

	var bolt: Node3D = projectile_scene.instantiate()
	# Parented to the zone, not to this NPC — a bolt in flight must not
	# inherit the caster's rotation, and must outlive it being freed.
	var host: Node = Game.current_zone if Game.current_zone else get_parent()
	host.add_child(bolt)
	bolt.launch(origin, aim)


# ---------------------------------------------------------------------------
# WANDER
# ---------------------------------------------------------------------------

func _enter_idle() -> void:
	state = State.IDLE
	_idle_timer = randf_range(idle_time_min, idle_time_max)
	_play(idle_clip)


func _enter_walk() -> void:
	# Pick a point within the wander circle around spawn, not around the
	# current position, so the character does not drift arbitrarily far from
	# where it was placed over many cycles.
	var angle := randf() * TAU
	var radius := sqrt(randf()) * wander_radius
	_target = _origin + Vector3(cos(angle), 0.0, sin(angle)) * radius
	state = State.WALK
	_play(walk_clip)


func _face(direction: Vector3, delta: float) -> void:
	if direction.length_squared() < 0.001:
		return
	var goal := atan2(direction.x, direction.z) + deg_to_rad(model_yaw_offset)
	rotation.y = lerp_angle(rotation.y, goal, 1.0 - exp(-turn_speed * delta))


func _play(clip: String) -> void:
	if _anim and _anim.has_animation(clip):
		_anim.play(clip)


func _force_loop(clip: String) -> void:
	if _anim == null or not _anim.has_animation(clip):
		return
	var anim_res := _anim.get_animation(clip)
	if anim_res.loop_mode == Animation.LOOP_NONE:
		anim_res.loop_mode = Animation.LOOP_LINEAR


func _find_animation_player(node: Node) -> AnimationPlayer:
	for child in node.get_children():
		if child is AnimationPlayer:
			return child
		var found := _find_animation_player(child)
		if found:
			return found
	return null
