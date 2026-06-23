@tool
class_name PSDImportCore
extends RefCounted

## Core PSD import logic — a pure import pipeline decoupled from EditorImportPlugin.
## Provides all static methods for generating PNGs, scene files, and import records from PSD files.
## Can be called by both EditorImportPlugin._import() and PSDImporterDock.

const PhotoshopDocumentResource := preload("res://addons/FromLan_PSD_Importer/photoshop_document.gd")
const PSDParserClass := preload("res://addons/FromLan_PSD_Importer/psd_parser.gd")
const SceneBuilderClass := preload("res://addons/FromLan_PSD_Importer/scene_builder.gd")
const LayerTreeBuilderClass := preload("res://addons/FromLan_PSD_Importer/layer_tree.gd")
const UINodeMapperClass := preload("res://addons/FromLan_PSD_Importer/ui_node_mapper.gd")
const NineSliceProcessorClass := preload("res://addons/FromLan_PSD_Importer/nine_slice_processor.gd")

#region Enums

enum Mode {
	ByLayerAndScene,
	ByLayer,
	Merged,
}

enum LayerNameEncoding {
	Utf8,
	GBK,
}

enum OldResourceHandling {
	Unlink,
	Delete,
}

enum GroupExportBehavior {
	Ignore,
	SubDirectories,
	Flattened,
}

enum DuplicateHandling {
	Rename,
	KeepFirst,
	KeepLast,
}

enum LayerMaskHandling {
	Error,
	Skip,
	Apply,
}

enum TextLayerBehavior {
	Rasterize,
	Label,
	RichTextLabel,
}

enum HierarchyGroupNodeType {
	Control,
	Panel,
	PanelContainer,
}

enum RootAnchorMode {
	Fixed,
	FullRect,
}

#endregion

#region Lightweight Import (EditorImportPlugin placeholder)

## Create a minimal import record containing only metadata.
## Used by EditorImportPlugin._import() — does not parse PSD, generate PNGs, or build scenes.
## [param source_file] PSD source file path.
## [param save_path] Base .tres path assigned by the Godot import system.
## [param gen_files] Output parameter; generated file paths are appended to this array.
static func import_lightweight(source_file: String, save_path: String, gen_files: Array[String]) -> Error:
	var resource_save_path := save_path + ".tres"
	var resource := PhotoshopDocumentResource.new()
	resource.imported_at_unix = int(Time.get_unix_time_from_system())
	var err := ResourceSaver.save(resource, resource_save_path)
	if err != OK:
		push_error("Unable to save minimal PSD import record: %s (error %d)" % [resource_save_path, err])
		return err
	gen_files.append(resource_save_path)
	return OK

#endregion

#region Full Import (triggered by Dock)

