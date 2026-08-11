extends CharacterBody3D

## Camera-relative WASD movement for the top-down view.
##
## Movement and aiming only. Casting lives in the sibling SpellCaster node; this
## script just forwards the input to it and lets it slow and turn the character
## while a cast is in flight.

enum State { IDLE, WALK, RUN }

signal state_changed(new_state: State)

@export_group("Movement")
@export_range(0.5, 80.0, 0.1) var walk_speed := 16.0
@export_range(0.5, 120.0, 0.1) var run_speed := 30.0
## Units/sec^2 while speeding up. High values feel responsive, low feel heavy.
@export_range(1.0, 100.0, 0.5) var acceleration := 30.0
@export_range(1.0, 100.0, 0.5) var deceleration := 40.0
## How quickly the model swings around to face the way it is moving.
@export_range(1.0, 40.0, 0.5) var turn_speed := 12.0
@export_range(0.0, 4.0, 0.05) var gravity_scale := 1.5

@export_group("Input")
## Shift toggles run on/off, as specced. Flip this for hold-to-run instead.
@export var run_is_toggle := true

@export_group("Debug Fly")
## TESTING TOOL, not a character ability — see terrain_manager.gd /
## grass_manager.gd's camera-driven streaming and screen-space LOD work.
## Holding "debug_fly" (Space) climbs at this rate and suspends gravity; letting
## go hands straight back to normal falling from whatever height and vertical
## speed the player was at, rather than snapping to a hover. There is
## deliberately no ceiling and no way to stop mid-air on purpose: this exists
## to let a person LOOK at how streaming and detail behave at altitude, not to
## be a designed movement mechanic. A real flight ability, if one gets
## designed later, is a different piece of work — controlled descent, limits,
## animation state, and probably resource cost.
@export_range(1.0, 60.0, 0.5) var fly_lift_speed := 20.0
## How quickly vertical speed ramps toward fly_lift_speed while held, and
## toward 0 the instant it is released (gravity takes over from there).
## Purely a smoothing knob; kept short so it does not feel laggy.
@export_range(0.5, 30.0, 0.5) var fly_lift_acceleration := 40.0

@export_group("Aiming")
## When true the model faces the mouse instead of the direction of travel.
## Off for now: strafing only makes sense once there is something to aim at.
@export var face_aim := false

@export_group("Knockback")
## How quickly an external shove bleeds off. Higher is snappier; low values
## let the player skid for a noticeable moment after being hit.
@export_range(0.5, 30.0, 0.5) var knockback_decay := 5.0

@export_group("Model")
## Yaw correction applied to the visual only, in degrees, in case an imported
## mesh does not face Godot's -Z forward. Mage.glb already does, hence 0.
@export var model_yaw_offset := 0.0

## Radius registered with TerrainManager.register_collision_anchor — see
## _ready(). Sized to comfortably outrun the player between terrain rescans:
## run_speed (30) x check_interval (0.25s default) is ~7.5 units of drift, and
## this needs to cover the anchor's own bookkeeping lag on top of that, so it
## is padded well past the worst case rather than tuned to the exact number.
@export var ground_anchor_radius := 16.0

## Where on the ground the mouse currently points, at the player's foot height.
var aim_point := Vector3.ZERO
## Normalised, flattened direction from the player toward [member aim_point].
var aim_direction := Vector3.FORWARD

var state: State = State.IDLE
## Horizontal motion the *input* is asking for. Held separately from
## [member velocity] so that a shove can be summed on top without either one
## corrupting the other — see the note in [method _physics_process].
var _move_velocity := Vector3.ZERO
## External shove, decaying, added on top of the above.
var _knockback := Vector3.ZERO
var _run_toggled := false
var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity", 9.8)
## Optional, exactly as on npc_controller.gd: no Health child means the player
## simply cannot be hurt, rather than erroring.
var _health: Health = null

@onready var model: Node3D = $Model
@onready var caster: Node = get_node_or_null("SpellCaster")


