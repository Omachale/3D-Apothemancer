extends Area3D

## A bolt of dark energy: travels in a straight line, shoves whatever it hits,
## and removes itself.
##
## Knockback only — no damage, no health. That is deliberate: there is no
## health system yet and the magic rules are undecided, so this delivers a
## purely physical effect that is fun to feel and commits to nothing. When
## damage does arrive, it goes in [method _on_body_entered] beside the shove.
##
## Moved by hand in [method _physics_process] rather than being a RigidBody3D:
## a bolt wants a dead-straight path at a constant speed, which is simpler to
## write directly than to coax out of the physics solver.

## Fired when the bolt hits something, with the impact point. A hook for
## impact effects later; nothing listens yet.
signal struck(at: Vector3)

@export_group("Flight")
@export_range(4.0, 80.0, 0.5) var speed := 22.0
## Seconds before it gives up and despawns, in case it never hits anything.
@export_range(0.5, 20.0, 0.5) var lifetime := 5.0
## What the bolt can hit. Kept exported rather than the flat PLAYER|SOLID mask
## this originally hardcoded, since the player's own bolts need ENEMY instead
## of PLAYER — an NPC's bolt must not be able to hit its own kind, but the
## player's must.
@export_flags_3d_physics var hit_mask := Layers.PLAYER | Layers.SOLID
## Stretches the orb along its direction of travel — see [method launch]. 1.0
## leaves it a plain sphere, matching every bolt before this existed.
@export_range(1.0, 4.0, 0.1) var elongation := 1.0

@export_group("Impact")
## Whether a hit shoves the thing it struck. Off for a bolt whose impact is
## meant to be purely visual (see [member explosion_scene]) rather than
## physical.
@export var apply_knockback_on_hit := true
@export_range(0.0, 60.0, 0.5) var knockback_force := 16.0
## Upward pop on impact. Without some of this a hit reads as a nudge rather
## than a blow.
@export_range(0.0, 20.0, 0.5) var knockback_lift := 4.0
## Spawned at the impact point on hit, e.g. a purely-visual burst. Left null
## for a bolt that has no aftermath beyond the knockback above.
@export var explosion_scene: PackedScene = null

@export_group("Look")
## Pulse depth of the orb, as a fraction of its size.
@export_range(0.0, 1.0, 0.05) var pulse := 0.18
@export_range(0.0, 30.0, 0.5) var pulse_speed := 14.0
@export_range(0.0, 20.0, 0.5) var spin_speed := 3.0

var direction := Vector3.FORWARD

var _age := 0.0
var _base_scale := Vector3.ONE

@onready var _orb: MeshInstance3D = $Orb


func _ready() -> void:
	collision_layer = Layers.PROJECTILE
	collision_mask = hit_mask
	body_entered.connect(_on_body_entered)
	if _orb:
		_base_scale = _orb.scale
		_base_scale.z *= elongation


func _physics_process(delta: float) -> void:
	_age += delta
	if _age >= lifetime:
		queue_free()
		return

	global_position += direction * speed * delta

	if _orb:
		_orb.scale = _base_scale * (1.0 + sin(_age * pulse_speed) * pulse)
		_orb.rotate_y(spin_speed * delta)


## Point the bolt and start it moving. Call straight after adding it to the
## tree; [param from] is where it appears, [param aim] the way it travels.
func launch(from: Vector3, aim: Vector3) -> void:
	global_position = from
	var flat := Vector3(aim.x, aim.y, aim.z)
	if flat.length_squared() > 0.001:
		direction = flat.normalized()
	# Turns the orb to face its own travel direction so elongation (a scale
	# along local Z, applied in _ready) stretches it the right way. Skipped
	# when there is nothing to stretch — aim is always near-horizontal here
	# (see SpellCaster's flattened aim_direction), so look_at has no reason to
	# hit its degenerate case, but there is no need to pay for it either.
	if elongation != 1.0:
		look_at(global_position + direction, Vector3.UP)


func _on_body_entered(body: Node3D) -> void:
	if apply_knockback_on_hit and body.has_method("apply_knockback"):
		# Shove along the bolt's own path rather than from its centre outward,
		# so a glancing hit still pushes the way the bolt was going instead of
		# sideways in whatever direction the overlap happened to resolve.
		body.apply_knockback(direction, knockback_force, knockback_lift)
	if explosion_scene:
		var fx: Node3D = explosion_scene.instantiate()
		var host: Node = get_parent()
		if host:
			host.add_child(fx)
			fx.global_position = global_position
	struck.emit(global_position)
	queue_free()
