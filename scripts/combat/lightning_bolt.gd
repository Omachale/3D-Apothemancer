extends Node3D

## A cosmetic-only lightning strike between two points already decided by
## something else — see the class note on THE HIT IS NOT COMPUTED HERE below.
##
## THE HIT IS NOT COMPUTED HERE. player_attacks.gd resolves who (or what) got
## struck with a straight-line raycast or a direct hit on the assisted target,
## BEFORE this node is even spawned, and hands the result in through
## [method strike] as [param body]. Everything this class draws — the jagged,
## forking path — is built afterward from the same two straight-line endpoints
## and has no way to change what was already decided. That split is
## deliberate: "the angles are cosmetic" only holds if the geometry that draws
## them cannot also be the thing doing the hit test.
##
## THE PATH IS BUILT BY MIDPOINT DISPLACEMENT: start with the straight segment
## from -> to, repeatedly split each segment at its midpoint and kick that
## midpoint sideways by a random amount, halving the kick each generation. The
## result vaguely follows the straight line while never actually being it —
## the same construction real lightning-generation demos use in 2D, extended
## to 3D by sampling the sideways kick in a full circle around the segment
## rather than along a single perpendicular.
##
## FORMING IS A REVEAL, NOT A GROWTH. Every segment box is built once, up
## front, and simply hidden until the "formed length" reaches it — cheap, and
## at the speeds this runs, indistinguishable from smoothly growing.
##
## THE VELOCITY SEAM: [member travel_speed_mps] is 0 today, meaning the strike
## lands the instant this node exists and the visual forms in
## [member min_form_time] regardless of distance. Raise it above zero and BOTH
## the forming duration and the moment the hit is actually applied switch to
## distance / travel_speed_mps automatically — see [method _travel_time] and
## [method _process]. Nothing else in this class needs to change for lightning
## to start travelling; that is the whole point of routing both timings
## through one number.
##
## THE BOLT ONLY EVER MOVES AWAY FROM THE CASTER, never back toward it. Forming
## is a reveal that runs from -> to (see above) and never runs in reverse; the
## fade-out at the end dims the shared material's alpha in place rather than
## scaling the node toward zero, because scaling toward this node's own origin
## — the caster's hand — is a visible retraction. A bolt that reached out and
## then visibly snapped back reads as the animation running backward, not as a
## strike.

## Fired once the strike actually lands — immediately for an instant bolt,
## after travel time for a fast one. A hook for hit reactions; nothing listens
## yet.
signal struck(at: Vector3, body: Node3D, damage: float)

## How much of a fork's direction is "still heading toward the target" versus
## "peeling sideways" — see [method _build_forks]. 1.0 would be no fork at
## all (dead straight); 0.0 would be the old purely-perpendicular stub that
## read as a second bolt firing off on its own.
const FORK_FORWARD_BIAS := 0.72

@export_group("Look")
## Blue-white on purpose — a real emissive material at a high energy
## multiplier reads as white-hot at the core and blue at the edges through
## bloom, the same trick cast_effect.gd's orb uses, so one colour is enough.
@export var color := Color(0.62, 0.82, 1.0)
@export_range(0.01, 0.2, 0.005) var thickness := 0.05
## How many times the path is split. Each split doubles the segment count, so
## keep this modest — 5 already gives 32 segments, plenty dense at the
## distances this is thrown over.
@export_range(1, 6) var subdivisions := 5
## Sideways kick at the FIRST split, in metres, halved every split after.
## Set to the tightest end of what the (now removed) tuning slider offered —
## see DEVLOG — so the bolt reads as a focused strike heading toward the
## target rather than a scribble.
@export_range(0.0, 4.0, 0.05) var jitter := 0.02
@export_range(0, 6) var fork_count := 5
## Length of a fork stub, as a fraction of the total straight-line distance.
@export_range(0.0, 0.6, 0.01) var fork_length_fraction := 0.22
@export_range(0.0, 16.0, 0.1) var light_energy := 7.0
@export_range(0.5, 12.0, 0.1) var light_range := 9.0
## Held fully visible after forming, before the fade begins.
@export_range(0.0, 0.3, 0.005) var sustain_time := 0.05
@export_range(0.0, 0.4, 0.005) var fade_time := 0.1

