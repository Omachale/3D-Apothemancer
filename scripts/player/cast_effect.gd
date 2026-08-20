extends Node

## Placeholder "something is happening in that hand" visual.
##
## Builds itself at runtime: finds the Skeleton3D, hangs a BoneAttachment3D off
## the casting bone and parents a glowing sphere and a light to it. Nothing is
## stored in the scene file, so swapping the character model does not break it
## as long as the bone name still exists.
##
## This is knowingly crude — an emissive ball that swells during the windup and
## flashes on release. It exists so a cast is legible while the actual spell
## system is still undecided, and so there is an obvious place to hang real
## particles later: keep the node, replace the mesh.
##
## [member color] is exported per-instance, which is the seam damage types will
## eventually want — one caster per element, or one caster recoloured on the fly.

@export_group("Look")
@export var color := Color(0.45, 0.62, 1.0)
## Radius at full charge, in metres. Generous on purpose: at the gameplay
## camera distance the character is only ~100px tall, so the orb is the part of
## a cast that actually reads — the arm pose barely survives the robe.
@export_range(0.02, 0.8, 0.01) var max_radius := 0.24
## Extra radius punched in at the moment of release.
@export_range(0.0, 1.5, 0.01) var flash_radius := 0.34
@export_range(0.0, 12.0, 0.1) var light_energy := 4.5
@export_range(0.5, 8.0, 0.1) var light_range := 4.5

@export_group("Wiring")
@export var caster_path: NodePath
## Defaults to whatever the caster is configured to use.
@export var bone_override := ""

var _caster: Node = null
var _attachment: BoneAttachment3D = null
var _mesh: MeshInstance3D = null
var _light: OmniLight3D = null
var _material: StandardMaterial3D = null
var _flash := 0.0


func _ready() -> void:
	var body := get_parent()
	_caster = get_node_or_null(caster_path)
	if _caster == null:
		_caster = body.get_node_or_null("SpellCaster")
	if _caster == null:
		push_warning("CastEffect: no SpellCaster found; effect disabled.")
		set_process(false)
		return
	_caster.cast_released.connect(_on_released)

	var skeleton := _find_skeleton(body)
	if skeleton == null:
		push_warning("CastEffect: no Skeleton3D found; effect disabled.")
		set_process(false)
		return

	var bone: String = bone_override if bone_override != "" else _caster.cast_bone
	if skeleton.find_bone(bone) == -1:
		push_warning("CastEffect: bone '%s' not found; effect disabled." % bone)
		set_process(false)
		return

	_build(skeleton, bone)


func _build(skeleton: Skeleton3D, bone: String) -> void:
	_attachment = BoneAttachment3D.new()
	_attachment.name = "CastAnchor"
	_attachment.bone_name = bone
	skeleton.add_child(_attachment)

	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.emission_enabled = true
	_material.emission = color
	_material.emission_energy_multiplier = 3.0
	_material.albedo_color = color
	# Additive so overlapping the robe reads as light rather than a solid ball.
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED

	var sphere := SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = 16
	sphere.rings = 8

	_mesh = MeshInstance3D.new()
	_mesh.name = "CastOrb"
	_mesh.mesh = sphere
	_mesh.material_override = _material
	_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_attachment.add_child(_mesh)

	_light = OmniLight3D.new()
	_light.name = "CastGlow"
	_light.light_color = color
	_light.omni_range = light_range
	_light.shadow_enabled = false
	_attachment.add_child(_light)

	_set_visible_amount(0.0, 0.0)


func _process(delta: float) -> void:
	if _mesh == null:
		return
	_flash = maxf(0.0, _flash - delta * 6.0)
	# Not every cast is magic — a drawn bow should not have a ball of light in its
	# fist. See SpellProfile.shows_cast_glow.
	var profile: SpellProfile = _caster.current_profile
	if profile and not profile.shows_cast_glow:
		_set_visible_amount(0.0, 0.0)
		return
	_set_visible_amount(_caster.charge, _caster.weight)


## The orb is gathered energy, faded by how much of a cast is happening — so it
## takes its SIZE from [member SpellCaster.charge] and its VISIBILITY from
## [member SpellCaster.weight]. Those used to be one value and are now two: on a
## charged cast the orb must keep swelling for as long as the player holds,
## which weight (blended in over a fraction of a second and then flat) cannot
## express. During recovery weight falls away and fades the orb out on its own,
## while charge deliberately holds the value that was fired.
func _set_visible_amount(charge: float, blend: float) -> void:
	var amount := charge * blend
	var radius := max_radius * amount + flash_radius * _flash
	var lit := amount > 0.01 or _flash > 0.01
	_mesh.visible = lit
	_light.visible = lit
	if not lit:
		return
	_mesh.scale = Vector3.ONE * radius
	_material.emission_energy_multiplier = 2.0 + 6.0 * _flash
	_light.light_energy = light_energy * (amount + _flash * 2.0)


func _on_released(_origin: Vector3, _direction: Vector3, _charge: float) -> void:
	var profile: SpellProfile = _caster.current_profile
	if profile and not profile.shows_cast_glow:
		return
	_flash = 1.0


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
