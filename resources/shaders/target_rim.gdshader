shader_type spatial;
// ADDITIVE, so this adds light to the character instead of replacing its
// colour. That is the whole point of the change from the old flat wash: an
// alpha-blended overlay covers the texture underneath in proportion to its
// alpha, which turned a selected character into a solid orange silhouette. Add
// leaves every original pixel intact and only brightens.
//
// unshaded: the glow is emitted by the effect, not lit by the sun, so a target
// standing in shadow reads exactly as brightly as one in the open — which is
// where the player most needs to see what is selected.
//
// depth_draw_never + shadows_disabled: this is a decal on top of geometry that
// has already drawn itself. It must not write depth over the real surface, and
// it must not cast a shadow of its own.
render_mode blend_add, unshaded, depth_draw_never, shadows_disabled;

uniform vec4 rim_color : source_color = vec4(1.0, 0.62, 0.1, 1.0);
// How tightly the glow hugs the silhouette. Higher confines it to a thinner
// band right at the edge; lower spreads it across the whole surface and starts
// to look like the flat wash this replaced.
uniform float rim_power : hint_range(0.5, 8.0) = 3.4;
uniform float rim_strength : hint_range(0.0, 4.0) = 1.25;
// A faint even glow underneath the rim. Without it a broad surface turned flat
// to the camera — a shoulder, the top of a head from this game's high angle —
// has almost no rim anywhere and the target can look unselected from certain
// angles. Deliberately small: enough to say "this one", not enough to tint.
uniform float fill : hint_range(0.0, 0.5) = 0.03;

void fragment() {
	// NORMAL and VIEW are both view-space here, so their dot product is the
	// facing ratio: 1 where the surface points straight at the camera, falling
	// to 0 where it turns away at the silhouette. The rim is the inverse of
	// that, which is why this needs no mesh duplication and no knowledge of the
	// rig — it is pure per-pixel geometry and works on any mesh, skinned or
	// not, including ones added later.
	float facing = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	float rim = pow(1.0 - facing, rim_power);
	ALBEDO = rim_color.rgb * (rim * rim_strength + fill);
	ALPHA = 1.0;
}
