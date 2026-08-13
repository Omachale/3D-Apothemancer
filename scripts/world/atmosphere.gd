class_name Atmosphere
extends WorldEnvironment

## Distance haze, plus the two view ranges that have to agree with it.
##
## The ground is streamed out to terrain_manager.gd's `horizon_distance` and
## then simply stops — there is no map edge, only unbuilt land, and on a clear
## day you can see the last ring end in mid-air. Fog is what makes that edge a
## non-event: terrain fades into the sky's own horizon colour well before it
## runs out, so "the world ends here" becomes "you cannot see that far".
##
## That only works if three numbers agree, which is why they are derived here
## rather than typed into three different files that drift apart:
##
##   fog end  <=  camera far
##
## Fog must reach full opacity BEFORE the far plane, or the far plane clips
## still-visible ground and you get a hard arc instead of a fade. And the far
## plane must reach past the ground being built, which it did not: the camera
## shipped with `far = 300` against a horizon of 480, so the outer two rings
## were being built and then clipped away every frame. Both now come from
## `horizon_distance`, so moving the horizon moves all three together.
##
## Shadows are deliberately NOT scaled with the horizon. A directional shadow
## map has a fixed texel budget spread over `shadow_distance`, so stretching it
## to the horizon buys shadows nobody can see through the fog at the cost of
## blurring every shadow near the player. It stays an authored distance; the
## only thing enforced is that it does not exceed the far plane.
##
## Every dial lives in zone.gd's [method Zone.get_atmosphere] alongside the
## terrain config it is derived from — see there for what each one does.

## Fog colour. Matching the sky's own horizon colour is what makes the fade
## read as depth rather than as a grey curtain hung in front of the hills.
var fog_color := Color(0.65098, 0.72549, 0.792157)

## Where the haze starts and where it is total, as fractions of the horizon
## distance. Start too near and the whole scene is milky; end past ~0.95 and
## the unbuilt edge is still faintly visible through it.
var fog_begin_fraction := 0.35
var fog_end_fraction := 0.95

## Shape of the ramp between those two. Above 1.0 the fog stays thin for longer
## and then thickens quickly, which keeps mid-distance landmarks readable.
var fog_curve := 1.6

## Overall opacity multiplier, 0..1. THE dial to reach for first — 1.0 is a
## solid wall of haze at `fog_end_fraction`, lower values leave the horizon
## permanently translucent (and, past about 0.9, visibly unbuilt).
var fog_opacity := 1.0

## How much the sun bleeds into the fog when looking toward it.
var fog_sun_scatter := 0.1

## How much the fog tints the SKY as opposed to the geometry. Near zero on
## purpose: the sky is drawn at infinite depth, so any real amount of this
## fogs the entire dome and the scene goes flat and overcast.
var fog_sky_affect := 0.0

## How far past the fog wall the camera still draws. Only needs to be enough
## that nothing pops at the exact moment it becomes invisible.
var far_margin := 1.05

## Directional shadow range, in metres. Authored, not derived — see the class
## doc. Clamped to the far plane.
var shadow_distance := 55.0


## Distance at which fog begins and reaches full opacity, for a given horizon.
func fog_range(horizon_distance: float) -> Vector2:
	return Vector2(horizon_distance * fog_begin_fraction,
		horizon_distance * fog_end_fraction)


## Camera far plane for a given horizon. Sits past the fog wall, never short of
## the ground the terrain manager is building.
func far_plane_for(horizon_distance: float) -> float:
	return horizon_distance * far_margin


## Writes the derived values onto the environment, the camera and the sun.
## Called by world.gd once the zone has published its config, since the fog
## ranges are meaningless without the zone's horizon distance.
func apply(config: Dictionary, horizon_distance: float,
		camera: Camera3D, sun: DirectionalLight3D) -> void:
	_read_config(config)

	if environment == null:
		push_warning("Atmosphere has no environment to apply fog to.")
		return
	# The environment is a shared .tres. Duplicating it first means these
	# runtime values are never written back to the file on disk, and a second
	# zone with its own atmosphere cannot inherit this one's fog.
	environment = environment.duplicate()

	var range := fog_range(horizon_distance)
	environment.fog_enabled = true
	environment.fog_mode = Environment.FOG_MODE_DEPTH
	environment.fog_depth_begin = range.x
	environment.fog_depth_end = range.y
	environment.fog_depth_curve = fog_curve
	environment.fog_density = fog_opacity
	environment.fog_light_color = fog_color
	environment.fog_sun_scatter = fog_sun_scatter
	environment.fog_sky_affect = fog_sky_affect

	var far := far_plane_for(horizon_distance)
	if camera != null:
		camera.far = far
	if sun != null:
		sun.directional_shadow_max_distance = minf(shadow_distance, far)


func _read_config(config: Dictionary) -> void:
	fog_color = config.get("fog_color", fog_color)
	fog_begin_fraction = config.get("fog_begin_fraction", fog_begin_fraction)
	fog_end_fraction = config.get("fog_end_fraction", fog_end_fraction)
	fog_curve = config.get("fog_curve", fog_curve)
	fog_opacity = config.get("fog_opacity", fog_opacity)
	fog_sun_scatter = config.get("fog_sun_scatter", fog_sun_scatter)
	fog_sky_affect = config.get("fog_sky_affect", fog_sky_affect)
	far_margin = config.get("far_margin", far_margin)
	shadow_distance = config.get("shadow_distance", shadow_distance)
