@tool
extends VBoxContainer

## PSD Importer side dock panel — UI scene loaded inside EditorDock.
## Handles: scanning project PSD files, configuring import options, triggering batch imports.

const PSDImportCoreClass := preload("res://addons/FromLan_PSD_Importer/psd_import_core.gd")
const PSDParserClass := preload("res://addons/FromLan_PSD_Importer/psd_parser.gd")
const PluginTranslation := preload("res://addons/FromLan_PSD_Importer/plugin_translation.gd")

#region Node References

@onready var _refresh_btn: Button = $Toolbar/RefreshBtn
@onready var _select_all_btn: Button = $Toolbar/SelectAllBtn
@onready var _deselect_all_btn: Button = $Toolbar/DeselectAllBtn
@onready var _import_btn: Button = $Toolbar/ImportBtn
@onready var _file_list: VBoxContainer = $FileScroll/FileList
@onready var _toggle_options_btn: Button = $OptionsHeader/ToggleOptionsBtn
@onready var _options_panel: VBoxContainer = $OptionsPanel
@onready var _status_label: Label = $StatusBar/StatusLabel
@onready var _progress_bar: ProgressBar = $StatusBar/ProgressBar

#endregion

#region State

## Current import options, initialized to defaults.
var current_options: Dictionary = {}
## File path -> CheckBox mapping.
var _file_checkboxes: Dictionary = {}
## Editor plugin reference.
var _editor_plugin: EditorPlugin = null
## Whether options panel is expanded.
var _options_expanded: bool = true
## Option row container references (for visibility linking).
var _option_rows: Dictionary = {}
## Import-in-progress flag to prevent re-entry.
var _importing: bool = false

#endregion

#region Lifecycle

## Save editor plugin reference (called by plugin.gd right after instantiate).
func initialize(editor_plugin: EditorPlugin) -> void:
	_editor_plugin = editor_plugin

## Initialize UI and signals on scene tree entry.
func _ready() -> void:
	current_options = PSDImportCoreClass.get_default_options()

	# Set translated button and label texts
	_refresh_btn.text = PluginTranslation.translate("BTN_REFRESH")
	_select_all_btn.text = PluginTranslation.translate("BTN_SELECT_ALL")
	_deselect_all_btn.text = PluginTranslation.translate("BTN_DESELECT_ALL")
	_import_btn.text = PluginTranslation.translate("BTN_IMPORT_SELECTED")
	_toggle_options_btn.text = PluginTranslation.translate("BTN_TOGGLE_OPTIONS")
	$OptionsHeader/OptionsTitle.text = PluginTranslation.translate("LBL_IMPORT_OPTIONS")
	_status_label.text = PluginTranslation.translate("LBL_READY")

	# Connect button signals
	_refresh_btn.pressed.connect(_on_refresh_pressed)
	_select_all_btn.pressed.connect(_on_select_all_pressed)
	_deselect_all_btn.pressed.connect(_on_deselect_all_pressed)
	_import_btn.pressed.connect(_on_import_pressed)
	_toggle_options_btn.pressed.connect(_on_toggle_options_pressed)

	# Build options panel
	_build_option_rows()
	_refresh_option_visibility()

	# Initial file list refresh
	_refresh_file_list.call_deferred()

## Clean up signal connections.
func cleanup() -> void:
	if _refresh_btn and _refresh_btn.pressed.is_connected(_on_refresh_pressed):
		_refresh_btn.pressed.disconnect(_on_refresh_pressed)
	if _select_all_btn and _select_all_btn.pressed.is_connected(_on_select_all_pressed):
		_select_all_btn.pressed.disconnect(_on_select_all_pressed)
	if _deselect_all_btn and _deselect_all_btn.pressed.is_connected(_on_deselect_all_pressed):
		_deselect_all_btn.pressed.disconnect(_on_deselect_all_pressed)
	if _import_btn and _import_btn.pressed.is_connected(_on_import_pressed):
		_import_btn.pressed.disconnect(_on_import_pressed)
	if _toggle_options_btn and _toggle_options_btn.pressed.is_connected(_on_toggle_options_pressed):
		_toggle_options_btn.pressed.disconnect(_on_toggle_options_pressed)
	_editor_plugin = null

#endregion

#region File List

