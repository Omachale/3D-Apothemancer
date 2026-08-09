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
//   turf     finer still — stands in for GrassField's blade geometry once it
//            has stopped rendering, see note 3 below
//   bump     same field, read as slope instead of colour — see note 2 above
//
// 3. THE TURF LAYER IS WHAT "THERE IS GRASS HERE" LOOKS LIKE WITHOUT BLADES.
//    grass_manager.gd only builds actual blade MultiMeshes within a radius of
//    the camera — past it, this material IS the ground's entire appearance,
//    and a grass blade is a sliver a few centimetres wide: at any real
//    distance it is already thinner than a pixel, so there is no resolution
//    of blade geometry that fixes it, only aliasing that flickers as the
//    camera moves. The fix is not to keep trying to draw blades, it is to
//    stop and let a material carry the impression instead. turf is exactly
//    that: a finer noise layer than speckle, faded by fwidth() (see [method
//    fragment]) so it does not just relocate the same sub-pixel aliasing
//    problem into the shader.

uniform vec4 color_a : source_color = vec4(0.30, 0.68, 0.22, 1.0);
uniform vec4 color_b : source_color = vec4(0.26, 0.60, 0.19, 1.0);
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
/// Stands in for individual blades once GrassField stops rendering them —
/// see note 3 at the top. Deliberately much finer than speckle_scale: this is
/// meant to read as "grass too far away to resolve as blades", not as another
/// colour blotch.
uniform float turf_scale = 9.0;
uniform float turf_strength : hint_range(0.0, 1.0) = 0.75;
/// Below this many noise cells per pixel (measured by fwidth, see [method
/// fragment]), the turf layer fades itself out rather than aliasing. Higher
/// means it gives up sooner — safer against flicker, but shortens how close
/// the shader-only look extends before real blade geometry needs to take
/// over. Lower risks visible shimmer on distant, fast-moving footage.
uniform float turf_fade_start : hint_range(0.1, 3.0) = 0.5;
uniform float turf_fade_end : hint_range(0.1, 4.0) = 2.0;
/// How much the turf layer perturbs the surface normal to make blades look
/// raised. Higher values make the micro-blade height more pronounced.
uniform float turf_bump_strength : hint_range(0.0, 1.0) = 0.5;
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

	// Turf layer: see note 3 at the top. fwidth(p * turf_scale) is how many
	// noise cells one pixel currently spans — small close up (many pixels per
	// cell, plenty of resolution), large far away (many cells per pixel,
	// headed for aliasing). turf_fade rides that measurement down to 0 BEFORE
	// the layer would start flickering, the same finite-difference spirit as
	// the bump below but measuring screen-space rate of change instead of
	// world-space slope.
	//
	// To look like raised grass blades rather than flat color, the turf layer
	// also perturbs the shading normal at a finer scale than the main bump —
	// this makes light catch the micro-texture as if blades are actually
	// standing up. Applied only on top faces (upness) like the macro bump.
	vec2 turf_p = p * turf_scale;
	float turf_cells_per_px = fwidth(turf_p.x) + fwidth(turf_p.y);
	float turf_fade = 1.0 - smoothstep(turf_fade_start, turf_fade_end, turf_cells_per_px);
	float turf = value_noise(turf_p + 37.1) - 0.5;
	// Directional component: grass leans — use different frequencies in X vs Z
	// to create elongated streaks that read as blade direction.
	float turf_x = value_noise(turf_p * vec2(2.0, 0.5) + 41.3) - 0.5;
	float turf_z = value_noise(turf_p * vec2(0.5, 2.0) + 43.7) - 0.5;
	turf = turf * 0.6 + (turf_x * 0.25 + turf_z * 0.15);

	// Blade color: bright tips, dark base (ambient occlusion in crevices).
	// Where turf is positive (blade tips), brighten; negative (crevices), darken.
	vec3 turf_color = mix(color_shadow.rgb, color_a.rgb, turf + 0.5);
	base += turf_color * turf_strength * turf_fade;

	// Directional variance: enhance specularity along blade direction using view-aligned
	// anisotropy. Where blades lean toward the camera view, they brighten slightly,
	// creating a glitter effect that reads as actual blade structure.
	float blade_aniso = abs(turf_x) + abs(turf_z);
	float aniso_spec = pow(blade_aniso * 0.5 + 0.5, 3.0) * turf_fade;
	base += aniso_spec * turf_strength * 0.2 * vec3(1.0);

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
	//
	// Apply bump at two scales: macro (bump_scale) and micro (turf_scale) for
	// the grass-blade appearance. The macro bump makes broad patches look uneven;
	// the micro bump makes individual grass blades cast tiny shadows as if
	// they are standing up off the ground.
	float e = 0.35;
	float h_dx = fbm((p + vec2(e, 0.0)) * bump_scale, 2) - fbm((p - vec2(e, 0.0)) * bump_scale, 2);
	float h_dz = fbm((p + vec2(0.0, e)) * bump_scale, 2) - fbm((p - vec2(0.0, e)) * bump_scale, 2);
	vec3 bumped_world_normal = normalize(world_normal - vec3(h_dx, 0.0, h_dz) * bump_strength);
	// Micro-bump for turf: finer scale, so it reads as grass-blade height
	// variation rather than terrain unevenness. Faded the same way the turf
	// color is, so it vanishes with the layer.
	float e_turf = 0.15;
	float h_turf_dx = value_noise((p + vec2(e_turf, 0.0)) * turf_scale) - value_noise((p - vec2(e_turf, 0.0)) * turf_scale);
	float h_turf_dz = value_noise((p + vec2(0.0, e_turf)) * turf_scale) - value_noise((p - vec2(0.0, e_turf)) * turf_scale);
	vec3 turf_bump = normalize(world_normal - vec3(h_turf_dx, 0.0, h_turf_dz) * turf_bump_strength * turf_fade);
	vec3 final_bump = normalize(bumped_world_normal + (turf_bump - world_normal) * turf_fade);
	vec3 shading_normal_world = mix(world_normal, final_bump, upness);
	NORMAL = normalize((VIEW_MATRIX * vec4(shading_normal_world, 0.0)).xyz);

	ROUGHNESS = surface_roughness;
	SPECULAR = 0.1;
}
