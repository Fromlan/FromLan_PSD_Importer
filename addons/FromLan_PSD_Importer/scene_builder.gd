class_name SceneBuilder
extends RefCounted

## .tscn scene file generator.
## Supports flat mode (backward compatible) and hierarchical mode.

const LayerTreeBuilderClass := preload("res://addons/FromLan_PSD_Importer/layer_tree.gd")

#region Flat Scene Generation (Legacy)

## Generate a flat Control root with TextureRect children referencing exported PNGs.
static func save_control_scene_flat(scene_save_path: String, source_file_name: String, entries: Array[Dictionary], source_size: Vector2i, root_anchor_mode: int = 0) -> Error:
	if entries.is_empty():
		push_error("save_control_scene: entries array is empty, nothing to save")
		return ERR_INVALID_PARAMETER
	if source_size.x <= 0 or source_size.y <= 0:
		push_error("save_control_scene: invalid source_size (%s), must be positive." % source_size)
		return ERR_INVALID_PARAMETER
	var lines: Array[String] = []
	lines.append("[gd_scene load_steps=%d format=3]" % [entries.size() + 1])
	lines.append("")
	for index: int in range(entries.size()):
		var entry: Dictionary = entries[index]
		var texture_path := entry["save_path"] as String
		lines.append("[ext_resource type=\"Texture2D\" path=%s id=\"%d_texture\"]" % [_quote_scene_string(texture_path), index + 1])
	lines.append("")
	lines.append("[node name=%s type=\"Control\"]" % _quote_scene_string(_sanitize_node_name(source_file_name)))
	if root_anchor_mode == 1:  # FullRect
		lines.append("anchors_preset = 15")
		lines.append("grow_horizontal = 2")
		lines.append("grow_vertical = 2")
		lines.append("offset_right = 0.0")
		lines.append("offset_bottom = 0.0")
	else:  # Fixed
		lines.append("anchors_preset = 0")
		lines.append("offset_right = %.1f" % float(source_size.x))
		lines.append("offset_bottom = %.1f" % float(source_size.y))
	lines.append("")
	var used_child_names: Dictionary = {}
	for index: int in range(entries.size()):
		var entry: Dictionary = entries[index]
		var image_data := entry["image_data"] as ImageData
		var layer_name := _make_unique_node_name(_sanitize_node_name("%03d_%s" % [index + 1, image_data.name]), used_child_names)
		var layer_position := image_data.position
		var layer_size := image_data.image.get_size()
		lines.append("[node name=%s type=\"TextureRect\" parent=\".\"]" % _quote_scene_string(layer_name))
		lines.append("offset_left = %.1f" % float(layer_position.x))
		lines.append("offset_top = %.1f" % float(layer_position.y))
		lines.append("offset_right = %.1f" % float(layer_position.x + layer_size.x))
		lines.append("offset_bottom = %.1f" % float(layer_position.y + layer_size.y))
		lines.append("mouse_filter = 2")
		lines.append("texture = ExtResource(\"%d_texture\")" % [index + 1])
		lines.append("expand_mode = 1")
		lines.append("stretch_mode = 2")
		lines.append("")
	var file := FileAccess.open(scene_save_path, FileAccess.WRITE)
	if file == null:
		var open_error := FileAccess.get_open_error()
		push_error("Unable to open PSD scene %s for writing: %s" % [scene_save_path, open_error])
		return open_error
	file.store_string("\n".join(lines))
	file.close()
	return OK

#endregion

#region Hierarchical Scene Generation

