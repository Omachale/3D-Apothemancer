shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx, depth_draw_opaque;

// Wind-swayed grass, drawn as real instanced blade geometry.
//
// WHY GEOMETRY AND NOT A TEXTURE. A blade has to bend from a fixed root to a
// free tip. That is a *shape* change, so there have to be vertices at
// different heights to move by different amounts — no amount of texture work
// on a flat ground plane can do it. Each blade is a handful of triangles and
// every blade in a field is one MultiMesh draw call, so the cost is in the
// instance count, not here.
//
// THE WIND IS TWO LAYERS — an always-on idle jitter, and separate GUSTS — not
// one continuous wave. See the note at the top of wind.gd for why: a single
// continuous sine reads as constant random wriggling, because nothing is ever
// still to contrast it against.
//
// GUSTS ARE LOCAL PATCHES, not a band spanning the whole world. Each gust is a
// small 2D Gaussian — soft-edged, no hard boundary to pop at — whose centre
// spawns at a random point and drifts across at a constant world-space speed
// for a limited lifetime, then fades and disappears. A patch of grass visibly
// leans as the centre approaches, straightens as it leaves, and the effect
// never touches ground outside its own radius. Several lanes run with
// independent random spawn points and timings, so different parts of a field
// gust at different times instead of the whole screen moving together. This
// also eases in/out over time (not just space), so a gust spawning already
// close to a blade doesn't pop into existence at full strength.
//
// The blade mesh carries its own normalised height in UV.y: 0 at the root,
// 1 at the tip. Reading that instead of dividing VERTEX.y by a "blade height"
// uniform means the mesh and the shader cannot drift out of step when the
// blade dimensions are changed.
//
// Per-blade variation comes in through INSTANCE_CUSTOM, written by
// grass_field.gd when the MultiMesh is filled:
//   r  phase offset, so neighbouring blades are not in lockstep
//   g  stiffness, so some blades resist the wind more than others
//   b  colour variation
//   a  unused

// Shared with every other swaying thing in the world. See wind.gd.
global uniform vec2 wind_direction;
global uniform float wind_strength;
/// World units per second a gust's centre drifts. Genuinely used now — it was
/// a dead parameter in an earlier version of this shader (see wind.gd notes).
global uniform float wind_speed;
/// Radius, in world units, of a single gust patch. This used to be the
/// half-width of a full-screen band; now it is the actual size of the patch,
/// so smaller values read as tighter local gusts.
global uniform float wind_gust_width;
/// Average seconds between spawns on each lane. Actual spacing is randomised
/// around this per spawn, so lanes do not fall into a visible metronome.
global uniform float wind_gust_period;
global uniform float wind_turbulence;

group_uniforms colour;
uniform vec4 root_color : source_color = vec4(0.13, 0.22, 0.09, 1.0);
uniform vec4 tip_color : source_color = vec4(0.47, 0.66, 0.28, 1.0);
/// How much blades differ from one another in tone.
uniform float colour_variation : hint_range(0.0, 1.0) = 0.35;
/// Darkening down at the root, which is what stops a field reading as a flat
/// green carpet — real grass is in shadow from itself near the ground.
uniform float root_occlusion : hint_range(0.0, 1.0) = 0.75;

group_uniforms motion;
/// How far the tip travels at the peak of a gust, in metres.
uniform float sway_distance : hint_range(0.0, 2.0) = 0.30;
/// Above 1 the bend concentrates toward the tip, which reads as a stiff stalk
/// hinging near the top; below 1 it bends low down like a soft leaf. Around
/// 1.6 gives the arc real grass has.
uniform float bend_curve : hint_range(0.5, 4.0) = 1.6;
/// Half-size of the square region, centred on the origin, that gust spawn
/// points are drawn from. Needs to comfortably cover every grass field in the
/// zone so a gust can spawn near any of them.
uniform float wind_travel_range = 140.0;
/// Seconds a single gust patch lives for, from spawn to fully faded. Together
/// with wind_speed this sets how far a patch travels before it disappears
/// (distance = wind_speed * this).
uniform float gust_lifetime : hint_range(1.0, 60.0) = 18.0;
/// Fast, small, ALWAYS-PRESENT flutter — the idle layer, distinct from a gust
/// passing through. This is the "slight random sway" that should read as
/// grass being alive, not as weather.
uniform float idle_distance : hint_range(0.0, 0.15) = 0.028;
uniform float idle_speed : hint_range(0.0, 30.0) = 6.0;

