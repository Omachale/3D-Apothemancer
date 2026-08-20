# Devlog

One or two lines per change, newest first. Not a commit log (git already has
that) and not a design doc (DESIGN_GOALS.md has that) — this exists so a
change made in an earlier session, now outside the conversation window, is
still discoverable before it gets suggested again or contradicted.

---

## 2026-08-18

- Lightning tightness settled and the tuning slider removed. The DebugHud
  slider from earlier today did its job — after trying the range live,
  `jitter` is locked to its tightest end, 0.02, as the permanent default.
  Reverted: `LightningBolt.jitter_override` and its `class_name`, the
  slider row in DebugHud.tscn, and debug_hud.gd's wiring for it. Nothing
  reads the old 0.32 default anymore; if a wider bolt is wanted again later,
  it's one export value in lightning_bolt.gd, not a rebuild of the slider.
- Live "lightning tightness" slider added to DebugHud (F3): drags
  `LightningBolt.jitter_override` between an extremely focused 0.02 and the
  shipped default's 0.32. It's a `static var` on `LightningBolt` (now a
  `class_name`), not an instance field, because a bolt only exists for the
  fraction of a second its strike lasts — there is no standing instance a
  slider could bind to, but every freshly spawned one checks the static in
  `strike()` before building its path. Negative is the sentinel for "no
  override, use the authored default"; 0.0 had to be ruled out as the
  sentinel since it's a legitimate (perfectly straight) value.
- Lightning forks were shooting off perpendicular to the main path — a fork's
  end point was `origin + swing * stub_length`, purely sideways, no forward
  component at all — which read as several separate bolts firing in random
  directions rather than one bolt forking. Forks now mix in `FORK_FORWARD_BIAS`
  (0.72) of the main direction, so a fork still visibly advances toward the
  target while peeling off. Main-path `jitter` also tightened (0.6 -> 0.32) so
  the whole thing reads as one focused strike.
- Lightning fade fixed: the sustain->fade transition scaled the whole node
  toward zero, and since the node's origin is the CASTER's hand (global_position
  = _from), that visibly retracted the bolt back into the hand it just left —
  the opposite of "only ever move away from the caster". Fade now dims the
  shared material's alpha in place instead. Also tightened the look per
  feedback: jitter 1.1 -> 0.6 (more focused), subdivisions 4 -> 5 (denser),
  fork_count 3 -> 5 (a couple more branch lines).
- Lightning attack added: `SpellProfile.AimMode.HITSCAN` resolves the hit — the
  assisted target, or a straight raycast — the instant a cast releases, in
  `player_attacks._cast_lightning`/`_lightning_target`. **The jagged bolt never
  computes the hit.** `lightning_bolt.gd` (Node3D, no collider) is spawned
  afterward with the already-decided (point, body) pair and only draws a
  midpoint-displaced forking path between them, revealing it in ~50ms so it
  reads as forming rather than popping in. **The velocity seam**:
  `travel_speed_mps` is 0 today (instant hit + instant form); raising it makes
  both the forming duration AND the moment damage lands switch to
  distance/speed automatically — see the class note in lightning_bolt.gd.
  `resources/spells/lightning_bolt.tres`: heavier punish-attack timing (0.6s
  windup, 0.9s cooldown) than red_bolt, 18 damage. New `verify_lightning.gd`
  suite (registered in run_verify.ps1) checks both halves of the split
  directly — instant vs delayed damage, and hit resolution against assisted
  target / raycast / open-air miss — since either half could break while the
  other still looks fine.
- Basic character screen added: **C** opens/closes `CharacterScreen.tscn`, two
  slots (LMB/RMB) each swappable to any profile in a flat exported pool
  (red_bolt, blue_bomb, lightning_bolt, bow_shot — the bow now goes through
  the same menu as spells rather than being hardcoded to secondary).
  `SpellCaster.set_profile()` reassigns a slot live; safe mid-cast because
  `current_profile` is snapshotted at windup start and not re-read from
  primary/secondary_profile until the next cast. Opening the screen calls
  `player_controller.set_input_frozen(true)`, which cancels any in-progress
  cast and skips movement/cast input entirely (not just zeroes it) until
  closed. `Targeting` also checks `player.is_input_frozen()` before treating a
  click as a select, so clicking a menu button can't also pick an enemy
  through it.
- Aim scatter simplified and tightened: scatter now happens only in the horizontal plane (no vertical deviation) and uses half the calculated stddev. At archery=10 that's 1.75° instead of 3.5°. Horizontal-only keeps lobbed shots honest without spray. Simplified the implementation from rotating around a random axis to just rotating around UP.

---

## 2026-08-17

- Arrow was INVISIBLE in play while still dealing damage, and the cause is worth
  recording because nothing was broken: it was built to real-world scale. A real
  shaft is ~8 mm and the gameplay camera renders ~50 px per metre (cast_effect.gd
  measures the character at ~100 px tall), so the arrow was 0.4 of a pixel wide.
  Rebuilt at ~7x true thickness, ~1.1 m long, with red fletching for contrast.
  Length matters independently: an arrow shorter than the ~0.76 m it covers per
  frame at 45 m/s reads as a dashed line rather than a streak. Same reasoning
  cast_effect.gd already documents for its oversized orb — at this camera
  distance readability beats fidelity. **Physical accuracy is not the default for
  anything whose on-screen size is what matters.**
