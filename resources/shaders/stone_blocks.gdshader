shader_type spatial;
render_mode cull_back, diffuse_burley;

// Stand-in masonry. Blocks are laid out in *world* space, so separate boxes
// that meet at a corner keep their courses lined up and nothing needs UV
// mapping — which is what makes a building buildable from plain BoxMeshes.
//
// The pattern orientation is picked from the surface normal: near-horizontal
// faces get square flagstones, vertical faces get running-bond wall courses
// laid out in (horizontal, height). Two materials share this shader and differ
// only in colour and block size.

uniform vec4 block_color : source_color = vec4(0.60, 0.58, 0.53, 1.0);
uniform vec4 mortar_color : source_color = vec4(0.36, 0.35, 0.33, 1.0);
// Height of one course and length of one block, in metres.
uniform float course_height = 0.55;
uniform float block_length = 1.10;
// Flagstones are square, so one number does for floors.
uniform float floor_stone = 1.60;
uniform float mortar_width = 0.055;
// How much neighbouring blocks differ in brightness. Without this the wall
// reads as wallpaper rather than as separate stones.
uniform float variation : hint_range(0.0, 1.0) = 0.18;
uniform float surface_roughness : hint_range(0.0, 1.0) = 0.92;

// World height above which this piece is cut away. Set per node by
// building.gd, which drives it from the player's head height so that a
// building opens up continuously as they climb rather than a storey at a
// time. Left effectively infinite means "do not clip".
instance uniform float clip_height = 100000.0;

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
	// A hard discard rather than an alpha fade: transparency here would mean
	// overlapping walls, floors and stair treads sorting against each other,
	// which goes wrong exactly in the stairwells this is meant to reveal.
	if (world_pos.y > clip_height) {
		discard;
	}

	vec3 n = abs(world_normal);
	vec2 uv;
	vec2 cell;
	if (n.y > max(n.x, n.z)) {
		uv = world_pos.xz;
		cell = vec2(floor_stone, floor_stone);
	} else if (n.x > n.z) {
		// Wall facing along X, so it runs along Z.
		uv = vec2(world_pos.z, world_pos.y);
		cell = vec2(block_length, course_height);
	} else {
		uv = vec2(world_pos.x, world_pos.y);
		cell = vec2(block_length, course_height);
	}

	float row = floor(uv.y / cell.y);
	// Offset alternate courses by half a block so the joints stagger.
	float along = uv.x / cell.x + mod(row, 2.0) * 0.5;
	float col = floor(along);

	vec2 f = vec2(fract(along), fract(uv.y / cell.y));
	vec2 m = vec2(mortar_width) / cell;
	vec2 edge = smoothstep(vec2(0.0), m, f) * smoothstep(vec2(0.0), m, vec2(1.0) - f);
	float joint = min(edge.x, edge.y);

	vec3 stone = block_color.rgb * (1.0 + (hash21(vec2(col, row)) - 0.5) * variation);
	ALBEDO = mix(mortar_color.rgb, stone, joint);
	ROUGHNESS = surface_roughness;
	SPECULAR = 0.12;
}
