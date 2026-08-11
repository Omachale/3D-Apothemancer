extends Node

## Autoload. The one place wind is controlled from, and — since gusts became
## stateful — the one place gusts actually LIVE.
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
##     position, so it cannot itself look like a travelling wave;
##   * distinct GUSTS are LOCAL PATCHES: each is a small 2D Gaussian — soft
##     edges, no hard boundary — that drifts across the world and fades in and
##     out over its life. Several run at once with independent spawn points,
##     so different parts of a field gust at different moments instead of the
##     whole screen moving together.
##
## WHY GUSTS ARE COMPUTED HERE AND NOT IN THE SHADER. They used to be: each
## shader ran a `gust_lane()` that derived a gust's position from TIME and a
## hash, with no state anywhere. That is elegant but it cannot express the
## behaviour actually wanted — "spawn near the player, then persist until you
## have left their view" — because a stateless function has no memory of where
## the player WAS when a gust was born. It also meant every consumer had to
## carry a copy of identical spawn math (grass had one, trees needed another),
## which is exactly the drift this file exists to prevent.
##
## So gusts are real objects here. Each frame they advance, retire once they
## are past the view, and are published as global shader uniforms
## `wind_gust_0` .. `wind_gust_5`, each a vec4 of
## (centre.x, centre.z, radius, strength). A shader's whole job is now to sum
## a Gaussian per gust — no hashing, no spawn logic, no trig. That is both
## cheaper (the old version recomputed ~30 transcendental ops per VERTEX to
## produce a value constant across the whole instance) and impossible to
## desync between grass and trees, since both read the same published numbers.
##
## Shaders read these as:
##
##     global uniform vec2 wind_direction;
##     global uniform float wind_strength;
##     global uniform vec4 wind_gust_0; // .. wind_gust_5
##
## Use `--wind-log=<seconds>` in the dev harness to print the live gusts. That
## readout is now the same data the shaders receive rather than a hand-kept
## mirror of shader math, so it cannot report something the screen disagrees
## with.

## How many gusts can be alive at once. This is a hard cap because each slot is
## its own global uniform — changing it means adding matching `wind_gust_N`
## entries to project.godot's [shader_globals] AND to every shader that reads
## them. Six patches of [member gust_width] radius still leave plenty of calm
## ground in a screen-sized view, which is the point of the two-layer model.
const MAX_GUSTS := 6

## Compass direction the wind blows toward, in degrees. 0 is +Z (this is a
## wind-local reference frame, NOT the North/East/South/West naming in
## DESIGN_GOALS.md — see that file's compass section for why the two don't
## line up; converting between them means going through raw XZ vectors).
##
## KEEP THIS ROUGHLY PERPENDICULAR TO THE DEFAULT CAMERA YAW (0, facing North
## / -Z, i.e. wind-compass 180). Grass bends along this direction, so when it
## points near the camera's own view axis the blades lean almost directly
## toward/away from the viewer and the on-screen movement collapses to a few
## pixels — the sway is still happening, it is just being viewed end-on. This
## was 32 degrees for a long time (13 degrees off a then-45-degree camera
## yaw) and made the wind look completely broken while every value was in
## fact correct; changing the camera's default yaw to 0 broke the
## perpendicularity again the same way, which is why this is now 90 rather
## than the old -45. Don't reach for screen-relative "left/right" language
## when tuning this: it only means one thing at the default camera yaw.
## Compass degrees are the one shared vocabulary; use those.
var direction_degrees := 90.0: set = set_direction_degrees
## Overall force. 0 is dead calm, 1 a decent breeze, 2+ a gale.
var strength := 1.0: set = set_strength
## World units per second a gust patch's centre drifts. CPU-side only now —
## no shader reads it, because no shader moves a gust any more.
var speed := 1.0: set = set_speed
## Radius, in world units, of a single gust patch. Smaller reads as a tight
## local squall; larger starts to cover a whole field at once.
var gust_width := 7.0: set = set_gust_width
## Average seconds between spawns. Actual spacing is randomised around this so
## gusts don't fall into a visible metronome. Note the cap: once MAX_GUSTS are
## alive, the timer still runs but finds no free slot.
var gust_period := 10.0: set = set_gust_period
## Maximum angle, in degrees, a gust's drift direction may wander from
## [member direction_degrees]. Drawn once at spawn and held for life — a patch
## does not curve mid-flight, it simply is not perfectly parallel to its
## neighbours. Blade LEAN still follows direction_degrees exactly regardless;
## only where each patch travels varies, which is what stops a field reading as
## one uniform band sweeping through every time.
var gust_direction_variance := 18.0: set = set_gust_direction_variance
## Fraction of a gust's life spent easing in and out, each side, rather than
## sitting at full strength. Paired with a smoothstep curve: a linear ramp
## still has a visible kink at zero, while smoothstep has zero slope at both
## ends, which is what reads as gradual rather than merely slow.
var gust_ease_fraction := 0.35
## Amount of the small, constant, always-present flutter — the "alive even
## when calm" layer, distinct from a gust passing through.
var turbulence := 1.0: set = set_turbulence

