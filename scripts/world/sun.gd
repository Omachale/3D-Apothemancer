extends DirectionalLight3D

## Spins the light around a fixed world axis, so its direction sweeps like a
## real sun arcing overhead and dipping below the horizon at night, AND scales
## [member light_energy] by how high it currently is — a light that still
## shone at full strength while pointing straight up from below ground (i.e.
## "midnight") made the day cycle purely cosmetic; it changed shadow direction
## and nothing else, which is why time of day never visibly affected the scene.
##
## [member light_energy] is written HERE, every frame, as
## `max_light_energy * day_factor * rain_factor` — the single place that
## combines both dimming sources, so nothing else needs to know the design
## max or capture a stale copy of it. rain.gd only ever writes
## [member rain_factor]; it never touches light_energy directly. That split
## matters: if rain instead multiplied WHATEVER light_energy happened to be
## at the moment it looked, a storm rolling in at dusk would freeze in the
## dusk-dim value as its "full brightness" baseline and never darken further
## for the rest of the night — two systems fighting over one number instead
## of each owning its own factor.

## How long one full rotation takes. 300 = a five-minute day.
@export_range(5.0, 600.0, 5.0) var day_length_seconds := 300.0
## Brightness floor at night, as a fraction of [member max_light_energy].
## Not 0: this is a stylised game, not a simulation, and full black would
## leave nothing but the (also sky-driven) ambient term to see by, which
## reads as fog rather than as night. Rain can still dim further below this
## via [member rain_factor] — the floor only bounds the DAY/NIGHT factor.
@export_range(0.0, 1.0, 0.01) var min_night_factor := 0.15
## How close to the horizon (in dot-product terms, not degrees) the
## day/night transition happens across. Centred on the horizon itself
## ([member 0.0]) rather than on noon, because that is where sunrise/sunset
## actually happen — the sun is either "up" or "down" almost everywhere else
## along its arc.
@export_range(0.05, 0.6, 0.01) var twilight_band := 0.22

## Captured once in [method _ready] from whatever the scene authored — the
## "full daylight, no rain" energy every other factor scales down from.
var max_light_energy := 1.0
## Set externally by rain.gd (0..1, 1 = no rain). Deliberately the ONLY thing
## outside this script that ever influences light_energy — see the file header.
var rain_factor := 1.0


func _ready() -> void:
	max_light_energy = light_energy


func _process(delta: float) -> void:
	global_rotate(Vector3.RIGHT, TAU / day_length_seconds * delta)
	light_energy = max_light_energy * _day_factor() * rain_factor


## 1.0 at noon (shining straight down), fading through [member min_night_factor]
## across [member twilight_band] either side of the horizon, floored at
## min_night_factor for the rest of the night.
##
## A DirectionalLight3D shines along its local -Z axis, so the light travels
## in direction -basis.z, and how much that points DOWN (1 = straight down,
## i.e. noon; -1 = straight up, i.e. midnight) is +basis.z.y — the double
## negation cancels, which is exactly the elevation this needs.
func _day_factor() -> float:
	var elevation := global_transform.basis.z.y
	var t := smoothstep(-twilight_band, twilight_band, elevation)
	return lerpf(min_night_factor, 1.0, t)
