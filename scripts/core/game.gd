extends Node

## Autoload singleton. The one stable place anything can reach the player,
## the camera or the active zone from, without hard NodePaths.
##
## Zone switching is stubbed here deliberately: right now there is a single
## starter zone, but every consumer already goes through [method change_zone]
## so adding more zones later does not touch the rest of the codebase.

signal player_registered(player: Node3D)
signal camera_registered(camera_rig: Node3D)
signal zone_changed(zone: Node3D)

var player: Node3D = null
var camera_rig: Node3D = null
var current_zone: Node3D = null

## Set by whichever zone is loaded; the world uses it to place the player.
var spawn_transform := Transform3D.IDENTITY


func register_player(node: Node3D) -> void:
	player = node
	player_registered.emit(node)


func register_camera(node: Node3D) -> void:
	camera_rig = node
	camera_registered.emit(node)


func register_zone(node: Node3D) -> void:
	current_zone = node
	zone_changed.emit(node)


## Placeholder for multi-zone support. Swaps the zone node under the world
## root and re-seats the player at the new zone's spawn point.
func change_zone(zone_scene: PackedScene) -> void:
	if current_zone == null:
		push_warning("Game.change_zone called before a zone was registered.")
		return
	var parent := current_zone.get_parent()
	var old := current_zone
	var next: Node3D = zone_scene.instantiate()
	parent.add_child(next)
	old.queue_free()
	register_zone(next)
	if player:
		player.global_transform = spawn_transform
