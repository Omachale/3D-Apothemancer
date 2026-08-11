shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx, depth_draw_opaque;

// Wind-swayed rigid-mesh foliage — trees, as opposed to grass.gdshader's
// per-blade MultiMesh. This is ONE mesh with no rig, so there is no bone to
// animate; instead each vertex bends by an amount set by its own height
// above the trunk's base, root-fixed and tip-free exactly like a grass
// blade, just measured in real local metres (tree_height) instead of a
// per-blade UV.y. See the note on grass.gdshader's vertex() for the same
// idea applied to a blade.
//
// GUSTS come from wind.gd as wind_gust_0..5, exactly as they do for grass —
// not recomputed here. There is deliberately NO copy of any spawn/drift math
// in this file: an earlier version duplicated grass's gust_lane() wholesale,
// which is precisely the "two copies that drift apart" problem wind.gd exists
// to prevent. Both shaders now sum the same published numbers, so a gust
// reaches a tree at the same instant it reaches the grass around its trunk.
//
// Only the swaying canopy needs texture + cutout handling done by hand here
// (StandardMaterial3D cannot run a custom vertex function) — ALBEDO, ALPHA
// and the normal map are sampled directly rather than left to fixed-function
// material properties.

// Shared with every other swaying thing in the world. See wind.gd.
global uniform vec2 wind_direction;
global uniform float wind_strength;
global uniform float wind_turbulence;
global uniform float rain_sway_boost;
global uniform vec4 wind_gust_0;
global uniform vec4 wind_gust_1;
global uniform vec4 wind_gust_2;
global uniform vec4 wind_gust_3;
global uniform vec4 wind_gust_4;
global uniform vec4 wind_gust_5;

group_uniforms textures;
uniform sampler2D albedo_texture : source_color;
uniform sampler2D normal_texture : hint_normal;

group_uniforms motion;
/// How far the treetop travels at the peak of a gust, in metres. Much
/// smaller than grass's sway_distance reads on screen because a tree's mass
/// is far greater — the same force bends a blade over further than it bends
/// a canopy.
uniform float sway_distance : hint_range(0.0, 2.0) = 0.525;
/// Local-space height, in metres, at which lean reaches full strength.
/// Roughly the tree's own height so the very top gets the full bend and the
/// trunk base gets almost none.
uniform float tree_height : hint_range(0.5, 30.0) = 4.2;
/// Same meaning as grass's bend_curve: above 1 the bend concentrates toward
/// the canopy; below 1 the whole tree leans more uniformly.
uniform float bend_curve : hint_range(0.5, 4.0) = 1.6;
/// Small, always-present flutter — far subtler than grass's idle layer,
/// since a tree's canopy resists jittering the way a single blade doesn't.
uniform float idle_distance : hint_range(0.0, 0.05) = 0.006;
uniform float idle_speed : hint_range(0.0, 10.0) = 2.0;

group_uniforms shading;
uniform float alpha_scissor_threshold : hint_range(0.0, 1.0) = 0.5;
/// Blends the normal toward straight up, same purpose as grass's
/// normal_softening but far gentler — a tree's own geometric normals already
/// read fine, this just takes the hardest edges off.
uniform float normal_softening : hint_range(0.0, 1.0) = 0.15;

varying vec2 v_uv;

/// Scatters the idle-flutter phase by world position, so two trees standing
/// near each other don't breathe in lockstep. This is the ONLY hashing left in
/// this shader — gust randomness is wind.gd's job now.
float phase_hash(float a, float b) {
	return fract(sin(a * 12.9898 + b * 78.233) * 43758.5453);
}

/// One published gust's contribution at world-space [param xz] — identical to
/// grass.gdshader's, and deliberately trivial: all the interesting behaviour
/// lives in wind.gd now.
float gust_at(vec2 xz, vec4 g) {
	if (g.w <= 0.0) {
		return 0.0;
	}
	vec2 offset = xz - g.xy;
	float radius = max(g.z, 0.5);
	return exp(-dot(offset, offset) / (radius * radius)) * g.w;
}

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
/// through known points. Identical to grass.gdshader's version, so trees and grass
/// respond to the same visible, predictable patch. This is NOT part of the real gust
/// system — purely for confirming the whole chain works. Remove once satisfied.
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
	v_uv = UV;
	vec3 origin = MODEL_MATRIX[3].xyz;
	vec2 dir = normalize(wind_direction);

	// Sampled at the tree's own root rather than per-vertex position, so the
	// whole canopy leans as one rigid mass rather than rippling internally,
	// which would read as cloth instead of timber.
	float gust = gust_total(origin.xz);

	// Add the deterministic proof gust for visual testing.
	gust += proof_gust(origin.xz, dir);
	gust = min(gust, 1.4);

	// Per-tree phase from world position so neighbouring trees don't flutter
	// in lockstep — same reasoning as grass's per-blade INSTANCE_CUSTOM
	// phase, just keyed off position since this mesh has no instancing data.
	float phase = phase_hash(origin.x, origin.z) * 6.28318;
	float idle = sin(TIME * idle_speed + phase) * idle_distance;

	float force = wind_strength * gust;
	float bend_amount = force * sway_distance * rain_sway_boost + idle * wind_turbulence;

	// Root fixed, tip free — same curve as grass, against real height
	// instead of a normalised UV.
	float lean = pow(clamp(VERTEX.y / max(tree_height, 0.1), 0.0, 1.0), bend_curve);
	float bend = bend_amount * lean;

	// World-space wind direction projected onto this instance's own local
	// axes — see grass.gdshader's identical trick for why: VERTEX is in the
	// mesh's own space, and the instance may be rotated by its yaw.
	vec3 wind3 = vec3(dir.x, 0.0, dir.y);
	vec3 tree_x = normalize(MODEL_MATRIX[0].xyz);
	vec3 tree_z = normalize(MODEL_MATRIX[2].xyz);
	VERTEX.x += dot(wind3, tree_x) * bend;
	VERTEX.z += dot(wind3, tree_z) * bend;
	// A bending trunk does not stretch — see grass.gdshader for the same
	// correction, scaled down since a tree's bend is already much smaller.
	VERTEX.y -= bend * bend * 0.5;

	NORMAL = normalize(mix(NORMAL, vec3(0.0, 1.0, 0.0), normal_softening));
}

void fragment() {
	vec4 tex = texture(albedo_texture, v_uv);
	ALBEDO = tex.rgb;
	ALPHA_SCISSOR_THRESHOLD = alpha_scissor_threshold;
	ALPHA = tex.a;
	NORMAL_MAP = texture(normal_texture, v_uv).rgb;
	NORMAL_MAP_DEPTH = 1.0;
	// Double-sided geometry: without this, needle cards facing away from a
	// light are lit as though they faced it. Same fix as grass.gdshader.
	NORMAL = FRONT_FACING ? NORMAL : -NORMAL;
}