- Archery step 4 of 4 — IT SHOOTS. RMB is now a bow: hold to draw, release to
  loose. `scripts/combat/archery_loadout.gd` holds the equipped bow, arrows and
  (temporarily) strength/archery stats; `resources/spells/bow_shot.tres` is the
  profile; `player_attacks.gd` routes on the new `SpellProfile.aim_mode`.
  **RMB's charged BlueBomb demo is retired** — it existed to prove the charge
  pipeline and archery is now the real user of it. The bomb profile is still there
  and rebindable.
- The equipment seam closed as designed: the caster asks its owner how drawn the
  bow is, `player_controller.get_charge_fraction` forwards to the loadout, the
  loadout answers from draw weight and stats. An owner may now DECLINE by
  returning a negative number, which falls back to the profile's own clock —
  needed because having the method and being able to answer are different things,
  and an unequipped archer guessing 0 (never draws) or 1 (instantly full) would
  both be wrong.
- `solve_shot_at_pull` added and `solve_shot` reduced to a wrapper over it. The
  game never has a hold time where it needs a shot — the caster hands out a
  charge, which IS the pull fraction — so threading the clock through the release
  signal would have been for nothing. Verified numerically identical to the old
  path, since the calibration rests on those figures.
- Free-aim archery lands the arrow AT THE CURSOR'S GROUND POINT rather than firing
  along a ray, because a falling projectile pointed along a direction has no
  destination. With a target selected it solves an intercept instead.
- Per-arm animation poses, because a bow is not symmetric: the bow arm holds
  extended while the string arm travels to the cheek. One pose applied to both
  arms cannot express that and reads as pantomime. The `bolt` set now names both
  arms with the same value, so spells are unchanged. Also added
  `SpellProfile.shows_cast_glow`, false for the bow — a drawn bow should not have
  a ball of light in its fist.
- **Two test-harness traps worth remembering**, both of which produced failures
  that looked exactly like broken product code:
  - `queue_free()` is DEFERRED, so in a suite whose checks all run inside one
    synchronous `_ready` the discarded nodes are still children when the next
    check builds its own. `add_child` then renames the new node to avoid the
    clash, and a sibling lookup by name (`get_node("ArcheryLoadout")`) resolves to
    the stale one. Use `free()` in synchronous teardown.
  - Asserting "half the draw time gives half the draw" is asserting the model is
    WRONG. Draw progress and draw ceiling are separate limits that multiply, so a
    clumsy archer at half the time sits at 0.43, not 0.5. The check now asserts
    the caster AGREES WITH THE LOADOUT and differs from the profile's clock, which
    is the actual claim.
- Archery step 3 of 4: `scripts/combat/arrow.gd` + `scenes/combat/Arrow.tscn` —
  the projectile. Arcs under gravity, sheds speed to drag, noses over as it
  falls, damages by energy-at-distance, and ends on the ENERGY FLOOR rather than
  a time or range cap (so a war bow outranges a selfbow with no range authored
  anywhere: measured 388 m against 253 m). Still not wired to input; step 4.
- **The arrow and the solver now share `BallisticSolver.step_velocity`**, which is
  the important structural point rather than a tidiness one. The solver picks an
  angle by predicting a flight; if the thing that flies integrated by any other
  rule the aim would be wrong by exactly that disagreement and a better solver
  would not help. `predict()` moved from Vector2 to Vector3 purely so the step
  function could be shared verbatim instead of transcribed twice.
- The arrow SUBSTEPS to the solver's own `PREDICT_DT` instead of taking one jump
  per physics frame. Euler at 60 Hz drifts ~10 cm from a 240 Hz prediction over a
  typical shot — small but systematic, and free to remove. With both in place the
  real arrow arrives **within 0.000 m** of where the solver aimed at 15-50 m.
- Hits are a RAYCAST ALONG THE PATH, not an Area3D overlap like projectile.gd
  uses. At 45 m/s an arrow crosses ~0.75 m per physics frame, comparable to the
  width of what it is shooting at, so overlap testing can step straight over a
  target. Verified at 500 m/s (2.08 m per substep) still hitting a 0.9 m body.
- Energy is read from the closed form on distance flown, NOT from ½mv² of the live
  velocity. The live velocity also carries what gravity added, so a lobbed arrow
  would gain energy on the way down and hit harder than a flat shot at the same
  range — true of real arrows, but not the model the 16.3-damage calibration was
  built on.
- Not a problem but worth knowing: an arrow that hits nothing flies 250-390 m over
  ~10 s. In the real world it will bury itself in terrain long before that (SOLID
  is in the hit mask); only a lob over a void reaches those numbers.
- Archery step 2 of 4: `scripts/combat/ballistic_solver.gd` — the launch-angle
  solver, the 3D counterpart to `lead_aim` and shaped the same way (static, pure,
  checked by firing the answer rather than by inspecting the formula). Returns
  the FLAT arc of the two roots, not the lob: it reads as aimed shooting and
  gives the target less time to move, and choosing the lob intelligently would
  need line-of-sight tests that do not exist. Still wired to nothing; no arrow
  flies yet.