## Perform a complete PSD import — parse, export PNGs, build scene, save import record.
## Returns a Dictionary; caller handles EditorFileSystem refresh and other editor operations.
## Return structure:
##   {
##     "error": Error,
##     "gen_files": Array[String],              # All generated PNG/scene file absolute paths
##     "resource": PhotoshopDocument,            # Import record resource instance
##     "resource_save_path": String,             # .tres file path
##     "source_file_dir": String,                # Source file directory
##     "old_resource_file_names": Array[String], # Old resource relative paths to clean
##     "old_scene_path": String,                 # Old scene path
##   }
static func import_full(source_file: String, save_path: String, options: Dictionary) -> Dictionary:
	# Parse options
	var opts := _parse_options(options)
	var merge_layers: bool = opts["merge_layers"] as bool
	var generate_scene: bool = opts["generate_scene"] as bool
	var layer_name_encoding: int = opts["layer_name_encoding"] as int
	var trim_layer: bool = opts["trim_layer"] as bool
	var perform_ownership_analysis: bool = opts["perform_ownership_analysis"] as bool
	var template: String = opts["template"] as String
	var old_resource_handling: int = opts["old_resource_handling"] as int
	var group_behavior: int = opts["group_behavior"] as int
	var subdir_naming: String = opts["subdir_naming"] as String
	var flat_naming: String = opts["flat_naming"] as String
	var dup_handling: int = opts["dup_handling"] as int
	var dup_rename_pattern: String = opts["dup_rename_pattern"] as String
	var use_hierarchy: bool = opts["use_hierarchy"] as bool
	var hierarchy_group_type: int = opts["hierarchy_group_type"] as int
	var root_anchor_mode: int = opts["root_anchor_mode"] as int
	var mask_handling: int = opts["mask_handling"] as int
	var text_layer_behavior: int = opts["text_layer_behavior"] as int
	var ui_mapping_enabled: bool = opts["ui_mapping_enabled"] as bool
	var nine_slice_enabled: bool = opts["nine_slice_enabled"] as bool
	var nine_slice_default_margin: int = opts["nine_slice_default_margin"] as int
	# PNG dimension limit: layers exceeding this long side are downscaled before saving (0 = no limit)
	var max_png_dimension: int = opts["max_png_dimension"] as int

	# Validate naming template
	var match_template := _substitute_name(template, "FileName", "LayerName")
	if !match_template.is_valid_filename():
		push_error("\"%s\" is not a valid filename" % match_template)
		return {"error": ERR_INVALID_PARAMETER}

	# Delegate to PSDParser for PSD binary parsing
	var img_data_array := PSDParserClass.read_psd_file(source_file, merge_layers, layer_name_encoding, trim_layer, mask_handling)
	if img_data_array.size() == 0:
		return {"error": ERR_FILE_CORRUPT}

	var source_file_name := source_file.get_basename().get_file()
	var source_file_dir := source_file.get_base_dir()
	var base_file_path := source_file.get_base_dir().path_join(source_file_name)
	var resource_save_path := save_path + ".tres"

	# Load or create import record resource
	var resource := PhotoshopDocumentResource.new()
	if FileAccess.file_exists(resource_save_path):
		var loaded_resource := ResourceLoader.load(resource_save_path)
		if loaded_resource != null:
			resource = loaded_resource

	var old_resource_file_names: Array[String] = resource.layer_paths.duplicate()
	var new_layer_paths: Array[String] = []
	var old_scene_path: String = resource.scene_path
	resource.scene_path = ""

	# Plan export entries
	var planned_entries: Array[Dictionary] = []
	var gen_files: Array[String] = []
	if merge_layers:
		planned_entries.append({
			"save_path": base_file_path + ".png",
			"image": img_data_array[0].image,
			"image_data": img_data_array[0],
		})
	else:
		for image_data: ImageData in img_data_array:
			if group_behavior == GroupExportBehavior.Ignore && image_data.group_path != "":
				continue
			planned_entries.append({
				"save_path": _build_layer_save_path(image_data,
					source_file_dir, source_file_name, template,
					group_behavior, subdir_naming, flat_naming,
				),
				"image": image_data.image,
				"image_data": image_data,
			})

	# Resolve duplicates
	var resolved_entries := _resolve_duplicate_entries(planned_entries, dup_handling, dup_rename_pattern)
	for entry: Dictionary in resolved_entries:
		var save_file_path := entry["save_path"] as String
		if !save_file_path.is_absolute_path() || !save_file_path.get_file().is_valid_filename():
			printerr("\"%s\" is not a valid filename" % save_file_path)
			return {"error": ERR_CANT_CREATE}

	# Save PNG files
	for entry: Dictionary in resolved_entries:
		var save_file_path := entry["save_path"] as String
		var make_dir_error := DirAccess.make_dir_recursive_absolute(save_file_path.get_base_dir())
		if make_dir_error != OK:
			push_error("Unable to create directory %s: %s" % [save_file_path.get_base_dir(), make_dir_error])
			return {"error": make_dir_error}
		if FileAccess.file_exists(save_file_path):
			DirAccess.remove_absolute(save_file_path)
		# PNG dimension limit
		var img_to_save := entry["image"] as Image
		if max_png_dimension > 0:
			var orig_w := img_to_save.get_width()
			var orig_h := img_to_save.get_height()
			var max_side := maxi(orig_w, orig_h)
			if max_side > max_png_dimension:
				var scale := float(max_png_dimension) / float(max_side)
				img_to_save = img_to_save.duplicate()
				img_to_save.resize(maxi(1, int(orig_w * scale)), maxi(1, int(orig_h * scale)), Image.INTERPOLATE_LANCZOS)
		var save_error := img_to_save.save_png(save_file_path)
		if save_error != OK:
			push_error("Unable to save %s: %s" % [save_file_path, save_error])
			return {"error": save_error}
		gen_files.append(save_file_path)

	# Update resource layer paths (build new array then assign as a whole, avoiding read-only array modification from .tres)
	var layer_path_prefix := source_file_dir
	if !layer_path_prefix.ends_with("/"):
		layer_path_prefix += "/"
	for created_file_paths: String in gen_files:
		var relative_file_path := created_file_paths.trim_prefix(layer_path_prefix)
		new_layer_paths.append(relative_file_path)
		var found := old_resource_file_names.find(relative_file_path)
		if found < 0:
			continue
		old_resource_file_names.remove_at(found)
	resource.layer_paths = new_layer_paths

	# Generate scene file (if enabled)
	if generate_scene:
		var scene_save_path := base_file_path + "__psd_scene.tscn"
		var scene_error: Error
		if use_hierarchy:
			var layer_records := PSDParserClass.get_last_layer_records()
			var all_layer_textures := PSDParserClass.get_last_layer_texture()
			var layer_tree_root = LayerTreeBuilderClass.build_tree(layer_records, all_layer_textures)
			_annotate_layer_tree(layer_tree_root, layer_records, resolved_entries, ui_mapping_enabled, text_layer_behavior, nine_slice_enabled, nine_slice_default_margin)
			scene_error = SceneBuilderClass.save_control_scene_hierarchical(
				scene_save_path, source_file_name, resolved_entries, img_data_array[0].source_size,
				layer_tree_root, hierarchy_group_type, root_anchor_mode,
			)
		else:
			scene_error = SceneBuilderClass.save_control_scene_flat(
				scene_save_path, source_file_name, resolved_entries, img_data_array[0].source_size, root_anchor_mode
			)
		if scene_error != OK:
			return {"error": scene_error}
		gen_files.append(scene_save_path)
		resource.scene_path = scene_save_path.trim_prefix(layer_path_prefix)
		if old_scene_path == resource.scene_path:
			old_scene_path = ""
	elif old_scene_path != "":
		print_rich("[color=yellow]Previous PSD scene is no longer generated by the selected import mode: %s[/color]" % source_file_dir.path_join(old_scene_path))

	# Save import record resource
	resource.source_size = img_data_array[0].source_size
	resource.layer_count = resource.layer_paths.size()
	resource.imported_at_unix = int(Time.get_unix_time_from_system())
	var main_res_save_error := ResourceSaver.save(resource, resource_save_path)
	if main_res_save_error != OK:
		push_error("Unable to save %s: %s" % [resource_save_path, main_res_save_error])
		return {"error": main_res_save_error}

	return {
		"error": OK,
		"gen_files": gen_files,
		"resource": resource,
		"resource_save_path": resource_save_path,
		"source_file_dir": source_file_dir,
		"source_file": source_file,
		"old_resource_file_names": old_resource_file_names,
		"old_scene_path": old_scene_path,
		"old_resource_handling": old_resource_handling,
		"perform_ownership_analysis": perform_ownership_analysis,
	}

