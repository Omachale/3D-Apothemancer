extends CanvasLayer

## Name and health of the currently selected target, at top centre. Hidden
## entirely when nothing is selected, rather than sitting there empty.
##
## Reads [Targeting] and the target's own [Health]; it holds no state of its
## own and decides nothing, so the panel cannot disagree with the game — if the
## bar is wrong, the health is wrong.
##
## The health connection is re-made on every target change and torn down on the
## way out. That teardown matters more than it looks: without it the panel stays
## connected to the previous target's Health, and since a dying NPC's health
## keeps changing while it collapses, the bar would go on animating for
## something the player is no longer looking at.

@onready var _root: Control = $Root
@onready var _name_label: Label = $Root/Box/Name
@onready var _bar: ProgressBar = $Root/Box/Bar

var _health: Health = null


func _ready() -> void:
	_root.visible = false
	Targeting.target_changed.connect(_on_target_changed)
	# Pick up a target that was already selected before this panel was ready.
	_on_target_changed(Targeting.current)


func _on_target_changed(target: Node3D) -> void:
	_disconnect_health()

	if target == null or not is_instance_valid(target):
		_root.visible = false
		return

	_root.visible = true
	_name_label.text = (target.get_display_name()
		if target.has_method("get_display_name") else target.name)

	if target.has_method("get_health"):
		_health = target.get_health()
	if _health and is_instance_valid(_health):
		_health.changed.connect(_on_health_changed)
		_show_health(_health.current, _health.maximum)
	else:
		# Targetable but with no Health component: show the name, drop the bar,
		# rather than displaying a full bar for something that cannot be hurt.
		_bar.visible = false


func _disconnect_health() -> void:
	if _health and is_instance_valid(_health) and _health.changed.is_connected(_on_health_changed):
		_health.changed.disconnect(_on_health_changed)
	_health = null


func _on_health_changed(current: float, maximum: float) -> void:
	_show_health(current, maximum)


func _show_health(current: float, maximum: float) -> void:
	_bar.visible = true
	_bar.max_value = maximum
	_bar.value = current