- **Two real bugs, both caught by the suite rather than by reading the code** —
  worth recording because both looked right:
  - The out-of-range fallback used the quadratic's VERTEX as the maximum-range
    angle. That is correct only for a target at exactly maximum range; beyond it
    the vertex angle keeps shrinking, so the fallback got FLATTER the further out
    of reach the target was — 32 degrees for a shot whose best angle was 45. The
    real formula is `atan(v / sqrt(v^2 - 2gh))`.
  - Drag correction by solving the parabola at a drag-adjusted average speed is
    FIRST-ORDER ONLY: it fixes flight time but ignores drag on the vertical
    component. Measured 0.69 m short at 55 m and 1.55 m worst over 15-70 m. Now
    the closed form is only the starting guess and the angle is refined by secant
    iteration against a predicted flight that includes drag — 0.029 m at 55 m,
    worst 0.038 m anywhere. The average-speed trick survives as the guess, which
    is what it is genuinely good for.
- WHY THAT REFINEMENT MATTERS BEYOND ACCURACY: the likeliest reason to shorten
  arrow range later is raising `DRAG_SCALE`, which makes a naive parabola worse.
  Refining against the real flight means heavier drag just moves the angle
  further — no redesign. `predict()` is the flight model, and whatever actually
  flies MUST integrate the same way or aiming is pointless. The suite crosschecks
  it with an integrator written independently, so a mistake in the model cannot
  hide behind itself.
- Moving targets are solved by iteration, since the problem is circular (arc ->
  flight time -> where the target will be -> arc). Same mechanism as the drag
  refinement, deliberately.
- Archery step 1 of 4: the arrow economy, ported from the 2D prototype
  (ARCHERY_HANDOFF.md sections 2-3). `scripts/combat/archery_physics.gd` holds
  the whole model as STATIC PURE FUNCTIONS in real SI units — draw energy,
  bow efficiency, muzzle velocity, drag decay, damage-from-energy — plus `Bow`,
  `BowArchetype` and `ArrowSpec` resources with the three shipped bows and
  arrows in `resources/archery/`. No scene, no node, no state, so the entire
  model is checkable headless (same reasoning as `lead_aim`). Deliberately NOT
  wired to anything yet: no arrow flies, nothing in game changed.
- The tuning constants stayed CONSTANTS rather than becoming a resource. A
  resource would have to be threaded through every call and would destroy the
  static-and-directly-testable property that makes the suite possible. Bows and
  arrows — the numbers actually tuned often — are data; the formulas' constants
  are not.
- **The calibration anchor is the check that matters.** Every constant was
  transcribed by hand, and a typo in any of them still yields a model that runs,
  returns finite numbers and looks plausible — it just disagrees with the game
  the numbers came from. The handoff doc records 15-20 damage per hit at typical
  range for the default loadout; the suite asserts it directly and measures
  16.3 at 20 m. That single check covers the whole chain.
- Measured behaviour, recorded so a later retune has a baseline: recurve +
  standard arrow at full draw is 38.4 J and 45.6 m/s at the string; the default
  10/10 player is exactly matched to the default 20 kg bow (reaches precisely
  full draw); a 4/4 archer caps at 36% draw on the 32 kg war bow however long
  they hold; light arrow 54.1 m/s / 36.6 J against heavy 36.5 m/s / 39.9 J.
- Worth knowing before tuning: at `DRAG_SCALE` 1.0 (physically honest) the
  effective range is ~121 m and arrows do not hit the despawn energy floor until
  ~357 m, both well beyond what the camera shows. So arrows will never expire
  from energy loss on screen, and the light-vs-heavy trade is real but modest at
  fighting distance (~18% at 20 m). The 2D game kept `drag_scale` as a named
  fudge for exactly this reason.
- Cast profiles: spells now carry their own timing, animation and WINDUP SHAPE
  (`scripts/combat/spell_profile.gd`, resources in `resources/spells/`).
  `spell_caster.gd` had one global set of timing exports serving every spell and
  a `current_spell` string tag nothing interpreted; it now executes whichever
  [SpellProfile] the cast named. Done BEFORE archery on purpose — a bow's draw
  ends when the player lets go, not on a clock, and bolting that onto a
  fixed-duration machine would have meant an `if charged` branch through most of
  its methods. Per-spell casting times/animations were wanted independently
  anyway, and once a spell owns its profile the charged windup is just one more
  profile shape. Designing the abstraction first and retrofitting the charge
  case later would have produced exactly the mess this avoids.
- `WindupMode.CHARGED` is live: WINDUP ends only on `release_charge()` (called
  by player_controller on button-release, tagged so the wrong button cannot
  loose a draw), never on a timeout — holding past full simply sits at full.
  `cancel()` added alongside, because a two-second draw makes mid-cast
  interruption (death, a hit, a weapon swap) real rather than theoretical.
- **`weight`/`charge`/`extend` are now three values, not two.** They used to be
  two because a fixed windup let "how blended-in is the cast pose" and "how far
  through the windup" ramp together. A long draw separates them: the pose blends
  in over a fixed short window (`CHARGED_POSE_BLEND_IN`) and holds, while
  `charge` creeps up over the whole hold and then HOLDS its released value so
  anything reading it after release sees what was actually fired. Timed casts
  keep their old blend curve exactly.