#endregion

#region Async Import

## Async full import — same functionality as import_full, but uses read_psd_file_async
## to yield between layer processing and keep the editor responsive.
## [param yield_target] Node used for await get_tree().process_frame.
static func import_full_async(source_file: String, save_path: String, options: Dictionary, yield_target: Node = null) -> Dictionary:
	# Parse options
	var opts := _parse_options(options)
	var merge_layers: bool = opts["merge_layers"] as bool
	var generate_scene: bool = opts["generate_scene"] as bool
	var layer_name_encoding: int = opts["layer_name_encoding"] as int
	var trim_layer: bool = opts["trim_layer"] as bool
	var perform_ownership_analysis: bool = opts["perform_ownership_analysis"] as bool
	var template: String = opts["template"] as String
	var old_resource_handling: int = opts["old_resource_handling"] as int
	var group_behavior: int = opts["group_behavior"] as int
	var subdir_naming: String = opts["subdir_naming"] as String
	var flat_naming: String = opts["flat_naming"] as String
	var dup_handling: int = opts["dup_handling"] as int
	var dup_rename_pattern: String = opts["dup_rename_pattern"] as String
	var use_hierarchy: bool = opts["use_hierarchy"] as bool
	var hierarchy_group_type: int = opts["hierarchy_group_type"] as int
	var root_anchor_mode: int = opts["root_anchor_mode"] as int
	var mask_handling: int = opts["mask_handling"] as int
	var text_layer_behavior: int = opts["text_layer_behavior"] as int
	var ui_mapping_enabled: bool = opts["ui_mapping_enabled"] as bool
	var nine_slice_enabled: bool = opts["nine_slice_enabled"] as bool
	var nine_slice_default_margin: int = opts["nine_slice_default_margin"] as int
	# PNG dimension limit: layers exceeding this long side are downscaled before saving (0 = no limit)
	var max_png_dimension: int = opts["max_png_dimension"] as int

	var match_template := _substitute_name(template, "FileName", "LayerName")
	if !match_template.is_valid_filename():
		push_error("\"%s\" is not a valid filename" % match_template)
		return {"error": ERR_INVALID_PARAMETER}

	# Async parse PSD — yields every 3 layers
	var img_data_array := await PSDParserClass.read_psd_file_async(source_file, merge_layers, layer_name_encoding, trim_layer, mask_handling, yield_target)
	if img_data_array.size() == 0:
		return {"error": ERR_FILE_CORRUPT}

	var source_file_name := source_file.get_basename().get_file()
	var source_file_dir := source_file.get_base_dir()
	var base_file_path := source_file.get_base_dir().path_join(source_file_name)
	var resource_save_path := save_path + ".tres"

	var resource := PhotoshopDocumentResource.new()
	if FileAccess.file_exists(resource_save_path):
		var loaded_resource := ResourceLoader.load(resource_save_path)
		if loaded_resource != null:
			resource = loaded_resource

	var old_resource_file_names: Array[String] = resource.layer_paths.duplicate()
	var new_layer_paths: Array[String] = []
	var old_scene_path: String = resource.scene_path
	resource.scene_path = ""

	var planned_entries: Array[Dictionary] = []
	var gen_files: Array[String] = []
	if merge_layers:
		planned_entries.append({
			"save_path": base_file_path + ".png",
			"image": img_data_array[0].image,
			"image_data": img_data_array[0],
		})
	else:
		for image_data: ImageData in img_data_array:
			if group_behavior == GroupExportBehavior.Ignore && image_data.group_path != "":
				continue
			planned_entries.append({
				"save_path": _build_layer_save_path(image_data,
					source_file_dir, source_file_name, template,
					group_behavior, subdir_naming, flat_naming,
				),
				"image": image_data.image,
				"image_data": image_data,
			})

	var resolved_entries := _resolve_duplicate_entries(planned_entries, dup_handling, dup_rename_pattern)
	for entry: Dictionary in resolved_entries:
		var save_file_path := entry["save_path"] as String
		if !save_file_path.is_absolute_path() || !save_file_path.get_file().is_valid_filename():
			printerr("\"%s\" is not a valid filename" % save_file_path)
			return {"error": ERR_CANT_CREATE}

	# Save PNG files (yield after each save to keep editor responsive)
	var total_pngs := resolved_entries.size()
	for png_idx in range(total_pngs):
		# Yield before each PNG save to keep editor responsive
		if yield_target != null:
			await yield_target.get_tree().process_frame
		var entry := resolved_entries[png_idx]
		var save_file_path := entry["save_path"] as String
		var make_dir_error := DirAccess.make_dir_recursive_absolute(save_file_path.get_base_dir())
		if make_dir_error != OK:
			push_error("Unable to create directory %s: %s" % [save_file_path.get_base_dir(), make_dir_error])
			return {"error": make_dir_error}
		if FileAccess.file_exists(save_file_path):
			DirAccess.remove_absolute(save_file_path)
		# PNG dimension limit: downscale if exceeded to speed up compression and reduce file size
		var img_to_save := entry["image"] as Image
		if max_png_dimension > 0:
			var orig_w := img_to_save.get_width()
			var orig_h := img_to_save.get_height()
			var max_side := maxi(orig_w, orig_h)
			if max_side > max_png_dimension:
				var scale := float(max_png_dimension) / float(max_side)
				var new_w := maxi(1, int(orig_w * scale))
				var new_h := maxi(1, int(orig_h * scale))
				img_to_save = img_to_save.duplicate()
				img_to_save.resize(new_w, new_h, Image.INTERPOLATE_LANCZOS)
				if png_idx < 5:
					print_rich("[color=dim_gray]  Downscaled %dx%d -> %dx%d for PNG save[/color]" % [orig_w, orig_h, new_w, new_h])
		var save_error := img_to_save.save_png(save_file_path)
		if save_error != OK:
			push_error("Unable to save %s: %s" % [save_file_path, save_error])
			return {"error": save_error}
		gen_files.append(save_file_path)

	var layer_path_prefix := source_file_dir
	if !layer_path_prefix.ends_with("/"):
		layer_path_prefix += "/"
	for created_file_paths: String in gen_files:
		var relative_file_path := created_file_paths.trim_prefix(layer_path_prefix)
		new_layer_paths.append(relative_file_path)
		var found := old_resource_file_names.find(relative_file_path)
		if found < 0:
			continue
		old_resource_file_names.remove_at(found)
	resource.layer_paths = new_layer_paths

	if generate_scene:
		var scene_save_path := base_file_path + "__psd_scene.tscn"
		var scene_error: Error
		if use_hierarchy:
			var layer_records := PSDParserClass.get_last_layer_records()
			var all_layer_textures := PSDParserClass.get_last_layer_texture()
			var layer_tree_root = LayerTreeBuilderClass.build_tree(layer_records, all_layer_textures)
			_annotate_layer_tree(layer_tree_root, layer_records, resolved_entries, ui_mapping_enabled, text_layer_behavior, nine_slice_enabled, nine_slice_default_margin)
			scene_error = SceneBuilderClass.save_control_scene_hierarchical(
				scene_save_path, source_file_name, resolved_entries, img_data_array[0].source_size,
				layer_tree_root, hierarchy_group_type, root_anchor_mode,
			)
		else:
			scene_error = SceneBuilderClass.save_control_scene_flat(
				scene_save_path, source_file_name, resolved_entries, img_data_array[0].source_size, root_anchor_mode
			)
		if scene_error != OK:
			return {"error": scene_error}
		gen_files.append(scene_save_path)
		resource.scene_path = scene_save_path.trim_prefix(layer_path_prefix)
		if old_scene_path == resource.scene_path:
			old_scene_path = ""
	elif old_scene_path != "":
		print_rich("[color=yellow]Previous PSD scene is no longer generated by the selected import mode: %s[/color]" % source_file_dir.path_join(old_scene_path))

	resource.source_size = img_data_array[0].source_size
	resource.layer_count = resource.layer_paths.size()
	resource.imported_at_unix = int(Time.get_unix_time_from_system())
	var main_res_save_error := ResourceSaver.save(resource, resource_save_path)
	if main_res_save_error != OK:
		push_error("Unable to save %s: %s" % [resource_save_path, main_res_save_error])
		return {"error": main_res_save_error}

	return {
		"error": OK,
		"gen_files": gen_files,
		"resource": resource,
		"resource_save_path": resource_save_path,
		"source_file_dir": source_file_dir,
		"source_file": source_file,
		"old_resource_file_names": old_resource_file_names,
		"old_scene_path": old_scene_path,
		"old_resource_handling": old_resource_handling,
		"perform_ownership_analysis": perform_ownership_analysis,
	}

