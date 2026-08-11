class_name Health
extends Node

## Hit points for anything that can be damaged.
##
## A COMPONENT rather than fields on npc_controller.gd, for the reason
## [[DESIGN_GOALS.md]] gives about game rules: they change repeatedly and
## should sit behind a seam they can be thrown away from without disturbing
## movement, camera or terrain. Nothing here knows what a hit point means or
## what killed anything — it counts down and announces, and the rules about
## damage types, resistances and death consequences live wherever they end up
## living. The player will want this same component when the player becomes
## damageable.
##
## Attach as a child node named "Health"; npc_controller.gd finds it by that
## name and forwards [method take_damage] to it.

## Emitted whenever [member current] changes, including the change that kills.
## Carries both numbers so a health bar needs no reference back to this node.
signal changed(current: float, maximum: float)
## Emitted exactly once, when health first reaches zero. Guarded by [member
## _dead] rather than by testing `current <= 0.0` at the call site, because two
## projectiles landing on the same frame would otherwise both see zero and fire
## this twice — which for a listener that spawns a death effect or grants
## experience is a real duplicate, not a harmless one.
signal died

@export_range(1.0, 1000.0, 1.0) var maximum := 20.0

## Set from [member maximum] in [method _ready] rather than exported, so there
## is no way to author a scene that starts already damaged by accident.
var current := 0.0

var _dead := false


func _ready() -> void:
	current = maximum


func take_damage(amount: float) -> void:
	if _dead or amount <= 0.0:
		return
	current = maxf(0.0, current - amount)
	changed.emit(current, maximum)
	if current <= 0.0:
		_dead = true
		died.emit()


func heal(amount: float) -> void:
	if _dead or amount <= 0.0:
		return
	current = minf(maximum, current + amount)
	changed.emit(current, maximum)


func is_alive() -> bool:
	return not _dead


## 0.0 to 1.0, so a bar can size itself without repeating the division (and
## without repeating the divide-by-zero guard).
func fraction() -> float:
	return current / maxf(maximum, 0.001)
