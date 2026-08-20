# Archery System — Handoff for the 3D Game

This documents the archery rules and values as implemented in the 2D
`hd-prototype` game (source repo: https://github.com/Omachale/Apoth-hd-prototype).
It's a factual record of what exists, not a proposal for how the 3D game
should work — the 3D project has its own setup and constraints this doc
doesn't know about.

Source files, all in `hd-prototype/scripts/`:
`ArcheryPhysics.gd`, `Config.gd`, `ShotSolver.gd`, `DrawState.gd`,
`DrawMeter.gd`, `Arrow.gd`, plus the archery-specific parts of
`WizardPlayer.gd`. Data lives in `hd-prototype/data/archery_config.json`.

---

## 1. Design principle

Everything runs in real SI units — joules, kilograms, metres, seconds,
newtons — end to end. Pixels/screen-space only enter at exactly one seam:
converting the computed muzzle velocity (m/s) into a speed the renderer
draws with. Damage is always a pure function of **energy**, and energy is
always a pure function of **distance travelled**, never of elapsed real
time or frame count. This is deliberate: it keeps flight framerate-
independent and keeps damage-at-range honest and reproducible.

Bows are authored in kilograms-force draw weight (the real-world archery
convention), not in an abstract game unit.

---

## 2. The formulas (`ArcheryPhysics.gd`)

### Bow properties
- `draw_force_N = draw_weight_kg * gravity`
- `spring_constant_N_per_m = draw_force_N / draw_length_m`
- `bow_power_J = draw_force_N * draw_length_m` (an energy quantity, named
  for traceability to the source design brief, not literally power)

### Draw (how far the player can pull, and how fast)
- `pull_capacity_kg = pull_base_kg + pull_per_point_kg * (pull_strength_weight * strength + pull_archery_weight * archery)`
- `max_draw_fraction = clamp(pull_capacity_kg / bow_draw_weight_kg, 0, 1)` —
  the hard cap: if the player isn't strong enough, they physically cannot
  reach full draw no matter how long they hold.
- `time_to_max_draw = draw_time_base_s * (draw_weight_kg / draw_weight_ref_kg) / max(speed, 0.01)`
  where `speed = 1 + draw_speed_per_point * (draw_speed_archery_weight * archery + draw_speed_strength_weight * strength)`
- `draw_progress = clamp(hold_time / time_to_max_draw, 0, 1)`
- `pull_fraction (p) = draw_progress * max_draw_fraction` — the actual
  spatial pull achieved, combining "how long you held" with "whether you
  could ever reach 100%."

### Energy at release
- `stored_energy_J = 0.5 * bow_power_J * p^2 * storage_factor`
  (quadratic in pull; `storage_factor` corrects for a real bow's force-draw
  curve not starting at zero — a linear spring from zero overstates energy
  by 20–30%)
- `suited_arrow_mass_kg = draw_weight_kg * lb_per_kg * grains_per_lb_draw / grains_per_kg`
  (~13 grains of arrow per lb of draw weight — a standard archery
  heuristic for "the arrow this bow is built around")
- `virtual_mass_kg = suited_arrow_mass_kg / virtual_mass_divisor` (divisor
  = 9; efficiency reaches ~90% of its ceiling at 9x virtual mass)
- `max_efficiency = lerp(archetype.efficiency_low, archetype.efficiency_high, quality)`
- `efficiency(arrow_mass) = max_efficiency * arrow_mass / (arrow_mass + virtual_mass)`
  — this is the entire reason arrow weight matters: too light an arrow for
  the bow wastes energy, too heavy carries more of it.
- `arrow_energy_J = stored_energy_J * efficiency`
- `muzzle_velocity_m_s = sqrt(2 * arrow_energy_J / arrow_mass_kg)`

### Flight (drag)
Closed-form solution in **distance**, not integrated per-frame in time
(avoids drift, is framerate-independent):
- `decay_rate = (drag_coefficient * drag_scale) / arrow_mass_kg`
- `velocity_at_distance(d) = v0 * exp(-decay_rate * d)`
- `energy_at_distance(d) = e0 * exp(-2 * decay_rate * d)` (energy decays at
  twice the velocity rate, since E ~ v²)
- `effective_range_m = 1 / (2 * decay_rate)` — the distance at which
  impact energy has fallen to 1/e; the honest basis for a "reach" stat
- `max_flight_distance_m = ln(e0 / despawn_floor_J) / (2 * decay_rate)` —
  arrow despawns on an energy floor, not a flat range cap, so it scales
  naturally with mass and bow strength

### Impact
- `damage = damage_scalar * energy_J` (simple linear map, `damage_scalar = 0.5`
  currently)

### Aim scatter
- `aim_stddev_deg = max(aim_base_stddev_deg - aim_deg_per_archery * archery, aim_min_stddev_deg)`
- Offset sampled from a **Gaussian** (not uniform cone) at release time,
  so shots cluster near the aim point rather than spreading evenly.

---

## 3. Tunable values (`archery_config.json`)

### Units / scale
```
gravity: 9.81
pixels_per_metre: 86.0       # 2D-screen-space only; not meaningful in 3D
speed_scale: 6.5             # 2D visual-speed fudge; not meaningful in 3D
grains_per_kg: 15432.36
lb_per_kg: 2.20462
```

### Tuning constants
```
pull_base_kg: 6.0
pull_per_point_kg: 1.4
pull_strength_weight: 0.8
pull_archery_weight: 0.2

draw_time_base_s: 2.0
draw_weight_ref_kg: 20.0
draw_speed_per_point: 0.05
draw_speed_archery_weight: 0.8
draw_speed_strength_weight: 0.2

grains_per_lb_draw: 13.0
virtual_mass_divisor: 9.0

aim_base_stddev_deg: 6.0
aim_deg_per_archery: 0.25
aim_min_stddev_deg: 0.4

damage_scalar: 0.5
despawn_energy_j: 2.0

drag_scale: 1.0   # honest fudge: real arrow drag is barely visible at
                   # game-world scale; raising this makes the light-vs-
                   # heavy arrow tradeoff legible at playable ranges.
                   # 1.0 = physically real drag.
```

### Archetypes (bow families)
```
self:     efficiency_low 0.50, efficiency_high 0.75
recurve:  efficiency_low 0.60, efficiency_high 0.85
compound: efficiency_low 0.70, efficiency_high 0.92
```

### Bows
| id | name | archetype | draw_weight_kg | draw_length_m | quality | storage_factor |
|---|---|---|---|---|---|---|
| selfbow | Hunter's Selfbow | self | 12.0 | 0.68 | 0.40 | 0.72 |
| recurve | Horn Recurve (default) | recurve | 20.0 | 0.72 | 0.70 | 0.78 |
| warbow | Yew War Bow | self | 32.0 | 0.78 | 0.55 | 0.75 |

### Arrows
| id | name | mass_g | drag_coefficient |
|---|---|---|---|
| light | Light Arrow | 25.0 | 0.000130 |
| standard | Standard Arrow (default) | 37.0 | 0.000153 |
| heavy | Heavy War Arrow | 60.0 | 0.000185 |

### Player stats (defaults)
```
strength: 10
archery: 10
```
Both are open-ended integer stats (no documented cap), feeding the pull/
draw-speed/aim formulas above.

---

## 4. Control flow (`DrawState.gd`)

Simple two-state machine: **Idle → Drawing → (release) → Idle**.
- `begin()` — press starts the draw, `hold_time` resets to 0
- `tick(delta)` — accumulates `hold_time` every physics frame while drawing
- `release()` — returns the held duration and resets to Idle; returns -1.0
  if called while not drawing (so a stray release event is a no-op)
- `cancel()` — aborts back to Idle without firing (used when switching
  weapons or bows mid-draw)

The shot is solved once, at release, using the final `hold_time`. Aim
direction and Gaussian scatter are also sampled once, at release — not
continuously while holding.

In `hd-prototype`, `WizardPlayer._physics_process` calls `draw_state.tick()`
every frame and continuously re-solves the shot (via `ShotSolver.solve`)
purely to drive the draw-meter UI live; the arrow itself isn't spawned
until release.

---

## 5. Damage numbers elsewhere in the same combat system

For calibration reference — these are the other weapons' first-guess
damage constants, tuned to land in the same ballpark as arrow damage
(which computes to roughly 15–20 per hit at typical range with the
Recurve/Standard-arrow default at full draw):

```
Sword swing:        18 damage, melee arc
Fireball (AOE):     30 damage, radius 150 (in the 2D game's px scale)
Lightning (hitscan): 25 damage, instant, 900 range (2D px)
Rat bite:            8 damage
```

Enemy health pools:
```
Rat:         40 HP
Evil Wizard: 70 HP
Player:      100 HP
```

---

## 6. Things that are 2D-specific and won't carry over as-is

- `pixels_per_metre` and `speed_scale` are screen-space conversion
  constants for a 2D top-down view; a 3D game will have its own way of
  mapping metres to engine units and won't need this seam in the same form.
- Aim scatter is applied as a 2D rotation of a direction vector
  (`aim_dir.rotated(spread)`); a 3D version needs an equivalent (e.g. a
  cone offset in 3D, not a single rotation angle).
- Hit detection in 2D is a flat-circle distance check (`hit_radius`) against
  everything in a "targets" group, checked every physics frame the arrow is
  alive. A 3D version will presumably use real collision shapes instead.
- The visible in-game arrow speed multiplier (100/150/175/200% option) is a
  2D-only feel dial layered on top of the physics purely so drawn arrows
  don't look floaty on screen at hd-prototype's px/metre scale — it doesn't
  change energy or damage math and may not be needed at all in 3D.

Everything in sections 2–5 above (the physics formulas, the tuning
constants, the bow/arrow data, the draw state machine, the damage numbers)
is engine-agnostic SI and should carry over directly.
