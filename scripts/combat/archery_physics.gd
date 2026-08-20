class_name ArcheryPhysics
extends RefCounted

## The arrow economy, in real SI units end to end — joules, kilograms, metres,
## seconds, newtons.
##
## WHY REAL UNITS. Every number a shot produces falls out of the bow's draw
## weight by physics rather than by tuning, so "a 32 kg war bow hits harder than
## a 12 kg selfbow" is arithmetic rather than a balance decision someone made
## and has to keep re-making. Authoring a new bow means describing a real bow;
## its damage, range and draw time follow.
##
## DAMAGE IS A FUNCTION OF ENERGY, AND ENERGY IS A FUNCTION OF DISTANCE
## TRAVELLED — never of elapsed time or frame count. That is deliberate and it
## is what keeps a shot honest: the same arrow hitting the same target at the
## same range does the same damage on any machine at any frame rate, and
## "damage falls off with range" needs no separate falloff curve because it is
## already what the drag solution says.
##
## EVERYTHING HERE IS STATIC AND PURE. No node, no scene, no state — each
## function takes numbers and returns numbers. That is what lets the whole model
## be checked directly by verify_archery_physics.gd, the same way
## player_attacks.lead_aim is, and it is why the tuning constants below are
## constants rather than a resource that would have to be threaded through every
## call.
##
## Ported from the 2D prototype's ArcheryPhysics.gd/archery_config.json (see
## ARCHERY_HANDOFF.md). The two 2D-only constants — pixels_per_metre and
## speed_scale — are deliberately absent: they existed to convert metres into a
## 2D screen space, and this project's world is already in metres.

# ---------------------------------------------------------------------------
# UNIT CONVERSIONS
# ---------------------------------------------------------------------------

const GRAVITY := 9.81
const GRAINS_PER_KG := 15432.36
const LB_PER_KG := 2.20462

# ---------------------------------------------------------------------------
# DRAW CAPACITY — how much bow the player can physically pull
# ---------------------------------------------------------------------------

## Pull the player has before any stats, in kilograms-force.
const PULL_BASE_KG := 6.0
## Extra pull per weighted stat point.
const PULL_PER_POINT_KG := 1.4
## Pull is mostly strength, with technique contributing the rest.
const PULL_STRENGTH_WEIGHT := 0.8
const PULL_ARCHERY_WEIGHT := 0.2

# ---------------------------------------------------------------------------
# DRAW SPEED — how long reaching full draw takes
# ---------------------------------------------------------------------------

## Seconds to full draw on a reference bow at zero stats.
const DRAW_TIME_BASE_S := 2.0
## The draw weight DRAW_TIME_BASE_S is quoted against. A heavier bow takes
## proportionally longer.
const DRAW_WEIGHT_REF_KG := 20.0
## Draw-speed multiplier gained per weighted stat point.
const DRAW_SPEED_PER_POINT := 0.05
## Drawing quickly is mostly technique, unlike raw pulling power above.
const DRAW_SPEED_ARCHERY_WEIGHT := 0.8
const DRAW_SPEED_STRENGTH_WEIGHT := 0.2

# ---------------------------------------------------------------------------
# ENERGY TRANSFER
# ---------------------------------------------------------------------------

## Grains of arrow per pound of draw weight for an arrow "suited" to a bow — a
## standard archery rule of thumb, used to work out what mass this bow is built
## around and therefore how it treats arrows lighter or heavier than that.
const GRAINS_PER_LB_DRAW := 13.0
## Efficiency reaches ~90% of its ceiling at nine times the virtual mass, which
## is what this divisor encodes. It is the knob that decides how sharply light
## arrows are punished.
const VIRTUAL_MASS_DIVISOR := 9.0

# ---------------------------------------------------------------------------
# FLIGHT AND IMPACT
# ---------------------------------------------------------------------------

