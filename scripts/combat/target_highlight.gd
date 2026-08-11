extends Node

## Outlines the selected target in a glowing rim so it is obvious which one is
## picked, without repainting the character.
##
## A fresnel rim in a `material_overlay` — see target_rim.gdshader. Two other
## approaches were tried or considered and both are worse here:
##
## An INVERTED-HULL outline (duplicate mesh, scaled up, front faces culled)
## gives the crispest edge, but on a skinned character the hull must follow the
## skeleton, so every character needs its MeshInstance3D duplicated and its
## Skeleton3D shared — per-rig setup work, repeated for every model ever added,
## on GLTF layouts this project does not control.
##
## A FLAT ALPHA WASH came first and shipped briefly. It is one material and no
## setup, but alpha blending covers the texture underneath in proportion to its
## alpha, so a selected character became a solid orange silhouette: easy to see,
## and unrecognisable.
##
## The rim has neither problem. It is per-pixel geometry — the angle between the
## surface normal and the view — so it needs no mesh duplication and knows
## nothing about any rig, which means it keeps working on characters added
## later with no per-model work. And it is ADDITIVE, so it brightens the edge
## rather than replacing colour: the character stays fully readable underneath.
##
## Kept separate from targeting.gd deliberately: that owns which thing is
## selected, this owns what that looks like, and neither needs to know how the
## other works.

const RIM_SHADER := preload("res://resources/shaders/target_rim.gdshader")

## Colour of the glow. Alpha is unused — the rim is additive, so its visible
## strength is [member rim_strength], not opacity.
@export var rim_color := Color(1.0, 0.62, 0.1)
## How tightly the glow hugs the silhouette. Raise to thin the band, lower to
## spread it across the surface.
@export_range(0.5, 8.0, 0.1) var rim_power := 2.8
@export_range(0.0, 4.0, 0.05) var rim_strength := 1.7
## Faint even glow beneath the rim, so a surface turned flat to the camera does
## not read as unselected. See the shader for why this is not zero.
@export_range(0.0, 0.5, 0.01) var fill := 0.05

## The meshes this has applied the rim to, so they can be put back exactly as
## they were.
var _tinted: Array[MeshInstance3D] = []
var _overlay: ShaderMaterial = null


func _ready() -> void:
	# One material shared by every mesh of every target. It carries no
	# per-target state — the rim is computed per pixel from the geometry — so
	# there is nothing to duplicate per character.
	_overlay = ShaderMaterial.new()
	_overlay.shader = RIM_SHADER
	_overlay.set_shader_parameter("rim_color", rim_color)
	_overlay.set_shader_parameter("rim_power", rim_power)
	_overlay.set_shader_parameter("rim_strength", rim_strength)
	_overlay.set_shader_parameter("fill", fill)
	Targeting.target_changed.connect(_on_target_changed)
	_on_target_changed(Targeting.current)


func _on_target_changed(target: Node3D) -> void:
	_clear()
	if target == null or not is_instance_valid(target):
		return
	for mesh in _find_meshes(target):
		# Never stomp an overlay something else owns — chiefly the death
		# blackening, which is applied on the killing blow, one frame before
		# targeting notices the target is dead and clears it. Without this the
		# rim would overwrite the shroud and the corpse would collapse glowing
		# instead of blackened.
		if mesh.material_overlay != null:
			continue
		mesh.material_overlay = _overlay
		_tinted.append(mesh)


## Restores only what this actually applied. The identity check matters for the
## same reason as above: by the time a killed target is deselected its meshes
## carry the death shroud, and clearing that would undo the death effect.
func _clear() -> void:
	for mesh in _tinted:
		if is_instance_valid(mesh) and mesh.material_overlay == _overlay:
			mesh.material_overlay = null
	_tinted.clear()


func _find_meshes(node: Node) -> Array[MeshInstance3D]:
	var found: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		found.append(node)
	for child in node.get_children():
		found.append_array(_find_meshes(child))
	return found
