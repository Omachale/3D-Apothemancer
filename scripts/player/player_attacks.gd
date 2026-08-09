extends Node

## Turns SpellCaster's cast_released signal into an actual projectile.
##
## SpellCaster only owns timing (see spell_caster.gd) and deliberately knows
## nothing about what a spell does — this is the other side of that seam: it
## reads [member SpellCaster.current_spell], the tag try_cast() was given, and
## spawns whichever bolt matches. Two spells for now (LMB/RMB); adding a third
## is one more scene reference and one more match arm, not new plumbing.

@export var caster_path: NodePath
@export var primary_scene: PackedScene
@export var secondary_scene: PackedScene

var _caster: Node = null


func _ready() -> void:
	_caster = get_node_or_null(caster_path)
	if _caster == null:
		_caster = get_parent().get_node_or_null("SpellCaster")
	if _caster == null:
		push_warning("PlayerAttacks: no SpellCaster found; attacks disabled.")
		return
	_caster.cast_released.connect(_on_cast_released)


func _on_cast_released(origin: Vector3, direction: Vector3) -> void:
	var scene: PackedScene = primary_scene if _caster.current_spell == "primary" else secondary_scene
	if scene == null:
		return
	var bolt: Node3D = scene.instantiate()
	var host: Node = Game.current_zone if Game.current_zone else get_parent()
	host.add_child(bolt)
	bolt.launch(origin, direction)