- Two seams left deliberately for archery. `SpellProfile.charge_duration_from_owner`
  makes the caster ask its owner `get_charge_fraction(hold)` — that is where bow
  draw weight and player strength enter, and it is OPT-IN per profile precisely
  so a charged bomb is not silently charged at the equipped bow's rate.
  `charge_damage_scale` is a plain lerp for ordinary charged spells and is NOT
  what archery will use (arrow damage comes from real stored energy).
- Animation is referenced BY TAG (`animation_tag` -> a pose set owned by
  `player_animator.gd`), not carried in the profile: those poses are written in
  Mage.glb's rest space and would tie spell data to one rig. Consequence worth
  keeping — when real keyframed animation replaces the procedural animator, the
  profiles do not change at all.
- BlueBomb (RMB) is now a charged cast whose damage scales 0.4x..2.0x with hold,
  chosen so the charge->power pipeline archery depends on is exercised for real
  rather than existing only in tests. RedBolt (LMB) is unchanged. Reverting is
  one field on `blue_bomb.tres`.
- New suite `verify_spell_profiles` (11 checks) drives casters by hand with
  synthetic deltas rather than waiting on real time. The check that matters most
  is that a charged windup held for 10s against a 1s `windup_time` still has not
  fired: a charged cast that also times out still works and still looks right,
  it just ignores the player, and nothing visible catches that.
- Trap hit and worth recording: `cast_released` gained a third parameter, and
  the missed call site was not a listener but `cast_effect.gd`'s own internal
  `_set_visible_amount(0.0)` in `_build()`. It surfaced as a script-load error
  the suite runner printed but still scored as OK, so `run_verify.ps1` does NOT
  currently fail a suite on a parse error in a script the scene merely loads.

## 2026-08-16

- Terrain LOD tuning: raised max_screen_error_px from 24.0 to 36.0, accepting
  coarser terrain 50% sooner to reduce tile count and build cost. Measures next.
- Grass tuning experiment: reduced density to 1/4 (11.25 from 45.0 blades/m²) and
  doubled blade dimensions (height 0.64 from 0.32, width 0.10 from 0.05). Zone
  JSON now supports blade_height and blade_width as data-driven settings, wired
  through zone_layout.gd schema and zone.gd's _make_grass_manager. Visual test
  to see if larger sparse coverage holds cohesion better than dense tiny blades.
- Added performance measurement tooling, because "the game feels slower" was
  not answerable by reading the code — rendering cost is routinely
  counter-intuitive and any answer reached by inspection would have been a
  guess. `scripts/dev/perf_probe.gd` (spawned by `dev_tools.gd` only when
  `--perf` is passed, so it is free on a normal run) samples frame time, GPU
  time, render-submit CPU time and GDScript `_process` time separately, plus
  draw calls and primitives split into VISIBLE and SHADOW passes. It also
  ABLATES: `--perf-disable=grass,shadows,…` removes one subsystem, so re-running
  an identical scripted route gives that subsystem's real cost as a difference.
  `scripts/dev/run_perf.ps1` drives the whole sweep and prints a ranked table.
  THREE THINGS THAT WOULD HAVE MADE EVERY NUMBER MEANINGLESS, all handled and
  all worth remembering: (1) v-sync pins any scene faster than the refresh rate
  to exactly the refresh rate, hiding every difference — the probe disables it
  and `Engine.max_fps`; (2) warm-up — the streaming managers are still building
  chunks many seconds in and each grass chunk costs ~33 ms, so a short warm-up
  measures loading rather than playing (a 1 s warm-up gave 18 ms/frame, an 8 s
  one gave 9 ms); (3) mean vs median — the first run reported a 41 ms mean
  script time alongside an 18 ms median frame time, which is not a possible
  steady state, only an average over two different populations, so everything
  is reported as a median with p95 alongside for stalls. Runs must be WINDOWED;
  `--headless` has no GPU timings.

- FIRST MEASUREMENT RESULTS (walking route, 6 s measured after 8 s warm-up).
  **The game is GPU-bound**: frame median 8.33 ms against a GPU median of
  7.57 ms, with render-submit CPU only 0.39 ms — frame time tracks GPU time
  almost exactly, so CPU-side optimisation would buy nothing right now.
  **Grass is ~50% of all GPU time**: removing it takes GPU 7.57 -> 3.68 ms
  (saving 3.89 ms) and frame 8.33 -> 4.43 ms. Reproduced twice, in a full sweep
  (4.49 ms of 8.05) and a clean warm back-to-back A/B (3.89 ms of 7.57). The
  scene draws ~4.2M primitives per frame in only ~128 draw calls, which is the
  shape you would expect if grass instancing dominates. Second tier, each about
  a quarter of grass: MSAA 1.92 ms, shadows 1.85 ms, SSAO 1.66 ms, terrain
  1.04 ms. **Everything else is at or below the noise floor** (~0.5 ms, set by
  the negative readings ablation produced): fog 0.42, npcs 0.22, trees 0.19,
  props 0.14, rain -0.21, sky -0.32, structures -0.47. So the recent rain, sky
  and day/night work is NOT what slowed the game down — worth recording
  explicitly, because it was the obvious suspect and it is wrong.
  TWO COLUMNS NOT TO TRUST YET: the script column (`Performance.TIME_PROCESS`
  never reads below ~10 ms even on 8 ms frames, so it is not per-frame script
  cost in this build — the probe now detects and prints this rather than
  publishing the impossible number), and the p95/stall table, which moved from
  108 ms in the cold sweep to 12.8 ms warm and once made grass removal look
  WORSE, i.e. it is dominated by run-to-run variance and needs repeats before
  any claim rests on it. Separately and independently, GrassField's own build
  logging shows ~33 ms per chunk with `max_concurrent_builds = 2`, so up to
  ~66 ms of blocking work can land in one frame — a real hitch source on the
  game's own instrumentation rather than on the probe's.

