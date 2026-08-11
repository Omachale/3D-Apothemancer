extends Node

## Washes the selected target in colour so it is obvious which one is picked.
##
## A `material_overlay` rather than a true outline. An inverted-hull outline —
## duplicate mesh, scaled up, front faces culled — is the usual technique and
## gives a crisper edge, but on a SKINNED character the hull has to follow the
## skeleton, which means duplicating each MeshInstance3D and sharing its
## Skeleton3D, on GLTF rigs whose node layout this project does not control. The
## overlay is five lines, works on any mesh regardless of rig, and is already
## proven on these exact characters because the death blackening in
## npc_controller.gd uses the same mechanism. If a wash turns out not to read
## clearly enough at the gameplay camera distance, THEN it is worth the hull.
##
## Kept separate from targeting.gd deliberately: that owns which thing is
## selected, this owns what that looks like, and neither needs to know how the
## other works.

## Colour laid over the target. Alpha is the strength of the wash — high enough
## to be unmistakable at the gameplay camera distance, low enough that the
## character underneath is still readable rather than a flat silhouette.
@export var tint := Color(1.0, 0.62, 0.1, 0.42)

## The meshes this has tinted, so they can be put back exactly as they were.
var _tinted: Array[MeshInstance3D] = []
var _overlay: StandardMaterial3D = null


func _ready() -> void:
	_overlay = StandardMaterial3D.new()
	# Unshaded so the wash reads as the same colour wherever the target is
	# standing — a lit overlay would go dark in shadow, which is exactly where
	# the player most needs to see which thing is selected.
	_overlay.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_overlay.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_overlay.albedo_color = tint
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
		# tint would overwrite the shroud and the corpse would collapse in
		# amber instead of black.
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
