shader_type spatial;
render_mode cull_back, diffuse_burley;

// Ground material. World-space, no texture — same convention as every other
// material in the project — but mottled noise instead of a grid checker.
//
// Replaces ground_checker.gdshader, which was a literal checkerboard: fine for
// reading scale and slope early on, but it tiles visibly and reads as floor
// tiles rather than terrain, especially now grass sits on top of it and the
// bare ground shows through at patch edges. Noise has no repeating unit for
// the eye to lock onto, which is the actual fix — not just "softer colours".
//
// TWO THINGS MAKE THIS LOOK MORE DETAILED THAN A SINGLE NOISE LOOKUP CAN:
//
// 1. FBM ON THE MACRO LAYER. One value_noise() call is a single smooth
//    gradient — round blotches, all the same "softness". Stacking a few
//    octaves at doubling frequency and halving amplitude (see [method fbm])
//    gives blotches WITHIN blotches, which is what reads as organic rather
//    than as "one noise texture, stretched". This costs a few extra hash
//    calls, not a different technique — same value_noise underneath.
//
// 2. THE SAME NOISE FIELD ALSO PERTURBS THE SHADING NORMAL, not just the
//    colour. Colour-only variation is flat under raking light — it looks
//    painted on because nothing about the surface actually reacts to the sun
//    moving. Sampling the field a short distance either side of each point
//    (the same finite-difference trick Heightfield.normal_at uses to turn a
//    height function into a slope) gives a cheap "which way is this patch
//    leaning" and tilts NORMAL by it. Two extra noise calls, and light starts
//    catching the ground unevenly the way real turf does.
//
// Layer breakdown:
//   macro    fbm, slow and large — the patchy tonal drift real turf has
//   micro    fine grain on top — stops large-scale flatness within a blotch
//   detail   higher frequency still — a middle step between micro and speckle
//   speckle  small bright/dark flecks — the last bit of "not a flat colour"
//   bump     same field, read as slope instead of colour — see note 2 above

uniform vec4 color_a : source_color = vec4(0.30, 0.44, 0.22, 1.0);
uniform vec4 color_b : source_color = vec4(0.26, 0.39, 0.19, 1.0);
uniform vec4 color_shadow : source_color = vec4(0.20, 0.30, 0.14, 1.0);
uniform vec4 side_color : source_color = vec4(0.34, 0.28, 0.20, 1.0);

uniform float macro_scale = 0.045;
/// Octaves stacked into the macro layer's fbm — see the note at the top.
/// Kept small deliberately: this runs per fragment, and the visible gain past
/// 3-4 octaves at typical viewing distance is negligible.
uniform int macro_octaves : hint_range(1, 4) = 3;
uniform float micro_scale = 0.55;
uniform float micro_strength : hint_range(0.0, 1.0) = 0.18;
uniform float detail_scale = 2.0;
uniform float detail_strength : hint_range(0.0, 1.0) = 0.12;
uniform float speckle_scale = 3.2;
uniform float speckle_strength : hint_range(0.0, 1.0) = 0.10;
uniform float depth_strength : hint_range(0.0, 1.0) = 0.08;
uniform float surface_roughness : hint_range(0.0, 1.0) = 0.95;

/// How strongly the noise field perturbs the surface NORMAL rather than only
/// its colour — see note 2 at the top for why this is the bigger of the two
/// changes here. 0 disables it (colour-only, the original behaviour).
uniform float bump_strength : hint_range(0.0, 1.0) = 0.35;
/// Frequency of the noise field used for bumping. Independent of macro_scale
/// so the surface's fine "roughness" and its broad colour blotches can be
/// tuned separately — a wide colour blotch does not imply a wide bump.
uniform float bump_scale = 0.9;

varying vec3 world_pos;
varying vec3 world_normal;

// Value noise. Cheap, and at this scale — under grass, seen from an isometric
// camera — nothing fancier than bilinear-interpolated hash noise is visible.
float hash21(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

/// [param octaves] layers of value_noise, each at double the previous
/// frequency and half the previous amplitude — see note 1 at the top for why
/// this reads as texture where a single value_noise() call reads as one
/// smooth gradient.
float fbm(vec2 p, int octaves) {
	float value = 0.0;
	float amplitude = 0.5;
	for (int i = 0; i < octaves; i++) {
		value += value_noise(p) * amplitude;
		p *= 2.0;
		amplitude *= 0.5;
	}
	return value;
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec2 p = world_pos.xz;

	// Macro layer: fbm instead of one octave, so tonal variation has real
	// structure — clumps within clumps — rather than one smooth gradient.
	float macro = fbm(p * macro_scale, macro_octaves);
	vec3 base = mix(color_b.rgb, color_a.rgb, macro);

	// Micro layer: fine grain.
	float micro = value_noise(p * micro_scale) - 0.5;
	base += micro * micro_strength * (color_a.rgb - color_b.rgb);

	// Detail layer: higher-frequency variation for texture.
	float detail = value_noise(p * detail_scale) - 0.5;
	base *= 1.0 + detail * detail_strength;

	// Speckle layer: tiny bright/dark flecks.
	float speckle = value_noise(p * speckle_scale + 91.7) - 0.5;
	base *= 1.0 + speckle * speckle_strength;

	// Pseudo-depth: modulate color based on a low-frequency "height" map.
	// Slightly darker in "valleys", lighter on "peaks" for visual depth.
	float height = fbm(p * macro_scale * 0.5, macro_octaves);
	vec3 depth_color = mix(color_shadow.rgb, color_a.rgb, height);
	base = mix(base, depth_color, depth_strength);

	// Near-vertical faces (the sides of raised plates) get a flat colour
	// instead of a smeared projection of the top-down pattern.
	float upness = smoothstep(0.35, 0.75, abs(world_normal.y));
	ALBEDO = mix(side_color.rgb, base, upness);

	// Bump: lean the shading normal toward whichever side of each point reads
	// darker in the same noise field, using the same short-offset
	// finite-difference approach Heightfield.normal_at uses to turn a height
	// function into a slope. Only applied on top faces (upness) — a vertical
	// side face has no "which way is this leaning" to speak of.
	float e = 0.35;
	float h_dx = fbm((p + vec2(e, 0.0)) * bump_scale, 2) - fbm((p - vec2(e, 0.0)) * bump_scale, 2);
	float h_dz = fbm((p + vec2(0.0, e)) * bump_scale, 2) - fbm((p - vec2(0.0, e)) * bump_scale, 2);
	vec3 bumped_world_normal = normalize(world_normal - vec3(h_dx, 0.0, h_dz) * bump_strength);
	vec3 shading_normal_world = mix(world_normal, bumped_world_normal, upness);
	NORMAL = normalize((VIEW_MATRIX * vec4(shading_normal_world, 0.0)).xyz);

	ROUGHNESS = surface_roughness;
	SPECULAR = 0.1;
}
