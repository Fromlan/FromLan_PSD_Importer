@tool
extends EditorPlugin

## Entry point for the PSD Scene Importer plugin.
## Registers EditorImportPlugin (for .psd recognition) and a side dock for manual imports.

const DockScene := preload("res://addons/FromLan_PSD_Importer/psd_importer_dock.tscn")
const PluginTranslation := preload("res://addons/FromLan_PSD_Importer/plugin_translation.gd")

var _import_plugin: PSDSceneImportPlugin
var _dock: EditorDock
var _dock_ui: Control

#region Lifecycle

## Register PSD importer and create the dock panel.
func _enter_tree() -> void:
	# Register EditorImportPlugin (.psd file recognition, minimal placeholder import)
	_import_plugin = PSDSceneImportPlugin.new()
	add_import_plugin(_import_plugin)

	# Initialize plugin translations
	PluginTranslation.init()

	# Create dock panel
	_dock_ui = DockScene.instantiate()
	_dock_ui.initialize(self)

	_dock = EditorDock.new()
	_dock.title = PluginTranslation.translate("PLUGIN_TITLE")
	_dock.default_slot = EditorDock.DOCK_SLOT_LEFT_BL
	_dock.add_child(_dock_ui)
	add_dock(_dock)

	# Listen to filesystem changes for auto-refresh
	var ed_iface := get_editor_interface()
	if ed_iface != null:
		var fs: EditorFileSystem = ed_iface.get_resource_filesystem()
		if fs != null:
			fs.filesystem_changed.connect(_on_filesystem_changed)

## Unregister PSD importer and remove the dock panel.
func _exit_tree() -> void:
	# Disconnect filesystem signal
	var ed_iface := get_editor_interface()
	if ed_iface != null:
		var fs: EditorFileSystem = ed_iface.get_resource_filesystem()
		if fs != null and fs.is_connected("filesystem_changed", _on_filesystem_changed):
			fs.filesystem_changed.disconnect(_on_filesystem_changed)

	# Remove dock panel
	if _dock != null:
		remove_dock(_dock)
		if _dock_ui != null and _dock_ui.has_method("cleanup"):
			_dock_ui.cleanup()
		_dock.queue_free()
		_dock = null
		_dock_ui = null

	# Remove import plugin
	if _import_plugin != null:
		remove_import_plugin(_import_plugin)
		_import_plugin = null

#endregion

#region Signal Handlers

## Refresh PSD file list when filesystem changes.
func _on_filesystem_changed() -> void:
	if _dock_ui != null and _dock_ui.has_method("_refresh_file_list"):
		_dock_ui._refresh_file_list()

#endregion
