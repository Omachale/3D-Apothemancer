extends Node

## Autoload. The one place wind is controlled from.
##
## The values themselves live as *global shader uniforms*, declared in
## project.godot under [shader_globals], so every material that sways reads the
## same numbers without anything having to pass them around. Grass uses them
## today. When foliage, cloth or anything else is added, it declares the same
## `global uniform` names and is automatically in sync — one gust moves the
## whole scene together, which is the entire reason for doing it this way
## rather than giving each material its own wind settings to drift apart.
##
## THE WIND MODEL IS TWO LAYERS, not one. Early on this was a single continuous
## sine wave, and it looked wrong for a reason worth remembering: it read as
## constant random wriggling because *everything was always moving*, with no
## calm to contrast it against. Real wind is mostly calm with occasional gusts
## passing through, so:
##
##   * an ambient idle jitter is small, fast and always present — barely
##     perceptible, just enough that grass reads as alive — controlled by
##     [member turbulence]. It varies by per-blade phase only, not by world
##     position, so it cannot itself look like a travelling wave — an earlier
##     version let it read as one, which was a real source of the field never
##     going calm no matter how the gust settings were changed;
##   * distinct GUSTS are LOCAL PATCHES: each is a small 2D Gaussian — soft
##     edges, no hard boundary — that spawns at a random point and drifts at
##     [member speed] for [member gust_lifetime] seconds before fading out,
##     easing in and out over time as well as space. Several lanes run with
##     independent random spawn points and timings, so different parts of a
##     field gust at different moments instead of the whole screen moving
##     together.
##
## An earlier version made the gust a band spanning the *entire* world
## perpendicular to the wind, and [member speed] was declared but never
## actually read by the shader math — every "make it slower" change was a
## no-op, which is why tuning it kept not working. Both are fixed now: gusts
## are genuinely local, and [member speed] genuinely controls how fast a
## patch's centre moves.
##
## All of that gust math lives in grass.gdshader; this script only owns the
## numbers. Use `--wind-log=<seconds>` in the dev harness to see the live
## values and the shader's own gust math evaluated as numbers, rather than
## guessing gust behaviour from screenshots — two frames a moment apart will
## always differ because of the idle layer, so a screenshot diff cannot tell
## you whether a gust actually happened.
##
## Shaders read these as:
##
##     global uniform vec2 wind_direction;
##     global uniform float wind_strength;
##     ...

## Compass direction the wind blows toward, in degrees. 0 is +Z.
##
## KEEP THIS ROUGHLY PERPENDICULAR TO THE DEFAULT CAMERA YAW (45). Grass bends
## along this direction, so when it points near the camera's own view axis the
## blades lean almost directly away from the viewer and the on-screen movement
## collapses to a few pixels — the sway is still happening, it is just being
## viewed end-on. This was 32 degrees for a long time, 13 degrees off the
## camera axis, and made the wind look completely broken while every value in
## the shader was in fact correct. -45 (315) puts it across the view instead,
## and matches the direction the proof gust patch travels in grass.gdshader —
## grass always leans the same way the patch is moving, since both are driven
## off this one vector. Don't reach for screen-relative "left/right" language
## when tuning this: it only means one thing at the default camera yaw, and
## the code used to keep an independent "screen right" copy that quietly
## pointed the opposite way from this vector — a real bug, not a description
## problem. Compass degrees are the one shared vocabulary; use those.
var direction_degrees := -45.0: set = set_direction_degrees
## Overall force. 0 is dead calm, 1 a decent breeze, 2+ a gale.
var strength := 1.0: set = set_strength
## World units per second a gust patch's centre drifts.
var speed := 2.0: set = set_speed
## Radius, in world units, of a single gust patch. Smaller reads as a tight
## local squall; larger starts to cover a whole field at once.
var gust_width := 7.0: set = set_gust_width
## Average seconds between spawns on each lane (actual spacing is randomised
## around this, so lanes don't fall into a visible metronome).
var gust_period := 10.0: set = set_gust_period
## Amount of the small, constant, always-present flutter — the "alive even
## when calm" layer, distinct from a gust passing through.
var turbulence := 1.0: set = set_turbulence


func _ready() -> void:
	# Push the declared defaults back out, so the inspector values above and
	# the shader globals cannot disagree at startup.
	set_direction_degrees(direction_degrees)
	set_strength(strength)
	set_speed(speed)
	set_gust_width(gust_width)
	set_gust_period(gust_period)
	set_turbulence(turbulence)


func set_direction_degrees(value: float) -> void:
	direction_degrees = value
	var radians := deg_to_rad(value)
	# Stored as a flat XZ vector so shaders do not each repeat the conversion.
	RenderingServer.global_shader_parameter_set(
		"wind_direction", Vector2(sin(radians), cos(radians)))


func set_strength(value: float) -> void:
	strength = maxf(value, 0.0)
	RenderingServer.global_shader_parameter_set("wind_strength", strength)


func set_speed(value: float) -> void:
	speed = maxf(value, 0.1)
	RenderingServer.global_shader_parameter_set("wind_speed", speed)


func set_gust_width(value: float) -> void:
	gust_width = maxf(value, 0.5)
	RenderingServer.global_shader_parameter_set("wind_gust_width", gust_width)


func set_gust_period(value: float) -> void:
	gust_period = maxf(value, 0.5)
	RenderingServer.global_shader_parameter_set("wind_gust_period", gust_period)


func set_turbulence(value: float) -> void:
	turbulence = maxf(value, 0.0)
	RenderingServer.global_shader_parameter_set("wind_turbulence", turbulence)


## Ramp the wind to a new strength over [param seconds]. Handy for weather
## changes, and for proving the whole scene responds together.
func gust_to(new_strength: float, seconds := 2.0) -> void:
	var tween := create_tween()
	tween.tween_method(set_strength, strength, new_strength, seconds)
