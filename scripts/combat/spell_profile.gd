class_name SpellProfile
extends Resource

## Everything that distinguishes one cast from another: how long each phase
## lasts, what shape the windup has, which animation plays, and what leaves the
## hand.
##
## WHY THIS EXISTS. spell_caster.gd used to carry a single set of timing exports
## that every spell shared, and `current_spell` was a bare string tag nothing
## ever interpreted. That works for exactly as long as every spell casts the
## same way. Two separate pressures broke it: spells wanting their own casting
## times and animations, and archery, whose draw does not end on a clock at all
## — it ends when the player lets go, over a duration derived from the bow and
## the player's own strength.
##
## Those two pressures have the same answer. Once a spell owns its casting
## profile, a charge-hold windup stops being a special case bolted onto a timed
## machine and becomes one more profile shape — see [enum WindupMode]. Adding
## the charged case AFTER designing this abstraction would have meant threading
## an `if charged` branch back through the state machine, which is precisely
## what profiles exist to avoid.
##
## A RESOURCE RATHER THAN JSON, deliberately, and the opposite call from
## data/zones/*.json. A profile holds a [PackedScene], and JSON cannot carry a
## resource reference — zone_layout.gd needed an entire string->scene registry
## plus its own validation for exactly that reason. Profiles are also few,
## hand-authored, and want the inspector's ranges and type checking. The zone
## precedent is for bulk world data a placement tool edits; this is not that.

## How the WINDUP phase ends. The one field that changes the state machine's
## shape rather than just its numbers.
enum WindupMode {
	## Ends on a clock, after [member windup_time]. Every spell cast before
	## profiles existed worked this way, and this stays the default.
	TIMED,
	## Ends when the player releases the button — see
	## [method SpellCaster.release_charge] — and never on its own.
	## [member windup_time] becomes the time taken to reach FULL charge;
	## holding past that simply stays at full rather than firing.
	CHARGED,
}

## How the shot is pointed, which decides what kind of projectile is spawned and
## how it is aimed.
enum AimMode {
	## Straight at the target, led for its motion — player_attacks.lead_aim. For
	## anything that flies flat at a constant speed and ignores gravity.
	STRAIGHT_LEAD,
	## An arc that lands on the target, solved by [BallisticSolver] against the
	## projectile's real speed and drag. For anything that falls.
	BALLISTIC,
	## The hit is resolved as a straight line the instant the cast releases —
	## the assisted target if one is selected, otherwise a raycast along the aim
	## direction. Nothing about that resolution is negotiable by presentation:
	## a HITSCAN projectile scene (see lightning_bolt.gd) may draw whatever
	## crooked, forking shape it likes, but the shape has zero say in what got
	## hit. For anything that should read as arriving too fast to dodge.
	HITSCAN,
}

@export_group("Identity")
## For logs and debug output only. Nothing branches on it — the whole point of
## profiles is that behaviour comes from the fields below, not from a tag.
@export var id: StringName = &"unnamed"

@export_group("Timing")
@export var windup_mode: WindupMode = WindupMode.TIMED
## TIMED: how long the windup lasts. CHARGED: how long a full charge takes,
## unless [member charge_duration_from_owner] hands that question elsewhere.
@export_range(0.05, 5.0, 0.01) var windup_time := 0.30
## CHARGED only: ignore [member windup_time] and ask the caster's owner how far
## along the charge is, via a `get_charge_fraction(hold_time)` method.
##
## THIS IS THE EQUIPMENT SEAM. A bow's time to full draw depends on its draw
## weight and the player's strength, none of which a static resource can know —
## so archery profiles set this and answer from live equipment and stats. A
## charged spell with no gear behind it leaves it false and charges on its own
## clock.
##
## Opt-in per profile rather than "ask the owner whenever one answers", because
## the owner has exactly one such method: without this flag a charged bomb
## would silently be charged at the equipped BOW's rate.
@export var charge_duration_from_owner := false
## The thrust itself. Short and sharp; this is the "hit" of the animation.
@export_range(0.02, 1.0, 0.01) var release_time := 0.14
## Settling back. Overlaps with being able to move again.
@export_range(0.0, 2.0, 0.01) var recover_time := 0.32
## Dead time after recovery before another cast is accepted.
@export_range(0.0, 5.0, 0.05) var cooldown_time := 0.15

