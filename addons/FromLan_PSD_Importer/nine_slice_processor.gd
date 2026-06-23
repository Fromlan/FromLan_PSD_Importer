class_name NineSliceProcessor
extends RefCounted

## NinePatchRect 九宫格处理器。
## 从命名约定参数或配套图层中解析九宫格边距。

#region Public API

## 从 extra_properties 中解析九宫格边距。
## [param extra_props] 从 [9Patch,key:val,...] 标签中提取的额外属性。
## [param default_margin] 未指定边距时的默认值。
## 返回 Dictionary: {left, right, top, bottom}，均为 int。
static func parse_margins_from_props(extra_props: Dictionary, default_margin: int) -> Dictionary:
	var margins := {
		"left": default_margin,
		"right": default_margin,
		"top": default_margin,
		"bottom": default_margin,
	}

	# 统一 margin 覆盖所有边
	if extra_props.has("margin"):
		var m := _parse_int(extra_props["margin"], default_margin)
		margins["left"] = m
		margins["right"] = m
		margins["top"] = m
		margins["bottom"] = m

	# 单独边距覆盖
	if extra_props.has("l") or extra_props.has("left"):
		margins["left"] = _parse_int(extra_props.get("l", extra_props.get("left", "")), margins["left"])
	if extra_props.has("r") or extra_props.has("right"):
		margins["right"] = _parse_int(extra_props.get("r", extra_props.get("right", "")), margins["right"])
	if extra_props.has("t") or extra_props.has("top"):
		margins["top"] = _parse_int(extra_props.get("t", extra_props.get("top", "")), margins["top"])
	if extra_props.has("b") or extra_props.has("bottom"):
		margins["bottom"] = _parse_int(extra_props.get("b", extra_props.get("bottom", "")), margins["bottom"])

	return margins

## 从配套图层检测九宫格边距。
## 配套图层命名约定: <layer_name>__9L / __9R / __9T / __9B
## [param layer_name] 主图层名称。
## [param all_entries] 所有导入条目。
## 返回 Dictionary 或空字典（无配套图层时）。
static func detect_companion_margins(layer_name: String, all_entries: Array[Dictionary]) -> Dictionary:
	var margins := {
		"left": -1,
		"right": -1,
		"top": -1,
		"bottom": -1,
	}
	var companion_suffixes := {
		"__9L": "left",
		"__9R": "right",
		"__9T": "top",
		"__9B": "bottom",
	}
	var found_any := false
	for entry: Dictionary in all_entries:
		var img_data: ImageData = entry["image_data"]
		if img_data == null:
			continue
		for suffix: String in companion_suffixes:
			if img_data.name == layer_name + suffix:
				var dim_key: String = companion_suffixes[suffix]
				if dim_key == "left" or dim_key == "right":
					margins[dim_key] = img_data.image.get_width()
				else:
					margins[dim_key] = img_data.image.get_height()
				found_any = true
	if !found_any:
		return {}
	return margins

## 判断一个图层是否为配套九宫格图层（应在场景中隐藏）。
static func is_companion_layer(layer_name: String) -> bool:
	var companion_suffixes := ["__9L", "__9R", "__9T", "__9B"]
	for suffix: String in companion_suffixes:
		if layer_name.ends_with(suffix):
			return true
	return false

#endregion

#region Helpers

## 安全解析字符串为整数，失败时返回默认值。
static func _parse_int(s: String, default: int) -> int:
	var cleaned := s.strip_edges()
	if cleaned.is_valid_int():
		return cleaned.to_int()
	return default

#endregion