## Scan the project filesystem and refresh the PSD file list.
func _refresh_file_list() -> void:
	# Clear existing list
	for child: Node in _file_list.get_children():
		child.queue_free()
	_file_checkboxes.clear()

	# Get editor filesystem
	var ed_iface = _get_editor_interface()
	if ed_iface == null:
		_update_status(PluginTranslation.translate("STATUS_NO_EDITOR_INTERFACE"), true)
		return

	var editor_fs = ed_iface.get_resource_filesystem()
	if editor_fs == null:
		_update_status(PluginTranslation.translate("STATUS_NO_EDITOR_FS"), true)
		return

	# Recursively scan .psd files
	var psd_paths := _find_psd_files(editor_fs.get_filesystem())
	psd_paths.sort()

	if psd_paths.is_empty():
		var empty_label := Label.new()
		empty_label.text = PluginTranslation.translate("STATUS_EMPTY_LIST")
		empty_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		_file_list.add_child(empty_label)
		_update_status(PluginTranslation.translate("STATUS_NO_PSD_FILES"))
		return

	# Create a checkbox row for each PSD file
	for psd_path in psd_paths:
		var row := HBoxContainer.new()
		row.size_flags_horizontal = SIZE_EXPAND_FILL

		var check := CheckBox.new()
		check.name = "CheckBox"
		_file_checkboxes[psd_path] = check
		row.add_child(check)

		var label := Label.new()
		label.text = psd_path.trim_prefix("res://")
		label.size_flags_horizontal = SIZE_EXPAND_FILL
		label.mouse_filter = Control.MOUSE_FILTER_PASS
		row.add_child(label)

		_file_list.add_child(row)

	_update_status(PluginTranslation.translate("STATUS_FOUND_PSD_FILES") % psd_paths.size())

## Recursively find all .psd files.
func _find_psd_files(dir: EditorFileSystemDirectory) -> PackedStringArray:
	var results: PackedStringArray = []
	for i: int in range(dir.get_file_count()):
		var path: String = dir.get_file_path(i)
		if path.get_extension().to_lower() == "psd":
			results.append(path)
	for i: int in range(dir.get_subdir_count()):
		results.append_array(_find_psd_files(dir.get_subdir(i)))
	return results

## Get list of selected PSD file paths.
func _get_selected_files() -> PackedStringArray:
	var selected: PackedStringArray = []
	for path: String in _file_checkboxes:
		var check := _file_checkboxes[path] as CheckBox
		if check.button_pressed:
			selected.append(path)
	return selected

#endregion

#region Import

## Execute import for selected files.
func _on_import_pressed() -> void:
	if _importing:
		_update_status(PluginTranslation.translate("STATUS_IMPORT_IN_PROGRESS"), true)
		return

	var selected := _get_selected_files()
	if selected.is_empty():
		_update_status(PluginTranslation.translate("STATUS_SELECT_FILES"), true)
		return

	_importing = true
	_import_btn.disabled = true
	_progress_bar.visible = true
	_progress_bar.max_value = selected.size()
	_progress_bar.value = 0

	var total_generated := 0
	var error_count := 0

	for i: int in range(selected.size()):
		var psd_path: String = selected[i]
		_update_status(PluginTranslation.translate("STATUS_IMPORTING") % [psd_path.get_file(), i + 1, selected.size()])

		var result := await _import_single_file(psd_path)
		if result:
			total_generated += result["gen_files"].size()
		else:
			error_count += 1

		_progress_bar.value = i + 1
		# Allow UI to update, preventing editor freezing on large files
		await get_tree().process_frame

	# Refresh filesystem
	var ed_iface = _get_editor_interface()
	if ed_iface != null:
		var editor_fs = ed_iface.get_resource_filesystem()
		if editor_fs != null:
			editor_fs.call_deferred(&"scan")

	if error_count == 0:
		_update_status(PluginTranslation.translate("STATUS_IMPORT_COMPLETE") % [selected.size(), total_generated])
	else:
		_update_status(PluginTranslation.translate("STATUS_IMPORT_PARTIAL") % [selected.size() - error_count, error_count], error_count > 0)

	_importing = false
	_import_btn.disabled = false
	_progress_bar.visible = false