#endregion

#region Layer Tree Annotation

## Traverse the layer tree and annotate each node with target type and extra properties based on import options.
static func _annotate_layer_tree(
	root: RefCounted,
	layer_records: Array,
	all_entries: Array[Dictionary],
	ui_mapping: bool,
	text_behavior: TextLayerBehavior,
	nine_slice: bool,
	nine_slice_margin: int,
) -> void:
	_annotate_layer_node(root, layer_records, all_entries, ui_mapping, text_behavior, nine_slice, nine_slice_margin)

## Recursively annotate a single LayerNode.
static func _annotate_layer_node(
	node: RefCounted,
	layer_records: Array,
	all_entries: Array[Dictionary],
	ui_mapping: bool,
	text_behavior: TextLayerBehavior,
	nine_slice: bool,
	nine_slice_margin: int,
) -> void:
	match node.node_type:
		LayerTreeBuilderClass.LayerNode.NodeType.LAYER:
			var has_text: bool = node.layer_record != null && node.layer_record.ty_sh_data != null && node.layer_record.ty_sh_data.is_valid
			if ui_mapping:
				var map_result := UINodeMapperClass.parse_layer_name(node.name, has_text)
				node.target_node_type = map_result["node_type"]
				node.extra_properties = map_result["extra_properties"]
				if map_result["clean_name"] != "":
					node.name = map_result["clean_name"]
			elif has_text and text_behavior != TextLayerBehavior.Rasterize:
				match text_behavior:
					TextLayerBehavior.Label:
						node.target_node_type = "Label"
					TextLayerBehavior.RichTextLabel:
						node.target_node_type = "RichTextLabel"

			if NineSliceProcessorClass.is_companion_layer(node.name):
				node.is_hidden = true

			if nine_slice and node.target_node_type == "NinePatchRect":
				var prop_margins := NineSliceProcessorClass.parse_margins_from_props(node.extra_properties, nine_slice_margin)
				var companion_margins := NineSliceProcessorClass.detect_companion_margins(node.name, all_entries)
				if !companion_margins.is_empty():
					for key in companion_margins:
						if companion_margins[key] >= 0:
							prop_margins[key] = companion_margins[key]
				node.extra_properties["nine_slice_margins"] = prop_margins

		LayerTreeBuilderClass.LayerNode.NodeType.GROUP:
			if ui_mapping:
				var map_result := UINodeMapperClass.parse_layer_name(node.name, false)
				if map_result["clean_name"] != "":
					node.name = map_result["clean_name"]
			for child: LayerTreeBuilderClass.LayerNode in node.children:
				_annotate_layer_node(child, layer_records, all_entries, ui_mapping, text_behavior, nine_slice, nine_slice_margin)

		LayerTreeBuilderClass.LayerNode.NodeType.ROOT:
			for child: LayerTreeBuilderClass.LayerNode in node.children:
				_annotate_layer_node(child, layer_records, all_entries, ui_mapping, text_behavior, nine_slice, nine_slice_margin)

