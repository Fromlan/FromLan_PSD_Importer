@tool
class_name PSDSceneImportPlugin
extends EditorImportPlugin

## PSD Scene Importer v2.0 — exports Photoshop layers to PNG textures and Godot UI scenes.
##
## Supports three import modes:
##   - ByLayerAndScene: Export per-layer PNG + generate Control scene
##   - ByLayer: Export per-layer PNG only
##   - Merged: Export a single merged PNG
##
## New features (v2.0):
##   - Hierarchical scene generation (generate_hierarchy)
##   - TySh text engine parsing -> Label nodes (text_layer_behavior)
##   - UI node type naming mapping (ui_node_mapping_enabled)
##   - NinePatchRect 9-slice support (nine_slice_enabled)
##   - Layer mask handling strategy (layer_mask_handling)

const PhotoshopDocumentResource := preload("res://addons/FromLan_PSD_Importer/photoshop_document.gd")
const PSDParserClass := preload("res://addons/FromLan_PSD_Importer/psd_parser.gd")
const SceneBuilderClass := preload("res://addons/FromLan_PSD_Importer/scene_builder.gd")
const LayerTreeBuilderClass := preload("res://addons/FromLan_PSD_Importer/layer_tree.gd")
const UINodeMapperClass := preload("res://addons/FromLan_PSD_Importer/ui_node_mapper.gd")
const NineSliceProcessorClass := preload("res://addons/FromLan_PSD_Importer/nine_slice_processor.gd")
const PSDImportCoreClass := preload("res://addons/FromLan_PSD_Importer/psd_import_core.gd")

#region EditorImportPlugin Overrides

## Return the importer's unique name.
func _get_importer_name() -> String:
	return "four_sided_hut.psd_scene_importer"

## Return the visible name shown in the Import dock.
func _get_visible_name() -> String:
	return "Photoshop Document Layers + Control Scene"

## Declare that this importer recognizes PSD files.
func _get_recognized_extensions() -> PackedStringArray:
	return ["psd"]

## Return the save extension for import record resources.
func _get_save_extension() -> String:
	return "tres"

## Return the Godot resource type name for import records.
func _get_resource_type() -> String:
	return "PhotoshopDocument"

## Return import order; keeping default is fine.
func _get_import_order() -> int:
	return 0

## Return number of presets.
func _get_preset_count() -> int:
	return 0

## Return preset name.
func _get_preset_name(_preset_index: int) -> String:
	return ""

## Return importer priority to ensure custom PSD importer takes precedence.
func _get_priority() -> float:
	return 1.0

#endregion

#region Import Options

## Control Import dock option visibility based on current import mode.
func _get_option_visibility(_path: String, option_name: StringName, options: Dictionary) -> bool:
	var import_mode := int(options["import_mode"]) as PSDImportCoreClass.Mode
	var is_layer_mode := import_mode != PSDImportCoreClass.Mode.Merged
	var is_scene_mode := import_mode == PSDImportCoreClass.Mode.ByLayerAndScene
	var use_hierarchy: bool = is_scene_mode && options.get("generate_hierarchy", false) == true
	var use_nine_slice: bool = use_hierarchy && options.get("nine_slice_enabled", false) == true

	match option_name:
		# Always visible
		"import_mode", "old_resource_handling", "max_png_dimension":
			return true
		# Visible only in layer mode
		"layer_name_encoding", "layer_trim_enabled", "layer_mask_handling", "layer_resource_naming", "group_export_behavior", "duplicate_handling":
			return is_layer_mode
		# Conditional visibility: group sub-options
		"group_subdir_naming":
			return is_layer_mode && options["group_export_behavior"] == PSDImportCoreClass.GroupExportBehavior.SubDirectories
		"group_flat_naming":
			return is_layer_mode && options["group_export_behavior"] == PSDImportCoreClass.GroupExportBehavior.Flattened
		"duplicate_rename_pattern":
			return is_layer_mode && options["duplicate_handling"] == PSDImportCoreClass.DuplicateHandling.Rename
		# Phase 2: Hierarchy generation
		"generate_hierarchy":
			return is_scene_mode
		# Phase 2: Hierarchy sub-options
		"hierarchy_group_node", "root_anchor_mode", "text_layer_behavior", "ui_node_mapping_enabled":
			return use_hierarchy
		# Phase 5: Nine-slice sub-options
		"nine_slice_enabled":
			return use_hierarchy
		"nine_slice_default_margin":
			return use_nine_slice
		_:
			return is_layer_mode

