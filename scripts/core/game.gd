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
## The active zone's streamed ground manager, set when the zone builds. Chiefly
## for TerrainManager.register_collision_anchor — see the note there for why
## anything standing on the ground away from the player needs this.
var terrain_manager: Node = null
## The active zone's ground shape, set when the zone builds. Anything that needs
## to know how high the ground is somewhere — spawning, placing props, dropping
## an NPC onto a hillside — should ask this rather than raycasting, because it
## answers instantly and works for ground that has not been streamed in yet.
##
## Only ever set at runtime. A zone's build() also runs in the editor, where
## this autoload is not fully constructed — which is why every Game access in
## zone.gd sits behind an Engine.is_editor_hint() check.
var heightfield: Heightfield = null

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


func register_terrain_manager(node: Node) -> void:
	terrain_manager = node


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