group_uniforms shading;
/// Blends each blade's own normal toward straight up. Grass lit strictly by
/// its own flat faces looks harsh and noisy; leaning the normals skyward makes
/// a field read as a soft surface while keeping some blade definition.
uniform float normal_softening : hint_range(0.0, 1.0) = 0.6;
uniform float surface_roughness : hint_range(0.0, 1.0) = 0.88;

group_uniforms culling;
/// Blades shrink to nothing between these distances, rather than popping out.
uniform float fade_start = 40.0;
uniform float fade_end = 62.0;

varying float v_height;
varying float v_tint;
// Gust strength at this blade, carried to the fragment shader so it can
// darken slightly under wind — see fragment().
varying float v_gust;

/// Hash function for pseudo-random values. Two inputs so a lane and a cycle
/// index together produce an uncorrelated stream, rather than two lanes on
/// the same cycle index landing on the same "random" number.
float hash(float a, float b) {
	return fract(sin(a * 12.9898 + b * 78.233) * 43758.5453);
}

/// One gust lane's contribution at world-space [param xz]. [param lane_seed]
/// separates lanes so each spawns at its own points and times; [param dir]
/// and [param perp] are the (normalized) wind direction and its perpendicular,
/// passed in rather than recomputed per lane.
///
/// A lane is a repeating cycle of (random wait) -> (gust alive for
/// gust_lifetime, drifting along dir at wind_speed) -> back to a new random
/// wait. Spawn position is randomised within a square of side
/// 2 * wind_travel_range, offset upwind so the whole drift happens near that
/// square rather than starting already deep inside it.
float gust_lane(vec2 xz, vec2 dir, vec2 perp, float lane_seed) {
	float lifetime = max(gust_lifetime, 0.5);
	float wait_min = max(wind_gust_period * 0.6, 0.1);
	float wait_max = max(wind_gust_period * 1.4, wait_min + 0.1);

	// Fixed-length cycle (lifetime + the longest possible wait) so mod/floor
	// stays exact; the gap between an actual (shorter) wait and wait_max is
	// simply dead time at the end of that cycle with no gust active.
	float cycle_length = lifetime + wait_max;
	float local_time = TIME + lane_seed * 4096.0;
	float cycle_time = mod(local_time, cycle_length);
	float cycle_index = floor(local_time / cycle_length);

	float wait = mix(wait_min, wait_max, hash(cycle_index, lane_seed));
	if (cycle_time < wait || cycle_time > wait + lifetime) {
		return 0.0;
	}
	float t = cycle_time - wait; // Seconds since this gust spawned.

	float travel_dist = wind_speed * lifetime;
	float spawn_along = mix(-wind_travel_range, wind_travel_range,
			hash(cycle_index + 0.37, lane_seed)) - travel_dist * 0.5;
	float spawn_lateral = mix(-wind_travel_range, wind_travel_range,
			hash(cycle_index + 0.71, lane_seed));

	vec2 center = dir * (spawn_along + wind_speed * t) + perp * spawn_lateral;
	float radius = max(wind_gust_width, 0.5);
	float dist = length(xz - center);
	float spatial = exp(-(dist * dist) / (radius * radius));

	// Temporal ease over the first/last 20% of the lifetime, so a gust that
	// happens to spawn or despawn close to a blade fades rather than pops.
	float fade_time = lifetime * 0.2;
	float temporal = clamp(min(t, lifetime - t) / max(fade_time, 0.01), 0.0, 1.0);

	return spatial * temporal;
}

/// TEMPORARY PROOF-OF-CONCEPT GUST. No randomness, loops continuously: a
/// patch drifts through the player's spawn point along [param dir] — the SAME
/// vector the blade-bend code uses, passed in rather than recomputed, so the
/// patch's travel direction and the direction blades lean can never diverge.
/// (An earlier version defined its own "screen right" copy of this vector and
/// moved against it instead of with it — patch and lean pointed opposite
/// ways. One source of truth for the wind axis fixes that structurally.)
/// Remove once the real gust system is confirmed and being tuned instead.
float proof_gust(vec2 xz, vec2 dir) {
	vec2 target = vec2(10.0, 22.0); // Player's spawn point, zone.gd.
	float screen_width = 40.0; // See README: "camera sees ~40 units of ground".
	vec2 start_pos = target - dir * screen_width; // Upwind of the target.
	float proof_speed = 10.5;
	float radius = 5.0;
	float lifetime = (screen_width * 2.0) / proof_speed;
	float t = mod(TIME, lifetime);
	vec2 center = start_pos + dir * proof_speed * t; // Drifts downwind, same as the bend.
	float dist = length(xz - center);
	return exp(-(dist * dist) / (radius * radius));
}

