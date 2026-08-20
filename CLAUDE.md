# Instructions for Claude

## Keep DEVLOG.md updated

After any code change — not just big ones — add one or two lines to
`DEVLOG.md`, newest entry at the top of its date section. Say what changed
and why, not a line-by-line diff. The point is that a past session is
outside the context window once it's compacted or ended, so without this a
change gets silently re-suggested, or contradicted, later. Read the top of
`DEVLOG.md` at the start of a session (or when picking work back up after a
gap) before proposing something that touches recently-changed code — check
it hasn't already been done or already been tried and reverted.

Skip the entry only for something with no lasting effect: a one-off
verification run, a question answered, exploration that changed nothing.

## Zone layout: now data-driven (Task #4, 2026-08-13)

All placed structures (plates, towers, NPCs, props, buildings, stairs), the
heightfield's features (hills, plateaus, flattens), and the two procedural
tree generators' dials now live in `data/zones/starter.json` instead of
`zone.gd` literals. This lets a terrain edit be a data diff and makes a
second zone just a new JSON file + a one-line `.tscn` override.

**The critical invariant:** Several call sites branch on whether a key is
*absent*, not on its value (Heightfield computes `level` from terrain when
missing, Tower solves its own `size` when missing, TerrainManager uses the
node's own declared defaults when missing). The loader in `zone_layout.gd`
never injects defaults — a key absent from JSON stays absent from the
converted dict. Getting this wrong is silent (the world still builds, just
subtly different). **If you edit the JSON or the converter, use
`dump_zone_layout.gd` to capture a golden output against both before and
after the change and diff them — they must be identical.** It's a one-time
tool, but well worth keeping for exactly this reason.

**All JSON knowledge lives in zone_layout.gd and nowhere else.** Its header
explains the schema tables, type converters, validation rules, and the
absence rule in detail. `zone.gd`'s getters are thin reads over the
loaded layout; nothing else touches JSON.

**Adding a zone:** write a new `data/zones/*.json` (copy `starter.json` and
edit the layout), save a `.tscn` with `Zone` attached and its `layout_path`
export pointing at that JSON, and pass the scene to `Game.change_zone()`.
No code changes needed. The old "subclass Zone and override getters" path
still works for anything genuinely code-shaped (the tree generators are
that way: their code stays in `zone.gd`, only their dials moved to JSON).

**Verifying zone data:** `scripts/dev/verify_zone_data.gd` (running as a
scene via `VerifyZoneData.tscn`) is the permanent guard — it checks the
shipped JSON parses cleanly, canary values survived transcription, and
absence-sensitive keys stayed optional. Run via `run_verify.ps1 -Suites zone_data`,
or as part of the full suite with `-Suites "*"` or no `-Suites` flag at all.

**New class gotcha:** `ZoneLayout` is a `class_name`. The **first headless
run after adding a new class_name** will parse-error (`Could not find type
"ZoneLayout" in the current scope"`) until the editor rescans the global
class cache. Pass `-RescanClasses` to `run_verify.ps1` to force a rescan —
the script documents this and does it automatically when needed. The error
mode is a hang (no crash, no output, just idles), not a crash, so it's caught
by the timeout, but documenting it here saves debugging time.

## Two different kinds of "placed content" — do not confuse them (2026-08-14)

`get_props()` in `zone.gd` returns things from two architecturally different
sources, and picking the wrong one for a new request is an easy mistake (one
was made and reverted the same day this note was written — see DEVLOG.md
2026-08-14 for the full story):

- **A finite list** (hand-placed `props` entries in the JSON, or a
  `generators.*` block like `mountain_trees`/`forest`) is instantiated once,
  entirely, at zone build. Correct for a **specific, deliberate, bounded**
  thing — a named landmark forest, a windbreak, a rock at a specific spot.
  Wrong for "cover the ground so it doesn't feel empty," because a finite
  list always has an outermost entry — an edge the player can walk to no
  matter how large the list or how big its radius. Making the list bigger
  moves the edge; it does not remove it, and it makes zone load slower.
- **A streamed manager** (`TreeScatterManager`, `GrassManager`,
  `TerrainManager`) builds content in chunks around the player and frees
  chunks that fall out of range. Cost is bounded by what's near the player,
  not by the size of the world, so there is no edge — chunks exist wherever
  the player currently is, including 4km from spawn. This is the only
  correct choice for "ambient coverage that should never run out."

If a future request is "add more X everywhere" / "X should never run out"
for something not yet streamed, the fix is a new streamed manager modelled on
`tree_scatter_manager.gd` or `grass_manager.gd` (density from low-frequency
`FastNoiseLite`, chunk seed = `base_seed ^ hash(cell coords)` for determinism
without save data), not a bigger or additional finite generator.
