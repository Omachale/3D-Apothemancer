extends SceneTree

## Temporary: dumps the Mage rig's bone list so the animator can be wired
## against real bone names. Run with:
##   godot --headless --path . --script res://scripts/dev/dump_bones.gd

const OUT_PATH := "user://bones.txt"
## Which model to dump. Override with --model=res://path/to/file.glb.
var _model_path := "res://assets/models/Mage.glb"

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--model="):
			_model_path = arg.substr("--model=".length())

	var lines: Array[String] = []
	var scene: PackedScene = load(_model_path)
	if scene == null:
		lines.append("FAILED TO LOAD " + _model_path)
	else:
		var root: Node = scene.instantiate()
		lines.append("--- tree ---")
		_dump_tree(root, 0, lines)
		lines.append("--- skeleton ---")
		var skel := _find(root)
		if skel == null:
			lines.append("NO SKELETON FOUND")
		else:
			lines.append("bone_count=%d" % skel.get_bone_count())
			for i in skel.get_bone_count():
				var rest := skel.get_bone_global_rest(i)
				var pose := skel.get_bone_global_pose(i)
				lines.append("%2d  %-16s parent=%2d\n     rest=(%.3f, %.3f, %.3f)  pose=(%.3f, %.3f, %.3f)" % [
					i, skel.get_bone_name(i), skel.get_bone_parent(i),
					rest.origin.x, rest.origin.y, rest.origin.z,
					pose.origin.x, pose.origin.y, pose.origin.z])
	var f := FileAccess.open(OUT_PATH, FileAccess.WRITE)
	f.store_string("\n".join(lines))
	f.close()
	print("\n".join(lines))
	quit()


func _find(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var f := _find(c)
		if f:
			return f
	return null


func _dump_tree(n: Node, depth: int, lines: Array[String]) -> void:
	var extra := ""
	if n is AnimationPlayer:
		var names := (n as AnimationPlayer).get_animation_list()
		extra = "  clips=%d %s" % [names.size(), names]
	elif n is MeshInstance3D:
		var aabb := (n as MeshInstance3D).get_aabb()
		extra = "  aabb=%s" % [aabb]
	lines.append("%s%s (%s)%s" % ["  ".repeat(depth), n.name, n.get_class(), extra])
	for c in n.get_children():
		_dump_tree(c, depth + 1, lines)
