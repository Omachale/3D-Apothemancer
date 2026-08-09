extends Node3D

## A crackling burst at a point in space — the blue bomb's payload once it
## hits something. Purely visual: no damage, no knockback, no collision at
## all. Knockback is deliberately the OTHER spell's job (see projectile.gd's
## apply_knockback_on_hit) — this one only needs to look like something
## happened.
##
## Self-contained lifetime: spawns, grows, fades, frees itself. Nothing external
## needs to track or clean this up.

@export var radius := 2.0
@export var duration := 0.5
@export var color := Color(0.25, 0.55, 1.0)

var _age := 0.0
var _material: StandardMaterial3D = null

@onready var _mesh: MeshInstance3D = $Burst
@onready var _light: OmniLight3D = $Glow


func _ready() -> void:
	# Duplicated, not read directly off the mesh — material_override loaded
	# from the .tres is one shared Resource. Without this, two explosions
	# overlapping in time would fight over the same alpha/energy values as
	# each mutates it in _process below.
	var shared := _mesh.material_override as StandardMaterial3D
	if shared:
		_material = shared.duplicate() as StandardMaterial3D
		_mesh.material_override = _material
	_mesh.scale = Vector3.ONE * 0.01


func _process(delta: float) -> void:
	_age += delta
	var t := _age / duration
	if t >= 1.0:
		queue_free()
		return

	# Fast expansion, then holds near full size while it fades — reads as a
	# burst rather than a balloon inflating.
	var grow := 1.0 - pow(1.0 - clampf(t / 0.3, 0.0, 1.0), 3.0)
	_mesh.scale = Vector3.ONE * (radius * grow)

	var fade := 1.0 - t
	if _material:
		_material.albedo_color.a = fade
		# Crackle: energy jitters instead of a smooth fade, so it reads as
		# electrical rather than as a simple dissolve.
		_material.emission_energy_multiplier = (1.5 + randf() * 2.5) * fade
	_light.light_energy = (3.0 + randf() * 5.0) * fade
