class_name ArrowSpec
extends Resource

## One kind of arrow: what it weighs and how hard the air fights it.
##
## Named ArrowSpec rather than Arrow because this is the TYPE, not the thing in
## flight — the projectile that actually flies carries one of these.
##
## ARROW MASS IS A REAL TRADE, NOT A STAT. A light arrow leaves faster but
## carries less energy and sheds it sooner; a heavy one is slower off the string
## and hits harder further out. Neither is simply better, and the reason is
## mechanical rather than authored: a bow transfers energy to a heavy arrow more
## efficiently (see [method ArcheryPhysics.efficiency]) while a light arrow
## wastes some of the draw accelerating the string and limbs themselves.

@export var id: StringName = &"unnamed"
@export var display_name := "Arrow"
## Mass in GRAMS, because that is the size of number an arrow is described in.
## Converted to kilograms at the one place the physics needs it.
@export_range(5.0, 200.0, 0.5) var mass_g := 37.0
## Air drag, in the form the closed-form flight solution wants — see
## [method ArcheryPhysics.decay_rate]. Heavier arrows are also physically
## bigger, so this rises with mass across the shipped set rather than being
## independent of it.
@export_range(0.00001, 0.01, 0.000001) var drag_coefficient := 0.000153


func mass_kg() -> float:
	return mass_g * 0.001
