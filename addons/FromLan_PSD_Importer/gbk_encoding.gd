class_name GBKEncoding
extends RefCounted

## GBK encoding converter.
## Translates GBK byte sequences into Godot UTF-16 strings using a built-in lookup table.

static var gbk_to_unicode_map: Dictionary = {} # PackedByteArray -> PackedByteArray

## Convert a GBK byte buffer to a Godot string.
static func get_string_from_gbk(buffer: PackedByteArray) -> String:
	if gbk_to_unicode_map.size() == 0:
		_load_map()
	var unicode_sequence: PackedByteArray = []
	var index := 0
	while index < buffer.size():
		var header := buffer[index]
		if header < 127:
			unicode_sequence.append(header)
			unicode_sequence.append(0)
			index += 1
		elif index + 1 >= buffer.size():
			# Lone trailing byte > 127, can't form a complete GBK code point; skip
			print_rich("[color=dim_gray]  GBK: lone high byte 0x%x at end of layer name, skipping[/color]" % header)
			index += 1
		else:
			var gbk_code_point := PackedByteArray([buffer[index], buffer[index + 1]])
			if gbk_to_unicode_map.has(gbk_code_point):
				unicode_sequence.append_array(gbk_to_unicode_map[gbk_code_point])
			else:
				print_rich("[color=dim_gray]  GBK: %s is not a valid code point, skipping[/color]" % gbk_code_point)
			index += 2
	return unicode_sequence.get_string_from_utf16()

## Load GBK -> UTF-16 mapping from plugin resource.
static func _load_map() -> void:
	var file := FileAccess.open("res://addons/FromLan_PSD_Importer/gbk_to_utf16.bytes", FileAccess.READ)
	while file.get_position() != file.get_length():
		gbk_to_unicode_map.get_or_add(file.get_buffer(2), file.get_buffer(2))