## Import a single PSD file.
## Returns the result dictionary, or an empty dictionary on failure.
func _import_single_file(psd_path: String) -> Dictionary:
	# Read .import file for save_path
	var import_file_path := psd_path + ".import"
	var save_path: String = ""
	if FileAccess.file_exists(import_file_path):
		var cfg := ConfigFile.new()
		var err := cfg.load(import_file_path)
		if err == OK:
			var dest_path: String = cfg.get_value("remap", "path", "")
			if dest_path != "" and dest_path.ends_with(".tres"):
				save_path = dest_path.trim_suffix(".tres")

	if save_path == "":
		# Fallback: construct save_path
		var source_file_name := psd_path.get_basename().get_file()
		save_path = psd_path.get_base_dir().path_join(source_file_name) + ".tres"
		save_path = save_path.trim_suffix(".tres")

	# Set progress callback
	PSDParserClass.progress_callback = func(current: int, total: int) -> void:
		_update_status(PluginTranslation.translate("STATUS_PARSING") % [psd_path.get_file(), current, total])

	# Call async import (yields process_frame every 3 layers internally)
	var result := await PSDImportCoreClass.import_full_async(psd_path, save_path, current_options, self)
	if result.is_empty():
		return {}

	# Check if import succeeded
	if result.get("error", Error.FAILED) != OK:
		push_error("Import failed: %s" % psd_path)
		return {}

	# Yield to main thread to keep UI responsive
	await get_tree().process_frame
	# Clear progress callback
	PSDParserClass.progress_callback = Callable()

	# Refresh editor filesystem
	var ed_iface = _get_editor_interface()
	if ed_iface != null:
		var editor_fs = ed_iface.get_resource_filesystem()
		if editor_fs != null:
			for gen_file: String in result.get("gen_files", []):
				editor_fs.update_file(gen_file)

	# Print result summary
	var gen_files: Array = result.get("gen_files", [])
	print_rich("[color=cyan]%s: %s -> %d files generated[/color]" % [PluginTranslation.translate("PLUGIN_NAME"), psd_path.get_file(), gen_files.size()])

	return result

#endregion

#region Options Panel

## Dynamically build all import option rows.
func _build_option_rows() -> void:
	# Clear existing rows
	for child: Node in _options_panel.get_children():
		child.queue_free()
	_option_rows.clear()

	# Import mode
	_add_enum_option("import_mode", PluginTranslation.translate("OPT_IMPORT_MODE"), [PluginTranslation.translate("VAL_BY_LAYER_AND_SCENE"), PluginTranslation.translate("VAL_BY_LAYER"), PluginTranslation.translate("VAL_MERGED")])
	# Layer name encoding
	_add_enum_option("layer_name_encoding", PluginTranslation.translate("OPT_LAYER_NAME_ENCODING"), [PluginTranslation.translate("VAL_UTF8"), PluginTranslation.translate("VAL_GBK")])
	# Trim transparent edges
	_add_bool_option("layer_trim_enabled", PluginTranslation.translate("OPT_LAYER_TRIM"))
	# Layer mask handling
	_add_enum_option("layer_mask_handling", PluginTranslation.translate("OPT_LAYER_MASK"), [PluginTranslation.translate("VAL_ERROR"), PluginTranslation.translate("VAL_SKIP"), PluginTranslation.translate("VAL_APPLY")])
	# Resource naming template
	_add_string_option("layer_resource_naming", PluginTranslation.translate("OPT_RESOURCE_NAMING"), "<file>__<layer>")
	# Group export behavior
	_add_enum_option("group_export_behavior", PluginTranslation.translate("OPT_GROUP_EXPORT"), [PluginTranslation.translate("VAL_IGNORE"), PluginTranslation.translate("VAL_SUB_DIR"), PluginTranslation.translate("VAL_FLAT")])
	# Sub-directory naming
	_add_string_option("group_subdir_naming", PluginTranslation.translate("OPT_GROUP_SUBDIR"), "<group>")
	# Flat naming
	_add_string_option("group_flat_naming", PluginTranslation.translate("OPT_GROUP_FLAT"), "<file>__<group>__<layer>")
	# Duplicate handling
	_add_enum_option("duplicate_handling", PluginTranslation.translate("OPT_DUPLICATE"), [PluginTranslation.translate("VAL_RENAME"), PluginTranslation.translate("VAL_KEEP_FIRST"), PluginTranslation.translate("VAL_KEEP_LAST")])
	# Rename pattern
	_add_string_option("duplicate_rename_pattern", PluginTranslation.translate("OPT_DUPLICATE_RENAME"), "<name>__<n>")
	# Hierarchy generation
	_add_bool_option("generate_hierarchy", PluginTranslation.translate("OPT_GENERATE_HIERARCHY"))
	# Group node type
	_add_enum_option("hierarchy_group_node", PluginTranslation.translate("OPT_HIERARCHY_GROUP_NODE"), [PluginTranslation.translate("VAL_CONTROL"), PluginTranslation.translate("VAL_PANEL"), PluginTranslation.translate("VAL_PANEL_CONTAINER")])
	# Root anchor mode
	_add_enum_option("root_anchor_mode", PluginTranslation.translate("OPT_ROOT_ANCHOR"), [PluginTranslation.translate("VAL_FIXED"), PluginTranslation.translate("VAL_FULL_RECT")])
	# Text layer behavior
	_add_enum_option("text_layer_behavior", PluginTranslation.translate("OPT_TEXT_LAYER"), [PluginTranslation.translate("VAL_RASTERIZE"), PluginTranslation.translate("VAL_LABEL"), PluginTranslation.translate("VAL_RICH_TEXT_LABEL")])
	# UI node mapping
	_add_bool_option("ui_node_mapping_enabled", PluginTranslation.translate("OPT_UI_MAPPING"))
	# Nine-slice
	_add_bool_option("nine_slice_enabled", PluginTranslation.translate("OPT_NINE_SLICE"))
	# Nine-slice default margin
	_add_int_option("nine_slice_default_margin", PluginTranslation.translate("OPT_NINE_SLICE_MARGIN"), 1, 64)
	# PNG size limit
	_add_int_option("max_png_dimension", PluginTranslation.translate("OPT_MAX_PNG"), 0, 8192)
	# Old resource handling
	_add_enum_option("old_resource_handling", PluginTranslation.translate("OPT_OLD_RESOURCE"), [PluginTranslation.translate("VAL_UNLINK"), PluginTranslation.translate("VAL_DELETE")])
	# Ownership analysis
	_add_bool_option("perform_ownership_analysis", PluginTranslation.translate("OPT_OWNERSHIP_ANALYSIS"))

