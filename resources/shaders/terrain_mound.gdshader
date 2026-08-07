shader_type spatial;
render_mode cull_back, diffuse_burley;

// Stand-in terrain material for the procedural mound.
//
// Deliberately shares the ground plane's world-space checker so the two read
// as the same surface at the same scale — a mound with its own unrelated
// material looks like an object sitting on the ground rather than part of it.
// On top of that, steep faces fade to rock, which is what actually makes the
// shape read as a hill rather than a green blob: the eye picks up the
// steepness from the colour change long before it picks it up from shading.

uniform vec4 color_a : source_color = vec4(0.30, 0.44, 0.22, 1.0);
uniform vec4 color_b : source_color = vec4(0.26, 0.39, 0.19, 1.0);
uniform vec4 line_color : source_color = vec4(0.19, 0.29, 0.14, 1.0);
uniform vec4 rock_color : source_color = vec4(0.40, 0.38, 0.35, 1.0);
uniform vec4 rock_shadow : source_color = vec4(0.26, 0.25, 0.23, 1.0);
uniform float cell_size = 2.0;
uniform float line_strength : hint_range(0.0, 1.0) = 0.40;
// Surface normal Y between these two turns from rock to grass. Below
// rock_start it is bare stone; above rock_end, full grass.
uniform float rock_start : hint_range(0.0, 1.0) = 0.62;
uniform float rock_end : hint_range(0.0, 1.0) = 0.86;
uniform float surface_roughness : hint_range(0.0, 1.0) = 0.95;

varying vec3 world_pos;
varying vec3 world_normal;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

float hash21(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

void fragment() {
	vec2 cell = floor(world_pos.xz / cell_size);
	float checker = mod(cell.x + cell.y, 2.0);
	vec3 grass = mix(color_a.rgb, color_b.rgb, checker);

	vec2 f = abs(fract(world_pos.xz / cell_size) - 0.5);
	float line = smoothstep(0.46, 0.5, max(f.x, f.y));
	grass = mix(grass, line_color.rgb, line * line_strength);

	// Break the rock up so a large steep face is not one flat tone. Keyed off
	// world height as well as position so bands read as strata.
	float grain = hash21(floor(vec2(world_pos.x + world_pos.z, world_pos.y) * 1.7));
	vec3 rock = mix(rock_shadow.rgb, rock_color.rgb, 0.45 + grain * 0.55);

	float steep = 1.0 - smoothstep(rock_start, rock_end, world_normal.y);
	ALBEDO = mix(grass, rock, steep);
	ROUGHNESS = surface_roughness;
	SPECULAR = 0.1;
}
