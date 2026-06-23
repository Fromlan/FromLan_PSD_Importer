class_name TyShParser
extends RefCounted

## PSD TySh (Type Tool Sheet) 文本引擎数据解析器。
## 从图层附加信息 TySh 块中提取文本内容、字体、颜色、对齐等属性。

#region TyShData

class TyShData extends RefCounted:
	## TySh 解析结果，包含文本图层的所有可提取属性。
	var text: String = ""
	var font_size: float = 14.0
	var font_name: String = ""
	var font_color: Color = Color.WHITE
	var alignment: int = 0
	var faux_bold: bool = false
	var faux_italic: bool = false
	var leading: float = 0.0
	var tracking: float = 0.0
	var transform: Transform2D
	var bounds: Rect2i = Rect2i()
	var is_valid: bool = false

#endregion

#region Main Parse Method

## 解析 TySh 块数据，返回 TyShData。
## reader 参数为 BigEndieanReader 实例（无类型注解以避免循环依赖）。
static func parse_ty_sh(reader, data_length: int) -> TyShData:
	var result: TyShData = TyShData.new()
	var start_pos: int = reader.get_position()
	var end_pos: int = start_pos + data_length

	# 1. 读取版本号
	var version: int = reader.get_u16()
	if version != 1:
		reader.seek(end_pos)
		return result

	# 2. 读取变换矩阵（6 × float64）
	var xx: float = reader.get_f64()
	var xy: float = reader.get_f64()
	var yx: float = reader.get_f64()
	var yy: float = reader.get_f64()
	var tx: float = reader.get_f64()
	var ty: float = reader.get_f64()
	result.transform = Transform2D(Vector2(xx, yx), Vector2(xy, yy), Vector2(tx, ty))

	# 3. 读取文本描述符版本
	var desc_version: int = reader.get_u16()
	if desc_version != 50 and desc_version != 16:
		reader.seek(end_pos)
		return result

	# 4. 解析文本引擎数据描述符
	var descriptor_version: int = reader.get_u32()
	if descriptor_version != 16:
		reader.seek(end_pos)
		return result

	# 跳过描述符名称
	_skip_descriptor_name(reader, end_pos)

	# 读取 classID
	var class_id: String = reader.get_ascii(4)

	# 读取条目数量
	var item_count: int = reader.get_u32()

	# 遍历描述符条目
	for _item_idx in range(item_count):
		# 边界保护：至少需要 key_id (4) + type_id (4) 才能继续
		if reader.get_position() + 8 > end_pos:
			break
		_skip_descriptor_name(reader, end_pos)
		var key_id: String = reader.get_ascii(4)
		var type_id: String = reader.get_ascii(4)

		match key_id:
			"Txt ":
				result.text = _read_unicode_string(reader, end_pos)
				result.is_valid = result.text.length() > 0
			"EngineData":
				if type_id == "TEXT":
					var engine_str: String = _read_unicode_string(reader, end_pos)
					if engine_str.length() > 0:
						_parse_engine_data_string(engine_str, result)
				else:
					_skip_descriptor_value(reader, type_id, end_pos)
			_:
				_skip_descriptor_value(reader, type_id, end_pos)

	# 确保不超过 end_pos
	reader.seek(end_pos)
	return result

#endregion

#region EngineData String Parser

