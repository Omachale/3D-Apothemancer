extends Node

## Checks the Health component and its wiring into the NPC scenes: both NPCs
## carry 20 hit points, damage forwards through npc_controller's duck-typed
## take_damage, death fires exactly once, and overkill cannot re-fire it.
##
## Run as a SCENE rather than with --script, because npc_controller.gd reaches
## the Game autoload and autoloads are not set up for --script:
##   Godot --headless res://scenes/dev/VerifyHealth.tscn
## Exits non-zero if any check fails.

const NPC_SCENES := [
	"res://scenes/npc/Witch.tscn",
	"res://scenes/npc/Medieval.tscn",
]
## Must match the `damage` set on the player's bolt scenes.
const BOLT_DAMAGE := 5.0

var _failures := 0


func _ready() -> void:
	for path in NPC_SCENES:
		_check_npc(path)
	_check_bolt_damage()
	if _failures == 0:
		print("VERIFY HEALTH: PASS")
	else:
		print("VERIFY HEALTH: FAIL (%d)" % _failures)
	get_tree().quit(1 if _failures > 0 else 0)


func _fail(message: String) -> void:
	print("  FAIL: %s" % message)
	_failures += 1


func _check_npc(path: String) -> void:
	var npc: Node = load(path).instantiate()
	add_child(npc)

	var health := npc.get_node_or_null("Health") as Health
	if health == null:
		_fail("%s has no Health child" % path)
		npc.queue_free()
		return
	if not is_equal_approx(health.maximum, 20.0):
		_fail("%s max health is %.1f, expected 20" % [path, health.maximum])
	if not is_equal_approx(health.current, health.maximum):
		_fail("%s starts at %.1f/%.1f, should start full" % [
			path, health.current, health.maximum])
	if not npc.has_method("take_damage"):
		_fail("%s has no take_damage() for projectile.gd to call" % path)
		npc.queue_free()
		return
	if npc.get_display_name().is_empty():
		_fail("%s has no display name for the target panel" % path)

	var deaths := [0]
	health.died.connect(func() -> void: deaths[0] += 1)

	# One bolt short of lethal: still alive, and quietly still alive.
	var hits_to_kill := int(health.maximum / BOLT_DAMAGE)
	for i in hits_to_kill - 1:
		npc.take_damage(BOLT_DAMAGE)
	if deaths[0] != 0:
		_fail("%s died after %d of %d hits" % [path, hits_to_kill - 1, hits_to_kill])
	if not health.is_alive():
		_fail("%s not alive with %.1f HP left" % [path, health.current])
	var expected := health.maximum - BOLT_DAMAGE * (hits_to_kill - 1)
	if not is_equal_approx(health.current, expected):
		_fail("%s at %.1f HP, expected %.1f" % [path, health.current, expected])

	# The lethal one.
	npc.take_damage(BOLT_DAMAGE)
	if deaths[0] != 1:
		_fail("%s fired died %d times on the killing blow, expected 1" % [path, deaths[0]])
	if health.is_alive():
		_fail("%s still alive at 0 HP" % path)
	if health.current < 0.0:
		_fail("%s health went negative (%.1f)" % [path, health.current])

	# Overkill, and a second hit after death, must both stay silent — two bolts
	# landing on the same frame must not each announce a death.
	npc.take_damage(999.0)
	npc.take_damage(BOLT_DAMAGE)
	if deaths[0] != 1:
		_fail("%s re-fired died after death (%d total)" % [path, deaths[0]])

	print("  %s: 20 HP, %d hits to kill, died once" % [path.get_file(), hits_to_kill])
	npc.queue_free()


## The bolts must actually carry damage, or everything above passes while
## nothing in the game can hurt anyone.
func _check_bolt_damage() -> void:
	for path in ["res://scenes/player/RedBolt.tscn", "res://scenes/player/BlueBomb.tscn"]:
		var bolt: Node = load(path).instantiate()
		if bolt.damage <= 0.0:
			_fail("%s does no damage (%.1f)" % [path, bolt.damage])
		else:
			print("  %s: %.1f damage" % [path.get_file(), bolt.damage])
		bolt.queue_free()

	# The NPC's own bolt must stay harmless: the player has no Health yet, so
	# arming it would be damage into a void that looks like it works.
	var dark: Node = load("res://scenes/npc/DarkBolt.tscn").instantiate()
	if dark.damage > 0.0:
		_fail("DarkBolt does %.1f damage but the player has no Health" % dark.damage)
	dark.queue_free()