#endregion

#region Naming Helpers

## Substitute file and layer name placeholders, then sanitize into a saveable filename component.
static func _substitute_name(template: String, p_filename: String, p_layername: String) -> String:
	return template.replace("<file>", _sanitize_filename_component(p_filename)).replace("<layer>", _sanitize_filename_component(p_layername))

## Substitute arbitrary naming template placeholders.
static func _substitute_tokens(template: String, substitutions: Dictionary) -> String:
	var result := template
	for key in substitutions.keys():
		result = result.replace("<%s>" % key, _sanitize_filename_component(str(substitutions[key])))
	return result

## Build the target PNG path for a single layer based on group export strategy.
static func _build_layer_save_path(image_data: ImageData,
	source_file_dir: String,
	source_file_name: String,
	template: String,
	group_behavior: GroupExportBehavior,
	subdir_naming: String,
	flat_naming: String,
) -> String:
	match group_behavior:
		GroupExportBehavior.SubDirectories:
			var target_dir := source_file_dir
			if image_data.group_path != "":
				for group_name: String in image_data.group_path.split("/", false):
					target_dir = target_dir.path_join(_substitute_tokens(subdir_naming, {
						"group": group_name,
					}))
			return target_dir.path_join(_substitute_name(template, source_file_name, image_data.name) + ".png")
		GroupExportBehavior.Flattened:
			if image_data.group_path == "":
				return source_file_dir.path_join(_substitute_name(template, source_file_name, image_data.name) + ".png")
			var flattened_group_name := image_data.group_path.replace("/", "-")
			return source_file_dir.path_join(_substitute_tokens(flat_naming, {
				"file": source_file_name,
				"group": flattened_group_name,
				"layer": image_data.name,
			}) + ".png")
		_:
			return source_file_dir.path_join(_substitute_name(template, source_file_name, image_data.name) + ".png")

