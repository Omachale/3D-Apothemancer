class_name Bow
extends Resource

## One bow, authored the way real bows are described: in draw weight and draw
## length, not in an abstract damage number.
##
## THE UNITS ARE REAL AND THAT IS THE POINT. Draw weight in kilograms-force is
## the archery convention, and every downstream number — stored energy, arrow
## speed, impact damage — falls out of it by physics rather than by tuning. So
## "a 32 kg war bow hits harder than a 12 kg selfbow" is not a balance decision
## someone made; it is arithmetic. See archery_physics.gd.

@export var id: StringName = &"unnamed"
@export var display_name := "Bow"
## Which family this is built as — see [BowArchetype]. Without one the bow
## cannot compute efficiency and is treated as unusable.
@export var archetype: BowArchetype = null

@export_group("Physical")
## Force needed to hold the bow at full draw, in kilograms-force. The single
## number that most defines a bow: it sets stored energy, how long the draw
## takes, and whether the player is strong enough to reach full draw at all.
@export_range(4.0, 80.0, 0.5) var draw_weight_kg := 20.0
## How far the string travels from rest to full draw, in metres.
@export_range(0.3, 1.0, 0.01) var draw_length_m := 0.72
## Where this individual bow sits inside its family's efficiency band, 0..1.
@export_range(0.0, 1.0, 0.01) var quality := 0.70
## Correction for the fact that a real bow's force-draw curve does not start at
## zero force and rise linearly.
##
## WITHOUT THIS THE ENERGY IS WRONG BY 20-30%. Treating a bow as an ideal spring
## (energy = half force times distance) overstates what it actually stores,
## because the early part of the draw resists more than a straight line from the
## origin would. This scales the ideal figure down to the real one, and is a
## property of the limb design — hence per bow rather than global.
@export_range(0.5, 1.0, 0.01) var storage_factor := 0.78


## The efficiency ceiling this specific bow can reach. Zero with no archetype
## assigned, which makes the bow loose nothing rather than silently behaving
## like some default weapon.
func max_efficiency() -> float:
	return archetype.max_efficiency_at(quality) if archetype else 0.0
