# 3D Apothemancer

A 3D top-down / isometric RPG foundation in **Godot 4.7**. This is the movement,
camera and terrain layer only — no combat, no NPCs, no inventory yet.

Open `project.godot` in Godot and press F5, or:

```bash
"C:/Users/LukeD/Desktop/Godot/Godot_v4.7-stable_win64.exe" --path "C:/Users/LukeD/Projects/3D Apothemancer"
```

## Controls

| Input | Action |
| --- | --- |
| `W` `A` `S` `D` | Move, relative to the camera |
| `Shift` | Toggle walk / run |
| `Q` `E` | Rotate the camera |
| Mouse | Aim — the character turns to face it while casting |
| `Left click` / `Space` | Cast |
| `F1` | Toggle the close-up inspect camera |
| `F3` | Toggle the debug overlay |
| `F12` | Screenshot to `user://screenshots` |

`F1` is worth knowing about. The gameplay camera is far enough out that the
character is only ~100px tall, which is useless for judging an animation; F1
swings in to eye level so you can actually see what a pose is doing.

## Layout

```
scenes/
  world/World.tscn            main scene — environment, sun, zone, player, camera, HUD
  world/zones/ZoneStarter.tscn the starter zone (terrain comes from zone.gd)
  player/Player.tscn          CharacterBody3D + Mage.glb + procedural animator
  npc/Witch.tscn              wandering NPC (caster silhouette)
  npc/Medieval.tscn           wandering NPC (armoured knight, carries a sword)
  camera/CameraRig.tscn       isometric follow rig
  props/                      tree / rock / wall stand-ins
scripts/
  core/game.gd                autoload singleton — player, camera, zone registry
  core/layers.gd              physics layer constants
  player/player_controller.gd movement, aiming, walk/run state
  player/player_animator.gd   placeholder locomotion + cast pose (see below)
  player/spell_caster.gd      cast state machine — the seam for a magic system
  player/cast_effect.gd       placeholder charge orb at the casting hand
  npc/npc_controller.gd       wander + optional ranged attack
  npc/projectile.gd           the Witch's bolt — knockback only, no damage
  dev/dump_bones.gd           prints a rig's bone names (see Dev harness)
  camera/camera_rig.gd        framing and follow
  terrain/ground_plate.gd     parametric walkable slab
  terrain/stairs.gd           parametric staircase
  terrain/terrain_mound.gd    procedural hill — heightmap mesh + trimesh body
  terrain/grass_field.gd      wind-swayed grass patch — one MultiMesh draw call
  world/wind.gd               autoload — the one global wind, everything reads it
  terrain/building.gd         multi-storey building + the cutaway reveal
  world/zone.gd               reads a zone's layout (data/zones/*.json) and builds it
  world/zone_layout.gd        loads + validates a zone's JSON layout — see ZoneLayout
  world/world.gd              spawn wiring
  dev/dev_tools.gd            screenshots and scripted-input harness
resources/                    materials, ground shader, environment
assets/models/Mage.glb        player mesh (texture is embedded in the file)
```

## How to extend it

**Add terrain.** Everything in the starter zone — heightfield features,
plates, staircases, buildings, towers, NPCs, props, the two procedural tree
generators' dials — lives in `data/zones/starter.json`, not in code. Adding a
hill is one entry in `heightfield.features`. `scripts/world/zone.gd` reads
that file (via `scripts/world/zone_layout.gd`, which validates it — an
unknown key or wrong-shaped value fails loudly rather than silently) and
builds it; nothing is baked into the `.tscn`, so terrain changes are readable
diffs in a data file, not a code change.

**Add grass.** `get_grass()`, via `grass_field.gd` — a patch is one `MultiMesh`
draw call, so instance count at *render* time costs almost nothing (three
patches, ~95k blades combined, three draw calls: 145 FPS, no measurable drop
from grass being absent). The real ceiling is *placement* time, spent once at
load raycasting each candidate blade onto the terrain below — logged per
field (`GrassField 'X': N blades — M ms placement`); all three patches here
place in well under half a second combined. That is also what a patch
automatically follows whatever terrain is underneath — flat ground, the
mound's slope, doesn't matter — skipping ground steeper than
`max_slope_degrees`. **Patches, not blanket coverage**: the camera only ever
sees ~40 units of ground, and covering the whole map at a real density would
mean a million-plus placement rays and a load-time stall, not a frame-rate
problem. Wind is read from `global uniform`s (see below), not from anything
local to the shader.

