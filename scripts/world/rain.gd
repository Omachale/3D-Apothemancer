extends Node

## Autoload. Owns the whole storm the same way wind.gd owns wind: one place
## with the state, everything else just reads it or gets driven by it. Rain
## and lightning are one toggle rather than two because they always arrive
## together in this world — there is no "clear-sky lightning" setting to keep
## in sync by hand.
##
## F5 cycles OFF -> LIGHT -> MODERATE -> HEAVY -> OFF. Off is the default.
##
## The falling streaks always drift in the SAME direction the grass bends,
## because both read [member Wind.direction_degrees] — there is only one wind
## in this world, never a separate "rain direction" to fall out of sync. See
## the note on that var for why screen-relative "left/right" language is
## avoided here in favour of compass degrees.
##
## There used to be a moving cloud-shadow effect here too. It was removed —
## every noise-based approach tried kept drawing a visible edge to the shadow
## (straight lines, then a diamond, then still-straight segments even with no
## threshold at all). See "Cloud shadows — abandoned" in DESIGN_GOALS.md for
## the full list of what was tried, why each attempt failed, and ideas for a
## future attempt with a genuinely different technique.
##
## The emitter and lightning flash are built in code — no .tscn, no texture,
## no imported cloud/lightning art. Stand-ins, as the design goals ask for,
## that read clearly on screen.

enum Intensity { OFF, LIGHT, MODERATE, HEAVY }

## Tuning per level: how many of the emitter's particles are actually drawn
## (amount_ratio), how fast they fall, and how visible they are. Real rain
## does not fall faster when it's heavier so much as there is simply more of
## it — speed only climbs a little between levels, count climbs a lot.
## light_factor multiplies the sun's energy (1 = untouched). lightning_period
## is the average seconds between flashes; 0 means no lightning at that level
## — a drizzle should not have thunder. HEAVY's period is half MODERATE's,
## i.e. lightning strikes twice as often.
const LEVELS := {
	Intensity.LIGHT: {"amount_ratio": 0.25, "speed": 10.0, "alpha": 0.35,
		"light_factor": 1.0, "lightning_period": 0.0},
	Intensity.MODERATE: {"amount_ratio": 0.55, "speed": 13.0, "alpha": 0.5,
		"light_factor": 0.7, "lightning_period": 25.0},
	Intensity.HEAVY: {"amount_ratio": 1.0, "speed": 16.0, "alpha": 0.65,
		"light_factor": 0.4, "lightning_period": 5.0},
}
## Multiplier on grass's gust-driven lean (rain_sway_boost, a global shader
## uniform — see grass.gdshader) at each level, including OFF. Grass already
## leans 10% further than its old baseline even with no rain at all; each
## level of rain stacks another 10% on top of THAT baseline rather than
## compounding level over level, so the numbers here are the flat totals
## (1.1/1.2/1.3/1.4), not per-step multipliers. Rain physically flattens
## grass more than raw wind_strength alone would, independent of how hard the
## wind happens to be blowing that moment. Both the base and the per-level
## step used to be 20%; halved across the board because the overall bend read
## as too strong.
const SWAY_BOOST := {
	Intensity.OFF: 1.1,
	Intensity.LIGHT: 1.2,
	Intensity.MODERATE: 1.3,
	Intensity.HEAVY: 1.4,
}
## Actual wait between flashes is randomised around lightning_period within
## this fraction, so strikes don't fall into a visible metronome — same trick
## grass.gdshader uses for gust spawn timing.
const LIGHTNING_JITTER := 0.5
## How long a flash takes to fully fade, in seconds.
const LIGHTNING_FADE_TIME := 0.7
## How long the first flash of a double-strike fades (half the normal time).
const LIGHTNING_FIRST_FLASH_FADE := 0.35
## Chance a strike is immediately followed by a second one.
const LIGHTNING_DOUBLE_CHANCE := 0.5
## Delay before that second flash.
const LIGHTNING_DOUBLE_DELAY := 0.15
## Seconds a light_factor change (dimming for rain, brightening when it eases)
## takes to complete — deliberately slow so it reads as weather rolling in,
## not a light switching.
const LIGHT_FADE_TIME := 4.0

## Total particles the emitter is built for. Levels above only ever show a
## fraction of this via amount_ratio, which is cheaper than resizing the
## particle buffer on every toggle.
@export var max_particles := 2000
## Floor for the box rain spawns within, in world units (x = width, z = depth).
## The box actually used grows with camera zoom — see [member box_size_per_distance]
## — so this is only the minimum, sized to comfortably cover the ~40-unit view
## the default camera frames at its default distance.
@export var emission_size := Vector2(44.0, 44.0)
## World units the emission box grows per unit of camera zoom distance, so rain
## keeps covering the visible ground as the player zooms out instead of leaving
## bare screen at the edges. 2.2 matches emission_size at the camera's default
## distance (44 / 20) — see camera_rig.gd's `distance`.
@export var box_size_per_distance := 2.2
## Furthest the camera can zoom out — camera_rig.gd clamps `distance` to this.
## Used only to size visibility_aabb generously enough up front; the box
## itself is sized from the camera's live distance every frame.
const MAX_CAMERA_DISTANCE := 60.0
## Height above the follow point rain spawns at, and how tall the spawn box
## is — particles need to fall the full height before recycling or the
## streaks read as starting mid-air.
@export var spawn_height := 18.0
@export var spawn_box_height := 4.0
## How far sideways, in world units per second at wind_strength 1, rain
## drifts to follow the wind. 0 would make rain fall perfectly straight
## regardless of wind — kept nonzero so the same gust that leans the grass
## visibly leans the rain too.
@export var wind_influence := 3.0