## Define PSD import options and their default values.
func _get_import_options(_path: String, _preset_index: int) -> Array[Dictionary]:
	return [
		# === Core ===
		{
			"name": "import_mode",
			"default_value": PSDImportCoreClass.Mode.ByLayerAndScene,
			"property_hint": PROPERTY_HINT_ENUM,
			"hint_string": PSDImportCoreClass._get_enum_selections(PSDImportCoreClass.Mode),
		},
		# === Layer Processing ===
		{
			"name": "layer_name_encoding",
			"default_value": PSDImportCoreClass.LayerNameEncoding.Utf8,
			"property_hint": PROPERTY_HINT_ENUM,
			"hint_string": PSDImportCoreClass._get_enum_selections(PSDImportCoreClass.LayerNameEncoding),
		},
		{
			"name": "layer_trim_enabled",
			"default_value": true,
		},
		{
			"name": "layer_mask_handling",
			"default_value": PSDImportCoreClass.LayerMaskHandling.Error,
			"property_hint": PROPERTY_HINT_ENUM,
			"hint_string": PSDImportCoreClass._get_enum_selections(PSDImportCoreClass.LayerMaskHandling),
		},
		# === Scene Generation (v2.0) ===
		{
			"name": "generate_hierarchy",
			"default_value": false,
		},
		{
			"name": "hierarchy_group_node",
			"default_value": PSDImportCoreClass.HierarchyGroupNodeType.Control,
			"property_hint": PROPERTY_HINT_ENUM,
			"hint_string": PSDImportCoreClass._get_enum_selections(PSDImportCoreClass.HierarchyGroupNodeType),
		},
		{
			"name": "root_anchor_mode",
			"default_value": PSDImportCoreClass.RootAnchorMode.Fixed,
			"property_hint": PROPERTY_HINT_ENUM,
			"hint_string": PSDImportCoreClass._get_enum_selections(PSDImportCoreClass.RootAnchorMode),
		},
		{
			"name": "text_layer_behavior",
			"default_value": PSDImportCoreClass.TextLayerBehavior.Rasterize,
			"property_hint": PROPERTY_HINT_ENUM,
			"hint_string": PSDImportCoreClass._get_enum_selections(PSDImportCoreClass.TextLayerBehavior),
		},
		{
			"name": "ui_node_mapping_enabled",
			"default_value": false,
		},
		{
			"name": "nine_slice_enabled",
			"default_value": false,
		},
		{
			"name": "nine_slice_default_margin",
			"default_value": 8,
			"property_hint": PROPERTY_HINT_RANGE,
			"hint_string": "1,64,1",
		},
		{
			"name": "max_png_dimension",
			"default_value": 0,
			"property_hint": PROPERTY_HINT_RANGE,
			"hint_string": "0,8192,1",
		},
		# === Resource Naming ===
		{
			"name": "layer_resource_naming",
			"default_value": "<file>__<layer>",
		},
		{
			"name": "group_export_behavior",
			"default_value": PSDImportCoreClass.GroupExportBehavior.Flattened,
			"property_hint": PROPERTY_HINT_ENUM,
			"hint_string": PSDImportCoreClass._get_enum_selections(PSDImportCoreClass.GroupExportBehavior),
		},
		{
			"name": "group_subdir_naming",
			"default_value": "<group>",
		},
		{
			"name": "group_flat_naming",
			"default_value": "<file>__<group>__<layer>",
		},
		{
			"name": "duplicate_handling",
			"default_value": PSDImportCoreClass.DuplicateHandling.Rename,
			"property_hint": PROPERTY_HINT_ENUM,
			"hint_string": PSDImportCoreClass._get_enum_selections(PSDImportCoreClass.DuplicateHandling),
		},
		{
			"name": "duplicate_rename_pattern",
			"default_value": "<name>__<n>",
		},
		# === Advanced ===
		{
			"name": "old_resource_handling",
			"default_value": PSDImportCoreClass.OldResourceHandling.Unlink,
			"property_hint": PROPERTY_HINT_ENUM,
			"hint_string": PSDImportCoreClass._get_enum_selections(PSDImportCoreClass.OldResourceHandling),
		},
		{
			"name": "perform_ownership_analysis",
			"default_value": false,
		},
	]