**Add a hill.** `get_mounds()`, via `terrain_mound.gd` — a real heightmap mesh
(radial smoothstep falloff plus noise) with matching trimesh collision, so the
player walks on exactly what they see. **`radius` and `height` are not
independent**: the falloff's steepest slope is `1.5 x height / radius`, and
anything past the player's 50-degree `floor_max_angle` is a wall they slide
off rather than ground. `noise_amplitude` eats into the same budget. Call
`max_slope_degrees()` to check a configuration instead of guessing — the
shipped hill is ~44 degrees at its worst and climbs at full speed.

**Add an NPC.** One entry in `get_npcs()`. Check the position against the
existing terrain footprints first — the Hill spans x ∈ [-2, 38], z ∈ [-32, 8]
and will silently swallow anything spawned inside it. `npc_wander.gd` finds
the `AnimationPlayer` by search rather than by a fixed path, so any character
exported in the same shape (root node + `Skeleton3D` + sibling
`AnimationPlayer` with baked in-place clips) works with no code change — which
is why one script drives both existing characters.

**Add a zone.** Write a new `data/zones/*.json` file, save a `.tscn` with
`zone.gd` attached and its `layout_path` export pointed at that file, and
hand the `PackedScene` to `Game.change_zone()`. No new code needed — the
switching path already exists. (Subclassing `zone.gd` and overriding a getter
still works for anything genuinely code-shaped, the way the two tree
generators are — most zones won't need it.)

**Conventions.** A plate's Y *is* the surface you walk on. A staircase starts at
its own origin and climbs toward local `+Z`, so `yaw` aims it; its rise
(`steps × step_height`) must match the plate it feeds.

## Decisions worth knowing

These deviate from the original brief, deliberately:

**Stairs collide as a ramp, not as steps.** Godot 4's `CharacterBody3D` has no
step-up handling, so a body walked into a stack of real step colliders stops
dead against the first riser. `stairs.gd` therefore builds *stepped visuals* but
a single smooth **collision ramp** across the step noses. `move_and_slide()`
carries the player up it with no raycasting and no Y-lerping — which is why the
brief's raycast-and-lerp height system isn't here; it isn't needed, and it would
fight the physics body. Keep the ramp angle under the player's `floor_max_angle`
(50°); the default 0.3 rise / 0.4 going is ~37°.

**Animation is procedural, not keyframed.** `Mage.glb` ships with a rig but no
clips. Rather than hand-authoring keyframes, `player_animator.gd` poses bones
directly: a sine-driven walk cycle blended against an idle breathing pose, with
step rate tied to actual ground speed so the feet never skate. It reads as
idle/walk/run immediately and costs nothing to discard.

To swap in real animations later: add an `AnimationPlayer` + `AnimationTree` to
`Player.tscn`, delete the `Animator` node, and drive the tree from
`PlayerController.state_changed`. Nothing else references the animator.

Note that it derives each bone's swing axis from that bone's global rest
orientation, so it does not assume any particular rig convention — it should
survive a mesh swap as long as the bone *names* match (`upperleg.l`, `spine`,
`chest`, …; see the `BONES` map).

**Buildings are cut away with a clip plane, not made transparent.** A solid
building is opaque to a camera looking down at 45 degrees, so while the player
is inside, the stone shader discards every fragment above a horizontal plane
that tracks their height, and `building.gd` additionally hides the walls whose
outer face is turned toward the camera. What is left is the interior seen from
above, which is how ARPGs have always done it.

It clips rather than fades because an alpha fade means overlapping walls,
floors and stair treads sorting against each other — which goes wrong in
exactly the stairwells the reveal exists to show — and costs shadows too. A
hard discard has neither problem.

**Near walls are cut to a low kneewall, not hidden outright.** A wall that
just disappears reads as a bug, and it takes the doorway with it — a doorway
has no geometry of its own, it is only visible as a *gap* in the wall around
it, so deleting that wall deletes the player's only way to see where the exit
is. `kneewall_height` (1.0m) keeps a stub standing so the building still reads
as a building and the door or window openings in it stay legible as gaps in
that stub. This is the same "dollhouse" technique The Sims and most isometric
RPGs use for their interior cutaways.

**There are two clip heights**, because upright and horizontal surfaces want
opposite things:

- *Walls and stairs* are cut `head_room` (3.5, a little over one storey) above
  the player's feet. That shows the whole flight ahead of them, and makes the
  storey above arrive as a growing band of wall while they climb toward it.
- *Floor slabs* are cut a mere `ceiling_clearance` (0.15) above the feet. They
  cannot use the taller number: a metre up a staircase it has already risen
  past the slab overhead, which then draws straight over the player and buries
  them. At 0.15 the slab underfoot shows and anything overhead does not, at
  every point of a climb.

**Which storeys are even eligible to be revealed is a separate, discrete gate**
from that continuous height. Only the player's current storey and the one
directly above it ever get clipped in at all; anything further away is simply
off, full stop. Skipping this gate was the first bug found once buildings
actually got walked through: a raw "feet + head_room" number, applied with no
other limit, is generous enough that early in the *first* flight it already
reaches into the *second* storey's walls, fading them in from the bottom with
nothing under them yet. The gate is what stops a distant storey ever starting
to appear before the player is anywhere near it.

**Stairs get a tighter version of that gate than walls do.** A flight is only
eligible once the player has actually reached the storey it leaves from —
not, like a wall, one storey early. This was the second bug: giving a flight
the same one-storey-early allowance as a wall let the *next* flight up begin
fading in while the player was still climbing the *current* one, which showed
steps with no landing floor under them — exactly the "hanging in nowhere"
look. A wall surviving that early preview still looks like a wall, because its
bottom edge sits at the true floor height regardless of whether that floor's
own slab has faded in yet. A staircase does not have that grace: its treads
only exist between the storey it leaves and the one it lands on, so showing
part of one before the player has reached its base is geometry with nothing
under it. `_stair_clip` vs `_upright_clip` in `building.gd` is where that
distinction lives.

**The building does not cast shadows on itself.** The clip is a per-fragment
discard in the stone shader; the mesh handed to the shadow pass is the full,
uncut box regardless. Left alone that produced two bugs that turned out to be
one bug: a hard, invisible edge in the shadow map right at the clip seam
caused streaky self-shadow acne there (visibly crawling, since the seam height
recalculates from the player's feet every frame), and a kneewalled or fully
hidden wall still threw its full, uncut shadow — a shadow with no visible
object causing it, which is exactly the kind of thing that breaks a cutaway.
Every mesh `building.gd` creates has shadow casting turned off for this
reason. Trees, props and the player are unaffected.

The very first version of this reveal hid whole storeys at a time instead of
clipping continuously, and read differently badly — you spent a flight of
stairs climbing toward nothing, and the storey appeared all at once on
arrival. Getting from there to here took three iterations, which is worth
knowing if this needs touching again: get the storey gate right before
tuning the numbers, not after.

**Successive flights alternate sides of the building** (`_flight_side`). If
they all sat in the same place they would stack: the head of the flight up from
storey 1 lands exactly where you step off the flight up from storey 0, so
arriving on a landing puts you nose-first against three metres of stone with
the way back down hidden behind it. No amount of clever clipping fixes that —
it is a layout problem. `stair_offset` is how far off centre they sit.

**A staircase needs clear floor in front of its bottom step.** This bit us:
because a flight's collision is a solid wedge (see below), a flight with its
foot flush against a wall cannot be walked onto at all — approach it from the
room and you meet the high end, which is a wall. `stair_approach` reserves the
run-up. The same applies to any staircase placed by hand.

**Casting is split into timing and consequence.** `spell_caster.gd` owns only
the state machine — WINDUP → RELEASE → RECOVER → COOLDOWN — and knows nothing
about what a spell *does*. It emits `cast_released(origin, direction)` at the
moment the spell should leave the hand, with the world position of the casting
bone. Whatever rules system arrives later (projectiles, damage types, mana)
connects to that one signal, so the rules can be rewritten repeatedly without
touching the character. Timings, the movement penalty while casting, and
whether the caster turns to face the aim point are all exported.

**The arms are the awkward part of this rig.** `Mage.glb`'s bind pose is a
T-pose: the arms lie *along* ±X. Rotating an arm about X therefore rolls it
along its own length instead of swinging it — which is what the walk cycle was
originally doing, invisibly, because the character renders too small to notice.
Arms now swing about Y and lift about Z, via `_pose_arm()`, and there is a rest
offset that drops them out of the T into a natural hang. The legs, which hang
along -Y, do genuinely swing about X. If you touch the animator, read the AXES
note at the top of the file first.

**At gameplay distance, effects matter and poses do not.** Worth knowing before
you invest in animation: at 15 units the hat brim hides almost the whole body,
and a carefully tuned arm pose is essentially invisible. What reads is the
glow, the light spilling onto the ground, and the ground decal. Budget
accordingly — the placeholder orb in `cast_effect.gd` is deliberately oversized
for this reason.

**Camera is at distance 15 / FOV 45 / pitch -45°**, not the 12–14 / ~50° in the
brief. Those numbers assumed a ~1.8-unit character; the mage is ~2.65 units tall
including the hat. These values put it at roughly 20% of viewport height, and
-45° shows meaningfully more of the body — at -50° the hat brim hides almost
everything. All four are exported on `CameraRig`, so tune to taste.

**Wind is one global shader value, not per-material settings.** Declared in
`project.godot` under `[shader_globals]` and driven by the `Wind` autoload
(`world/wind.gd`), which calls `RenderingServer.global_shader_parameter_set`
rather than exposing per-material uniforms. Every shader that sways reads the
same `global uniform`s and gets the same gust at the same moment — the whole
point is that grass, and foliage/cloth added later, move together instead of
each doing their own independent thing. Change the weather from
`Wind.strength = 2.0` or `Wind.gust_to(0.0, 3.0)`; never write to
`RenderingServer` directly from anywhere else. What the values actually mean —
idle jitter versus travelling gusts — is covered below, under "the wind model
is two layers".

**Grass bends by geometry, not by texture, because a texture cannot change
shape.** `grass_field.gd` builds a tiny tapered blade mesh (UV.y = 0 at root,
1 at tip) and instances it thousands of times via `MultiMeshInstance3D`. The
vertex shader (`grass.gdshader`) reads that UV to weight how much of the wind's
sideways push each vertex gets — root fixed, tip free — and bends by `bend^2`
in Y as well as sideways, because a real blade shortens in silhouette as it
leans; without that a strong gust visibly stretches the grass. Per-blade phase,
stiffness and tint ride in `INSTANCE_CUSTOM`, which is what stops a field
swaying in perfect lockstep like a single object.

**Grass patches feather at the edge and follow terrain by raycasting.**
Planting rejects points probabilistically as they approach the patch radius
(`edge_feather`), which is the difference between a meadow and a green disc
with a visible rim. Placement rays straight down onto whatever the physics
world reports, so a patch dropped onto the mound's flank plants correctly on
the slope with no special-casing — the cost is that `--at` in the
dev harness must spawn *above* the real ground height at sloped points, or the
character falls through to whatever flat plane is underneath instead of
resting on the slope.

**Stone is generated in world space, not textured.**
`resources/shaders/stone_blocks.gdshader` lays masonry courses out from world
coordinates, so separate boxes meeting at a corner keep their joints lined up
and nothing needs UV mapping — which is what makes a whole building buildable
out of plain `BoxMesh`es. It picks square flagstones for near-horizontal faces
and running-bond courses for vertical ones, off the surface normal. Stone was
chosen over wood because a staggered grid of blocks is convincing with almost
no work, where planks need believable grain and direction.

**Ground is mottled noise, not a checkerboard.** It was a world-space grid at
first, kept for readability while there was no real texturing — but it tiled
visibly and read as floor tiles rather than terrain, more obviously once grass
sat on top of it and bare patches showed the ground at the edges.
`resources/shaders/ground_meadow.gdshader` replaced it: three octaves of
world-space value noise (macro blotches, fine grain, small speckle), no
texture, same convention as everything else. Noise has no repeating unit for
the eye to lock onto, which is the actual fix — softening the old grid's
contrast would not have been enough.

**The wind model is two layers, not one, and this was a real redesign, not a
tuning pass.** The first version was a single continuous sine wave, and it
looked wrong for a specific, nameable reason: everything was always moving, so
there was no calm to contrast a gust against, and it just read as constant
random wriggling. Real wind is mostly still with occasional gusts passing
through, so `grass.gdshader` now has:

- an always-on **idle jitter** — small, fast, barely perceptible, just enough
  that grass reads as alive when nothing else is happening;
- distinct **gusts** — a bell-shaped (Gaussian) band of extra bend positioned
  along the wind direction, whose centre moves at a constant world-space
  speed. Because the maths only depends on each vertex's own position along
  the wind axis and a single shared, time-driven centre, the peak genuinely
  sweeps across the world from upwind to downwind rather than the whole field
  pulsing in place — confirmed by watching one location go calm → visibly bent
  → calm again over a single gust's passage. Three gusts run on staggered
  timers so they arrive every few seconds and occasionally overlap for a
  stronger combined push, rather than the whole map waiting through one long
  silence between identical, evenly-spaced pulses.

Every wind number lives on the `Wind` autoload and is a *global* shader
uniform — see the dedicated note further down for why.

## Dev harness

`dev_tools.gd` can drive the game from the command line, which is how the
movement above was verified:

```bash
godot --path . -- --shot=out.png --shot-frames=700 --drive=move_forward,move_right --log=0.5
```

- `--drive=<actions>` holds input actions for the whole run
- `--log=<seconds>` prints player position / speed / grounded state, plus cast
  phase and where the casting hand is relative to the feet, plus one line per
  NPC with its position, speed, wander state and current animation clip
- `--shot=<path> --shot-frames=<n>` writes a PNG after N frames, then quits
- `--shot-at=<seconds>` shoots at a wall-clock time instead — what you want
  when timing a shot against an animation
- `--cast-at=<seconds>` fires a single cast
- `--cam=<yaw,pitch,distance>` overrides the camera framing
- `--mouse=<x,y>` pins the mouse to a fraction of the viewport. The character
  turns to face the mouse while casting, so without this the pose a screenshot
  catches depends on wherever the cursor happened to be.

The `--log` hand readout is the honest way to check a pose. The robe hides the
arms from most angles, so a screenshot will not tell you whether an arm moved:

```bash
godot --path . -- --cast-at=1.0 --log=0.06 --shot=out.png --shot-at=1.8
```

`scripts/dev/dump_bones.gd` prints a rig's bone names and rest positions, which
is the first thing to run against any new character model:

```bash
godot --headless --path . --script res://scripts/dev/dump_bones.gd
```

## Running the verification suites

Always go through the runner rather than invoking Godot directly:

```bash
pwsh -File scripts/dev/run_verify.ps1
```

Single suites, and the switch to use after adding a `class_name`:

```bash
pwsh -File scripts/dev/run_verify.ps1 -Suites tower,zone_layout,zone_data -RescanClasses
```

**Why not call Godot directly.** Every `verify_*.gd` exits through a single
`quit()` as the last statement of `_ready()`/`_init()`. There is no watchdog.
A GDScript error is fatal to the *script* but not to the *process*: on a parse
error `_ready()` never runs, so `quit()` is unreachable, and headless Godot —
no window, no input, no work queue — idles forever. It does not crash, time
out, or exit non-zero. One such run sat there for over twenty minutes because
of a single un-inferable `:=`.

The runner closes the three ways that trap gets sprung:

- **Parse-checks first** (`--check-only`), so a bad script fails in under a
  second with a line number instead of hanging. Note `--check-only` implies
  `--script`, which does *not* set up autoloads, so `Compile Error: Identifier
  not found: Game` (and its cascade) is expected noise and is ignored;
  `Parse Error` never is.
- **`-RescanClasses`** forces the editor filesystem scan that writes
  `.godot/global_script_class_cache.cfg`. A new `class_name` is invisible to
  headless runs until that happens, so the first run after adding one is
  otherwise *guaranteed* to parse-error and therefore hang.
- **Two backstops** — `--quit-after` bounds the process from inside, and a
  wall-clock `WaitForExit` kills it from outside.

Because `--quit-after` force-quits with exit code 0, a hung suite would look
like a silent pass on exit code alone. A suite counts as passing only if it
exits 0 **and** prints its own success marker.

## Verified

Measured via the harness above, not eyeballed:

- Walks at exactly 4.00 u/s, runs at 7.50 u/s
- Climbs the hill staircase 0 → 3.00 and holds Y=3.00 on the plateau, at both
  walk and run speed, never losing floor contact
- Stops dead against a tree at the exact capsule + collider radius, no jitter or
  penetration
- ~100–145 FPS at 1280×720
- A cast runs WINDUP → RELEASE → RECOVER → READY on the exported timings, and
  the casting hand travels from 0.46 to 0.96 units above the feet and 0.60
  units forward across it
- Casting while walking drops the walk speed from 4.00 to 1.00 u/s
- Running swings the hand between 0.06 and 0.35 units forward — the arm swing
  the pre-T-pose-fix code was silently not producing
- The player walks through the keep's doorway without losing speed, and climbs
  both flights at a steady 4.00 u/s, 0 → 3.20 → 6.40, never losing floor
  contact
- Inside the keep, the ceiling overhead is cut away at every point of a climb —
  including mid-flight, where it would otherwise draw over the player — and the
  two camera-facing walls are cut to a low kneewall rather than removed;
  rotating the camera swaps which pair
- The second flight of stairs does not appear at all while the player is still
  climbing the first — it becomes visible, complete with its landing floor,
  only once they actually reach the storey it leaves from
- No self-shadow streaking at the clip seam, and no shadow cast by a wall
  that has been cut away or hidden
- From outside, the building is solid and unclipped
- Both NPCs cycle IDLE → WALK → IDLE, moving at exactly their 2.20 u/s walk
  speed with the `Idle` and `Walk` clips switching to match, and both rest at
  exactly y = 0.00 rather than sunk into the ground
- The Witch's bolt shoves the player 3.07 units directly *away* from her and
  lifts them off the ground — matching the predicted `force / decay` = 16 / 5
- The hill's summit sits at exactly 10.92 = `height` 11 − `rim_sink` 0.08, and
  the player walks base-to-summit (0.00 → 10.77) at full 16 u/s without ever
  losing floor contact
- Three grass patches (~95k blades combined, three draw calls) hold 145 FPS,
  placing all three in well under half a second combined at load
- A single gust visibly bends a fixed patch of grass from calm, through a
  clear lean, and back to calm as it passes — confirmed by watching one
  location across a gust's full transit, not inferred from the shader math
- The hillside patch plants correctly onto the mound's sloped, noisy surface,
  not just flat ground
- Walking through a grass patch holds full speed with no collision and no
  floor loss; grass is purely visual
- ~120 FPS at 1280×720 inside the building

## Known gaps

- The main plane has open edges — walk far enough off it and you fall.
- Staircases have no side rails; you can walk off the side of a flight. Inside
  the keep the stairwell openings are exactly as wide as the flights, so there
  is no gap beside them, but the upper storeys' openings are unguarded.
- The reveal only hides *walls*. Interior geometry — the staircase itself
  above all — still gets between the camera and the player. A real fix is to
  draw the character through occluders, not to remove more geometry.
- The keep's ground floor sits flat on the terrain and assumes it is level
  there. It has no foundation, so placing one on a slope would leave a gap.
- `cast_released` fires but nothing listens: a cast currently produces a glow
  and no projectile, damage or cost. That is the next seam to fill.
- `face_aim` on the player is off outside of casting, so you cannot strafe.
- `Game.change_zone()` exists but is untested — there is only one zone.
- `assets/textures/mage_texture.png` is a source reference only; the GLB embeds
  its own copy, which is what actually renders.
