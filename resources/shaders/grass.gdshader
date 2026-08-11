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
// GUSTS ARE LOCAL PATCHES, not a band spanning the whole world, and THEY ARE
// NOT COMPUTED HERE. wind.gd owns them — where each one is, how big, how
// strong — and publishes them as wind_gust_0..5. This shader only sums their
// Gaussians. That split is what lets a gust spawn near the player and live
// until it has left their view (a stateless TIME-and-hash version could not
// know where the player was when a gust was born), and it means grass and
// trees are driven by literally the same numbers instead of two copies of the
// same spawn math that can drift apart.
//
// BLADE LEAN DOES NOT FOLLOW THE GUST'S OWN HEADING. Each gust travels at its
// own slight angle off wind_direction, but a blade always leans along
// wind_direction itself, however off-axis the gust bending it happens to be
// moving. Only where a patch goes varies; how grass responds to being inside
// one does not.
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
global uniform float wind_turbulence;
/// The live gusts, published by wind.gd every frame: each is
/// (centre.x, centre.z, radius, strength), and an all-zero strength means the
/// slot is empty. Gust POSITION is no longer derived here — this shader used
/// to hash TIME into a spawn point and drift it itself, which could not
/// express "spawn near the player and persist until out of view" and forced
/// every swaying material to carry a duplicate of the same spawn math. See
/// the long note at the top of wind.gd for why that moved to the CPU.
global uniform vec4 wind_gust_0;
global uniform vec4 wind_gust_1;
global uniform vec4 wind_gust_2;
global uniform vec4 wind_gust_3;
global uniform vec4 wind_gust_4;
global uniform vec4 wind_gust_5;
/// Multiplies gust-driven LEAN only (sway_distance below) — not the idle
/// flutter, which stays a "grass is alive" cue independent of weather. Grass
/// visibly bends further under a heavier downpour than raw wind_strength
/// alone would give it. Owned by rain.gd exactly the way the wind globals
/// above are owned by wind.gd: one broadcaster, so every material that reads
/// this name — grass today, trees later — rises and falls with the same
/// storm rather than each keeping its own rain coupling to drift out of sync.
global uniform float rain_sway_boost;

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
uniform float sway_distance : hint_range(0.0, 2.0) = 0.252;
/// Above 1 the bend concentrates toward the tip, which reads as a stiff stalk
/// hinging near the top; below 1 it bends low down like a soft leaf. Around
/// 1.6 gives the arc real grass has.
uniform float bend_curve : hint_range(0.5, 4.0) = 1.6;
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

/// One published gust's contribution at world-space [param xz]. A soft-edged
/// 2D Gaussian, so a patch has no hard boundary to pop at. [param g] is
/// (centre.x, centre.z, radius, strength) straight from wind.gd; an empty slot
/// carries strength 0 and costs one compare.
float gust_at(vec2 xz, vec4 g) {
	if (g.w <= 0.0) {
		return 0.0;
	}
	vec2 offset = xz - g.xy;
	float radius = max(g.z, 0.5);
	return exp(-dot(offset, offset) / (radius * radius)) * g.w;
}

/// Total gust intensity here, summed over every live gust and capped so a
/// pile-up of overlapping patches cannot bend a blade absurdly far.
/// wind.gd's gust_value_at() is the same sum in GDScript, for tests.
float gust_total(vec2 xz) {
	float total = gust_at(xz, wind_gust_0)
			+ gust_at(xz, wind_gust_1)
			+ gust_at(xz, wind_gust_2)
			+ gust_at(xz, wind_gust_3)
			+ gust_at(xz, wind_gust_4)
			+ gust_at(xz, wind_gust_5);
	return min(total, 1.4);
}

/// DETERMINISTIC PROOF GUST for visual testing — no randomness, loops continuously
/// through known points. A patch drifts past a target point along wind_direction,
/// with a fixed cycle and visible edge. This is NOT part of the real gust system —
/// it is purely here so you can point at a tree and watch a patch arrive, bend it,
/// and leave. Remove once satisfied that the whole chain works.
float proof_gust(vec2 xz, vec2 dir) {
	float screen_width = 40.0;
	vec2 origin = vec2(10.0, 22.0) - dir * screen_width; // Upwind of player spawn.
	float proof_speed = 5.25;
	float radius = 7.5; // 50% larger than before: was 5.0.
	float lifetime = (screen_width * 2.0) / proof_speed;
	float t = mod(TIME, lifetime);
	vec2 center = origin + dir * proof_speed * t;
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

		// Evaluated at the blade's own root, so a whole blade leans as one
		// rather than shearing internally.
		float gust = gust_total(origin.xz);

		// Add the deterministic proof gust for visual testing.
		gust += proof_gust(origin.xz, dir);
		gust = min(gust, 1.4);
		v_gust = clamp(gust, 0.0, 1.0);

		// Per-blade only — no world-position term. An earlier version added
		// `along * 0.9` here, which made "idle" a second travelling ripple
		// coherent across the whole field instead of independent flutter,
		// and was a real source of the field never reading as calm.
		float idle = sin(TIME * idle_speed + phase * 2.7) * idle_distance * give;

		float force = wind_strength * gust * give;
		float bend_amount = force * sway_distance * rain_sway_boost + idle * wind_turbulence;

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
	colour *= mix(1.0, 0.48, v_gust);

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