@export_group("Impact")
@export var damage := 0.0
@export var apply_knockback_on_hit := true
@export_range(0.0, 60.0, 0.5) var knockback_force := 10.0
@export_range(0.0, 20.0, 0.5) var knockback_lift := 2.0

@export_group("Flight")
## 0 = arrives, and hits, instantly — see the class note. Above 0, both the
## forming animation and the moment damage lands stretch out to
## distance / this value, in metres per second.
@export_range(0.0, 400.0, 1.0) var travel_speed_mps := 0.0
## However fast, the forming animation is never literally zero-length — a
## same-frame reveal would read as a pop rather than a bolt. Applies whether
## or not travel_speed_mps is ever tuned above zero.
@export_range(0.01, 0.2, 0.005) var min_form_time := 0.05

var _from := Vector3.ZERO
var _to := Vector3.ZERO
var _body: Node3D = null
var _rng := RandomNumberGenerator.new()
var _material: StandardMaterial3D = null
var _light: OmniLight3D = null

var _form_time := 0.05
var _age := 0.0
var _forming := true
var _struck := false
var _total_length := 0.0
var _segments: Array[MeshInstance3D] = []
var _segment_start_lengths: PackedFloat32Array = []


func _ready() -> void:
	_rng.randomize()
	_material = StandardMaterial3D.new()
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.emission_enabled = true
	_material.emission = color
	_material.emission_energy_multiplier = 5.0
	_material.albedo_color = color
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	set_process(false)


## Points the bolt from [param from] to [param to] and, if [param body] is
## given, deals damage and knockback to it once the strike lands — instantly
## unless [member travel_speed_mps] says otherwise. Call straight after adding
## this to the tree, same as arrow.gd's launch() and projectile.gd's launch().
func strike(from: Vector3, to: Vector3, body: Node3D = null) -> void:
	_from = from
	_to = to
	_body = body
	global_position = from
	_form_time = maxf(_travel_time(), min_form_time)
	_build_path()
	_light = OmniLight3D.new()
	_light.light_color = color
	_light.omni_range = light_range
	_light.shadow_enabled = false
	_light.position = (_to - _from) * 0.5
	_light.light_energy = 0.0
	add_child(_light)
	if travel_speed_mps <= 0.0:
		_apply_impact()
	set_process(true)


func _travel_time() -> float:
	if travel_speed_mps <= 0.0:
		return 0.0
	return _from.distance_to(_to) / travel_speed_mps


func _process(delta: float) -> void:
	_age += delta
	if _forming:
		var t := clampf(_age / _form_time, 0.0, 1.0)
		_reveal_up_to(_total_length * t)
		_light.light_energy = light_energy * t
		if t >= 1.0:
			_forming = false
			if not _struck and travel_speed_mps > 0.0:
				_apply_impact()
		return

	var since_formed := _age - _form_time
	if since_formed < sustain_time:
		return
	# Dims in place rather than shrinking — see the class note on
	# ONLY EVER MOVING AWAY FROM THE CASTER. A scale-to-zero fade shrinks
	# every segment toward this node's own origin (the caster's hand), which
	# reads as the bolt retracting into the hand it just left. Fading the
	# shared material's alpha instead extinguishes every segment where it
	# already is, so nothing this class draws ever moves toward the caster.
	var fade_t := clampf((since_formed - sustain_time) / maxf(fade_time, 0.001), 0.0, 1.0)
	_material.albedo_color.a = 1.0 - fade_t
	_light.light_energy = light_energy * (1.0 - fade_t)
	if fade_t >= 1.0:
		queue_free()


func _apply_impact() -> void:
	_struck = true
	if _body and damage > 0.0 and _body.has_method("take_damage"):
		_body.take_damage(damage)
	if _body and apply_knockback_on_hit and _body.has_method("apply_knockback"):
		_body.apply_knockback((_to - _from).normalized(), knockback_force, knockback_lift)
	struck.emit(_to, _body, damage)


func _reveal_up_to(formed_length: float) -> void:
	for i in _segments.size():
		_segments[i].visible = _segment_start_lengths[i] <= formed_length


