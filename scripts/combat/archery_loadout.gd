class_name ArcheryLoadout
extends Node

## What the archer is carrying, and the one place that turns it into a shot.
##
## THE EQUIPMENT SEAM SpellProfile.charge_duration_from_owner EXISTS FOR. A bow's
## time to full draw and the fraction of it a given archer can actually reach
## depend on draw weight and on strength — neither of which a static resource can
## know and neither of which the cast state machine has any business knowing. So
## spell_caster.gd asks its owner how drawn the bow is, the player forwards the
## question here, and this answers from live equipment.
##
## WHY A SEPARATE NODE rather than fields on the player: the player is about
## moving, and archery is about neither moving nor casting. Keeping it here means
## an NPC archer is the same node on a different body, and swapping bows later is
## one property on one node rather than a change to the character.
##
## Stats live here TEMPORARILY. Strength and archery are character stats and
## belong to whatever progression system eventually exists; they sit here now
## because nothing else owns them yet, and this is the only thing that reads them.

@export_group("Equipment")
@export var bow: Bow = null
@export var arrow: ArrowSpec = null

@export_group("Stats")
## See the class note — these are placeholders for a progression system.
@export_range(0.0, 100.0, 1.0) var strength := 10.0
@export_range(0.0, 100.0, 1.0) var archery := 10.0


## Whether there is anything here to shoot with.
func is_ready_to_shoot() -> bool:
	return bow != null and arrow != null and bow.archetype != null


## How far the string is drawn after holding for [param hold_time], 0..1.
##
## Returns -1 when there is nothing equipped, which is spell_caster.gd's signal to
## fall back to the profile's own clock rather than trust a number this could not
## work out — see [method SpellCaster._compute_charge]. Answering 0 or 1 instead
## would silently produce a bow that never draws, or one that is always at full.
func charge_fraction(hold_time: float) -> float:
	if not is_ready_to_shoot():
		return -1.0
	return ArcheryPhysics.pull_fraction(hold_time, bow.draw_weight_kg, strength, archery)


## Everything about the shot loosed at [param pull] — see
## [method ArcheryPhysics.solve_shot_at_pull]. An empty loadout returns a shot of
## zero everything, so a caller sees "this loosed nothing" rather than crashing.
func solve_at_pull(pull: float) -> Dictionary:
	return ArcheryPhysics.solve_shot_at_pull(bow, arrow, archery, pull)


## Seconds this archer needs to reach full draw on the current bow — for a draw
## meter, and for tuning the profile's fallback windup_time against reality.
func time_to_full_draw() -> float:
	if not is_ready_to_shoot():
		return 0.0
	return ArcheryPhysics.time_to_max_draw(bow.draw_weight_kg, strength, archery)


## The furthest this archer can draw this bow, 0..1 — below 1 means the bow is
## too heavy for them and no amount of holding will fix it.
func draw_ceiling() -> float:
	if not is_ready_to_shoot():
		return 0.0
	return ArcheryPhysics.max_draw_fraction(bow.draw_weight_kg, strength, archery)
