class_name UINodeMapper
extends RefCounted

## UI 节点类型映射器。
## 通过 PSD 图层命名约定 `[Type]` 标签自动映射到对应的 Godot UI 节点类型。

#region Type Map

## 支持的 [Type] 标签 → Godot 节点类型映射表
const NODE_TYPE_MAP: Dictionary = {
	"Button": "Button",
	"Label": "Label",
	"Panel": "Panel",
	"PanelContainer": "PanelContainer",
	"Texture": "TextureRect",
	"TextureRect": "TextureRect",
	"9Patch": "NinePatchRect",
	"NinePatch": "NinePatchRect",
	"NinePatchRect": "NinePatchRect",
	"VBox": "VBoxContainer",
	"VBoxContainer": "VBoxContainer",
	"HBox": "HBoxContainer",
	"HBoxContainer": "HBoxContainer",
	"Margin": "MarginContainer",
	"MarginContainer": "MarginContainer",
	"Grid": "GridContainer",
	"GridContainer": "GridContainer",
	"Scroll": "ScrollContainer",
	"ScrollContainer": "ScrollContainer",
	"ColorRect": "ColorRect",
	"VSlider": "VSlider",
	"HSlider": "HSlider",
	"Progress": "ProgressBar",
	"ProgressBar": "ProgressBar",
	"RichText": "RichTextLabel",
	"RichTextLabel": "RichTextLabel",
	"CheckBox": "CheckBox",
	"LineEdit": "LineEdit",
	"TextEdit": "TextEdit",
	"HSeparator": "HSeparator",
	"VSeparator": "VSeparator",
}

## 容器类型的节点（需要特殊处理子节点布局）
const CONTAINER_TYPES: Array[String] = [
	"VBoxContainer", "HBoxContainer", "GridContainer",
	"MarginContainer", "ScrollContainer", "PanelContainer",
]

## Layout 类型的节点（不应被嵌套在 Container 中但可以包含子节点）
const LAYOUT_TYPES: Array[String] = [
	"Control", "Panel", "PanelContainer",
]

#endregion

#region Public API

## 解析图层名称，返回映射结果。
## [param full_name] PSD 图层原始名称。
## [param is_text_layer] 该图层是否含有 TySh 文本数据。
## 返回 Dictionary: {clean_name, node_type, type_tag, extra_properties, auto_detected}
static func parse_layer_name(full_name: String, is_text_layer: bool) -> Dictionary:
	var stripped := full_name.strip_edges()

	# 匹配模式：[TypeTag optional_params] rest_of_name
	if stripped.begins_with("[") and stripped.find("]") != -1:
		var bracket_close := stripped.find("]")
		var bracket_content := stripped.substr(1, bracket_close - 1)
		var clean_name := stripped.substr(bracket_close + 1).strip_edges()

		var parts := bracket_content.split(",", false)
		var type_tag := parts[0].strip_edges() if parts.size() > 0 else ""

		var extra_props: Dictionary = {}
		for i: int in range(1, parts.size()):
			var param_parts := parts[i].split(":", false, 1)
			var p_key := param_parts[0].strip_edges().to_lower() if param_parts.size() > 0 else ""
			var p_value := param_parts[1].strip_edges() if param_parts.size() > 1 else ""
			if p_key != "":
				extra_props[p_key] = p_value

		if NODE_TYPE_MAP.has(type_tag):
			return {
				"clean_name": clean_name if clean_name != "" else full_name,
				"node_type": NODE_TYPE_MAP[type_tag],
				"type_tag": type_tag,
				"extra_properties": extra_props,
				"auto_detected": false,
			}
		else:
			push_warning("Unknown node type tag '[%s]' in layer '%s', falling back to TextureRect" % [type_tag, full_name])

	# 自动检测：有 TySh 文本数据的图层 → Label
	if is_text_layer:
		return {
			"clean_name": stripped,
			"node_type": "Label",
			"type_tag": "",
			"extra_properties": {},
			"auto_detected": true,
		}

	# 默认
	return {
		"clean_name": stripped,
		"node_type": "TextureRect",
		"type_tag": "",
		"extra_properties": {},
		"auto_detected": false,
	}

## 判断给定节点类型是否为容器（可以有子节点）。
static func is_container_type(node_type: String) -> bool:
	return CONTAINER_TYPES.has(node_type) or LAYOUT_TYPES.has(node_type)

#endregion