## Add an enum-type option row.
func _add_enum_option(key: String, label_text: String, values: PackedStringArray) -> void:
	var row := HBoxContainer.new()
	row.name = "Row_%s" % key
	row.size_flags_horizontal = SIZE_EXPAND_FILL

	var label := Label.new()
	label.text = label_text + ":"
	label.custom_minimum_size = Vector2(140, 0)
	label.mouse_filter = Control.MOUSE_FILTER_PASS
	row.add_child(label)

	var option := OptionButton.new()
	option.name = "Control"
	option.size_flags_horizontal = SIZE_EXPAND_FILL
	for v: String in values:
		option.add_item(v)
	# Set current value
	var default_val: int = current_options.get(key, 0)
	option.select(default_val)
	option.item_selected.connect(_on_option_selected.bind(key))
	row.add_child(option)

	_options_panel.add_child(row)
	_option_rows[key] = row

## Add a bool-type option row.
func _add_bool_option(key: String, label_text: String) -> void:
	var row := HBoxContainer.new()
	row.name = "Row_%s" % key
	row.size_flags_horizontal = SIZE_EXPAND_FILL

	var check := CheckBox.new()
	check.name = "Control"
	check.text = label_text
	var default_val: bool = current_options.get(key, false)
	check.button_pressed = default_val
	check.toggled.connect(_on_bool_toggled.bind(key))
	row.add_child(check)

	_options_panel.add_child(row)
	_option_rows[key] = row

## Add a string-type option row.
func _add_string_option(key: String, label_text: String, default_val: String) -> void:
	var row := HBoxContainer.new()
	row.name = "Row_%s" % key
	row.size_flags_horizontal = SIZE_EXPAND_FILL

	var label := Label.new()
	label.text = label_text + ":"
	label.custom_minimum_size = Vector2(140, 0)
	label.mouse_filter = Control.MOUSE_FILTER_PASS
	row.add_child(label)

	var line_edit := LineEdit.new()
	line_edit.name = "Control"
	line_edit.size_flags_horizontal = SIZE_EXPAND_FILL
	line_edit.text = current_options.get(key, default_val)
	line_edit.text_changed.connect(_on_string_changed.bind(key))
	row.add_child(line_edit)

	_options_panel.add_child(row)
	_option_rows[key] = row