## Generate a hierarchical Control scene, mapping PSD groups to nested Control/Panel nodes.
## [param scene_save_path] Full save path for the scene file.
## [param source_file_name] Source PSD filename, used as root node name.
## [param entries] Layer entry array, each containing save_path, image, image_data.
## [param source_size] PSD document canvas size.
## [param layer_tree_root] LayerNode tree root.
## [param group_node_type] GROUP node's corresponding Godot type.
static func save_control_scene_hierarchical(
	scene_save_path: String,
	source_file_name: String,
	entries: Array[Dictionary],
	source_size: Vector2i,
	layer_tree_root,
	group_node_type: int,
	root_anchor_mode: int = 0,
) -> Error:
	if entries.is_empty():
		push_error("save_control_scene_hierarchical: entries array is empty")
		return ERR_INVALID_PARAMETER

	# Step 1: Build image_data -> ext_resource_id mapping
	var ext_resource_lines: Array[String] = []
	var ext_resource_map: Dictionary = {} # ImageData -> ext_resource_id
	var name_ext_resource_map: Dictionary = {} # String(name) -> ext_resource_id (fallback name match)
	for index: int in range(entries.size()):
		var entry: Dictionary = entries[index]
		var texture_path := entry["save_path"] as String
		var ext_id := "%d_texture" % (index + 1)
		ext_resource_lines.append("[ext_resource type=\"Texture2D\" path=%s id=\"%s\"]" % [_quote_scene_string(texture_path), ext_id])
		ext_resource_map[entry["image_data"]] = ext_id
		var img_data = entry["image_data"] as ImageData
		if img_data != null:
			name_ext_resource_map[img_data.name] = ext_id

	# Step 2: Recursively generate node lines for each layer level
	var node_lines: Array[String] = []
	var load_steps_counter := entries.size() # ext_resource count

	# Assign ext_resource_id to each LAYER node
	_assign_ext_resource_ids(layer_tree_root, ext_resource_map, name_ext_resource_map)

	# Root node
	var group_type_name := _group_node_type_name(group_node_type)
	node_lines.append("[node name=%s type=\"%s\"]" % [_quote_scene_string(_sanitize_node_name(source_file_name)), group_type_name])
	if root_anchor_mode == 1:  # FullRect
		node_lines.append("anchors_preset = 15")
		node_lines.append("grow_horizontal = 2")
		node_lines.append("grow_vertical = 2")
		node_lines.append("offset_right = 0.0")
		node_lines.append("offset_bottom = 0.0")
	else:  # Fixed
		node_lines.append("anchors_preset = 0")
		node_lines.append("offset_right = %.1f" % float(source_size.x))
		node_lines.append("offset_bottom = %.1f" % float(source_size.y))
	if group_node_type == 2: # PanelContainer
		pass # PanelContainer doesn't need extra mouse_filter

	# Recursively generate child nodes
	var parent_bounds := Rect2i(Vector2i.ZERO, source_size)
	var root_child_names: Dictionary = {}
	for child_index: int in range(layer_tree_root.children.size() - 1, -1, -1):
		var child_layer = layer_tree_root.children[child_index]
		_generate_node_lines(child_layer, node_lines, ".", parent_bounds, ext_resource_map, load_steps_counter, group_node_type, root_child_names)

	# Step 3: Assemble and write .tscn
	var all_lines: Array[String] = []
	all_lines.append("[gd_scene load_steps=%d format=3]" % [entries.size() + 1])
	all_lines.append("")
	all_lines.append_array(ext_resource_lines)
	all_lines.append("")
	all_lines.append_array(node_lines)

	var file := FileAccess.open(scene_save_path, FileAccess.WRITE)
	if file == null:
		var open_error := FileAccess.get_open_error()
		push_error("Unable to open PSD scene %s for writing: %s" % [scene_save_path, open_error])
		return open_error
	file.store_string("\n".join(all_lines))
	file.close()
	return OK