func _ready() -> void:
	# Stairs are ramps under the hood (see stairs.gd); give the body enough
	# slope tolerance to walk them, and enough snap to stay glued going down.
	floor_max_angle = deg_to_rad(50.0)
	floor_snap_length = 0.6
	floor_stop_on_slope = false
	collision_layer = Layers.PLAYER
	collision_mask = Layers.SOLID
	_health = get_node_or_null("Health") as Health
	if _health:
		_health.died.connect(_on_died)
	Game.register_player(self)
	# Terrain now streams around the CAMERA, not the player (see
	# terrain_manager.gd's _rescan) — the two used to be the same point for
	# this purpose, since distance-from-player was always exactly 0 under the
	# player's own feet. They are no longer guaranteed to coincide: zoomed far
	# out, or at altitude once flying exists, the camera can sit well away from
	# the player in real 3D distance, and without this the ground the player is
	# actually standing on could retile down to a tier with no collision out
	# from under them — the same silent fall-through NPCs were registered as
	# anchors to prevent (see npc_controller.gd's _ready()).
	if Game.terrain_manager:
		Game.terrain_manager.register_collision_anchor(self, ground_anchor_radius)


func _exit_tree() -> void:
	if Game.terrain_manager:
		Game.terrain_manager.unregister_collision_anchor(self)


func _physics_process(delta: float) -> void:
	# Ground streams in now rather than existing the instant the zone loads —
	# see npc_controller.gd's _ground_ready() for the full reasoning, which
	# applies here identically: without this, gravity can run for however long
	# real-world asset/shader loading happens to delay the first terrain scan,
	# and a large enough fall can tunnel through or wedge into a freshly-built
	# tile in a way that never resolves. The player's spawn Y already comes
	# from the same heightfield the terrain reads (see zone.gd's
	# get_spawn_transform), so simply not moving until the ground is confirmed
	# built means there is never a fall to have in the first place.
	if not _ground_ready():
		return

	_update_run_toggle()
	_update_aim()
	if caster:
		if Input.is_action_just_pressed("cast_primary"):
			caster.try_cast("primary")
		elif Input.is_action_just_pressed("cast_secondary"):
			caster.try_cast("secondary")

	if Input.is_action_pressed("debug_fly"):
		velocity.y = move_toward(velocity.y, fly_lift_speed, fly_lift_acceleration * delta)
	elif not is_on_floor():
		velocity.y -= _gravity * gravity_scale * delta

	var direction := _get_move_direction()
	var target_speed := (run_speed if _wants_run() else walk_speed)
	if caster:
		target_speed *= caster.get_move_scale()
	var goal := direction * target_speed
	var rate := acceleration if direction.length_squared() > 0.0 else deceleration

	# Input-driven motion is tracked separately from the shove so the two decay
	# on their own schedules and simply sum into `velocity`.
	#
	# Deriving the input part by subtracting the knockback back out of
	# `velocity` does not work, and failed in a way worth recording: on the
	# frame a hit lands, `velocity` does not contain the knockback yet, so the
	# subtraction injects an equal and opposite phantom velocity that then
	# bleeds off at the deceleration rate. The two nearly cancel, and the
	# player gets shoved a few centimetres *toward* the attacker instead of
	# away. `velocity` is also whatever move_and_slide last left there after a
	# collision, which is not a reliable place to read intent from.
	_move_velocity = _move_velocity.move_toward(goal, rate * delta)
	_knockback = _knockback.lerp(Vector3.ZERO, 1.0 - exp(-knockback_decay * delta))
	velocity.x = _move_velocity.x + _knockback.x
	velocity.z = _move_velocity.z + _knockback.z

	move_and_slide()

	_face(direction, delta)
	_update_state(direction)


## Horizontal speed in units/sec. Drives the animation blend.
func get_planar_speed() -> float:
	return Vector2(velocity.x, velocity.z).length()


## True once the ground under the player's CURRENT position is confirmed built
## and collidable. Zones without a TerrainManager (none exist yet, but nothing
## here should hard-require one) are treated as always-ready — this is a
## streaming safeguard, not a dependency.
func _ground_ready() -> bool:
	var terrain_manager: Node = Game.terrain_manager
	if terrain_manager == null:
		return true
	return terrain_manager.has_ground_at(global_position.x, global_position.z)