## Multiplier on real drag. 1.0 is physically honest.
##
## AN HONEST FUDGE FACTOR, kept named rather than folded into the arrow data:
## real arrow drag is barely perceptible over the ranges a game is played at, so
## at 1.0 the light-vs-heavy arrow trade is technically present and practically
## invisible. Raising this makes the trade legible at playable distances. Change
## it knowing that is what is being bought.
const DRAG_SCALE := 1.0
## Hit points per joule of impact energy.
const DAMAGE_SCALAR := 0.5
## An arrow is removed once its energy falls below this, in joules.
##
## AN ENERGY FLOOR RATHER THAN A RANGE CAP, so a war bow's arrow naturally flies
## further than a selfbow's without anyone authoring two range numbers.
const DESPAWN_ENERGY_J := 2.0

# ---------------------------------------------------------------------------
# AIM
# ---------------------------------------------------------------------------

## Spread at zero archery skill, as one standard deviation in degrees.
const AIM_BASE_STDDEV_DEG := 6.0
## Degrees of spread removed per point of archery.
const AIM_DEG_PER_ARCHERY := 0.25
## However skilled, a shot is never perfectly true.
const AIM_MIN_STDDEV_DEG := 0.4


# ---------------------------------------------------------------------------
# BOW PROPERTIES
# ---------------------------------------------------------------------------

## Force held at full draw, in newtons.
static func draw_force_newtons(draw_weight_kg: float) -> float:
	return draw_weight_kg * GRAVITY


## The energy an ideal spring of this bow's force and travel would store, in
## joules — the figure [method stored_energy_joules] then corrects and scales.
static func bow_power_joules(draw_weight_kg: float, draw_length_m: float) -> float:
	return draw_force_newtons(draw_weight_kg) * draw_length_m


# ---------------------------------------------------------------------------
# THE DRAW
# ---------------------------------------------------------------------------

## How much bow the player can pull at all, in kilograms-force.
static func pull_capacity_kg(strength: float, archery: float) -> float:
	var weighted := PULL_STRENGTH_WEIGHT * strength + PULL_ARCHERY_WEIGHT * archery
	return PULL_BASE_KG + PULL_PER_POINT_KG * weighted


## The furthest this player can draw this bow, as a fraction of full draw.
##
## A HARD PHYSICAL CEILING, not a penalty. Under-strength for the bow, the
## player cannot reach full draw however long they hold — which is exactly what
## happens with a real bow, and it is why draw time and draw fraction are two
## separate ideas throughout this file.
static func max_draw_fraction(draw_weight_kg: float, strength: float, archery: float) -> float:
	if draw_weight_kg <= 0.0:
		return 0.0
	return clampf(pull_capacity_kg(strength, archery) / draw_weight_kg, 0.0, 1.0)


## Draw-speed multiplier from stats. 1.0 at zero stats, rising from there.
static func draw_speed_multiplier(strength: float, archery: float) -> float:
	var weighted := DRAW_SPEED_ARCHERY_WEIGHT * archery + DRAW_SPEED_STRENGTH_WEIGHT * strength
	return 1.0 + DRAW_SPEED_PER_POINT * weighted


## Seconds to reach this player's maximum draw on this bow.
static func time_to_max_draw(draw_weight_kg: float, strength: float, archery: float) -> float:
	var speed := maxf(draw_speed_multiplier(strength, archery), 0.01)
	return DRAW_TIME_BASE_S * (draw_weight_kg / DRAW_WEIGHT_REF_KG) / speed


## How far the string is ACTUALLY back after holding for [param hold_time] — the
## number every energy calculation squares, and the one the animation should
## show.
##
## Two independent limits multiplied: how far through the draw the hold got, and
## how far this player can draw this bow at all. A strong archer on a light bow
## is limited only by time; a weak one on a war bow tops out early and stays
## there however long they hold.
static func pull_fraction(hold_time: float, draw_weight_kg: float,
		strength: float, archery: float) -> float:
	var full_at := time_to_max_draw(draw_weight_kg, strength, archery)
	var progress := clampf(hold_time / maxf(full_at, 0.0001), 0.0, 1.0)
	return progress * max_draw_fraction(draw_weight_kg, strength, archery)


# ---------------------------------------------------------------------------
# ENERGY
# ---------------------------------------------------------------------------

## Energy in the drawn bow, in joules. Quadratic in pull: drawing halfway stores
## a quarter, which is why a snap shot is so much weaker than a held one.
static func stored_energy_joules(bow_power_j: float, pull: float,
		storage_factor: float) -> float:
	var p := clampf(pull, 0.0, 1.0)
	return 0.5 * bow_power_j * p * p * storage_factor