@export_group("Behaviour")
## Movement multiplier while this cast is in flight. 0 roots the caster, 1 lets
## them move at full speed.
##
## PER PROFILE because the right answer depends on the cast. A 0.3 s bolt at
## 25% speed is barely felt; a two-second draw at the same multiplier is a long
## time to be crawling, and may want to be more generous.
@export_range(0.0, 1.0, 0.05) var move_scale_while_casting := 0.25
## Whether the character snaps to face the aim point for the duration.
@export var face_aim_while_casting := true
## Queue a press that arrives slightly too early rather than dropping it.
##
## IGNORED FOR CHARGED PROFILES, and not as an oversight — see
## [method buffers_input] for why a buffered draw is incoherent.
@export var allow_input_buffer := true

@export_group("Presentation")
## WHICH animation to play, not the animation itself. player_animator.gd owns
## the mapping from tag to actual bone poses; an unknown or empty tag falls
## back to its default set.
##
## The split matters. Those poses are written in Mage.glb's rest space and mean
## nothing on another rig, so carrying them here would couple spell data to the
## character model. It also means that when real keyframed animations replace
## the procedural animator, PROFILES DO NOT CHANGE AT ALL — only the mapping
## inside the animator does.
@export var animation_tag: StringName = &"bolt"
## Whether the glowing orb gathers in the casting hand — see cast_effect.gd.
## False for anything that is not magic: a drawn bow should not have a ball of
## light in its fist.
@export var shows_cast_glow := true

@export_group("Effect")
## How this shot is pointed — see [enum AimMode]. Also decides which projectile
## contract [member projectile_scene] is expected to satisfy: a straight-lead
## scene is launched like projectile.gd, a ballistic one like arrow.gd.
@export var aim_mode: AimMode = AimMode.STRAIGHT_LEAD
## What leaves the hand at release. Null casts nothing, which is legitimate for
## a spell whose whole effect is elsewhere.
@export var projectile_scene: PackedScene = null
## Multiplier applied to the projectile's own authored damage, at zero charge
## (x) and at full charge (y). Ignored entirely by TIMED profiles.
##
## A DELIBERATELY SIMPLE HOOK, and NOT the seam archery uses. An arrow's damage
## comes from real stored energy — a quadratic in draw fraction, scaled by bow
## efficiency and decayed over distance — which is a physics model of its own
## and does not reduce to a lerp. This exists so an ordinary charged spell can
## say "harder when held longer" without one.
@export var charge_damage_scale := Vector2(1.0, 1.0)


## Whether this profile's windup waits on the player rather than on a clock.
func is_charged() -> bool:
	return windup_mode == WindupMode.CHARGED


## Whether an early press should be queued for this profile.
##
## CHARGED PROFILES NEVER BUFFER. The buffer exists to catch a press that
## arrived a few frames before the caster was ready, and it fires that press
## once the cast finishes. For a charged cast the player has almost certainly
## let go by then, so the buffered draw would begin and end in the same breath
## and loose a shot at essentially zero power — which reads as the game eating
## an input and firing a dud, not as responsiveness. Dropping the press is the
## honest behaviour, and encoding the rule here keeps it out of the caller.
func buffers_input() -> bool:
	return allow_input_buffer and not is_charged()


## The damage multiplier for a shot released at [param charge] (0..1). Exactly
## 1.0 for a TIMED profile, so callers never need to branch on the mode.
func damage_multiplier_at(charge: float) -> float:
	if not is_charged():
		return 1.0
	return lerpf(charge_damage_scale.x, charge_damage_scale.y, clampf(charge, 0.0, 1.0))
