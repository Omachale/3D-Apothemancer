extends Node3D

## Top-level wiring for the playable scene. Keeps the scene file dumb: the
## world just seats the player at whatever spawn the current zone declares and
## points the camera at them.

@onready var zone: Node3D = $Zone
@onready var player: CharacterBody3D = $Player
@onready var camera_rig: Node3D = $CameraRig
@onready var atmosphere: Atmosphere = $WorldEnvironment
@onready var sun: DirectionalLight3D = $Sun


func _ready() -> void:
	# Fog has to be applied from here rather than by the WorldEnvironment
	# itself: its distances are derived from the zone's horizon distance, and
	# siblings are ready in tree order, so WorldEnvironment runs before the
	# zone has published anything. The world is ready after both.
	atmosphere.apply(zone.get_atmosphere(),
		zone.get_terrain_manager().get("horizon_distance", 480.0),
		camera_rig.get_camera(), sun)

	# Children are ready before us, so the zone has already published its spawn.
	var spawn := Game.spawn_transform
	if spawn != Transform3D.IDENTITY:
		player.global_position = spawn.origin
		# Facing lives on the model, not the body, so movement stays
		# camera-relative regardless of which way the character is looking.
		player.model.rotation.y = spawn.basis.get_euler().y + deg_to_rad(player.model_yaw_offset)

	camera_rig.target = player
	camera_rig.snap_to_target()
