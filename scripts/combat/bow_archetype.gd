class_name BowArchetype
extends Resource

## A family of bow — selfbow, recurve, compound — and the efficiency band its
## construction can reach.
##
## SEPARATE FROM [Bow] because efficiency is a property of how a bow is BUILT,
## not of the individual weapon. Every recurve, good or bad, converts stored
## energy into arrow speed better than any selfbow of the same draw weight,
## because the limb geometry is doing the work. An individual bow's
## [member Bow.quality] then places it inside its family's band.
##
## The consequence worth having: a new bow is authored by picking a family and
## a quality, rather than by inventing two efficiency numbers and hoping they
## sit sensibly against the bows that already exist.

@export var id: StringName = &"unnamed"
## Efficiency of the worst example of this family — [member Bow.quality] 0.
@export_range(0.1, 1.0, 0.01) var efficiency_low := 0.50
## Efficiency of the best example — [member Bow.quality] 1.
@export_range(0.1, 1.0, 0.01) var efficiency_high := 0.75


## The efficiency ceiling a bow of this family at [param quality] can reach.
## Still a ceiling, not the answer: the arrow's own mass decides how much of it
## is actually realised — see [method ArcheryPhysics.efficiency].
func max_efficiency_at(quality: float) -> float:
	return lerpf(efficiency_low, efficiency_high, clampf(quality, 0.0, 1.0))