## How far, in world units per unit of camera zoom distance, the player can
## actually see. A gust must cross this much ground before it is allowed to
## die. 1.6 covers the corners of the view at the default zoom, where the
## visible ground is about 2.2 units wide per unit of distance (see rain.gd's
## box_size_per_distance, which sizes its emission box off the same fact).
var view_radius_per_distance := 1.6
## Floor for the above, so a very close camera still gets gusts that travel a
## sensible distance rather than popping in and out a few metres away.
var min_view_radius := 30.0
## How far beyond the view's edge a gust spawns, so it eases in off-screen and
## is already at full strength by the time it is visible.
var spawn_margin := 8.0
## How far past the far edge a gust must travel before it is retired. Larger
## than spawn_margin deliberately: a gust must never be culled while any part
## of its soft edge could still be on screen.
var retire_margin := 12.0

## Live gusts. Each is {pos: Vector2, dir: Vector2, age: float,
## lifetime: float, radius: float}.
var _gusts: Array[Dictionary] = []
var _spawn_timer := 0.0
var _seeded := false


func _ready() -> void:
	# Push the declared defaults back out, so the values above and the shader
	# globals cannot disagree at startup.
	set_direction_degrees(direction_degrees)
	set_strength(strength)
	set_turbulence(turbulence)
	_publish_gusts()


func _process(delta: float) -> void:
	# Autoloads are not processed in the editor unless they are @tool, but the
	# guard costs nothing and this codebase has already been bitten once by a
	# node ticking against a not-fully-constructed Game singleton.
	if Engine.is_editor_hint():
		return

	var focus := _focus_point()
	var view_radius := _view_radius()

	# Held off until the player exists, or the opening gusts would be seeded
	# around the world origin rather than around wherever the zone actually
	# drops them.
	if not _seeded and Game.player != null:
		_seeded = true
		_seed_initial_gusts(focus, view_radius)

	_advance_gusts(delta, focus, view_radius)

	_spawn_timer -= delta
	if _spawn_timer <= 0.0:
		_spawn_timer = randf_range(gust_period * 0.6, gust_period * 1.4)
		if _gusts.size() < MAX_GUSTS:
			_gusts.append(_make_gust(focus, view_radius, _spawn_distance(view_radius)))

	_publish_gusts()


## Moves every gust along its own heading and drops the ones that are done.
##
## Two separate retirement tests, and both are needed. The age test is the
## backstop for a gust that never gets anywhere near the player again — if they
## walk perpendicular to the wind, a patch off to the side would otherwise
## drift forever. The distance test is the one that implements "persist until
## no longer visible", and it measures how far DOWNWIND of the player the gust
## has travelled rather than plain radial distance: a gust spawned with a large
## sideways offset is already far away in a straight line, and a radial test
## would cull it the instant it was born.
func _advance_gusts(delta: float, focus: Vector2, view_radius: float) -> void:
	var step := speed * delta
	var i := _gusts.size() - 1
	while i >= 0:
		var g := _gusts[i]
		g["age"] += delta
		g["pos"] += g["dir"] * step
		var downwind: float = (g["pos"] - focus).dot(g["dir"])
		if g["age"] >= g["lifetime"] or downwind > view_radius + retire_margin:
			_gusts.remove_at(i)
		i -= 1


## Starts the world with wind already in it. Without this the first gust is a
## full spawn-distance away and the opening ~20 seconds are dead calm, which
## reads as the system being broken rather than as weather. One patch is placed
## already over the player at full strength, one a little upwind so there is a
## visible arrival shortly after.
func _seed_initial_gusts(focus: Vector2, view_radius: float) -> void:
	# Lateral pinned near zero for this one: the usual random sideways offset
	# can be most of a view radius, which would put the "already here" gust far
	# enough off to one side that the opening frames still look calm.
	var overhead := _make_gust(focus, view_radius, 0.0, 0.0)
	overhead["age"] = overhead["lifetime"] * 0.5
	_gusts.append(overhead)
	_gusts.append(_make_gust(focus, view_radius, view_radius * 0.5))


func _spawn_distance(view_radius: float) -> float:
	return view_radius + spawn_margin


