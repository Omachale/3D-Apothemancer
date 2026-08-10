extends Control

## Debug compass: shows where world X and Z point ON SCREEN at the camera's
## current yaw. Y is the third world axis and is not drawn — it is vertical,
## straight out of the monitor at you, so there is nothing to project.
##
## Lives inside DebugHud's CanvasLayer and shares its F3 visibility toggle —
## see debug_hud.gd — rather than owning a toggle of its own.
##
## THE ROTATION IS get_ground_basis() UNDONE. camera_rig.gd rotates WASD input
## by Basis(Y, yaw) to turn it into a world direction — pressing "forward"
## moves along Basis(Y, yaw) * (0,0,-1), which is why W always means "away
## from the camera" regardless of which way the rig has spun. This draws the
## inverse: take a world axis, rotate it by -yaw, and what comes out is where
## that axis currently sits on screen. Its x becomes screen-right; its z
## becomes screen-up when negative (matching camera_rig's own convention that
## camera-forward is z = -1 in that same rotated space).

const RADIUS := 32.0
const X_COLOR := Color(0.92, 0.35, 0.32)
const Z_COLOR := Color(0.35, 0.58, 0.95)


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	if Game.camera_rig == null:
		return
	var center := size * 0.5
	var yaw := deg_to_rad(Game.camera_rig.yaw)
	# World axis (1,0,0) and (0,0,1), each rotated by -yaw — see the class doc.
	var x_dir := Vector2(cos(yaw), sin(yaw)) * RADIUS
	var z_dir := Vector2(-sin(yaw), cos(yaw)) * RADIUS

	draw_circle(center, RADIUS + 6.0, Color(0.0, 0.0, 0.0, 0.35))
	_draw_axis(center, x_dir, X_COLOR, "X+", "X-")
	_draw_axis(center, z_dir, Z_COLOR, "Z+", "Z-")
	draw_string(ThemeDB.fallback_font, center + Vector2(-30.0, RADIUS + 20.0),
		"Y ↑ vertical", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.8, 0.8, 0.8))


func _draw_axis(center: Vector2, dir: Vector2, color: Color, pos_label: String, neg_label: String) -> void:
	draw_line(center - dir, center + dir, color, 2.0)
	draw_circle(center + dir, 3.0, color)
	draw_string(ThemeDB.fallback_font, center + dir + Vector2(6.0, 4.0),
		pos_label, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, color)
	draw_string(ThemeDB.fallback_font, center - dir + Vector2(6.0, 4.0),
		neg_label, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, color.darkened(0.35))