void vertex() {
	v_height = UV.y;
	v_tint = 1.0 + (INSTANCE_CUSTOM.b - 0.5) * colour_variation;
	v_gust = 0.0;
	vec3 origin = MODEL_MATRIX[3].xyz;

	// Shrink distant blades away instead of drawing thousands of sub-pixel
	// slivers, which is both wasteful and where grass shimmering comes from.
	float dist = distance(origin, CAMERA_POSITION_WORLD);
	float visible = 1.0 - smoothstep(fade_start, fade_end, dist);
	if (visible <= 0.001) {
		VERTEX = vec3(0.0);
	} else {
		vec2 dir = normalize(wind_direction);
		float phase = INSTANCE_CUSTOM.r * 6.28318;
		// Stiffer blades bend less and flutter less.
		float give = mix(0.6, 1.0, INSTANCE_CUSTOM.g);

		vec2 perp = vec2(-dir.y, dir.x);
		// Four independent local gust patches. Capped so an overlap of
		// several cannot bend a blade absurdly far.
		float gust = gust_lane(origin.xz, dir, perp, 0.11)
				+ gust_lane(origin.xz, dir, perp, 0.53)
				+ gust_lane(origin.xz, dir, perp, 0.79)
				+ gust_lane(origin.xz, dir, perp, 0.97)
				+ proof_gust(origin.xz, dir);
		gust = min(gust, 1.4);
		v_gust = clamp(gust, 0.0, 1.0);

		// Per-blade only — no world-position term. An earlier version added
		// `along * 0.9` here, which made "idle" a second travelling ripple
		// coherent across the whole field instead of independent flutter,
		// and was a real source of the field never reading as calm.
		float idle = sin(TIME * idle_speed + phase * 2.7) * idle_distance * give;

		float force = wind_strength * gust * give;
		float bend_amount = force * sway_distance + idle * wind_turbulence;

		// Root fixed, tip free. Everything about the bend lives in this curve.
		float lean = pow(v_height, bend_curve);
		float bend = bend_amount * lean;

		// The wind arrives in world space but VERTEX is in the blade's own
		// space, and every blade is planted at a random angle. Projecting the
		// direction onto the instance's own axes converts it without the
		// per-vertex matrix inverse the obvious approach would need.
		vec3 wind3 = vec3(dir.x, 0.0, dir.y);
		vec3 blade_x = normalize(MODEL_MATRIX[0].xyz);
		vec3 blade_z = normalize(MODEL_MATRIX[2].xyz);
		VERTEX.x += dot(wind3, blade_x) * bend;
		VERTEX.z += dot(wind3, blade_z) * bend;
		// A bending blade does not stretch: as the tip swings out it must also
		// come down. Without this the grass visibly grows during a gust.
		VERTEX.y -= bend * bend * 0.9;

		VERTEX *= visible;

		NORMAL = normalize(mix(NORMAL, vec3(0.0, 1.0, 0.0), normal_softening));
	}
}

void fragment() {
	vec3 colour = mix(root_color.rgb, tip_color.rgb, v_height) * v_tint;
	// Grass darkens slightly as a gust bends it, the way real grass turns to
	// show more shaded blade and less sunlit face when wind flattens it.
	// Doubles as a readable "wind is here" cue without being a debug colour.
	colour *= mix(1.0, 0.6, v_gust);

	ALBEDO = colour;
	ROUGHNESS = surface_roughness;
	SPECULAR = 0.2;
	// Self-shadowing near the ground, faked. Cheaper and steadier than asking
	// the shadow map to resolve gaps between individual blades.
	AO = mix(1.0 - root_occlusion, 1.0, v_height);
	AO_LIGHT_AFFECT = 1.0;
	// Double-sided geometry: without this, blades facing away from a light are
	// lit as though they were facing it.
	NORMAL = FRONT_FACING ? NORMAL : -NORMAL;
}
