extends CharacterBody3D

## NPC behaviour: wander aimlessly, and — if [member attack_enabled] — stop and
## throw a bolt at the player when one comes within range.
##
## Damage runs ONE WAY for now: the player's bolts hurt these, and their bolts
## still only shove the player, because the player has no [Health] component
## yet. That asymmetry is deliberate rather than overlooked — see
## `projectile.gd`'s note on why damage defaults to zero per bolt.
##
## One script drives every character. Built against Quaternius-style exports
## specifically: a root node containing a Skeleton3D and a sibling
## AnimationPlayer with baked, in-place clips (no root motion), found by
## search rather than by a fixed node path so a new character with the same
## export shape needs no code change.

enum State { IDLE, WALK, ATTACK }

@export_group("Identity")
## Shown on the target panel when this NPC is selected. Falls back to the node
## name, so an unnamed NPC reads as "Witch" rather than as blank.
@export var display_name := ""
## Whether the player can target and attack this. Separate from
## [member attack_enabled] on purpose: that is "does this shoot at me", this is
## "can I shoot at it", and a harmless NPC still wants to be targetable so the
## player can inspect it.
@export var targetable := true

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

@export_group("Knockback")
## No hit-reaction animation exists for these rigs (only Idle/Walk/Gun_Shoot
## ship on the Quaternius characters), so a hit is a pure physical shove —
## nothing else changes about the NPC's state or behaviour.
@export_range(0.5, 30.0, 0.5) var knockback_decay := 5.0

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
## Decaying external shove, summed on top of whatever the current state (idle
## /walk/attack) sets velocity.x/z to — see [method _physics_process] and
## player_controller.gd's identical split for why this stays separate rather
## than being folded into the state logic itself.
var _knockback := Vector3.ZERO
## Optional: an NPC with no Health child simply cannot be hurt, rather than
## erroring. Kept as a plain reference so consumers (the target panel) can read
## the live numbers and connect to its signals directly.
var _health: Health = null


func _ready() -> void:
	collision_layer = Layers.ENEMY
	collision_mask = Layers.SOLID
	floor_max_angle = deg_to_rad(50.0)
	floor_snap_length = 0.6
	_origin = global_position
	_health = get_node_or_null("Health") as Health
	if _health:
		_health.died.connect(_on_died)
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

	# Terrain detail is keyed to the player's position, so ground under an NPC
	# the player has walked away from can retile down to a tier with no
	# collision — this NPC is a CharacterBody3D that needs is_on_floor() to be
	# true or it falls straight through the world. Registering as an anchor
	# guarantees solid ground within its wander circle regardless of where the
	# player is. See TerrainManager.register_collision_anchor.
	if Game.terrain_manager:
		Game.terrain_manager.register_collision_anchor(self, wander_radius + 4.0)


func _exit_tree() -> void:
	if Game.terrain_manager:
		Game.terrain_manager.unregister_collision_anchor(self)


func _physics_process(delta: float) -> void:
	# Ground is streamed in now, not permanently present the instant the zone
	# loads — see [[has_ground_at]]. Without this gate, an NPC starts falling
	# under gravity the moment it spawns, and how far it falls before its tile
	# actually finishes building depends on real-world load timing (asset
	# import, shader compilation), which is NOT bounded or deterministic. Given
	# enough of a head start the fall can be fast enough to tunnel a thin
	# single-layer trimesh outright, or land hard enough to wedge partway into
	# it — a wedged body sits blocked but touching the mesh from the WRONG
	# side, so is_on_floor() never reads true and the character looks sunk
	# into the ground forever, with nothing (no error, no warning) marking
	# what happened. Since an NPC's authored spawn Y is already the correct
	# ground height (it comes from the same heightfield terrain reads from —
	# see zone.gd), simply not moving at all until the ground under it is
	# confirmed built means it never has anywhere to fall from in the first
	# place: no visible drop, no tunnelling, no wedging, ever.
	if not _ground_ready():
		return

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

	velocity.x += _knockback.x
	velocity.z += _knockback.z
	_knockback = _knockback.lerp(Vector3.ZERO, 1.0 - exp(-knockback_decay * delta))

	move_and_slide()


## True once the ground under this NPC's CURRENT position is confirmed built
## and collidable. Zones without a TerrainManager (none exist yet, but nothing
## here should hard-require one) are treated as always-ready — this is a
## streaming safeguard, not a dependency.
func _ground_ready() -> bool:
	var terrain_manager: Node = Game.terrain_manager
	if terrain_manager == null:
		return true
	return terrain_manager.has_ground_at(global_position.x, global_position.z)


## Shove this NPC. Same signature as player_controller.gd's version, since
## both are called by the same projectile.gd hit check — but no lift is used
## here, and there is no animation reaction to trigger (see [member
## knockback_decay]'s note).
func apply_knockback(direction: Vector3, force: float, _lift := 0.0) -> void:
	var flat := Vector3(direction.x, 0.0, direction.z)
	if flat.length_squared() > 0.001:
		_knockback += flat.normalized() * force


## Hurt this NPC. Duck-typed the same way [method apply_knockback] is, so
## projectile.gd can call it without knowing what it hit — see the note there.
func take_damage(amount: float) -> void:
	if _health:
		_health.take_damage(amount)


## The live [Health], or null. For the target panel, which wants both the
## current numbers and the `changed` signal.
func get_health() -> Health:
	return _health


## What to call this on screen — [member display_name] if set, node name if not.
func get_display_name() -> String:
	return display_name if not display_name.is_empty() else name


## Removed outright on death. There is no death animation on these rigs (only
## Idle/Walk/Gun_Shoot ship with the Quaternius characters, same limitation
## that made a hit a pure shove), so anything more than vanishing would be a
## stand-in needing its own art. Flagged as placeholder rather than dressed up.
func _on_died() -> void:
	queue_free()


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