- Improved rain visual quality with three material tweaks: (1) Particles fade
  to transparent over their lifetime via GradientTexture1D on
  ParticleProcessMaterial.color_ramp, softening the visual edge as particles
  recycle. (2) Switched from pure white (0.8, 0.85, 0.95) to cool blue-grey
  (0.72, 0.78, 0.88), reading as stormy rather than washed-out. (3) Adjusted
  initial alpha to 0.5 base for better layering with the fade curve. No
  texture asset needed for these improvements — all code changes to the draw
  material and particle process material.

---

## 2026-08-14

- Fixed the scene reading as too bright, and rain barely darkening anything.
  ROOT CAUSE, found via `git log` on `world_environment.tres`: `sky_top_color`
  and `ground_bottom_color` were brightened from dark values (`(0.31, 0.46,
  0.68)` / `(0.20, 0.20, 0.21)`, present since the original commit, in place
  when rain was tuned and looked right) to much lighter ones (`(0.7, 0.8,
  1.0)` / `(0.5, 0.58, 0.68)`) in the SAME commit that added the moving sun —
  before this session. Asking to "return to default" earlier in this session
  reverted to that already-brightened value, not the true original; there was
  no further-back state on file to return to. Reverted both colours to the
  original dark values in `resources/environments/world_environment.tres`.
  SEPARATELY: `rain.gd` only ever dimmed `Sun.light_energy` (the directional
  light), never the environment's `ambient_light_energy` — and
  `ambient_light_source = SKY` means ambient comes straight from the sky
  colour, entirely independent of the sun. A storm dimmed direct light while
  full-strength sky ambient kept flooding everything, which is why rain
  barely read as darker even before the sky got brighter. Fixed by having
  `rain.gd` locate the `WorldEnvironment` too (new `"world_environment"`
  group on that node in `World.tscn`, same pattern as the existing `"sun"`
  group) and tween its ambient_light_energy in parallel with the sun, both
  driven by the same `_light_factor_target`. Also gave `LIGHT` intensity an
  actual light_factor (0.85, was 1.0 — literally zero dimming) since that's
  the level a player hits on their first rain toggle and is most likely to
  judge the effect by; MODERATE/HEAVY tightened slightly too (0.6/0.35, was
  0.7/0.4) since ambient now shares the load.
  SEPARATELY AGAIN: `sun.gd`'s day/night cycle only ever rotated the light —
  `light_energy` never varied, so time of day changed shadow direction and
  nothing else. Added `_day_factor()`: 1.0 at noon, fading through a
  `min_night_factor` floor (0.15) across a `twilight_band` either side of the
  horizon, computed from the light's own elevation
  (`global_transform.basis.z.y`) so it needs no separate day-time clock.
  THE COUPLING TRAP THIS AVOIDED: rain.gd used to capture `Sun.light_energy`
  ONCE (whenever it first found the node) as its "full brightness" baseline
  and multiply from there. With `light_energy` now changing continuously for
  day/night, that capture would go stale the instant it fired — a storm
  rolling in at dusk would freeze dusk-dim as its baseline and never darken
  further for the rest of the night. Fixed by giving `sun.gd` sole ownership
  of `light_energy`, written every frame as `max_light_energy * day_factor *
  rain_factor`; `rain_factor` is the ONLY thing rain.gd ever sets on the sun
  now, a plain 0..1 multiplier sun.gd folds in itself. Two systems each own
  exactly one factor instead of fighting over one number.
  GOTCHA HIT: removing `_apply_light_factor`'s old `if _sun == null: return`
  (needed since the function now also drives the independently-found
  atmosphere) meant it unconditionally called `create_tween()` even when
  NEITHER target existed yet — every verify suite's bare Rain autoload does
  exactly that on `_ready()`, producing "Tween started with no Tweeners"
  errors across all 11 suites. Fixed by returning early when both `_sun` and
  `_atmosphere` are still null, restoring the original short-circuit while
  keeping the dual-target logic.
  VERIFIED headless (temporary script, deleted after use): baseline
  light_energy 1.25 / ambient 0.55 → HEAVY rain fades both to 0.438 / 0.193
  (a real ~65% cut in both) → returns cleanly to baseline off rain; a manual
  sweep of the sun's rotation confirmed light_energy actually varies from the
  0.19 night floor up to the full 1.25 noon value. All 11 verify suites pass.