## Add an int-type option row (with range).
func _add_int_option(key: String, label_text: String, min_val: int, max_val: int) -> void:
	var row := HBoxContainer.new()
	row.name = "Row_%s" % key
	row.size_flags_horizontal = SIZE_EXPAND_FILL

	var label := Label.new()
	label.text = label_text + ":"
	label.custom_minimum_size = Vector2(140, 0)
	label.mouse_filter = Control.MOUSE_FILTER_PASS
	row.add_child(label)

	var spin := SpinBox.new()
	spin.name = "Control"
	spin.size_flags_horizontal = SIZE_EXPAND_FILL
	spin.min_value = min_val
	spin.max_value = max_val
	spin.value = current_options.get(key, 8)
	spin.value_changed.connect(_on_int_changed.bind(key))
	row.add_child(spin)

	_options_panel.add_child(row)
	_option_rows[key] = row

#endregion

#region Option Signal Handlers

## Enum option changed.
func _on_option_selected(index: int, key: String) -> void:
	current_options[key] = index
	_refresh_option_visibility()

## Bool option changed.
func _on_bool_toggled(pressed: bool, key: String) -> void:
	current_options[key] = pressed
	_refresh_option_visibility()

## String option changed.
func _on_string_changed(text: String, key: String) -> void:
	current_options[key] = text

## Int option changed.
func _on_int_changed(value: float, key: String) -> void:
	current_options[key] = int(value)

## Refresh option row visibility based on current import_mode.
func _refresh_option_visibility() -> void:
	var import_mode: int = current_options.get("import_mode", 0)
	var is_layer_mode := import_mode != 2  # not Merged
	var is_scene_mode := import_mode == 0  # ByLayerAndScene
	var use_hierarchy: bool = is_scene_mode and current_options.get("generate_hierarchy", false)
	var use_nine_slice: bool = use_hierarchy and current_options.get("nine_slice_enabled", false)

	# Define visibility rules for each option
	var visibility_rules := {
		"import_mode": true,
		"old_resource_handling": true,
		"layer_name_encoding": is_layer_mode,
		"layer_trim_enabled": is_layer_mode,
		"layer_mask_handling": is_layer_mode,
		"layer_resource_naming": is_layer_mode,
		"group_export_behavior": is_layer_mode,
		"group_subdir_naming": is_layer_mode and current_options.get("group_export_behavior", 0) == 1,
		"group_flat_naming": is_layer_mode and current_options.get("group_export_behavior", 0) == 2,
		"duplicate_handling": is_layer_mode,
		"duplicate_rename_pattern": is_layer_mode and current_options.get("duplicate_handling", 0) == 0,
		"generate_hierarchy": is_scene_mode,
		"hierarchy_group_node": use_hierarchy,
		"root_anchor_mode": is_scene_mode,
		"text_layer_behavior": use_hierarchy,
		"ui_node_mapping_enabled": use_hierarchy,
		"nine_slice_enabled": use_hierarchy,
		"nine_slice_default_margin": use_nine_slice,
		"perform_ownership_analysis": true,
	}

	for key: String in _option_rows:
		var row := _option_rows[key] as Control
		if row != null:
			row.visible = visibility_rules.get(key, true)

#endregion

#region Button Handlers

## Refresh button click.
func _on_refresh_pressed() -> void:
	_refresh_file_list()

## Select all button click.
func _on_select_all_pressed() -> void:
	for check: CheckBox in _file_checkboxes.values():
		check.button_pressed = true
	_update_status(PluginTranslation.translate("STATUS_SELECT_ALL") % _file_checkboxes.size())

## Deselect all button click.
func _on_deselect_all_pressed() -> void:
	for check: CheckBox in _file_checkboxes.values():
		check.button_pressed = false
	_update_status(PluginTranslation.translate("STATUS_DESELECT_ALL"))

## Toggle options panel collapse/expand.
func _on_toggle_options_pressed() -> void:
	_options_expanded = !_options_expanded
	_options_panel.visible = _options_expanded
	_toggle_options_btn.text = "▼" if _options_expanded else "▶"

#endregion

#region Helpers

## Get EditorInterface singleton.
func _get_editor_interface() -> EditorInterface:
	if _editor_plugin != null:
		return _editor_plugin.get_editor_interface()
	var ei = Engine.get_singleton("EditorInterface")
	if ei is EditorInterface:
		return ei
	return null


## Update status text.
func _update_status(message: String, is_error: bool = false) -> void:
	if _status_label == null:
		return
	_status_label.text = message
	if is_error:
		_status_label.add_theme_color_override("font_color", Color(1, 0.4, 0.4))
	else:
		_status_label.remove_theme_color_override("font_color")

#endregion