var intensity: Intensity = Intensity.OFF: set = set_intensity

var _particles: GPUParticles3D
var _process_material: ParticleProcessMaterial
var _draw_material: StandardMaterial3D

var _light_factor_target := 1.0

var _flash_layer: CanvasLayer
var _flash_rect: ColorRect
var _lightning_wait := 0.0
var _lightning_accum := 0.0
## >= 0.0 while a second flash of a double-strike is armed; counts down to 0.
var _second_strike_in := -1.0
## True if the currently-fading flash is the first of a double-strike.
var _is_first_flash := false

## Found lazily once World.tscn's Sun node exists (autoloads are ready before
## the main scene is). See the "sun" group added on that node.
var _sun: DirectionalLight3D
var _sun_base_energy := 1.0
var _light_tween: Tween


func _ready() -> void:
	_build_emitter()
	_build_lightning()
	set_intensity(Intensity.OFF)


func _process(delta: float) -> void:
	if Input.is_action_just_pressed("toggle_rain"):
		_advance_intensity()

	_tick_lightning(delta)
	_ensure_sun()

	if intensity == Intensity.OFF:
		return
	_follow_player()
	_sync_to_wind()
	_sync_box_to_camera()


func _advance_intensity() -> void:
	var next: int = (int(intensity) + 1) % Intensity.size()
	set_intensity(next)


func set_intensity(value: Intensity) -> void:
	intensity = value
	# Pushed unconditionally, ahead of the particle-system early-out below —
	# grass sways by rain level regardless of whether the rain emitter itself
	# has been built yet, the same way the OFF branch still needs its own
	# value pushed rather than being skipped entirely.
	RenderingServer.global_shader_parameter_set("rain_sway_boost", SWAY_BOOST[value])
	if _particles == null:
		return
	if value == Intensity.OFF:
		_particles.emitting = false
		_lightning_wait = 0.0
		_lightning_accum = 0.0
		_second_strike_in = -1.0
		_is_first_flash = false
		_light_factor_target = 1.0
		_apply_light_factor()
		return
	var level: Dictionary = LEVELS[value]
	_particles.amount_ratio = level.amount_ratio
	_process_material.initial_velocity_min = level.speed
	_process_material.initial_velocity_max = level.speed
	_draw_material.albedo_color.a = level.alpha
	_particles.emitting = true
	_light_factor_target = level.light_factor
	_apply_light_factor()
	# Roll a fresh wait so switching straight from HEAVY to MODERATE doesn't
	# inherit a wait that was already timed for the old level's frequency.
	_lightning_accum = 0.0
	_second_strike_in = -1.0
	_lightning_wait = _next_lightning_wait(level.lightning_period)
	# Snap to the player immediately so switching levels doesn't leave a
	# frame of rain falling over wherever the emitter last was.
	_follow_player()
	_sync_box_to_camera()


func _follow_player() -> void:
	if Game.player == null or _particles == null:
		return
	var p: Vector3 = Game.player.global_position
	_particles.global_position = Vector3(p.x, p.y + spawn_height, p.z)


## Keeps the fall direction locked to Wind.direction_degrees every frame, so
## a change in wind (a live gust, or the value being tuned) is reflected in
## rain immediately, the same way it already is in grass.
func _sync_to_wind() -> void:
	if _process_material == null:
		return
	var radians := deg_to_rad(Wind.direction_degrees)
	var dir2d := Vector2(sin(radians), cos(radians))
	var lean := dir2d * Wind.strength * wind_influence
	# Mostly straight down, leaning sideways by [lean]. Y is left large and
	# negative so the direction stays dominated by "down" even at high wind.
	_process_material.direction = Vector3(lean.x, -20.0, lean.y).normalized()


## Grows the emission box with camera zoom, so rain keeps covering the ground
## the player can actually see rather than only the box it was originally sized
## for at the default zoom. Reads the camera's live distance via duck typing
## (Game.camera_rig is declared as plain Node3D) rather than a fixed
## assumption, so this stays correct if camera_rig.gd's own zoom range changes.
func _sync_box_to_camera() -> void:
	if _process_material == null:
		return
	var distance := 20.0
	if Game.camera_rig and Game.camera_rig.has_method("get_active_distance"):
		distance = Game.camera_rig.get_active_distance()
	var size := maxf(emission_size.x, distance * box_size_per_distance)
	_process_material.emission_box_extents = Vector3(size * 0.5, spawn_box_height * 0.5, size * 0.5)