## 解析 EngineData 标记语言字符串，提取样式和段落信息。
static func _parse_engine_data_string(engine_str: String, result: TyShData) -> void:
	# EngineData 使用类似 PostScript 的标记语法：<< /Key value /Key2 value >>
	var current_pos: int = 0

	while current_pos < engine_str.length():
		var tag_start: int = engine_str.find("/", current_pos)
		if tag_start == -1:
			break

		# 找到标记名
		var tag_end: int = engine_str.find(" ", tag_start)
		var value_start: int = 0
		if tag_end == -1:
			break
		var tag_name: String = engine_str.substr(tag_start + 1, tag_end - tag_start - 1)

		match tag_name:
			"FontSize":
				value_start = _skip_whitespace(engine_str, tag_end)
				var font_size_str: String = _extract_number_string(engine_str, value_start)
				if font_size_str.is_valid_float():
					result.font_size = font_size_str.to_float()
				current_pos = value_start + font_size_str.length()

			"FontSet":
				value_start = _skip_whitespace(engine_str, tag_end)
				if value_start < engine_str.length() and engine_str[value_start] == "[":
					var array_end: int = _find_matching_bracket(engine_str, value_start, "[", "]")
					if array_end != -1:
						var font_array: String = engine_str.substr(value_start, array_end - value_start + 1)
						result.font_name = _extract_first_font_name(font_array)
						current_pos = array_end + 1
					else:
						current_pos = value_start + 1
				else:
					current_pos = tag_end + 1

			"FillColor":
				value_start = _skip_whitespace(engine_str, tag_end)
				if value_start < engine_str.length() and engine_str[value_start] == "<":
					var dict_end: int = _find_matching_double_angle(engine_str, value_start)
					if dict_end != -1:
						var color_dict: String = engine_str.substr(value_start, dict_end - value_start + 1)
						result.font_color = _parse_fill_color(color_dict)
						current_pos = dict_end + 1
					else:
						current_pos = value_start + 1
				else:
					current_pos = tag_end + 1

			"FauxBold":
				value_start = _skip_whitespace(engine_str, tag_end)
				var bold_str: String = _extract_token(engine_str, value_start)
				result.faux_bold = (bold_str == "true")
				current_pos = value_start + bold_str.length()

			"FauxItalic":
				value_start = _skip_whitespace(engine_str, tag_end)
				var italic_str: String = _extract_token(engine_str, value_start)
				result.faux_italic = (italic_str == "true")
				current_pos = value_start + italic_str.length()

			"Alignment":
				value_start = _skip_whitespace(engine_str, tag_end)
				var align_str: String = _extract_number_string(engine_str, value_start)
				if align_str.is_valid_int():
					result.alignment = align_str.to_int()
				current_pos = value_start + align_str.length()

			"Leading":
				value_start = _skip_whitespace(engine_str, tag_end)
				var lead_str: String = _extract_number_string(engine_str, value_start)
				if lead_str.is_valid_float():
					result.leading = lead_str.to_float()
				current_pos = value_start + lead_str.length()

			"Tracking":
				value_start = _skip_whitespace(engine_str, tag_end)
				var track_str: String = _extract_number_string(engine_str, value_start)
				if track_str.is_valid_float():
					result.tracking = track_str.to_float()
				current_pos = value_start + track_str.length()

			_:
				value_start = _skip_whitespace(engine_str, tag_end)
				if value_start < engine_str.length():
					current_pos = _skip_value(engine_str, value_start)
				else:
					current_pos = tag_end + 1

		if current_pos <= tag_start:
			current_pos = tag_end + 1

## 从 FontSet 数组中提取第一个字体名称。
static func _extract_first_font_name(font_array: String) -> String:
	var name_start: int = font_array.find("/Name")
	if name_start == -1:
		return ""
	name_start += 5
	name_start = _skip_whitespace(font_array, name_start)
	if name_start < font_array.length() and font_array[name_start] == "(":
		var paren_close: int = _find_matching_paren(font_array, name_start)
		if paren_close != -1:
			return _decode_ps_string(font_array.substr(name_start + 1, paren_close - name_start - 1))
	return ""

## 解析 FillColor 字典为 Godot Color。
static func _parse_fill_color(color_dict: String) -> Color:
	var values_start: int = color_dict.find("/Values")
	if values_start == -1:
		return Color.WHITE
	values_start = _skip_whitespace(color_dict, values_start + 7)
	if values_start >= color_dict.length() or color_dict[values_start] != "[":
		return Color.WHITE
	var bracket_close: int = _find_matching_bracket(color_dict, values_start, "[", "]")
	if bracket_close == -1:
		return Color.WHITE
	var values_str: String = color_dict.substr(values_start + 1, bracket_close - values_start - 1)
	var parts: PackedStringArray = values_str.split(" ", false)
	if parts.size() >= 4:
		return Color(_safe_float(parts[0]), _safe_float(parts[1]), _safe_float(parts[2]), _safe_float(parts[3]))
	elif parts.size() >= 3:
		return Color(_safe_float(parts[0]), _safe_float(parts[1]), _safe_float(parts[2]))
	return Color.WHITE

#endregion

#region Descriptor Helpers