## The arrow mass this bow is built around, in kilograms.
static func suited_arrow_mass_kg(draw_weight_kg: float) -> float:
	return draw_weight_kg * LB_PER_KG * GRAINS_PER_LB_DRAW / GRAINS_PER_KG


## Fraction of stored energy this arrow actually receives.
##
## THIS IS THE ENTIRE REASON ARROW WEIGHT MATTERS. A bow has to accelerate its
## own limbs and string as well as the arrow, and that share is fixed. A light
## arrow therefore leaves a larger fraction of the draw behind in the bow, while
## a heavy one carries more of it away. The virtual mass is that self-load
## expressed as an equivalent arrow.
static func efficiency(arrow_mass_kg: float, draw_weight_kg: float,
		max_efficiency: float) -> float:
	if arrow_mass_kg <= 0.0:
		return 0.0
	var virtual_mass := suited_arrow_mass_kg(draw_weight_kg) / VIRTUAL_MASS_DIVISOR
	return max_efficiency * arrow_mass_kg / (arrow_mass_kg + virtual_mass)


## Speed off the string, in metres per second, for an arrow given
## [param energy_j] of kinetic energy.
static func muzzle_velocity(energy_j: float, arrow_mass_kg: float) -> float:
	if arrow_mass_kg <= 0.0 or energy_j <= 0.0:
		return 0.0
	return sqrt(2.0 * energy_j / arrow_mass_kg)


# ---------------------------------------------------------------------------
# FLIGHT
#
# Solved in DISTANCE, in closed form, rather than integrated per frame. Two
# reasons, both mattering: a per-frame integration drifts with frame rate, so
# the same shot would do different damage on different machines; and a closed
# form can answer "how much energy will this have at 40 m" without simulating
# anything, which the aim solver needs before the arrow exists.
# ---------------------------------------------------------------------------

## Drag decay constant, per metre. Light arrows decay faster — the same drag
## acting on less mass.
static func decay_rate(drag_coefficient: float, arrow_mass_kg: float) -> float:
	if arrow_mass_kg <= 0.0:
		return 0.0
	return (drag_coefficient * DRAG_SCALE) / arrow_mass_kg


static func velocity_at_distance(muzzle_velocity_ms: float, decay: float,
		distance_m: float) -> float:
	return muzzle_velocity_ms * exp(-decay * maxf(distance_m, 0.0))


## Energy decays at TWICE the velocity rate, because energy goes as v squared.
static func energy_at_distance(muzzle_energy_j: float, decay: float,
		distance_m: float) -> float:
	return muzzle_energy_j * exp(-2.0 * decay * maxf(distance_m, 0.0))


## The distance at which impact energy has fallen to 1/e of what it left with —
## an honest basis for a "reach" stat, since it is derived from the arrow rather
## than authored alongside it. Infinite with no drag at all.
static func effective_range_m(decay: float) -> float:
	if decay <= 0.0:
		return INF
	return 1.0 / (2.0 * decay)


## How far the arrow travels before its energy falls under [constant
## DESPAWN_ENERGY_J]. Infinite with no drag; zero if the shot never had enough
## energy to be worth tracking in the first place.
static func max_flight_distance_m(muzzle_energy_j: float, decay: float) -> float:
	if muzzle_energy_j <= DESPAWN_ENERGY_J:
		return 0.0
	if decay <= 0.0:
		return INF
	return log(muzzle_energy_j / DESPAWN_ENERGY_J) / (2.0 * decay)


# ---------------------------------------------------------------------------
# IMPACT AND AIM
# ---------------------------------------------------------------------------

static func damage_from_energy(energy_j: float) -> float:
	return DAMAGE_SCALAR * maxf(energy_j, 0.0)


## Spread of the shot, as one standard deviation in degrees.
static func aim_stddev_degrees(archery: float) -> float:
	return maxf(AIM_BASE_STDDEV_DEG - AIM_DEG_PER_ARCHERY * archery, AIM_MIN_STDDEV_DEG)


