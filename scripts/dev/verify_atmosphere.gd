extends Node

## Checks atmosphere.gd's derived ranges and its wiring into zone.gd.
##
## The point of atmosphere.gd is that three numbers agree — fog end, camera far
## plane, shadow range — and the failure when they do not is a LOOK, not an
## error: a hard clipped arc at the horizon, or shadows that stop in open
## ground. Nothing raises, so nothing catches it except a check like this one.
## The camera shipped at far=300 against a horizon of 480 for exactly that
## reason, and it was invisible until someone looked into the distance.
##
## Run as a SCENE, not with --script — see verify_tower.gd's header for why:
##   Godot --headless res://scenes/dev/VerifyAtmosphere.tscn
## Exits non-zero if any check fails.

const ATMOSPHERE_SCRIPT := preload("res://scripts/world/atmosphere.gd")
const SHARED_ENVIRONMENT := preload("res://resources/environments/world_environment.tres")

## Horizon used for the standalone checks. Deliberately not the zone's own
## value — the ranges are fractions, so they must hold at any horizon.
const TEST_HORIZON := 800.0

## Fog must be total well before the ground runs out, or the last ring's edge
## is visible through it. Anything under this fraction of the horizon is fine;
## past it, the world edge shows.
const MAX_FOG_END_FRACTION := 0.97


func _ready() -> void:
	var fails := 0
	fails += _check_derived_ranges()
	fails += _check_shared_environment_untouched()
	fails += _check_zone_config()

	print("")
	if fails == 0:
		print("ALL ATMOSPHERE CHECKS PASSED")
	else:
		print("%d CHECK(S) FAILED" % fails)
	get_tree().quit(1 if fails > 0 else 0)


## The whole invariant, measured on the nodes that actually receive it rather
## than on the fractions that produce it.
func _check_derived_ranges() -> int:
	var fails := 0
	var atmosphere: WorldEnvironment = ATMOSPHERE_SCRIPT.new()
	atmosphere.environment = Environment.new()
	var camera := Camera3D.new()
	var sun := DirectionalLight3D.new()
	add_child(atmosphere)
	add_child(camera)
	add_child(sun)

	var zone := Zone.new()
	atmosphere.apply(zone.get_atmosphere(), TEST_HORIZON, camera, sun)
	zone.free()

	var env: Environment = atmosphere.environment
	var begin: float = env.fog_depth_begin
	var end: float = env.fog_depth_end
	print("horizon=%.1f fog=[%.1f..%.1f] far=%.1f shadow=%.1f opacity=%.2f" % [
		TEST_HORIZON, begin, end, camera.far,
		sun.directional_shadow_max_distance, env.fog_density])

	if not env.fog_enabled:
		print("FAIL fog is not enabled -- the horizon edge is bare")
		fails += 1
	if env.fog_mode != Environment.FOG_MODE_DEPTH:
		print("FAIL fog is not in depth mode, so it does not key off distance")
		fails += 1
	if begin >= end:
		print("FAIL fog begins at %.1f, at or past where it ends (%.1f)" % [begin, end])
		fails += 1
	if end > TEST_HORIZON * MAX_FOG_END_FRACTION:
		print("FAIL fog only reaches full at %.1f of a %.1f horizon -- the unbuilt edge shows" % [
			end, TEST_HORIZON])
		fails += 1
	if camera.far < end:
		print("FAIL camera far %.1f clips inside the fog (full at %.1f) -- hard arc" % [
			camera.far, end])
		fails += 1
	# The bug this check exists for: a far plane short of the horizon throws
	# away ground the terrain manager is still paying to build every frame.
	if camera.far < TEST_HORIZON:
		print("FAIL camera far %.1f is inside the horizon %.1f -- built ground is clipped" % [
			camera.far, TEST_HORIZON])
		fails += 1
	if sun.directional_shadow_max_distance > camera.far:
		print("FAIL shadow range %.1f exceeds the far plane %.1f" % [
			sun.directional_shadow_max_distance, camera.far])
		fails += 1
	# Fog that fades toward something other than the sky it meets reads as a
	# wall rather than as distance.
	var sky_horizon := Color(0.65098, 0.72549, 0.792157)
	var fog_rgb := Vector3(env.fog_light_color.r, env.fog_light_color.g,
		env.fog_light_color.b)
	var sky_rgb := Vector3(sky_horizon.r, sky_horizon.g, sky_horizon.b)
	if fog_rgb.distance_to(sky_rgb) > 0.1:
		print("FAIL fog colour %s does not match the sky horizon %s" % [
			env.fog_light_color, sky_horizon])
		fails += 1

	if fails == 0:
		print("PASS fog, far plane and shadow range agree")
	atmosphere.queue_free()
	camera.queue_free()
	sun.queue_free()
	return fails


## world_environment.tres is a shared resource: writing runtime fog onto it
## dirties it for every future zone (and, in the editor, for the file on disk).
## apply() duplicates first — this is what proves it still does.
func _check_shared_environment_untouched() -> int:
	var fails := 0
	var atmosphere: WorldEnvironment = ATMOSPHERE_SCRIPT.new()
	atmosphere.environment = SHARED_ENVIRONMENT
	add_child(atmosphere)
	atmosphere.apply({}, TEST_HORIZON, null, null)

	if atmosphere.environment == SHARED_ENVIRONMENT:
		print("FAIL apply() wrote onto the shared environment instead of a copy")
		fails += 1
	if SHARED_ENVIRONMENT.fog_enabled:
		print("FAIL the shared world_environment.tres now has fog baked into it")
		fails += 1
	if fails == 0:
		print("PASS the shared environment resource is left alone")
	atmosphere.queue_free()
	return fails


## Every dial atmosphere.gd reads should exist in the zone's table, or it is
## silently running on a default nobody can find to tune.
func _check_zone_config() -> int:
	var fails := 0
	var zone := Zone.new()
	var config: Dictionary = zone.get_atmosphere()
	var horizon: float = zone.get_terrain_manager().get("horizon_distance", 0.0)
	zone.free()

	for key in ["fog_begin_fraction", "fog_end_fraction", "fog_curve",
			"fog_opacity", "fog_color", "fog_sun_scatter", "fog_sky_affect",
			"far_margin", "shadow_distance"]:
		if not config.has(key):
			print("FAIL zone.get_atmosphere() is missing the %s dial" % key)
			fails += 1

	if horizon <= 0.0:
		print("FAIL zone has no horizon_distance to derive fog from")
		fails += 1

	if fails == 0:
		print("PASS zone publishes every atmosphere dial")
	return fails