## 跳过描述符名称（4 字节长度 + UTF-16BE 字符串）。
## [param end_pos] TySh 块结束位置，用于边界检查。传 -1 表示不检查。
static func _skip_descriptor_name(reader, end_pos: int = -1) -> void:
	if end_pos > 0 and reader.get_position() + 4 > end_pos:
		reader.seek(end_pos)
		return
	var len_val: int = reader.get_u32()
	if len_val > 0:
		if end_pos > 0 and reader.get_position() + len_val > end_pos:
			reader.seek(end_pos)
			return
		reader.skip(len_val)

## 读取 UTF-16BE Unicode 描述符字符串。
## [param end_pos] TySh 块结束位置，用于边界检查。传 -1 表示不检查。
static func _read_unicode_string(reader, end_pos: int = -1) -> String:
	if end_pos > 0 and reader.get_position() + 4 > end_pos:
		reader.seek(end_pos)
		return ""
	var len_val: int = reader.get_u32()
	if len_val == 0:
		return ""
	if end_pos > 0 and reader.get_position() + len_val > end_pos:
		reader.seek(end_pos)
		return ""
	var raw_bytes: PackedByteArray = reader.get_buffer(len_val)
	return raw_bytes.get_string_from_utf16()

## 跳过描述符值（根据 OSType 类型）。
## [param end_pos] TySh 块结束位置，用于边界检查。传 -1 表示不检查。
static func _skip_descriptor_value(reader, type_id: String, end_pos: int = -1) -> void:
	# 边界检查：任何分支至少需要 1 字节
	if end_pos > 0 and reader.get_position() >= end_pos:
		reader.seek(end_pos)
		return
	match type_id:
		"long": 
			if end_pos > 0 and reader.get_position() + 4 > end_pos: reader.seek(end_pos); return
			reader.skip(4)
		"comp": 
			if end_pos > 0 and reader.get_position() + 8 > end_pos: reader.seek(end_pos); return
			reader.skip(8)
		"doub": 
			if end_pos > 0 and reader.get_position() + 8 > end_pos: reader.seek(end_pos); return
			reader.skip(8)
		"bool": 
			if end_pos > 0 and reader.get_position() + 1 > end_pos: reader.seek(end_pos); return
			reader.skip(1)
		"TEXT": _read_unicode_string(reader, end_pos)
		"enum":
			_skip_descriptor_name(reader, end_pos)
			_skip_descriptor_name(reader, end_pos)
		"UntF":
			if end_pos > 0 and reader.get_position() + 12 > end_pos: reader.seek(end_pos); return
			reader.skip(4)
			reader.skip(8)
		"Objc", "GlbO":
			_skip_descriptor_name(reader, end_pos)
			if end_pos > 0 and reader.get_position() + 4 > end_pos: reader.seek(end_pos); return
			reader.skip(4)
			if end_pos > 0 and reader.get_position() + 4 > end_pos: reader.seek(end_pos); return
			var item_count: int = reader.get_u32()
			for _i in range(item_count):
				if end_pos > 0 and reader.get_position() >= end_pos:
					break
				_skip_descriptor_key_value(reader, end_pos)
		"VlLs":
			if end_pos > 0 and reader.get_position() + 4 > end_pos: reader.seek(end_pos); return
			var list_count: int = reader.get_u32()
			var list_type: String = reader.get_ascii(4)
			for _i in range(list_count):
				if end_pos > 0 and reader.get_position() >= end_pos:
					break
				_skip_descriptor_value(reader, list_type, end_pos)
		"alis":
			if end_pos > 0 and reader.get_position() + 4 > end_pos: reader.seek(end_pos); return
			var alias_len: int = reader.get_u32()
			if end_pos > 0 and reader.get_position() + alias_len > end_pos:
				alias_len = end_pos - reader.get_position()
			reader.skip(alias_len)
		"tdta":
			if end_pos > 0 and reader.get_position() + 4 > end_pos: reader.seek(end_pos); return
			var data_len: int = reader.get_u32()
			if end_pos > 0 and reader.get_position() + data_len > end_pos:
				data_len = end_pos - reader.get_position()
			reader.skip(data_len)
		_:
			pass