## Builds the jagged main path plus its forks and instances a thin emissive
## box per segment, hidden until [method _reveal_up_to] shows it.
func _build_path() -> void:
	var main_points: PackedVector3Array = [_from]
	_displace(_from, _to, subdivisions, jitter, main_points)

	var cumulative := 0.0
	cumulative = _add_segments(main_points, 0.0)
	_total_length = cumulative

	var straight_length := _from.distance_to(_to)
	if straight_length > 0.001 and fork_count > 0 and main_points.size() > 2:
		_build_forks(main_points, straight_length)


## Recursive midpoint displacement. [param out_points] accumulates every point
## from just after [param a] through [param b] inclusive — the caller seeds it
## with [code][a][/code] first, so the finished array is the whole polyline in
## order.
func _displace(a: Vector3, b: Vector3, depth: int, amplitude: float,
		out_points: PackedVector3Array) -> void:
	if depth <= 0 or amplitude < 0.001:
		out_points.append(b)
		return
	var dir := b - a
	var length := dir.length()
	if length < 0.001:
		out_points.append(b)
		return
	dir /= length
	var reference := Vector3.UP if absf(dir.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	var perp1 := dir.cross(reference).normalized()
	var perp2 := dir.cross(perp1).normalized()
	var angle := _rng.randf() * TAU
	var kick := (perp1 * cos(angle) + perp2 * sin(angle)) * amplitude * _rng.randf_range(0.6, 1.0)
	var mid := (a + b) * 0.5 + kick
	_displace(a, mid, depth - 1, amplitude * 0.5, out_points)
	_displace(mid, b, depth - 1, amplitude * 0.5, out_points)


## Instances one box per consecutive pair in [param points], starting at
## cumulative length [param start_length]. Returns the cumulative length after
## the last segment, so the main path and each fork can be built the same way.
func _add_segments(points: PackedVector3Array, start_length: float) -> float:
	var cumulative := start_length
	for i in points.size() - 1:
		var p0: Vector3 = points[i]
		var p1: Vector3 = points[i + 1]
		var dir := p1 - p0
		var seg_len := dir.length()
		if seg_len < 0.001:
			continue
		dir /= seg_len
		var reference := Vector3.UP if absf(dir.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
		var box := BoxMesh.new()
		box.size = Vector3(thickness, thickness, seg_len)
		var seg := MeshInstance3D.new()
		seg.mesh = box
		seg.material_override = _material
		seg.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		seg.visible = false
		seg.transform = Transform3D(Basis.looking_at(dir, reference), (p0 + p1) * 0.5 - _from)
		add_child(seg)
		_segments.append(seg)
		_segment_start_lengths.append(cumulative)
		cumulative += seg_len
	return cumulative


## A few short jagged stubs branching off interior points of the main path,
## each revealed at the moment the main bolt reaches where it sprouts from —
## so a fork never appears before the strike has visibly gotten there.
##
## BIASED FORWARD, TOWARD THE TARGET, not purely sideways. A stub built from a
## perpendicular kick alone starts by heading exactly 90 degrees off the main
## path, which reads as a second bolt firing off toward nowhere rather than as
## a fork of the first — real forking lightning peels away at a shallow angle
## while still, on the whole, advancing. [constant FORK_FORWARD_BIAS] is the
## mix between "keep heading toward the target" and "peel sideways".
func _build_forks(main_points: PackedVector3Array, straight_length: float) -> void:
	var stub_length := straight_length * fork_length_fraction
	for _i in fork_count:
		var index := _rng.randi_range(1, main_points.size() - 2)
		var origin: Vector3 = main_points[index]
		var reveal_at := _length_up_to(main_points, index)
		var direction := (main_points[index + 1] - main_points[maxi(index - 1, 0)])
		if direction.length_squared() < 0.001:
			direction = Vector3.FORWARD
		direction = direction.normalized()
		var reference := Vector3.UP if absf(direction.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
		var perp := direction.cross(reference).normalized()
		var swing := perp.rotated(direction, _rng.randf() * TAU)
		var mix := direction * FORK_FORWARD_BIAS + swing * (1.0 - FORK_FORWARD_BIAS)
		var end := origin + mix * stub_length * _rng.randf_range(0.8, 1.1)
		var stub_points: PackedVector3Array = [origin]
		_displace(origin, end, 2, stub_length * 0.2, stub_points)
		_add_segments(stub_points, reveal_at)


func _length_up_to(points: PackedVector3Array, index: int) -> float:
	var total := 0.0
	for i in index:
		total += points[i].distance_to(points[i + 1])
	return total
