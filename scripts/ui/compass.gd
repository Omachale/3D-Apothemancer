extends Control

## Debug compass: shows which way N/E/S/W point ON SCREEN at the camera's
## current yaw. Y is the third world axis and is not drawn — it is vertical,
## straight out of the monitor at you, so there is nothing to project.
##
## The compass points are the axis-aligned names from DESIGN_GOALS.md:
## North = -Z, South = +Z, East = +X, West = -X. They are aliases for world
## axes and nothing more — in particular they are unrelated to
## Wind.direction_degrees, which is its own 0-360 system measured from +Z.
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
## North is picked out in red the way a real compass needle is; the other three
## are muted so the eye lands on north first and reads orientation from it.
const NORTH_COLOR := Color(0.92, 0.35, 0.32)
const POINT_COLOR := Color(0.82, 0.86, 0.9)
const NEEDLE_COLOR := Color(0.55, 0.6, 0.66)


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	if Game.camera_rig == null:
		return
	var center := size * 0.5
	var yaw := deg_to_rad(Game.camera_rig.yaw)
	# World axis (1,0,0) and (0,0,1), each rotated by -yaw — see the class doc.
	var east := Vector2(cos(yaw), sin(yaw)) * RADIUS
	var south := Vector2(-sin(yaw), cos(yaw)) * RADIUS

	draw_circle(center, RADIUS + 6.0, Color(0.0, 0.0, 0.0, 0.35))
	draw_line(center - south, center + south, NEEDLE_COLOR, 2.0)
	draw_line(center - east, center + east, NEEDLE_COLOR, 2.0)
	# North last of the four so its marker sits over the crossing lines.
	_draw_point(center, east, "E", POINT_COLOR)
	_draw_point(center, south, "S", POINT_COLOR)
	_draw_point(center, -east, "W", POINT_COLOR)
	_draw_point(center, -south, "N", NORTH_COLOR)


## Draws one lettered point at [param dir] from centre. The label is offset
## ALONG dir rather than by a fixed corner offset, so letters sit outside the
## ring on whichever side they are on instead of overlapping it when the
## compass spins.
func _draw_point(center: Vector2, dir: Vector2, label: String, color: Color) -> void:
	var font := ThemeDB.fallback_font
	var tip := center + dir
	draw_circle(tip, 3.0, color)
	var text_size := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 14)
	# draw_string takes a BASELINE, so the vertical centring is half the cap
	# height rather than half the full line height.
	var at := tip + dir.normalized() * 12.0 - Vector2(text_size.x * 0.5, -5.0)
	draw_string(font, at, label, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, color)