## 跳过单个描述符键值对。
static func _skip_descriptor_key_value(reader, end_pos: int = -1) -> void:
	if end_pos > 0 and reader.get_position() + 8 > end_pos:
		reader.seek(end_pos)
		return
	_skip_descriptor_name(reader, end_pos)
	var type_id: String = reader.get_ascii(4)
	_skip_descriptor_value(reader, type_id, end_pos)

#endregion

#region String Parsing Helpers

## 跳过空白字符。
static func _skip_whitespace(s: String, pos: int) -> int:
	var p: int = pos
	while p < s.length() and (s[p] == " " or s[p] == "\t" or s[p] == "\n" or s[p] == "\r"):
		p += 1
	return p

## 提取数字字符串。
static func _extract_number_string(s: String, pos: int) -> String:
	var result: String = ""
	var p: int = pos
	if p < s.length() and s[p] == "-":
		result += "-"
		p += 1
	while p < s.length() and (s[p].is_valid_int() or s[p] == "."):
		result += s[p]
		p += 1
	return result

## 提取一般 token。
static func _extract_token(s: String, pos: int) -> String:
	var result: String = ""
	var p: int = pos
	while p < s.length() and not (s[p] == " " or s[p] == "\t" or s[p] == "\n" or s[p] == "\r" or s[p] == ">"):
		result += s[p]
		p += 1
	return result

## 查找匹配的括号。
static func _find_matching_bracket(s: String, start: int, open_ch: String, close_ch: String) -> int:
	var depth: int = 1
	var pos: int = start + 1
	while pos < s.length() and depth > 0:
		if s[pos] == open_ch:
			depth += 1
		elif s[pos] == close_ch:
			depth -= 1
			if depth == 0:
				return pos
		pos += 1
	return -1

## 查找匹配的 >> 结束位置。
static func _find_matching_double_angle(s: String, start: int) -> int:
	var depth: int = 1
	var pos: int = start + 1
	while pos < s.length() - 1 and depth > 0:
		if s[pos] == "<" and s[pos + 1] == "<":
			depth += 1
			pos += 2
			continue
		elif s[pos] == ">" and s[pos + 1] == ">":
			depth -= 1
			if depth == 0:
				return pos + 1
			pos += 2
			continue
		pos += 1
	return -1

## 查找匹配的圆括号。
static func _find_matching_paren(s: String, start: int) -> int:
	return _find_matching_bracket(s, start, "(", ")")

## 解码 PS 风格的字符串（处理转义）。
static func _decode_ps_string(raw: String) -> String:
	var result: String = ""
	var pos: int = 0
	while pos < raw.length():
		if raw[pos] == "\\":
			pos += 1
			if pos >= raw.length():
				break
			match raw[pos]:
				"n": result += "\n"
				"r": result += "\r"
				"t": result += "\t"
				"(": result += "("
				")": result += ")"
				"\\": result += "\\"
				_:
					if raw[pos] == "x" and pos + 2 < raw.length():
						var hex_str: String = raw.substr(pos + 1, 2)
						if hex_str.is_valid_hex_number():
							result += char(hex_str.hex_to_int())
							pos += 2
					else:
						result += raw[pos]
		elif raw[pos] == char(0xFE) and pos + 1 < raw.length() and raw[pos + 1] == char(0xFF):
			# UTF-16BE BOM，跳过
			pos += 2
			continue
		else:
			result += raw[pos]
		pos += 1
	return result

## 安全转换字符串为 float。
static func _safe_float(s: String) -> float:
	var cleaned: String = s.strip_edges()
	if cleaned.is_valid_float():
		return cleaned.to_float()
	return 0.0

## 跳过值。
static func _skip_value(s: String, pos: int) -> int:
	var p: int = pos
	if p >= s.length():
		return p
	var ch: String = s[p]
	if ch == "<" and p + 1 < s.length() and s[p + 1] == "<":
		var end_pos: int = _find_matching_double_angle(s, p)
		return end_pos + 1 if end_pos != -1 else p + 1
	elif ch == "[":
		var bracket_end: int = _find_matching_bracket(s, p, "[", "]")
		return bracket_end + 1 if bracket_end != -1 else p + 1
	elif ch == "(":
		var paren_end: int = _find_matching_paren(s, p)
		return paren_end + 1 if paren_end != -1 else p + 1
	else:
		var token: String = _extract_token(s, p)
		return _skip_whitespace(s, p + token.length())

#endregion