## [param direction] nudged off true by a random amount in the horizontal plane only.
##
## GAUSSIAN, NOT A UNIFORM CONE, and the difference is felt rather than merely
## correct: a uniform cone scatters shots evenly across the whole spread, so
## most shots are noticeably off and the aim point means little. A Gaussian
## clusters them around where the player aimed, with the occasional flier —
## which is what shooting badly actually looks like.
##
## Scatter is horizontal only — the vertical component is never affected — and
## uses half the calculated stddev to keep spread tight.
static func scatter_direction(direction: Vector3, stddev_deg: float,
		rng: RandomNumberGenerator) -> Vector3:
	if direction.length_squared() < 0.0000001 or stddev_deg <= 0.0:
		return direction
	var aim := direction.normalized()
	var tilt := deg_to_rad(rng.randfn(0.0, stddev_deg * 0.5))
	return aim.rotated(Vector3.UP, tilt) * direction.length()


# ---------------------------------------------------------------------------
# THE WHOLE SHOT
# ---------------------------------------------------------------------------

## Everything about a shot loosed from [param bow] with [param arrow] after
## holding for [param hold_time], as one dictionary.
##
## The composite the game actually calls. Each step is available separately
## above so the model can be checked piece by piece, but nothing in the game
## should be assembling these by hand — that is how two call sites end up
## disagreeing about what a shot is worth.
##
## Returns keys: pull, stored_energy_j, efficiency, muzzle_energy_j,
## muzzle_velocity_ms, decay, effective_range_m, max_flight_distance_m,
## impact_damage, aim_stddev_deg. An unusable loadout (no bow, no arrow, no
## archetype) reports a shot of zero everything rather than failing, so a caller
## sees "this did nothing" instead of a crash.
static func solve_shot(bow: Bow, arrow: ArrowSpec, strength: float, archery: float,
		hold_time: float) -> Dictionary:
	if bow == null or arrow == null:
		return _blank_shot()
	return solve_shot_at_pull(bow, arrow, archery,
		pull_fraction(hold_time, bow.draw_weight_kg, strength, archery))


## The same shot, from a pull fraction that has already been worked out.
##
## EXISTS BECAUSE THE GAME DOES NOT KNOW HOLD TIME AT THE POINT IT NEEDS A SHOT.
## spell_caster.gd tracks the draw and hands out a 0..1 charge — which IS the pull
## fraction, since that is what it asked the loadout for — so re-deriving pull
## from a hold time it no longer has would mean threading the clock through the
## release signal for no gain. [method solve_shot] is now a thin wrapper that
## computes the pull first, so there is still one code path.
static func solve_shot_at_pull(bow: Bow, arrow: ArrowSpec, archery: float,
		pull: float) -> Dictionary:
	if bow == null or arrow == null:
		return _blank_shot()

	var mass := arrow.mass_kg()
	var stored := stored_energy_joules(
		bow_power_joules(bow.draw_weight_kg, bow.draw_length_m), pull, bow.storage_factor)
	var eff := efficiency(mass, bow.draw_weight_kg, bow.max_efficiency())
	var muzzle_energy := stored * eff
	var decay := decay_rate(arrow.drag_coefficient, mass)

	return {
		"pull": pull,
		"stored_energy_j": stored,
		"efficiency": eff,
		"muzzle_energy_j": muzzle_energy,
		"muzzle_velocity_ms": muzzle_velocity(muzzle_energy, mass),
		"decay": decay,
		"effective_range_m": effective_range_m(decay),
		"max_flight_distance_m": max_flight_distance_m(muzzle_energy, decay),
		"impact_damage": damage_from_energy(muzzle_energy),
		"aim_stddev_deg": aim_stddev_degrees(archery),
	}


## A shot that does nothing, for an unusable loadout — reported rather than
## failing, so a caller sees "this loosed nothing" instead of a crash.
static func _blank_shot() -> Dictionary:
	return {
		"pull": 0.0, "stored_energy_j": 0.0, "efficiency": 0.0,
		"muzzle_energy_j": 0.0, "muzzle_velocity_ms": 0.0, "decay": 0.0,
		"effective_range_m": 0.0, "max_flight_distance_m": 0.0,
		"impact_damage": 0.0, "aim_stddev_deg": AIM_BASE_STDDEV_DEG,
	}
