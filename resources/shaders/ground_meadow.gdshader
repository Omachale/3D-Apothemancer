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
// Three octaves, each doing a different job:
//   macro    slow, large blotches — the patchy tonal drift real turf has
//   micro    fine grain on top — stops large-scale flatness within a blotch
//   speckle  small bright/dark flecks — the last bit of "not a flat colour"

uniform vec4 color_a : source_color = vec4(0.30, 0.44, 0.22, 1.0);
uniform vec4 color_b : source_color = vec4(0.26, 0.39, 0.19, 1.0);
uniform vec4 color_shadow : source_color = vec4(0.20, 0.30, 0.14, 1.0);
uniform vec4 side_color : source_color = vec4(0.34, 0.28, 0.20, 1.0);

uniform float macro_scale = 0.045;
uniform float micro_scale = 0.55;
uniform float micro_strength : hint_range(0.0, 1.0) = 0.18;
uniform float detail_scale = 2.0;
uniform float detail_strength : hint_range(0.0, 1.0) = 0.12;
uniform float speckle_scale = 3.2;
uniform float speckle_strength : hint_range(0.0, 1.0) = 0.10;
uniform float depth_strength : hint_range(0.0, 1.0) = 0.08;
uniform float surface_roughness : hint_range(0.0, 1.0) = 0.95;

varying vec3 world_pos;
varying vec3 world_normal;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

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

void fragment() {
	vec2 p = world_pos.xz;

	// Macro layer: large-scale tonal variation.
	float macro = value_noise(p * macro_scale);
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
	float height = value_noise(p * macro_scale * 0.5);
	vec3 depth_color = mix(color_shadow.rgb, color_a.rgb, height);
	base = mix(base, depth_color, depth_strength);

	// Near-vertical faces (the sides of raised plates) get a flat colour
	// instead of a smeared projection of the top-down pattern.
	float upness = smoothstep(0.35, 0.75, abs(world_normal.y));
	ALBEDO = mix(side_color.rgb, base, upness);

	ROUGHNESS = surface_roughness;
	SPECULAR = 0.1;
}