#endregion

#region Main Import

## Minimal import: create a placeholder import record (with timestamp).
## Full import (PNG generation, scene building) is triggered via the PSD Importer dock.
func _import(source_file: String, save_path: String, options: Dictionary, _platform_variants: Array[String], gen_files: Array[String]) -> Error:
	return PSDImportCoreClass.import_lightweight(source_file, save_path, gen_files)

#endregion

#region Old Resource Cleanup

## Clean up old resource files (delete or unlink).
func _cleanup_old_resources(
	old_resource_file_names: Array[String],
	old_resource_handling: PSDImportCoreClass.OldResourceHandling,
	source_file: String,
	source_file_dir: String,
	editor_fs: EditorFileSystem,
	project_resources_owner_map: Dictionary,
) -> void:
	var delete_old := old_resource_handling == PSDImportCoreClass.OldResourceHandling.Delete
	var color := ""
	if delete_old:
		print_rich("[color=tomato]The following resources are no longer a part of the original file and have been deleted after the PSD update:")
		color = "[color=light_salmon]"
	else:
		print_rich("[color=yellow]The following resources are no longer a part of the original file after the PSD update:")
		color = "[color=gold]"
	var deleted_dirs: Dictionary = {} # String -> bool
	for old_resource_file_name: String in old_resource_file_names:
		var resource_path := source_file.get_base_dir().path_join(old_resource_file_name)
		var import_path := resource_path + ".import"
		if delete_old:
			var remove_result := OS.move_to_trash(ProjectSettings.globalize_path(resource_path))
			if remove_result != OK:
				push_error("Unable to delete the resource %s: %s" % [resource_path, remove_result])
			else:
				# Also delete the corresponding .import file to avoid leftover import config
				if FileAccess.file_exists(import_path):
					OS.move_to_trash(ProjectSettings.globalize_path(import_path))
				editor_fs.update_file(resource_path)
				print_rich("%s  x %s" % [color, resource_path])
				var dir_path := resource_path.get_base_dir()
				if dir_path != source_file_dir:
					deleted_dirs[dir_path] = true
		else:
			# Unlink mode: keep resource file but remove .import to prevent Godot re-importing
			if FileAccess.file_exists(import_path):
				DirAccess.remove_absolute(import_path)
				editor_fs.update_file(import_path)
			print_rich("%s  - %s" % [color, resource_path])
		if !project_resources_owner_map.has(resource_path):
			continue
		for owner: String in (project_resources_owner_map[resource_path] as Array[String]):
			if owner == source_file:
				continue
			print_rich("%s      - %s is affected" % [color, owner])

	if delete_old:
		var dirs_to_clean := deleted_dirs.keys()
		dirs_to_clean.sort()
		dirs_to_clean.reverse()
		for dir_path: String in dirs_to_clean:
			var d := DirAccess.open(dir_path)
			if d && d.get_files().size() == 0 && d.get_directories().size() == 0:
				DirAccess.remove_absolute(dir_path)
				print_rich("%s  x %s (empty directory removed)" % [color, dir_path])

#endregion

#region Helpers

const DEBUG_OWNERSHIP := false

## Recursively scan project resource dependencies for impact reporting on reimport.
static func _build_project_resources_owner_map(efsd: EditorFileSystemDirectory, map: Dictionary) -> void:
	if !efsd:
		return
	for i: int in efsd.get_subdir_count():
		_build_project_resources_owner_map(efsd.get_subdir(i), map)
	for i: int in efsd.get_file_count():
		var path := efsd.get_file_path(i)
		if !ResourceLoader.exists(path):
			continue
		@warning_ignore("integer_division")
		if DEBUG_OWNERSHIP and map.size() % 100 == 0:
			print_rich("[color=dim_gray]  Ownership scan: %d files processed[/color]" % map.size())
		var dependencies := ResourceLoader.get_dependencies(path)
		for dependency: String in dependencies:
			(map.get_or_add(dependency.get_slice("::", 2), []) as Array[String]).append(path)

#endregion
