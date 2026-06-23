@tool
## Plugin translation utility for the PSD Importer.
##
## Manages a custom TranslationDomain for editor-plugin UI strings,
## keeping plugin translations separate from the project's main translations.
## Uses .tres Translation resources loaded from the locales/ directory.
## Locale is synced with the Godot editor's current UI language.

const EN_TRANSLATION := preload("res://addons/FromLan_PSD_Importer/locales/en.tres")
const ZH_TRANSLATION := preload("res://addons/FromLan_PSD_Importer/locales/zh.tres")

## Custom domain name for this plugin's translations.
const DOMAIN_NAME := &"fromlan_psd_importer"

## Cached domain reference.
static var _domain: TranslationDomain = null

#region Initialization

## Initialize the plugin translation domain.
## Must be called once from plugin.gd _enter_tree().
static func init() -> void:
	_domain = TranslationServer.get_or_add_domain(DOMAIN_NAME)
	_domain.add_translation(EN_TRANSLATION)
	_domain.add_translation(ZH_TRANSLATION)
	_auto_set_locale()

## Sync the domain locale with the editor UI language.
## Call this when the editor language changes at runtime.
static func _auto_set_locale() -> void:
	if _domain == null:
		return
	var tool_locale: String = TranslationServer.get_tool_locale()
	if tool_locale != "":
		_domain.set_locale_override(tool_locale)

#endregion

#region Translation Lookup

## Translate a key using the plugin's custom translation domain.
## Falls back to the key itself if no translation is found.
static func translate(key: String, context: String = "") -> String:
	if _domain == null:
		return key
	var result: StringName = _domain.translate(StringName(key), StringName(context))
	if result == StringName():
		return key
	return str(result)

#endregion
