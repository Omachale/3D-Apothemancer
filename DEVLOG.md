# Devlog

One or two lines per change, newest first. Not a commit log (git already has
that) and not a design doc (DESIGN_GOALS.md has that) — this exists so a
change made in an earlier session, now outside the conversation window, is
still discoverable before it gets suggested again or contradicted.

---

## 2026-08-13

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