## Resolve the final generation list based on the duplicate file name handling strategy.
static func _resolve_duplicate_entries(entries: Array[Dictionary], duplicate_handling: DuplicateHandling, rename_pattern: String) -> Array[Dictionary]:
	var resolved_entries: Array[Dictionary] = []
	var path_to_index: Dictionary = {}
	for entry in entries:
		var save_path := entry["save_path"] as String
		if !path_to_index.has(save_path):
			path_to_index[save_path] = resolved_entries.size()
			resolved_entries.append(entry)
			continue
		match duplicate_handling:
			DuplicateHandling.KeepFirst:
				continue
			DuplicateHandling.KeepLast:
				resolved_entries[path_to_index[save_path]] = entry
			DuplicateHandling.Rename:
				var original_name := save_path.get_file().get_basename()
				var target_dir := save_path.get_base_dir()
				var duplicate_number := 2
				var renamed_path := save_path
				while true:
					renamed_path = target_dir.path_join(_substitute_tokens(rename_pattern, {
						"name": original_name,
						"n": duplicate_number,
					}) + ".png")
					if !path_to_index.has(renamed_path):
						break
					duplicate_number += 1
				var renamed_entry := entry.duplicate()
				renamed_entry["save_path"] = renamed_path
				path_to_index[renamed_path] = resolved_entries.size()
				resolved_entries.append(renamed_entry)
	return resolved_entries