## Recursively generate node lines for the LayerNode tree.
## [param layer] Current layer node.
## [param lines] Output line array.
## [param parent_name] Parent node's .tscn reference name.
## [param parent_bounds] Parent node's bounding box in PSD coordinates.
## [param ext_resource_map] ImageData -> ext_resource_id mapping.
## [param _load_steps_counter] Unused, reserved for future expansion.
## [param group_node_type] GROUP node type enum.
static func _generate_node_lines(
	layer: LayerTreeBuilderClass.LayerNode,
	lines: Array[String],
	parent_name: String,
	parent_bounds: Rect2i,
	ext_resource_map: Dictionary,
	_load_steps_counter: int,
	group_node_type: int,
	used_sibling_names: Dictionary,
) -> void:
	# Skip hidden layers (companion 9-slice layers, etc.)
	if layer.is_hidden:
		return

	var node_name := _make_unique_node_name(_sanitize_node_name(layer.name), used_sibling_names)
	var node_type := _resolve_node_type(layer)
	var node_parent := parent_name

	lines.append("[node name=%s type=\"%s\" parent=%s]" % [_quote_scene_string(node_name), node_type, _quote_scene_string(node_parent)])

	match layer.node_type:
		LayerTreeBuilderClass.LayerNode.NodeType.GROUP:
			# GROUP node: Control/Panel/PanelContainer
			# Position relative to parent
			var rel_pos: Vector2i = layer.bounds.position - parent_bounds.position
			lines.append("offset_left = %.1f" % float(rel_pos.x))
			lines.append("offset_top = %.1f" % float(rel_pos.y))
			lines.append("offset_right = %.1f" % float(rel_pos.x + layer.bounds.size.x))
			lines.append("offset_bottom = %.1f" % float(rel_pos.y + layer.bounds.size.y))
			lines.append("mouse_filter = 2") # MOUSE_FILTER_IGNORE: don't block child clicks
			lines.append("")
			# Recursive children
			var child_names: Dictionary = {}
			for child_index: int in range(layer.children.size() - 1, -1, -1):
				var child_layer = layer.children[child_index]
				_generate_node_lines(child_layer, lines, node_parent + "/" + node_name, layer.bounds, ext_resource_map, _load_steps_counter, group_node_type, child_names)

		LayerTreeBuilderClass.LayerNode.NodeType.LAYER:
			# LAYER node: TextureRect / Label / Button / NinePatchRect etc.
			var rel_pos: Vector2i = layer.bounds.position - parent_bounds.position
			lines.append("offset_left = %.1f" % float(rel_pos.x))
			lines.append("offset_top = %.1f" % float(rel_pos.y))
			lines.append("offset_right = %.1f" % float(rel_pos.x + layer.bounds.size.x))
			lines.append("offset_bottom = %.1f" % float(rel_pos.y + layer.bounds.size.y))
			lines.append("mouse_filter = 2")
			# Generate different properties based on node type
			match node_type:
				"TextureRect":
					if layer.ext_resource_id != "":
						lines.append("texture = ExtResource(\"%s\")" % layer.ext_resource_id)
					lines.append("expand_mode = 1")
					lines.append("stretch_mode = 2")
				"NinePatchRect":
					if layer.ext_resource_id != "":
						lines.append("texture = ExtResource(\"%s\")" % layer.ext_resource_id)
					# Apply nine-slice margins
					_append_nine_patch_margins(lines, layer)
				"Label":
					_append_label_properties(lines, layer)
				"RichTextLabel":
					_append_label_properties(lines, layer)
					lines.append("bbcode_enabled = true")
				"Button":
					_append_button_properties(lines, layer)
				"ColorRect":
					_append_color_rect_properties(lines, layer)
			lines.append("")
		_:
			pass

## Determine Godot node type from a LayerNode.
static func _resolve_node_type(layer: LayerTreeBuilderClass.LayerNode) -> String:
	if layer.target_node_type != "TextureRect":
		return layer.target_node_type
	# Fall back to default based on node_type
	match layer.node_type:
		LayerTreeBuilderClass.LayerNode.NodeType.GROUP:
			return "Control"
		_:
			return "TextureRect"

## Convert GROUP node type enum to Godot class name.
static func _group_node_type_name(group_node_type: int) -> String:
	match group_node_type:
		0: return "Control"
		1: return "Panel"
		2: return "PanelContainer"
		_: return "Control"

## Recursively traverse the tree and assign ext_resource_id to each LAYER node.
## [param name_ext_resource_map] Fallback mapping by layer name, used when ImageData object references are inconsistent.
static func _assign_ext_resource_ids(node: LayerTreeBuilderClass.LayerNode, ext_resource_map: Dictionary, name_ext_resource_map: Dictionary = {}) -> void:
	match node.node_type:
		LayerTreeBuilderClass.LayerNode.NodeType.LAYER:
			if node.image_data != null:
				if ext_resource_map.has(node.image_data):
					node.ext_resource_id = ext_resource_map[node.image_data]
				elif name_ext_resource_map.has(node.name):
					node.ext_resource_id = name_ext_resource_map[node.name]
		LayerTreeBuilderClass.LayerNode.NodeType.GROUP, LayerTreeBuilderClass.LayerNode.NodeType.ROOT:
			for child: LayerTreeBuilderClass.LayerNode in node.children:
				_assign_ext_resource_ids(child, ext_resource_map, name_ext_resource_map)

## Write NinePatchRect patch_margin properties into node lines.
static func _append_nine_patch_margins(lines: Array[String], layer: LayerTreeBuilderClass.LayerNode) -> void:
	var margins: Dictionary = layer.extra_properties.get("nine_slice_margins", {})
	if margins.is_empty():
		return
	var left: int = int(margins.get("left", 0))
	var right: int = int(margins.get("right", 0))
	var top: int = int(margins.get("top", 0))
	var bottom: int = int(margins.get("bottom", 0))
	lines.append("patch_margin_left = %d" % left)
	lines.append("patch_margin_right = %d" % right)
	lines.append("patch_margin_top = %d" % top)
	lines.append("patch_margin_bottom = %d" % bottom)

