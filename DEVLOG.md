# Devlog

One or two lines per change, newest first. Not a commit log (git already has
that) and not a design doc (DESIGN_GOALS.md has that) — this exists so a
change made in an earlier session, now outside the conversation window, is
still discoverable before it gets suggested again or contradicted.

---

## 2026-08-13

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