## Sanitize an arbitrary string into a stable filename component.
static func _sanitize_filename_component(value: String) -> String:
	var result := value.strip_edges()
	if result == "":
		return "unnamed"
	var invalid_chars := ["<", ">", ":", "\"", "/", "\\", "|", "?", "*"]
	for invalid_char: String in invalid_chars:
		result = result.replace(invalid_char, "_")
	return result

#endregion

#region Helpers

## Convert an enum dictionary into the hint_string format required by Godot's Import panel.
static func _get_enum_selections(dict: Dictionary) -> String:
	var enum_text: String = ""
	for value: Variant in dict.values():
		if enum_text != "":
			enum_text += ","
		enum_text += dict.keys()[value] + ":" + str(value)
	return enum_text

## Parse the import options dictionary into a flat option-value dictionary.
## Eliminates duplicate parsing logic between import_full and import_full_async.
static func _parse_options(options: Dictionary) -> Dictionary:
	return {
		"merge_layers": (int(options["import_mode"]) as Mode) == Mode.Merged,
		"generate_scene": (int(options["import_mode"]) as Mode) == Mode.ByLayerAndScene,
		"layer_name_encoding": int(options["layer_name_encoding"]) as LayerNameEncoding,
		"trim_layer": options["layer_trim_enabled"] as bool,
		"perform_ownership_analysis": options["perform_ownership_analysis"] as bool,
		"template": options["layer_resource_naming"] as String,
		"old_resource_handling": int(options["old_resource_handling"]) as OldResourceHandling,
		"group_behavior": int(options["group_export_behavior"]) as GroupExportBehavior,
		"subdir_naming": options["group_subdir_naming"] as String,
		"flat_naming": options["group_flat_naming"] as String,
		"dup_handling": int(options["duplicate_handling"]) as DuplicateHandling,
		"dup_rename_pattern": options["duplicate_rename_pattern"] as String,
		"use_hierarchy": (int(options["import_mode"]) as Mode) == Mode.ByLayerAndScene && (options.get("generate_hierarchy", false) as bool),
		"hierarchy_group_type": int(options.get("hierarchy_group_node", HierarchyGroupNodeType.Control)),
		"root_anchor_mode": int(options.get("root_anchor_mode", RootAnchorMode.Fixed)),
		"mask_handling": int(options.get("layer_mask_handling", LayerMaskHandling.Error)),
		"text_layer_behavior": int(options.get("text_layer_behavior", TextLayerBehavior.Rasterize)),
		"ui_mapping_enabled": options.get("ui_node_mapping_enabled", false) as bool,
		"nine_slice_enabled": options.get("nine_slice_enabled", false) as bool,
		"nine_slice_default_margin": int(options.get("nine_slice_default_margin", 8)),
		"max_png_dimension": int(options.get("max_png_dimension", 0)),
	}

## Return default import options dictionary (consistent with _get_import_options defaults).
static func get_default_options() -> Dictionary:
	return {
		"import_mode": Mode.ByLayerAndScene,
		"layer_name_encoding": LayerNameEncoding.Utf8,
		"layer_trim_enabled": true,
		"layer_mask_handling": LayerMaskHandling.Error,
		"generate_hierarchy": false,
		"hierarchy_group_node": HierarchyGroupNodeType.Control,
		"root_anchor_mode": RootAnchorMode.Fixed,
		"text_layer_behavior": TextLayerBehavior.Rasterize,
		"ui_node_mapping_enabled": false,
		"nine_slice_enabled": false,
		"nine_slice_default_margin": 8,
		"max_png_dimension": 0,
		"layer_resource_naming": "<file>__<layer>",
		"group_export_behavior": GroupExportBehavior.Flattened,
		"group_subdir_naming": "<group>",
		"group_flat_naming": "<file>__<group>__<layer>",
		"duplicate_handling": DuplicateHandling.Rename,
		"duplicate_rename_pattern": "<name>__<n>",
		"old_resource_handling": OldResourceHandling.Unlink,
		"perform_ownership_analysis": false,
	}

#endregion
