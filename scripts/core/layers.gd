class_name Layers
extends RefCounted

## Central definition of the physics layers used across the project.
## Keep in sync with the [layer_names] block in project.godot.

const WORLD := 1 << 0        ## Terrain: ground plates, hills, stair ramps.
const OBSTACLE := 1 << 1     ## Static props the player bumps into.
const PLAYER := 1 << 2
const ENEMY := 1 << 3
const INTERACTABLE := 1 << 4
const PROJECTILE := 1 << 5

## Everything the player is expected to stand on or be blocked by.
const SOLID := WORLD | OBSTACLE
