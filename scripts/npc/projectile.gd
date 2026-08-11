extends Area3D

## A bolt of dark energy: travels in a straight line, shoves and damages
## whatever it hits, and removes itself.
##
## Damage is per-scene and defaults to ZERO, so a bolt only hurts if its scene
## says how much. That keeps the previous "knockback is the whole interaction"
## behaviour as the default rather than silently arming every existing bolt the
## moment health existed — notably the NPC's DarkBolt, which is aimed at a
## player who has no [Health] component yet.
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
## Hit points removed from whatever this strikes, if it has a [Health]. Zero
## means this bolt is a pure shove — see the class note above for why that is
## the default rather than a damaging one.
@export_range(0.0, 100.0, 0.5) var damage := 0.0
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
	if aim.length_squared() > 0.001:
		direction = aim.normalized()
	# Turns the orb to face its own travel direction so elongation (a scale
	# along local Z, applied in _ready) stretches it the right way. Skipped
	# when there is nothing to stretch.
	#
	# look_at's degenerate case is a direction parallel to its up vector, i.e.
	# a shot straight up or down. Aim used to be flattened so that could not
	# happen; it now carries height, so guard it rather than relying on an
	# assumption that is no longer true.
	if elongation != 1.0 and absf(direction.dot(Vector3.UP)) < 0.999:
		look_at(global_position + direction, Vector3.UP)


func _on_body_entered(body: Node3D) -> void:
	# Duck-typed exactly like apply_knockback below: anything that can be hurt
	# implements take_damage, and this stays ignorant of what it hit.
	if damage > 0.0 and body.has_method("take_damage"):
		body.take_damage(damage)
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