- Added `TreeScatterManager` (`scripts/world/tree_scatter_manager.gd`): ambient
  tree cover streamed in a grid of chunks around the player, same architecture as
  `grass_manager.gd`/`terrain_manager.gd`. THIS REPLACES THREE FAILED ATTEMPTS
  EARLIER TODAY (`scattered_groves`, `northeast_forest`, `western_forest` — all
  now removed, see below) that tried to fix "trees run out if you walk far in one
  direction" by adding more `generators.*`-style finite placement lists with
  bigger radii. That approach cannot work: `get_props()` returns an Array,
  `zone.gd` instantiates every entry once at build time, and a finite list
  always has an outermost entry — moving that edge further out is not the same
  as removing it, and does not scale (bigger radius = more trees instantiated
  at zone load even in places the player may never visit). The actual fix is
  the one grass and terrain already use: don't place a list, place a FUNCTION —
  stream chunks in/out around the player, so cost is bounded by what's visible,
  not by the size of the world, and there is no edge because nothing is ever
  computed for ground far from the player until the player is what's near it.
  Per-chunk tree count comes from low-frequency `FastNoiseLite` sampled at the
  chunk centre (same technique heightfield.gd uses for rolling/mountains, read
  as a density instead of a height) — that's what makes the result read as
  copses and glades rather than a uniform sprinkle: neighbouring chunks share
  similar noise, so density rises and falls over tens of chunks together.
  `trees_per_chunk_floor` (default 1) sits UNDER the noise, not gated by it —
  every chunk gets at least that many candidate trees regardless of the roll,
  which is the actual guarantee against "large bare areas" (the literal bug
  report): a whole region cannot go to zero, because each chunk rolls
  independently and the floor never lets any single one hit true zero except by
  an unlucky slope/exclusion rejection. Deterministic without being saved, same
  principle as every other generated layer here (chunk seed = `seed ^ hash(cell
  coords)`) — leave a chunk's range and come back, same trees regrow.
  `generators.mountain_trees` and `generators.forest` are UNCHANGED and were
  never the problem — they're deliberate, hand-tuned landmark stands (a
  specific treeline, a specific windbreak), and a finite list is the *correct*
  tool for that; only "ambient coverage over open ground with no natural edge"
  needed the streaming approach. New JSON section `tree_scatter` in
  `starter.json` holds the tuning (chunk_size, noise_frequency, trees_per_chunk
  floor/max, bare_threshold, max_slope_degrees, clear_radius around spawn);
  registered in `zone_layout.gd`'s `SECTION_FIELD_TYPES` and `TOP_LEVEL_KEYS`.
  Wired into `zone.gd` via `get_tree_scatter()`/`_make_tree_scatter_manager()`,
  parallel to the grass wiring; reuses `get_grass_exclusions()` for structure
  footprints (that getter is now genuinely dual-purpose despite its name — see
  its updated doc comment). Verified headless: 103 trees within 260 units of
  spawn, and — the actual regression test for the original bug report — 127
  trees still generate after teleporting the player to (3000, 3000), ~4.2km
  from spawn, with the same streaming mechanism. All 11 verify suites pass
  unchanged.

## 2026-08-13

- Added a `_guide` section to the top of `starter.json` with quick how-tos for
  the most common edits (adding trees, moving a building, adding a flatten pad,
  adding NPCs/props). It lives in the JSON itself so it won't be missed after
  context compaction; zone_layout.gd silently ignores it. Future-me will see it
  the moment I open the file to edit.