## One gust, [param upwind_distance] world units upwind of [param focus] with a
## random sideways offset. Lifetime is derived rather than configured: it is
## exactly the time needed to cross from here to past the far edge of the view
## at the current [member speed], which is what makes "lasts until it is no
## longer visible" true at any zoom level instead of a number that has to be
## re-tuned whenever the camera changes.
## [param lateral] overrides the random sideways offset when >= 0; leave it
## negative for the usual randomised placement.
func _make_gust(focus: Vector2, view_radius: float, upwind_distance: float,
		lateral := -1.0) -> Dictionary:
	var dir := _direction_vector().rotated(
		deg_to_rad(randf_range(-gust_direction_variance, gust_direction_variance)))
	var perp := Vector2(-dir.y, dir.x)
	# Kept inside the view rather than the full spawn radius, so most gusts
	# actually pass through ground the player can see.
	if lateral < 0.0:
		lateral = randf_range(-view_radius * 0.8, view_radius * 0.8)
	var travel := upwind_distance + view_radius + retire_margin
	return {
		"pos": focus - dir * upwind_distance + perp * lateral,
		"dir": dir,
		"age": 0.0,
		"lifetime": travel / maxf(speed, 0.01),
		"radius": gust_width,
	}


## Where the wind is centred. The player rather than the camera: gusts should
## follow whoever the world is being generated around, and the camera can swing
## a long way off them while rotating.
func _focus_point() -> Vector2:
	if Game.player:
		var p: Vector3 = Game.player.global_position
		return Vector2(p.x, p.z)
	return Vector2.ZERO


## How far the player can see, from the camera's live zoom. Read by duck typing
## the same way rain.gd sizes its emission box, so this stays correct if
## camera_rig.gd's zoom range changes.
func _view_radius() -> float:
	var distance := 20.0
	if Game.camera_rig and Game.camera_rig.has_method("get_active_distance"):
		distance = Game.camera_rig.get_active_distance()
	return maxf(min_view_radius, distance * view_radius_per_distance)


## Smoothstep ease in and out over [member gust_ease_fraction] of the life.
func _gust_strength(g: Dictionary) -> float:
	var lifetime: float = g["lifetime"]
	if lifetime <= 0.0:
		return 0.0
	var progress: float = clampf(g["age"] / lifetime, 0.0, 1.0)
	var fade: float = maxf(gust_ease_fraction, 0.01)
	var ramp: float = clampf(minf(progress, 1.0 - progress) / fade, 0.0, 1.0)
	return smoothstep(0.0, 1.0, ramp)


## Unused slots are published as all-zero, which the shaders skip on strength.
func _publish_gusts() -> void:
	for i in MAX_GUSTS:
		var value := Vector4.ZERO
		if i < _gusts.size():
			var g := _gusts[i]
			var pos: Vector2 = g["pos"]
			value = Vector4(pos.x, pos.y, g["radius"], _gust_strength(g))
		RenderingServer.global_shader_parameter_set("wind_gust_%d" % i, value)


func _direction_vector() -> Vector2:
	var radians := deg_to_rad(direction_degrees)
	return Vector2(sin(radians), cos(radians))


func set_direction_degrees(value: float) -> void:
	direction_degrees = value
	# Stored as a flat XZ vector so shaders do not each repeat the conversion.
	RenderingServer.global_shader_parameter_set("wind_direction", _direction_vector())


func set_strength(value: float) -> void:
	strength = maxf(value, 0.0)
	RenderingServer.global_shader_parameter_set("wind_strength", strength)


func set_turbulence(value: float) -> void:
	turbulence = maxf(value, 0.0)
	RenderingServer.global_shader_parameter_set("wind_turbulence", turbulence)


func set_speed(value: float) -> void:
	speed = maxf(value, 0.1)


func set_gust_width(value: float) -> void:
	gust_width = maxf(value, 0.5)


func set_gust_period(value: float) -> void:
	gust_period = maxf(value, 0.5)


func set_gust_direction_variance(value: float) -> void:
	gust_direction_variance = clampf(value, 0.0, 45.0)


## The live gusts, for debugging and tests. These are the same numbers the
## shaders were handed this frame, so a disagreement between this and the
## screen is a shader bug, never a stale mirror.
func get_gusts() -> Array:
	var out: Array = []
	for g in _gusts:
		out.append({
			"pos": g["pos"], "radius": g["radius"], "strength": _gust_strength(g),
			"age": g["age"], "lifetime": g["lifetime"],
		})
	return out


## Combined gust intensity at a world XZ point — the same sum the shaders do,
## including the same cap, so it can be asserted against in a test.
func gust_value_at(xz: Vector2) -> float:
	var total := 0.0
	for g in _gusts:
		var offset: Vector2 = xz - g["pos"]
		var r: float = maxf(g["radius"], 0.5)
		total += exp(-offset.length_squared() / (r * r)) * _gust_strength(g)
	return minf(total, 1.4)


## Ramp the wind to a new strength over [param seconds]. Handy for weather
## changes, and for proving the whole scene responds together.
func gust_to(new_strength: float, seconds := 2.0) -> void:
	var tween := create_tween()
	tween.tween_method(set_strength, strength, new_strength, seconds)