#endregion

#region Node Property Helpers

## Generate text properties for Label nodes (extracted from TySh data).
static func _append_label_properties(lines: Array[String], layer: LayerTreeBuilderClass.LayerNode) -> void:
	lines.append("clip_contents = true")
	if layer.layer_record == null or layer.layer_record.ty_sh_data == null:
		return
	var ty_data = layer.layer_record.ty_sh_data
	if ty_data.text.length() > 0:
		lines.append("text = %s" % JSON.stringify(ty_data.text))
	# Alignment mapping: TySh 0=Left, 1=Center, 2=Right
	match ty_data.alignment:
		1: lines.append("horizontal_alignment = 1")  # CENTER
		2: lines.append("horizontal_alignment = 2")  # RIGHT
	# Font color
	if ty_data.font_color != Color.WHITE:
		lines.append("modulate = Color(%.4f, %.4f, %.4f, 1)" % [ty_data.font_color.r, ty_data.font_color.g, ty_data.font_color.b])
	# Font size annotation (set label_settings in editor if needed)
	if ty_data.font_size > 0:
		lines.append("# font size: %.1fpt (set label_settings in editor)" % ty_data.font_size)
	# Font name hint
	if ty_data.font_name.length() > 0:
		lines.append("# font: %s" % ty_data.font_name)

## Generate properties for Button nodes.
static func _append_button_properties(lines: Array[String], layer: LayerTreeBuilderClass.LayerNode) -> void:
	lines.append("clip_contents = true")
	# Extract button text from TySh data
	if layer.layer_record != null and layer.layer_record.ty_sh_data != null:
		var ty_data = layer.layer_record.ty_sh_data
		if ty_data.text.length() > 0:
			lines.append("text = %s" % JSON.stringify(ty_data.text))
			if ty_data.font_color != Color.WHITE:
				lines.append("modulate = Color(%.4f, %.4f, %.4f, 1)" % [ty_data.font_color.r, ty_data.font_color.g, ty_data.font_color.b])

## Generate color properties for ColorRect nodes.
static func _append_color_rect_properties(lines: Array[String], layer: LayerTreeBuilderClass.LayerNode) -> void:
	# Extract fill color from TySh data
	if layer.layer_record != null and layer.layer_record.ty_sh_data != null:
		var ty_data = layer.layer_record.ty_sh_data
		lines.append("color = Color(%.4f, %.4f, %.4f, 1)" % [ty_data.font_color.r, ty_data.font_color.g, ty_data.font_color.b])
	else:
		lines.append("color = Color(1, 1, 1, 1)")

#endregion

#region Helpers

## Encode a string as a quoted .tscn-compatible string.
static func _quote_scene_string(value: String) -> String:
	return JSON.stringify(value)

## Builds a sibling-unique node name so Godot does not rename generated scene nodes.
static func _make_unique_node_name(base_name: String, used_names: Dictionary) -> String:
	var safe_base := base_name
	if safe_base == "":
		safe_base = "unnamed"
	if !used_names.has(safe_base):
		used_names[safe_base] = 1
		return safe_base

	var suffix: int = int(used_names[safe_base]) + 1
	var unique_name := "%s_%d" % [safe_base, suffix]
	while used_names.has(unique_name):
		suffix += 1
		unique_name = "%s_%d" % [safe_base, suffix]
	used_names[safe_base] = suffix
	used_names[unique_name] = 1
	return unique_name

## Sanitize an arbitrary string into a stable filename component.
static func _sanitize_filename_component(value: String) -> String:
	var result := value.strip_edges()
	if result == "":
		return "unnamed"
	var invalid_chars := ["<", ">", ":", "\"", "/", "\\", "|", "?", "*", "@", "%"]
	for invalid_char: String in invalid_chars:
		result = result.replace(invalid_char, "_")
	return result

## Sanitize a layer name into a Godot node name, preserving readability while avoiding path separators.
static func _sanitize_node_name(value: String) -> String:
	var result := _sanitize_filename_component(value)
	result = result.replace(".", "_")
	return result

#endregion