## Shove the player. [param direction] is flattened and normalised, so callers
## can hand over a raw vector between two points. [param lift] pops them off
## the ground, which is what makes a hit read as an impact rather than a
## slide — it is applied straight to the vertical velocity and then left to
## gravity, not decayed like the horizontal part.
##
## This is the seam an attack calls, and it stays purely physical — damage is
## the separate [method take_damage] below, so a shove that should not hurt
## (and a hit that should not shove) each stay expressible.
func apply_knockback(direction: Vector3, force: float, lift := 0.0) -> void:
	var flat := Vector3(direction.x, 0.0, direction.z)
	if flat.length_squared() > 0.001:
		_knockback += flat.normalized() * force
	if lift > 0.0:
		velocity.y = maxf(velocity.y, lift)


## Hurt the player. Duck-typed identically to npc_controller.gd's, so
## projectile.gd hits both through the same call and knows about neither.
func take_damage(amount: float) -> void:
	if _health:
		_health.take_damage(amount)


## The live [Health], or null. For a player health bar when one exists.
func get_health() -> Health:
	return _health


## PLACEHOLDER DEATH: respawn at the zone's spawn point with health restored.
##
## There is no death sequence, no penalty and no game-over — those are game
## rules and none are decided (see [[DESIGN_GOALS.md]]). Respawning is the
## least presumptuous thing that keeps a session going: it commits to nothing
## while making "the player can die" real enough to feel while testing.
func _on_died() -> void:
	global_transform = Game.spawn_transform
	velocity = Vector3.ZERO
	_knockback = Vector3.ZERO
	if _health:
		_health.revive()
	# Without this the camera sweeps across the whole map to catch up, which
	# reads as a bug rather than as a respawn.
	if Game.camera_rig and Game.camera_rig.has_method("snap_to_target"):
		Game.camera_rig.snap_to_target()


func _get_move_direction() -> Vector3:
	var input := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	if input.length_squared() < 0.01:
		return Vector3.ZERO
	var basis := Basis.IDENTITY
	if Game.camera_rig:
		basis = Game.camera_rig.get_ground_basis()
	var dir: Vector3 = basis * Vector3(input.x, 0.0, input.y)
	dir.y = 0.0
	return dir.normalized() * minf(input.length(), 1.0)


func _wants_run() -> bool:
	if run_is_toggle:
		return _run_toggled
	return Input.is_action_pressed("toggle_run")


func _update_run_toggle() -> void:
	if run_is_toggle and Input.is_action_just_pressed("toggle_run"):
		_run_toggled = not _run_toggled


func _update_aim() -> void:
	if Game.camera_rig == null:
		return
	var mouse := get_viewport().get_mouse_position()
	var hit: Variant = Game.camera_rig.screen_point_to_ground(mouse, global_position.y)
	if hit == null:
		return
	aim_point = hit
	var flat := aim_point - global_position
	flat.y = 0.0
	if flat.length_squared() > 0.001:
		aim_direction = flat.normalized()


func _face(direction: Vector3, delta: float) -> void:
	# A cast always turns the character to face its target, whatever they were
	# walking toward — otherwise the thrust animation points off into nothing.
	var casting: bool = caster != null and caster.is_casting() and caster.face_aim_while_casting
	var facing := aim_direction if (face_aim or casting) else direction
	if facing.length_squared() < 0.001:
		return
	var goal := atan2(facing.x, facing.z) + deg_to_rad(model_yaw_offset)
	model.rotation.y = lerp_angle(model.rotation.y, goal, 1.0 - exp(-turn_speed * delta))


func _update_state(direction: Vector3) -> void:
	var next := State.IDLE
	if direction.length_squared() > 0.0 and get_planar_speed() > 0.15:
		next = State.RUN if _wants_run() else State.WALK
	if next != state:
		state = next
		state_changed.emit(state)