## Looks up the Sun the first time it exists (World.tscn's main scene loads
## after autoloads do, so it isn't there yet in _ready) and captures its
## un-dimmed energy as the baseline every fade multiplies against.
func _ensure_sun() -> void:
	if _sun != null:
		return
	var found := get_tree().get_first_node_in_group("sun")
	if found == null:
		return
	_sun = found as DirectionalLight3D
	_sun_base_energy = _sun.light_energy
	_apply_light_factor(true) # Snap to whatever level is already active, no fade.


## Moves the sun toward _light_factor_target. Fades over LIGHT_FADE_TIME on a
## normal intensity change; snaps instantly when [param immediate] is true,
## which only happens once, from _ensure_sun(), so the very first frame the
## sun is found doesn't visibly fade from full brightness even though rain
## may already have been running for a while.
func _apply_light_factor(immediate := false) -> void:
	if _sun == null:
		return
	if _light_tween:
		_light_tween.kill()
	var target_energy := _sun_base_energy * _light_factor_target
	if immediate:
		_sun.light_energy = target_energy
		return
	_light_tween = create_tween()
	_light_tween.tween_property(_sun, "light_energy", target_energy, LIGHT_FADE_TIME)


func _next_lightning_wait(period: float) -> float:
	if period <= 0.0:
		return 0.0
	return randf_range(period * (1.0 - LIGHTNING_JITTER), period * (1.0 + LIGHTNING_JITTER))


func _tick_lightning(delta: float) -> void:
	if _lightning_wait > 0.0:
		_lightning_accum += delta
		if _lightning_accum >= _lightning_wait:
			_lightning_accum = 0.0
			var level: Dictionary = LEVELS.get(intensity, {})
			_lightning_wait = _next_lightning_wait(level.get("lightning_period", 0.0))
			_strike()
			_is_first_flash = false
			if randf() < LIGHTNING_DOUBLE_CHANCE:
				_second_strike_in = LIGHTNING_DOUBLE_DELAY
				_is_first_flash = true

	if _second_strike_in >= 0.0:
		_second_strike_in -= delta
		if _second_strike_in <= 0.0:
			_second_strike_in = -1.0
			_is_first_flash = false
			_strike()

	if _flash_rect == null or _flash_rect.modulate.a <= 0.0:
		return
	# Fast up, slower fade — a real flash is near-instant, the afterglow isn't.
	var a: float = _flash_rect.modulate.a
	var fade_time = LIGHTNING_FIRST_FLASH_FADE if _is_first_flash else LIGHTNING_FADE_TIME
	_flash_rect.modulate.a = maxf(0.0, a - delta / fade_time)


func _strike() -> void:
	if _flash_rect:
		_flash_rect.modulate.a = 1.0


func _build_emitter() -> void:
	_particles = GPUParticles3D.new()
	_particles.name = "RainEmitter"
	_particles.amount = max_particles
	_particles.lifetime = 1.6
	_particles.local_coords = false # Spawn point follows the player; falling drops stay put in world space.
	# Sized for the camera's maximum zoom, not just the default view — this is
	# only a culling bound, so making it generous costs nothing, but making it
	# too small would cull rain the player can actually see once _sync_box_to_camera
	# has grown the emission box past what this AABB expects.
	var culling_extent := MAX_CAMERA_DISTANCE * box_size_per_distance
	_particles.visibility_aabb = AABB(
		Vector3(-culling_extent, -spawn_height - 4.0, -culling_extent),
		Vector3(culling_extent * 2.0, spawn_height + 8.0, culling_extent * 2.0))
	add_child(_particles)

	_process_material = ParticleProcessMaterial.new()
	_process_material.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	_process_material.emission_box_extents = Vector3(
		emission_size.x * 0.5, spawn_box_height * 0.5, emission_size.y * 0.5)
	_process_material.gravity = Vector3.ZERO
	_process_material.spread = 3.0
	_process_material.initial_velocity_min = 12.0
	_process_material.initial_velocity_max = 12.0
	# Orients each streak along its own fall direction, so it visibly slants
	# with the wind instead of always hanging straight up and down.
	_process_material.particle_flag_align_y = true
	_particles.process_material = _process_material

	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.02, 0.55, 0.02)
	_draw_material = StandardMaterial3D.new()
	_draw_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_draw_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_draw_material.albedo_color = Color(0.8, 0.85, 0.95, 0.5)
	_draw_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.material = _draw_material
	_particles.draw_pass_1 = mesh


## A full-viewport white rect, opacity spiked to 1 on a strike and eased back
## to 0 by _tick_lightning(). No forked-bolt geometry, as asked — just a
## global flash, which is also the cheapest and most reliable way to make a
## strike read regardless of where the camera happens to be looking.
func _build_lightning() -> void:
	_flash_layer = CanvasLayer.new()
	_flash_layer.name = "LightningFlash"
	_flash_layer.layer = 90
	add_child(_flash_layer)

	_flash_rect = ColorRect.new()
	_flash_rect.color = Color.WHITE
	_flash_rect.modulate.a = 0.0
	_flash_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_flash_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_flash_layer.add_child(_flash_rect)