- Task #4: moved the zone's whole layout — every heightfield feature, plate,
  staircase, building, tower, NPC, prop, plus the two procedural tree
  generators' dials — out of hardcoded GDScript literals in `zone.gd` and
  into `data/zones/starter.json`, so a terrain edit is now a data diff a
  future tool can write, not a code change. New `scripts/world/zone_layout.gd`
  (`ZoneLayout`) owns ALL the JSON knowledge: a schema-driven loader that
  converts JSON into the exact typed shapes (Vector2/Vector3/Rect2, resolved
  PackedScene/Material) the existing `_make_*` builders in `zone.gd` already
  expected, and validates on every load rather than only in tests (unknown
  key, wrong type/arity, unresolvable scene/material name, unsupported
  `format_version` — every error collected and reported at once, not
  first-fail). `zone.gd`'s getters are now thin reads over the parsed
  layout; nothing outside `zone_layout.gd` knows JSON exists. A second zone
  needs no new code — a new `.json` plus a `.tscn` with `layout_path`
  overridden is enough; the old "subclass and override a getter" path still
  works for anything genuinely code-shaped (the tree generators are exactly
  that: code stays in `zone.gd`, only their seed/count/radius dials moved).

  THE ONE THING THAT MATTERS HERE: several existing call sites branch on a
  key being ABSENT, not on its value — `heightfield.gd`'s flatten pads
  compute `level` from the terrain when it's missing, `_make_tower` only
  sets `size` when `data.has("size")` (else Tower solves its own footprint),
  `_make_terrain_manager` defaults five fields to the NODE's own declared
  defaults. `ZoneLayout`'s conversion is written to never inject a default
  of its own — a key present in JSON survives conversion, a key absent from
  JSON stays absent from the returned Dictionary. Getting this wrong would
  be silent: the world still builds, just subtly different, with nothing to
  fail. Caught, not by inspection, but by a golden-file equivalence check
  built specifically for this migration: `scripts/dev/dump_zone_layout.gd`
  (run via `scenes/dev/DumpZoneLayout.tscn`) prints every `Zone` getter's
  fully-expanded output at fixed float precision; captured once against the
  original GDScript literals, then again after the rewrite — `diff` came
  back completely empty, proving the migration changed nothing about the
  actual world despite touching almost every line of `zone.gd`.

  New standing suite `verify_zone_data.gd` (`-Suites zone_data`) replaces
  what GDScript's own type system used to guarantee for free: asserts the
  shipped JSON parses with zero errors, spot-checks a few values that matter
  (SouthValley's falloff=60/level=-30, EastMountain's radius=100, spawn
  position) survived transcription, and explicitly asserts the
  absence-sensitive cases stayed absent (`towers[0]` has no `size`; at least
  one flatten pad has no `level`) rather than trusting that nothing
  regressed. Registered in `run_verify.ps1`; all 11 suites (the 10 existing
  plus this one) pass.

  Rationale that used to live as `zone.gd` comments (SouthValley's falloff
  derivation, why EastMountain's summit pad is a plateau rather than a hill,
  the stale-pines warning, why the terrace and its stairs share one pad)
  moved to per-entry `"note"` fields in the JSON, right next to the numbers
  they explain — cross-cutting rules (the pos-is-clearance convention, the
  every-structure-needs-a-pad rule) stayed as `zone.gd` doc comments since
  they govern every entry, not one.

  Gotcha hit and now documented in both `zone_layout.gd` and
  `run_verify.ps1`'s existing `-RescanClasses` note: `ZoneLayout` is a new
  `class_name`, so the FIRST headless run after adding it parse-errors
  (`Could not find type "ZoneLayout" in the current scope"`) until the
  editor's global class cache is rescanned (`Godot --headless --editor
  --quit`) — exactly the failure mode `-RescanClasses` exists for.
- Widened grass and rain coverage: `grass_manager.gd` load_radius 50→80m (chunks build
  earlier, streaming stutter moves further from player), `rain.gd` emission_size 44→88
  (doubling the spawn box so rain stays edge-to-edge at wide camera zoom).
- Added SouthValley, a 30m-deep basin south of spawn (`scripts/world/zone.gd`
  features list, centred (10, 220)) — required two new capabilities on
  Heightfield's "flatten" pads (`scripts/terrain/heightfield.gd`), both
  generic and documented there, not one-off valley code:
    - `shape: "ellipse"` — a pad's core can now be curved everywhere
      instead of the rectangle-with-rounded-corners it was, for anything
      that should read as carved by nature rather than built.
      `_ellipse_outside_distance` gets the outside-the-core world distance
      EXACTLY (no trig, no approximation) by using the ellipse's own
      definition: `d` (the normalised radius) is by construction equal to
      `distance_from_centre / true_boundary_distance`, so
      `distance_from_centre * (1 - 1/d)` recovers that boundary distance
      directly. `_pad_max_slope_degrees`'s probe dict was missing `shape`
      entirely (it only carried pos/half/falloff) — would have silently
      measured every ellipse pad's slope against the wrong, rectangular
      footprint; caught before it shipped.
    - `noise` on a pad — irregularity added ON TOP of the level a pad
      blends to, reusing the pad's own falloff weight rather than a second
      curve, so it is strong across the whole core and fades out exactly
      where the level-blend does. Existing pads are unaffected (default 0
      reproduces the old perfectly-level behaviour).
  SouthValley's own numbers: core 40x80 (the requested "large flat
  surface"), falloff 60, noise 4.5 (proportionally similar to the SouthHill
  feature's 1.9 on an 11m hill), explicit level -30. The 60-unit falloff
  is not a styling choice — it is the minimum the player's 50 degree
  floor_max_angle forces for a 30m drop (a smoothstep's steepest point is
  1.5x its average slope, so 30m needs ≥57 units of run even before noise
  adds its own gradient) — which is also why the overall footprint ends up
  ~160x200 despite an 80x40 core: a valley this deep cannot be climbed out
  of in less space than that, regardless of technique. Measured (not
  predicted) at 45.2 degrees via the existing numerical pad-slope walk,
  comfortably under the 50 degree limit and in line with every other
  feature (37-47 degree range). `verify_zone_layout.gd`'s skirt/seam check
  had its z-sampling range widened from a fixed square (which only reached
  z=138) out to z=320 — SouthValley's footprint would otherwise have gone
  completely unchecked by the one test whose job is catching exactly this
  ("land got more dramatic, recheck the skirt").
- Fixed camera ground-collision getting stuck permanently pushed up
  (`scripts/camera/camera_rig.gd`). The clamp writes `_camera.global_position`,
  and because the camera is a CHILD of the rig, that write lands on its
  LOCAL transform — nothing was resetting that offset each frame, so one
  clamp near a hill baked in a permanent displacement that never relaxed
  even after the player walked clear of the slope that caused it. Fix: call
  `_apply_camera_transform()` (restores the canonical local offset from
  pitch/distance) every frame right before the ground check, so the clamp is
  a fresh one-frame correction instead of an accumulating one. Added a
  regression case to `verify_camera_pitch.gd`: push the camera up with a
  wall heightfield, swap to flat ground, and assert one more frame brings it
  back down rather than leaving it parked at the wall's height.
- Added a day/night cycle (`scripts/world/sun.gd`, attached to World.tscn's
  Sun node): the simplest version possible — `global_rotate(Vector3.RIGHT,
  ...)` on the DirectionalLight3D every frame, no colour/intensity/shadow
  animation, just motion. `day_length_seconds` (default 120) is the only
  dial. Not tied to any game-time system.
- Reverted `sky_top_color` in `resources/environments/world_environment.tres`
  from the brightened 0.9/0.95 (2026-08-12 session) back to the original
  0.7/0.8 — the brightening was requested mid-session to help diagnose the
  black-abyss-at-horizon issue and the user wants the sky back to normal now
  that fog/horizon work is done. `ground_bottom_color` (0.5/0.58/0.68, fixing
  the actual black-abyss bug) stays as-is.

## 2026-08-12

- Reworked camera controls (`scripts/camera/camera_rig.gd`): default pitch
  lowered 45→20 degrees for a closer, over-the-shoulder feel; removed the F12
  lock/unlock step entirely (also dropped its input action from
  project.godot) so middle-mouse drag always works; horizontal drag now
  orbits yaw (same rotation Q/E drive — new `yaw_drag_speed`) alongside the
  existing vertical-drag pitch. Added ground collision: after the rig follows
  its target each frame, the real Camera3D world position is checked against
  `Game.heightfield` and pushed straight up if it would sit inside the
  ground (`ground_clearance`, default 0.4m) — a height check, not a raycast,
  so it's blind to buildings/the tower but free and correct for hillsides.
  Rewrote verify_camera_pitch.gd for the new always-on behaviour plus a
  ground-collision case (a heightfield "wall" the camera must be pushed
  above) — tripped once on a real async bug: calling the awaiting check
  function without `await` let `_ready` race past it and quit before it ran,
  silently skipping the check with no error.
- Added procedural mountains to the heightfield (`scripts/terrain/heightfield.gd`):
  a new FastNoiseLite layer with ~500m wavelength (mountains_frequency 0.002) at
  18m amplitude, seeded separately from rolling so it doesn't follow the same
  pattern. Fades to zero within 80m of spawn (protected_center/radius) so the
  starting area stays level. Tunable via zone.gd's get_heightfield() —
  mountains_amplitude is the main dial (0 to disable, default 18).
- Added distance fog (`scripts/world/atmosphere.gd`, script on World.tscn's
  WorldEnvironment, dials in `zone.gd:get_atmosphere()`). Fog begin/end are
  FRACTIONS of `horizon_distance` (0.35/0.95) and the camera far plane comes
  from it too, so moving the horizon moves all three together. Found in
  passing: the camera shipped `far = 300` against a horizon of 480, so the
  outer two rings were built and then clipped every frame — now 504. Shadow
  range stays authored at 55m on purpose (fixed texel budget; stretching it to
  the horizon blurs near shadows to buy shadows the fog hides), only clamped to
  the far plane. `apply()` duplicates the shared `world_environment.tres`
  before writing, so runtime fog never lands on the file. New `atmosphere`
  suite in run_verify.ps1 checks the three ranges agree.
- Widened EastMountainTower ~50%: `stair_width` 1.6→2.4, `min_steps_per_leg`
  6→10 (footprint 5.58m→8.40m, door 1.40m→2.10m, roof opening 1.60m→2.40m).
  Derived from the same two dials, not hardcoded — `suggest_size()` still
  means "narrowest square these stairs fit in".
- Fixed two verify_tower.gd checks (roof headroom, door clearance) that were
  comparing a shared construction edge for exact float equality and failing
  on ~1cm noise; added an `OVERLAP_TOLERANCE` and proved both checks still
  catch the real defect (solid roof: 3.92×2.40m overlap; walled-up door)
  before restoring.
- Built `scripts/dev/run_verify.ps1`: every `verify_*.gd` exits through a
  single `quit()`, so any script error before it hangs Godot headless
  forever (no crash, no timeout — confirmed one hung 20+ minutes on one
  un-inferable `:=`). Runner parse-checks first (`--check-only`), forces a
  class-cache rescan after new `class_name`s (`-RescanClasses`), and bounds
  every run with both `--quit-after` and a wall-clock kill. Judges on exit
  code AND a success-marker string, since `--quit-after` alone force-quits
  with code 0. See README.md "Running the verification suites".
- Added Tower (`scripts/terrain/tower.gd`): square helix staircase to a
  parapeted roof platform, footprint derived from stair geometry rather
  than authored, one door. Fixed two real bugs from the first pass: leg 0
  starting on the same wall as the door blocked entry (reordered the corner
  sequence so ground-level stairs are never on the door wall); the roof was
  one solid slab with no clearance over the final flight (cut a stairwell
  opening, strips built around it like building.gd's floors). Placed on
  EastMountain's summit pad as `EastMountainTower`.
- Removed the placeholder "lollipop tree" prop and its materials; added
  ~100 trees across EastMountain (clumped + sparse) leaving the summit
  clear for the tower, and replaced the grass's hard slope cutoff with
  three reduced-density tiers (80/60/40%) so steep ground thins out
  instead of going bare.
