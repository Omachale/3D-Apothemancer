extends CanvasLayer

## Minimal loadout screen: two slots, LMB and RMB, each swappable to any
## profile in the known pool. Opens and closes on "C".
##
## FREEZES THE PLAYER WHILE OPEN — see player_controller.set_input_frozen —
## so browsing a menu can never also be mid-fight movement or a stray cast.
## The freeze is the actual seam; this class does not touch movement or
## casting directly, it just tells the player controller whose turn it is.
##
## THE POOL IS A FLAT EXPORTED LIST, not a scan of resources/spells/ and not a
## real inventory — neither exists yet, and nothing yet distinguishes "owned"
## from "not owned". That is the obvious seam for later: swap
## [member known_profiles] for a query into whatever ends up owning unlocks,
## and nothing else here changes.

@export var known_profiles: Array[SpellProfile] = []
@export var caster_path: NodePath
@export var player_path: NodePath

var _caster: Node = null
var _player: Node = null
## "primary" or "secondary" while the picker is open for that slot; empty
## when the picker is closed.
var _picking_slot := ""

@onready var _root: Control = $Root
@onready var _primary_button: Button = $Root/Card/Box/Slots/PrimaryButton
@onready var _secondary_button: Button = $Root/Card/Box/Slots/SecondaryButton
@onready var _picker: Control = $Root/Card/Box/Picker
@onready var _picker_title: Label = $Root/Card/Box/Picker/PickerBox/PickerTitle
@onready var _picker_list: VBoxContainer = $Root/Card/Box/Picker/PickerBox/List
@onready var _picker_cancel: Button = $Root/Card/Box/Picker/PickerBox/Cancel


func _ready() -> void:
	layer = 90
	_caster = get_node_or_null(caster_path)
	if _caster == null and Game.player:
		_caster = Game.player.get_node_or_null("SpellCaster")
	_player = get_node_or_null(player_path)
	if _player == null:
		_player = Game.player
	_primary_button.pressed.connect(_open_picker.bind("primary"))
	_secondary_button.pressed.connect(_open_picker.bind("secondary"))
	_picker_cancel.pressed.connect(_close_picker)
	_close_picker()
	_set_open(false)


func _process(_delta: float) -> void:
	if Input.is_action_just_pressed("open_character_screen"):
		_set_open(not _root.visible)


func _set_open(open: bool) -> void:
	_root.visible = open
	if not open:
		_close_picker()
	else:
		_refresh_labels()
	if _player and _player.has_method("set_input_frozen"):
		_player.set_input_frozen(open)


func _refresh_labels() -> void:
	var primary: SpellProfile = _caster.primary_profile if _caster else null
	var secondary: SpellProfile = _caster.secondary_profile if _caster else null
	_primary_button.text = "LMB:  %s" % _profile_name(primary)
	_secondary_button.text = "RMB:  %s" % _profile_name(secondary)


func _profile_name(profile: SpellProfile) -> String:
	return String(profile.id).capitalize() if profile else "(empty)"


func _open_picker(slot: String) -> void:
	_picking_slot = slot
	_picker_title.text = "Choose attack for %s" % ("LMB" if slot == "primary" else "RMB")
	for child in _picker_list.get_children():
		child.queue_free()
	for profile in known_profiles:
		if profile == null:
			continue
		var button := Button.new()
		button.text = _profile_name(profile)
		button.pressed.connect(_pick.bind(profile))
		_picker_list.add_child(button)
	_picker.visible = true


func _pick(profile: SpellProfile) -> void:
	if _caster and _caster.has_method("set_profile"):
		_caster.set_profile(_picking_slot, profile)
	_refresh_labels()
	_close_picker()


func _close_picker() -> void:
	_picking_slot = ""
	_picker.visible = false
